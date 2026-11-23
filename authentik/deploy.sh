#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

prompt_if_empty() {
    local varname="$1"
    local prompt="$2"
    local default="$3"
    local silent="${4:-false}"
    local current="${!varname}"

    if [ -n "$current" ]; then
        return 0
    fi

    if [ ! -t 0 ]; then
        if [ -n "$default" ]; then
            printf -v "$varname" '%s' "$default"
            return 0
        fi
        print_error "$varname is required in non-interactive mode"
        exit 1
    fi

    local reply
    if [ "$silent" = "true" ]; then
        read -r -s -p "$prompt" reply
        echo
    else
        read -r -p "$prompt" reply
    fi
    if [ -z "$reply" ]; then
        reply="$default"
    fi
    printf -v "$varname" '%s' "$reply"
}

create_namespace() {
    print_section "Namespace"
    if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        print_info "Namespace '$NAMESPACE' already exists"
    else
        kubectl create namespace "$NAMESPACE"
        print_success "Created namespace '$NAMESPACE'"
    fi
}

collect_settings() {
    print_section "Standalone authentik Settings"

    NAMESPACE="${AUTHENTIK_NAMESPACE:-$DEFAULT_NAMESPACE}"

    prompt_if_empty AUTHENTIK_HOSTNAME "authentik hostname (e.g. authentik.example.com): "
    AUTHENTIK_HOSTNAME="$(strip_host "$AUTHENTIK_HOSTNAME")"
    if [ -z "$AUTHENTIK_HOSTNAME" ]; then
        print_error "AUTHENTIK_HOSTNAME is required"
        exit 1
    fi

    ADMIN_EMAIL="${AUTHENTIK_ADMIN_EMAIL:-$DEFAULT_ADMIN_EMAIL}"

    EXPOSE_MODE="${EXPOSE_MODE:-ingress}"
    if [ -z "$INGRESS_CLASS" ] && [ "$EXPOSE_MODE" = "ingress" ]; then
        INGRESS_CLASS="$(detect_ingress_class || true)"
    fi

    if [ "$EXPOSE_MODE" = "ingress" ] && [ -z "$INGRESS_CLASS" ]; then
        print_warning "No IngressClass found on this cluster"
        if [ -t 0 ] && [ -z "$AUTHENTIK_FORCE" ]; then
            echo "  1) Continue with Ingress anyway (cluster default class)"
            echo "  2) Expose authentik via LoadBalancer service (HTTP)"
            local choice
            read -r -p "Choose 1 or 2 [1]: " choice
            if [ "$choice" = "2" ]; then
                EXPOSE_MODE="loadbalancer"
            fi
        else
            print_info "Falling back to LoadBalancer exposure"
            EXPOSE_MODE="loadbalancer"
        fi
    fi

    if [ -n "$AUTHENTIK_SKIP_TLS" ]; then
        TLS_MODE="none"
    elif [ -n "$AUTHENTIK_TLS_SECRET" ]; then
        TLS_MODE="existing"
        TLS_SECRET_NAME="$AUTHENTIK_TLS_SECRET"
    elif [ "$EXPOSE_MODE" = "loadbalancer" ]; then
        TLS_MODE="none"
        print_warning "LoadBalancer mode serves HTTP only. Set AUTHENTIK_SKIP_TLS=true to silence this."
    elif [ -t 0 ] && [ -z "$AUTHENTIK_TLS_MODE" ]; then
        echo ""
        print_info "TLS for the authentik Ingress:"
        echo "  1) Use an existing TLS secret"
        echo "  2) Generate a self-signed certificate (lab only; Run:AI must trust it)"
        echo "  3) No TLS (HTTP)"
        local tls_choice
        read -r -p "Choose 1, 2, or 3 [2]: " tls_choice
        case "$tls_choice" in
            1) TLS_MODE="existing" ;;
            3) TLS_MODE="none" ;;
            *) TLS_MODE="selfsigned" ;;
        esac
    else
        TLS_MODE="${AUTHENTIK_TLS_MODE:-selfsigned}"
    fi

    if [ "$TLS_MODE" = "existing" ] && [ -z "$TLS_SECRET_NAME" ]; then
        prompt_if_empty TLS_SECRET_NAME "TLS secret name: "
        prompt_if_empty AUTHENTIK_TLS_SECRET_NAMESPACE "Namespace of that secret [${NAMESPACE}]: " "$NAMESPACE"
    fi

    if [ "$TLS_MODE" = "none" ]; then
        PUBLIC_URL="http://${AUTHENTIK_HOSTNAME}"
        TLS_SECRET_NAME=""
    else
        PUBLIC_URL="https://${AUTHENTIK_HOSTNAME}"
        if [ "$TLS_MODE" = "selfsigned" ]; then
            TLS_SECRET_NAME="${AUTHENTIK_HOSTNAME}-tls"
        else
            TLS_SECRET_NAME="${TLS_SECRET_NAME:-authentik-tls}"
        fi
    fi

    # The chart names the server service <fullname>-server.
    INTERNAL_URL="http://${HELM_RELEASE}-server.${NAMESPACE}.svc.cluster.local"

    if [ -n "$AUTHENTIK_USE_EMPTYDIR" ]; then
        USE_PVC=false
    elif has_default_storage_class || [ -n "$AUTHENTIK_STORAGE_CLASS" ]; then
        USE_PVC=true
    else
        USE_PVC=false
        print_warning "No default StorageClass found; bundled PostgreSQL will run without a PVC"
    fi

    echo ""
    print_info "Namespace:     $NAMESPACE"
    print_info "Helm chart:    $AUTHENTIK_CHART $AUTHENTIK_CHART_VERSION ($AUTHENTIK_CHART_REPO)"
    print_info "Hostname:      $AUTHENTIK_HOSTNAME"
    print_info "Public URL:    $PUBLIC_URL"
    print_info "Internal URL:  $INTERNAL_URL"
    print_info "Expose:        $EXPOSE_MODE ${INGRESS_CLASS:+(class $INGRESS_CLASS)}"
    print_info "TLS:           $TLS_MODE ${TLS_SECRET_NAME:+($TLS_SECRET_NAME)}"
    print_info "Postgres:      bundled ($([ "$USE_PVC" = true ] && echo PVC || echo "no PVC"))"
    print_info "Admin user:    akadmin ($ADMIN_EMAIL)"
}

