#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Picks between an Ingress and a Gateway API HTTPRoute. EXPOSE_MODE wins when
# set; otherwise the cluster decides, and the user is asked only when the
# cluster genuinely offers both.
resolve_expose_mode() {
    if [ -n "$EXPOSE_MODE" ]; then
        print_info "Expose mode set explicitly: $EXPOSE_MODE"
        return 0
    fi

    case "$(detect_expose_mode)" in
        ingress)
            EXPOSE_MODE="ingress"
            print_success "Detected an IngressClass and no gateway; exposing authentik with an Ingress"
            ;;
        gateway)
            EXPOSE_MODE="gateway"
            print_success "Detected a Gateway API gateway and no IngressClass; exposing authentik with an HTTPRoute"
            ;;
        both)
            print_info "This cluster has both an IngressClass and a Gateway API gateway:"
            kubectl get ingressclass --no-headers 2>/dev/null | awk '{print "    ingress class: " $1}'
            detect_gateways | sed 's/^/    gateway:       /'
            if [ -t 0 ] && [ -z "$AUTHENTIK_FORCE" ]; then
                echo ""
                echo "  1) Ingress"
                echo "  2) Gateway API HTTPRoute"
                local choice
                read -r -p "Choose 1 or 2 [1]: " choice
                if [ "$choice" = "2" ]; then
                    EXPOSE_MODE="gateway"
                else
                    EXPOSE_MODE="ingress"
                fi
            else
                EXPOSE_MODE="ingress"
                print_info "Defaulting to Ingress; set EXPOSE_MODE=gateway to use the gateway instead"
            fi
            ;;
        *)
            EXPOSE_MODE="ingress"
            print_warning "Found neither an IngressClass nor a Gateway API gateway"
            ;;
    esac
}

resolve_gateway() {
    if [ -z "$GATEWAY_NAME" ] || [ -z "$GATEWAY_NAMESPACE" ]; then
        local found count
        found="$(detect_gateways)"
        count=$(printf '%s\n' "$found" | grep -c . || true)

        if [ "$count" -eq 0 ]; then
            print_error "No Gateway API gateway found on this cluster"
            print_info "Set GATEWAY_NAME and GATEWAY_NAMESPACE, or use EXPOSE_MODE=ingress"
            exit 1
        elif [ "$count" -eq 1 ]; then
            GATEWAY_NAMESPACE="${found%%/*}"
            GATEWAY_NAME="${found##*/}"
            print_info "Using the only gateway on the cluster: $GATEWAY_NAMESPACE/$GATEWAY_NAME"
        elif [ -t 0 ] && [ -z "$AUTHENTIK_FORCE" ]; then
            print_info "Multiple gateways found:"
            printf '%s\n' "$found" | nl -w4 -s') '
            local pick selected
            read -r -p "Choose a gateway by number: " pick
            selected=$(printf '%s\n' "$found" | sed -n "${pick}p")
            if [ -z "$selected" ]; then
                print_error "Invalid selection"
                exit 1
            fi
            GATEWAY_NAMESPACE="${selected%%/*}"
            GATEWAY_NAME="${selected##*/}"
        else
            print_error "Multiple gateways found; set GATEWAY_NAME and GATEWAY_NAMESPACE"
            printf '%s\n' "$found" | sed 's/^/    /'
            exit 1
        fi
    fi

    if ! kubectl -n "$GATEWAY_NAMESPACE" get gateway "$GATEWAY_NAME" >/dev/null 2>&1; then
        print_error "Gateway '$GATEWAY_NAME' not found in namespace '$GATEWAY_NAMESPACE'"
        exit 1
    fi

    if ! gateway_allows_other_namespaces "$GATEWAY_NAMESPACE" "$GATEWAY_NAME"; then
        print_warning "No listener on $GATEWAY_NAMESPACE/$GATEWAY_NAME accepts routes from other namespaces"
        print_info "The HTTPRoute will likely be rejected; check the gateway's allowedRoutes"
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

    resolve_expose_mode

    if [ "$EXPOSE_MODE" = "gateway" ]; then
        resolve_gateway
    fi

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

    if [ "$EXPOSE_MODE" = "gateway" ]; then
        # The gateway listener terminates TLS with its own certificate.
        TLS_MODE="gateway"
        TLS_SECRET_NAME=""
    elif [ -n "$AUTHENTIK_SKIP_TLS" ]; then
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

    local scheme="https"
    if [ "$TLS_MODE" = "none" ]; then
        scheme="http"
        TLS_SECRET_NAME=""
    elif [ "$TLS_MODE" = "selfsigned" ]; then
        TLS_SECRET_NAME="${AUTHENTIK_HOSTNAME}-tls"
    elif [ "$TLS_MODE" = "existing" ]; then
        TLS_SECRET_NAME="${TLS_SECRET_NAME:-authentik-tls}"
    fi

    # A URL path prefix lets authentik share a hostname with something else,
    # which is the only option when the one trusted certificate belongs to that
    # hostname. authentik is told about it via AUTHENTIK_WEB__PATH and then
    # expects the prefix on every request, internal ones included.
    URL_PATH_BASE="${AUTHENTIK_URL_PATH%/}"
    case "$URL_PATH_BASE" in
        ""|/) URL_PATH_BASE="" ;;
        /*) ;;
        *) URL_PATH_BASE="/$URL_PATH_BASE" ;;
    esac
    if [ -n "$URL_PATH_BASE" ]; then
        URL_PATH="$URL_PATH_BASE"
        WEB_PATH="${URL_PATH_BASE}/"
    else
        URL_PATH="/"
        WEB_PATH="/"
    fi

    PUBLIC_URL="${scheme}://${AUTHENTIK_HOSTNAME}${URL_PATH_BASE}"

    # authentik's own "base URL" setting is deliberately scheme + host only; it
    # combines that with AUTHENTIK_WEB__PATH itself, so the prefix is left out.
    BASE_URL="${scheme}://${AUTHENTIK_HOSTNAME}"

    # The chart names the server service <fullname>-server.
    INTERNAL_URL="http://${HELM_RELEASE}-server.${NAMESPACE}.svc.cluster.local${URL_PATH_BASE}"

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
    if [ "$EXPOSE_MODE" = "gateway" ]; then
        print_info "Expose:        gateway ($GATEWAY_NAMESPACE/$GATEWAY_NAME, path $URL_PATH)"
    else
        print_info "Expose:        $EXPOSE_MODE ${INGRESS_CLASS:+(class $INGRESS_CLASS)}"
    fi
    print_info "TLS:           $TLS_MODE ${TLS_SECRET_NAME:+($TLS_SECRET_NAME)}"
    print_info "Postgres:      bundled ($([ "$USE_PVC" = true ] && echo PVC || echo "no PVC"))"
    print_info "Admin user:    akadmin ($ADMIN_EMAIL)"
}

ensure_tls_secret() {
    if [ "$TLS_MODE" = "none" ]; then
        return 0
    fi

    if [ "$TLS_MODE" = "gateway" ]; then
        print_section "TLS"
        print_info "TLS is terminated by gateway '$GATEWAY_NAMESPACE/$GATEWAY_NAME'; no secret needed here"
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
    # That also means authentik.* Helm values are ignored, so AUTHENTIK_WEB__PATH
    # has to be set here rather than through the chart.
    kubectl -n "$NAMESPACE" create secret generic authentik-admin \
        --from-literal=AUTHENTIK_WEB__PATH="$WEB_PATH" \
        --from-literal=AUTHENTIK_WEB__BASE_URL="$BASE_URL" \
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
        --from-literal=AK_BASE_URL="$BASE_URL" \
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
        --from-literal=URL_PATH="$URL_PATH" \
        --from-literal=GATEWAY_NAME="${GATEWAY_NAME:-}" \
        --from-literal=GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-}" \
        --from-literal=HELM_RELEASE="$HELM_RELEASE" \
        --from-literal=PLACEHOLDER_RUNAI_CTRL_PLANE_URL="$PLACEHOLDER_RUNAI_CTRL_PLANE_URL" \
        --dry-run=client -o yaml | kubectl apply -f -

    if [ ! -f "$SCRIPT_DIR/realm.json" ]; then
        print_error "Shared realm.json not found at $SCRIPT_DIR/realm.json"
        exit 1
    fi

    # realm.json carries the users and groups only; the providers and claim
    # mappings are built by the seed script against authentik's own API.
    kubectl -n "$NAMESPACE" create configmap authentik-seed-data \
        --from-file=realm.json="$SCRIPT_DIR/realm.json" \
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

    case "$EXPOSE_MODE" in
        loadbalancer) service_type="LoadBalancer" ;;
        gateway) ;;  # ClusterIP; an HTTPRoute fronts it
        *) ingress_enabled="true" ;;
    esac

    cat > "$dest" <<EOF
global:
  security:
    allowInsecureImages: true
authentik:
  existingSecret:
    secretName: authentik-admin
  web:
    path: ${WEB_PATH}
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

    # Download the chart before installing. Passing a bare chart name with --repo
    # makes Helm resolve it as a local path first, which collides with this
    # directory being named 'authentik'.
    local chart_dir chart_tgz
    chart_dir=$(mktemp -d)
    print_info "Fetching chart $AUTHENTIK_CHART $AUTHENTIK_CHART_VERSION from $AUTHENTIK_CHART_REPO"
    if ! helm pull "$AUTHENTIK_CHART" \
        --repo "$AUTHENTIK_CHART_REPO" \
        --version "$AUTHENTIK_CHART_VERSION" \
        --destination "$chart_dir"; then
        print_error "Failed to download the authentik Helm chart"
        rm -rf "$chart_dir" "$values_file"
        exit 1
    fi
    chart_tgz="$chart_dir/${AUTHENTIK_CHART}-${AUTHENTIK_CHART_VERSION}.tgz"

    print_info "Installing release '$HELM_RELEASE'"
    if ! helm upgrade --install "$HELM_RELEASE" "$chart_tgz" \
        --namespace "$NAMESPACE" \
        --values "$values_file" \
        --wait \
        --timeout 15m; then
        print_error "Helm install failed"
        helm status "$HELM_RELEASE" -n "$NAMESPACE" || true
        kubectl -n "$NAMESPACE" get pods || true
        rm -rf "$chart_dir" "$values_file"
        exit 1
    fi
    rm -rf "$chart_dir" "$values_file"

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
    elif [ "$EXPOSE_MODE" = "gateway" ]; then
        print_info "Exposure is handled by an HTTPRoute (applied next)"
    else
        print_success "Ingress is managed by the Helm chart for host $AUTHENTIK_HOSTNAME"
    fi
}

expose_via_gateway() {
    if [ "$EXPOSE_MODE" != "gateway" ]; then
        return 0
    fi

    print_section "HTTPRoute"

    apply_rendered "$SCRIPT_DIR/manifests/httproute.yaml"

    local accepted=""
    local waited=0
    while [ $waited -lt 60 ]; do
        accepted=$(kubectl -n "$NAMESPACE" get httproute authentik-httproute \
            -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
        if [ -n "$accepted" ]; then
            break
        fi
        sleep 3
        waited=$((waited + 3))
    done

    if [ "$accepted" = "True" ]; then
        print_success "HTTPRoute accepted by $GATEWAY_NAMESPACE/$GATEWAY_NAME"
    else
        print_warning "HTTPRoute not reported as Accepted yet. Check with:"
        print_info "kubectl -n $NAMESPACE describe httproute authentik-httproute"
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
    print_info "authentik URL:    $PUBLIC_URL/"
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
    echo "  ./integrate.sh"
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
    expose_via_gateway
    seed_authentik
    display_summary
}

main