ensure_tls_secret() {
    if [ "$TLS_MODE" = "none" ]; then
        return 0
    fi

    print_section "TLS Secret"

    if [ "$TLS_MODE" = "selfsigned" ]; then
        if kubectl -n "$NAMESPACE" get secret "$TLS_SECRET_NAME" >/dev/null 2>&1; then
            print_info "Reusing existing self-signed secret '$TLS_SECRET_NAME'"
            return 0
        fi
        if ! command_exists openssl; then
            print_error "openssl is required to generate a self-signed certificate"
            print_info "Install openssl, pass AUTHENTIK_TLS_SECRET=<name>, or set AUTHENTIK_SKIP_TLS=true"
            exit 1
        fi
        # Unlike the Bitnami Keycloak chart, the authentik chart has no
        # self-signed certificate helper, so generate one here.
        local tmp
        tmp=$(mktemp -d)
        openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
            -keyout "$tmp/tls.key" -out "$tmp/tls.crt" \
            -subj "/CN=${AUTHENTIK_HOSTNAME}" \
            -addext "subjectAltName=DNS:${AUTHENTIK_HOSTNAME}" >/dev/null 2>&1
        kubectl -n "$NAMESPACE" create secret tls "$TLS_SECRET_NAME" \
            --cert="$tmp/tls.crt" --key="$tmp/tls.key" \
            --dry-run=client -o yaml | kubectl apply -f -
        rm -rf "$tmp"
        print_success "Generated self-signed certificate for $AUTHENTIK_HOSTNAME"
        print_warning "A remote Run:AI control plane will not trust this cert unless you install it there"
        return 0
    fi

    local src_ns="${AUTHENTIK_TLS_SECRET_NAMESPACE:-$NAMESPACE}"
    if [ "$src_ns" != "$NAMESPACE" ]; then
        print_info "Copying TLS secret '$TLS_SECRET_NAME' from namespace '$src_ns'"
        kubectl -n "$src_ns" get secret "$TLS_SECRET_NAME" -o json \
            | jq --arg ns "$NAMESPACE" --arg name "$TLS_SECRET_NAME" '
                .metadata = {name: $name, namespace: $ns, labels: (.metadata.labels // {})}
                | del(.metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid, .metadata.ownerReferences)
              ' \
            | kubectl apply -f -
    elif ! kubectl -n "$NAMESPACE" get secret "$TLS_SECRET_NAME" >/dev/null 2>&1; then
        print_error "TLS secret '$TLS_SECRET_NAME' not found in namespace '$NAMESPACE'"
        exit 1
    fi
    print_success "Using TLS secret '$TLS_SECRET_NAME'"
}

create_secrets() {
    print_section "Secrets"

    # Generated values must survive a re-deploy: PostgreSQL keeps the password
    # it was initialised with, and changing secret_key invalidates sessions.
    local existing_pg existing_secret_key existing_token existing_password
    existing_pg="$(get_secret_value authentik-postgresql password || true)"
    existing_secret_key="$(get_secret_value authentik-admin AUTHENTIK_SECRET_KEY || true)"
    existing_token="$(get_secret_value authentik-admin AUTHENTIK_BOOTSTRAP_TOKEN || true)"
    existing_password="$(get_secret_value authentik-admin AUTHENTIK_BOOTSTRAP_PASSWORD || true)"

    PG_PASSWORD="${existing_pg:-$(random_secret 24)}"
    SECRET_KEY="${existing_secret_key:-$(random_secret 50)}"
    AK_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN:-${existing_token:-$(random_secret 32)}}"
    ADMIN_PASSWORD="${AUTHENTIK_ADMIN_PASSWORD:-${existing_password:-$(random_secret 12)}}"

    if [ -n "$existing_pg" ]; then
        print_info "Reusing the existing PostgreSQL password and secret key"
    fi

    kubectl -n "$NAMESPACE" create secret generic authentik-postgresql \
        --from-literal=password="$PG_PASSWORD" \
        --from-literal=postgres-password="$PG_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -
    print_success "Applied PostgreSQL secret"

    # Consumed by the chart via authentik.existingSecret.secretName, which
    # mounts it with envFrom, so the keys are the full AUTHENTIK_* env names.
    kubectl -n "$NAMESPACE" create secret generic authentik-admin \
        --from-literal=AUTHENTIK_SECRET_KEY="$SECRET_KEY" \
        --from-literal=AUTHENTIK_BOOTSTRAP_PASSWORD="$ADMIN_PASSWORD" \
        --from-literal=AUTHENTIK_BOOTSTRAP_TOKEN="$AK_TOKEN" \
        --from-literal=AUTHENTIK_BOOTSTRAP_EMAIL="$ADMIN_EMAIL" \
        --from-literal=AUTHENTIK_POSTGRESQL__HOST="${HELM_RELEASE}-postgresql" \
        --from-literal=AUTHENTIK_POSTGRESQL__NAME="authentik" \
        --from-literal=AUTHENTIK_POSTGRESQL__USER="authentik" \
        --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="$PG_PASSWORD" \
        --from-literal=AUTHENTIK_POSTGRESQL__PORT="5432" \
        --from-literal=AUTHENTIK_ERROR_REPORTING__ENABLED="false" \
        --from-literal=AUTHENTIK_DISABLE_UPDATE_CHECK="true" \
        --from-literal=AUTHENTIK_DISABLE_STARTUP_ANALYTICS="true" \
        --from-literal=AUTHENTIK_LOG_LEVEL="info" \
        --dry-run=client -o yaml | kubectl apply -f -
    print_success "Applied authentik config secret (bootstrap admin + API token)"

    local runai_url="$PLACEHOLDER_RUNAI_CTRL_PLANE_URL"
    local runai_user="placeholder"
    local runai_pass="placeholder"
    local runai_type="OIDC"
    if resource_exists secret runai-ctrl-plane-data; then
        local stored_url
        stored_url="$(get_secret_value runai-ctrl-plane-data RUNAI_CTRL_PLANE_URL)"
        if ! is_placeholder_url "$stored_url"; then
            runai_url="$stored_url"
            runai_user="$(get_secret_value runai-ctrl-plane-data RUNAI_ADMIN_USERNAME)"
            runai_pass="$(get_secret_value runai-ctrl-plane-data RUNAI_ADMIN_PASSWORD)"
            runai_type="$(get_secret_value runai-ctrl-plane-data RUNAI_IDP_TYPE)"
            print_info "Preserving existing Run:AI control plane settings"
        fi
    fi

    kubectl -n "$NAMESPACE" create secret generic runai-ctrl-plane-data \
        --from-literal=AK_TOKEN="$AK_TOKEN" \
        --from-literal=AK_HOSTNAME="$PUBLIC_URL" \
        --from-literal=AK_PUBLIC_URL="$PUBLIC_URL" \
        --from-literal=OIDC_APP_SLUG="$OIDC_APP_SLUG" \
        --from-literal=SAML_APP_SLUG="$SAML_APP_SLUG" \
        --from-literal=OIDC_CLIENT_ID="$OIDC_CLIENT_ID" \
        --from-literal=RUNAI_SCOPE_NAME="$RUNAI_SCOPE_NAME" \
        --from-literal=RUNAI_CTRL_PLANE_URL="$runai_url" \
        --from-literal=RUNAI_ADMIN_USERNAME="$runai_user" \
        --from-literal=RUNAI_ADMIN_PASSWORD="$runai_pass" \
        --from-literal=RUNAI_IDP_TYPE="$runai_type" \
        --dry-run=client -o yaml | kubectl apply -f -
    print_success "Created / updated job secret"
}

create_configmaps() {
    print_section "ConfigMaps"

    kubectl -n "$NAMESPACE" create configmap authentik-idp-config \
        --from-literal=NAMESPACE="$NAMESPACE" \
        --from-literal=AUTHENTIK_HOSTNAME="$AUTHENTIK_HOSTNAME" \
        --from-literal=AUTHENTIK_PUBLIC_URL="$PUBLIC_URL" \
        --from-literal=AUTHENTIK_INTERNAL_URL="$INTERNAL_URL" \
        --from-literal=TLS_SECRET_NAME="${TLS_SECRET_NAME:-}" \
        --from-literal=EXPOSE_MODE="$EXPOSE_MODE" \
        --from-literal=HELM_RELEASE="$HELM_RELEASE" \
        --from-literal=PLACEHOLDER_RUNAI_CTRL_PLANE_URL="$PLACEHOLDER_RUNAI_CTRL_PLANE_URL" \
        --dry-run=client -o yaml | kubectl apply -f -

    if [ ! -f "$REPO_ROOT/realm.json" ]; then
        print_error "Shared realm.json not found at $REPO_ROOT/realm.json"
        exit 1
    fi

    # Users and groups come from the same realm.json both Keycloak paths use;
    # only the client/provider plumbing is authentik-specific.
    kubectl -n "$NAMESPACE" create configmap authentik-seed-data \
        --from-file=realm.json="$REPO_ROOT/realm.json" \
        --dry-run=client -o yaml | kubectl apply -f -

    kubectl -n "$NAMESPACE" create configmap authentik-scripts \
        --from-file=01-url-health-check.sh="$SCRIPT_DIR/scripts/01-url-health-check.sh" \
        --from-file=01-integrate-health-check.sh="$SCRIPT_DIR/scripts/01-integrate-health-check.sh" \
        --from-file=02-authentik-setup.sh="$SCRIPT_DIR/scripts/02-authentik-setup.sh" \
        --from-file=03-runai-setup.sh="$SCRIPT_DIR/scripts/03-runai-setup.sh" \
        --from-file=with-tls-bundle.sh="$SCRIPT_DIR/scripts/with-tls-bundle.sh" \
        --dry-run=client -o yaml | kubectl apply -f -

    print_success "Created ConfigMaps (shared realm.json + setup scripts)"
}

write_helm_values() {
    local dest="$1"
    local service_type="ClusterIP"
    local ingress_enabled="false"

    if [ "$EXPOSE_MODE" = "loadbalancer" ]; then
        service_type="LoadBalancer"
    else
        ingress_enabled="true"
    fi

    cat > "$dest" <<EOF
global:
  security:
    allowInsecureImages: true
authentik:
  existingSecret:
    secretName: authentik-admin
server:
  replicas: 1
  service:
    type: ${service_type}
  ingress:
    enabled: ${ingress_enabled}
EOF

    if [ "$ingress_enabled" = "true" ]; then
        cat >> "$dest" <<EOF
    pathType: Prefix
    hosts:
      - ${AUTHENTIK_HOSTNAME}
EOF
        if [ -n "$INGRESS_CLASS" ]; then
            echo "    ingressClassName: ${INGRESS_CLASS}" >> "$dest"
        fi
        if [ -z "$INGRESS_CLASS" ] || [ "$INGRESS_CLASS" = "nginx" ]; then
            cat >> "$dest" <<EOF
    annotations:
      nginx.ingress.kubernetes.io/proxy-buffer-size: "128k"
      nginx.ingress.kubernetes.io/proxy-body-size: "20m"
EOF
        fi
        if [ -n "$TLS_SECRET_NAME" ]; then
            cat >> "$dest" <<EOF
    tls:
      - hosts:
          - ${AUTHENTIK_HOSTNAME}
        secretName: ${TLS_SECRET_NAME}
EOF
        fi
    fi

    cat >> "$dest" <<EOF
worker:
  replicas: 1
postgresql:
  enabled: true
  auth:
    username: authentik
    database: authentik
    existingSecret: authentik-postgresql
  primary:
    persistence:
EOF

    if [ "$USE_PVC" = true ]; then
        echo "      enabled: true" >> "$dest"
        if [ -n "$AUTHENTIK_STORAGE_CLASS" ]; then
            echo "      storageClass: ${AUTHENTIK_STORAGE_CLASS}" >> "$dest"
        fi
    else
        echo "      enabled: false" >> "$dest"
    fi
}

helm_install_authentik() {
    print_section "Helm: authentik (bundled PostgreSQL)"

    local values_file
    values_file=$(mktemp)
    write_helm_values "$values_file"

    print_info "Installing release '$HELM_RELEASE' from $AUTHENTIK_CHART_REPO"
    if ! helm upgrade --install "$HELM_RELEASE" "$AUTHENTIK_CHART" \
        --repo "$AUTHENTIK_CHART_REPO" \
        --namespace "$NAMESPACE" \
        --version "$AUTHENTIK_CHART_VERSION" \
        --values "$values_file" \
        --wait \
        --timeout 15m; then
        print_error "Helm install failed"
        helm status "$HELM_RELEASE" -n "$NAMESPACE" || true
        kubectl -n "$NAMESPACE" get pods || true
        rm -f "$values_file"
        exit 1
    fi
    rm -f "$values_file"

    print_success "Helm release '$HELM_RELEASE' is installed"
    wait_for_authentik 300s || true

    if [ "$EXPOSE_MODE" = "loadbalancer" ]; then
        print_info "Waiting for LoadBalancer external IP..."
        local ip=""
        local waited=0
        while [ $waited -lt 120 ]; do
            ip=$(kubectl -n "$NAMESPACE" get "svc/${HELM_RELEASE}-server" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
            if [ -z "$ip" ]; then
                ip=$(kubectl -n "$NAMESPACE" get "svc/${HELM_RELEASE}-server" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
            fi
            if [ -n "$ip" ]; then
                break
            fi
            sleep 3
            waited=$((waited + 3))
        done
        if [ -n "$ip" ]; then
            print_success "LoadBalancer address: $ip"
            print_info "Point DNS (or /etc/hosts) for $AUTHENTIK_HOSTNAME at $ip"
        else
            print_warning "LoadBalancer address is not ready yet. Check with:"
            print_info "kubectl -n $NAMESPACE get svc ${HELM_RELEASE}-server"
        fi
    else
        print_success "Ingress is managed by the Helm chart for host $AUTHENTIK_HOSTNAME"
    fi
}

seed_authentik() {
    print_section "Seeding Users, Groups, Mappings and Providers"

    if resource_exists job authentik-idp-seed; then
        print_info "Deleting previous seed job"
        kubectl -n "$NAMESPACE" delete job authentik-idp-seed --timeout=60s
        sleep 2
    fi

    apply_rendered "$SCRIPT_DIR/manifests/job-seed.yaml"
    monitor_job authentik-idp-seed "url-health-check authentik-setup"
}

display_summary() {
    print_section "Standalone authentik is Ready"

    echo ""
    print_success "authentik is deployed and seeded from the shared realm.json."
    echo ""
    print_info "authentik URL:    $PUBLIC_URL"
    print_info "Admin console:    $PUBLIC_URL/if/admin/"
    print_info "Helm release:     $HELM_RELEASE (ns $NAMESPACE)"
    print_info "Admin user:       akadmin"
    print_info "Admin password:   $ADMIN_PASSWORD"
    print_info "API token:        kubectl -n $NAMESPACE get secret authentik-admin -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' | base64 -d"
    echo ""
    print_info "Providers use placeholder control-plane URLs:"
    echo "  $PLACEHOLDER_RUNAI_CTRL_PLANE_URL"
    echo ""
    print_info "Pre-configured users (password: 123456):"
    echo "  • john.doe@acme.zzz (admin-group)"
    echo "  • jane.smith@acme.zzz (developer-group)"
    echo "  • steve.johnson@acme.zzz (read-only-group)"
    echo "  • jacky.fox@acme.zzz (read-only-group)"
    echo "  • blip.blop@acme.zzz (read-only-group)"
    echo ""
    print_info "This instance is independent of any Run:AI control plane."
    print_info "When you have a control plane URL, attach it with:"
    echo "  ./authentik/integrate.sh"
    echo ""
}

main() {
    print_section "Standalone authentik Deployment"
    print_info "Installs authentik via its official Helm chart (PostgreSQL included)"
    print_info "and seeds the shared realm.json with placeholder Run:AI URLs."
    echo ""

    check_prerequisites helm
    collect_settings
    create_namespace
    ensure_tls_secret
    create_secrets
    create_configmaps
    helm_install_authentik
    seed_authentik
    display_summary
}

main
