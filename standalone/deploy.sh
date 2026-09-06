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

generate_password() {
    if command_exists openssl; then
        openssl rand -hex 16
    else
        tr -dc 'a-f0-9' </dev/urandom | head -c 32
    fi
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
    print_section "Standalone Keycloak Settings"

    NAMESPACE="${KEYCLOAK_NAMESPACE:-$DEFAULT_NAMESPACE}"
    GENERATED_ADMIN_PASSWORD=false

    prompt_if_empty KEYCLOAK_HOSTNAME "Keycloak hostname (e.g. keycloak.example.com): "
    KEYCLOAK_HOSTNAME="$(strip_host "$KEYCLOAK_HOSTNAME")"
    if [ -z "$KEYCLOAK_HOSTNAME" ]; then
        print_error "KEYCLOAK_HOSTNAME is required"
        exit 1
    fi

    ADMIN_USER="${KEYCLOAK_ADMIN:-$DEFAULT_ADMIN_USER}"
    if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
        KEYCLOAK_ADMIN_PASSWORD="$(generate_password)"
        GENERATED_ADMIN_PASSWORD=true
    fi

    EXPOSE_MODE="${EXPOSE_MODE:-ingress}"
    if [ -z "$INGRESS_CLASS" ] && [ "$EXPOSE_MODE" = "ingress" ]; then
        INGRESS_CLASS="$(detect_ingress_class || true)"
    fi

    if [ "$EXPOSE_MODE" = "ingress" ] && [ -z "$INGRESS_CLASS" ]; then
        print_warning "No IngressClass found on this cluster"
        if [ -t 0 ] && [ -z "$KEYCLOAK_FORCE" ]; then
            echo "  1) Continue with Ingress anyway (cluster default class)"
            echo "  2) Expose Keycloak via LoadBalancer service (HTTP)"
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

    if [ -n "$KEYCLOAK_SKIP_TLS" ]; then
        TLS_MODE="none"
    elif [ -n "$KEYCLOAK_TLS_SECRET" ]; then
        TLS_MODE="existing"
        TLS_SECRET_NAME="$KEYCLOAK_TLS_SECRET"
    elif [ "$EXPOSE_MODE" = "loadbalancer" ]; then
        TLS_MODE="none"
        print_warning "LoadBalancer mode serves HTTP only. Set KEYCLOAK_SKIP_TLS=true to silence this."
    elif [ -t 0 ] && [ -z "$KEYCLOAK_TLS_MODE" ]; then
        echo ""
        print_info "TLS for the Keycloak Ingress:"
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
        TLS_MODE="${KEYCLOAK_TLS_MODE:-selfsigned}"
    fi

    if [ "$TLS_MODE" = "existing" ] && [ -z "$TLS_SECRET_NAME" ]; then
        prompt_if_empty TLS_SECRET_NAME "TLS secret name: "
        prompt_if_empty KEYCLOAK_TLS_SECRET_NAMESPACE "Namespace of that secret [${NAMESPACE}]: " "$NAMESPACE"
    fi

    if [ "$TLS_MODE" = "none" ]; then
        PUBLIC_URL="http://${KEYCLOAK_HOSTNAME}"
        TLS_SECRET_NAME=""
    else
        PUBLIC_URL="https://${KEYCLOAK_HOSTNAME}"
        TLS_SECRET_NAME="${TLS_SECRET_NAME:-keycloak-tls}"
    fi

    INTERNAL_URL="http://keycloak.${NAMESPACE}.svc.cluster.local"

    if [ -n "$KEYCLOAK_USE_EMPTYDIR" ]; then
        USE_PVC=false
    elif has_default_storage_class || [ -n "$KEYCLOAK_STORAGE_CLASS" ]; then
        USE_PVC=true
    else
        USE_PVC=false
        print_warning "No default StorageClass found; bundled PostgreSQL will run without a PVC"
    fi

    if [ "$TLS_MODE" = "selfsigned" ]; then
        TLS_SECRET_NAME="${KEYCLOAK_HOSTNAME}-tls"
    fi

    echo ""
    print_info "Namespace:     $NAMESPACE"
    print_info "Helm chart:    $KEYCLOAK_CHART (version $KEYCLOAK_CHART_VERSION)"
    print_info "Hostname:      $KEYCLOAK_HOSTNAME"
    print_info "Public URL:    $PUBLIC_URL"
    print_info "Internal URL:  $INTERNAL_URL"
    print_info "Expose:        $EXPOSE_MODE ${INGRESS_CLASS:+(class $INGRESS_CLASS)}"
    print_info "TLS:           $TLS_MODE ${TLS_SECRET_NAME:+($TLS_SECRET_NAME)}"
    print_info "Postgres:      bundled ($([ "$USE_PVC" = true ] && echo PVC || echo no PVC))"
    print_info "Admin user:    $ADMIN_USER"
}

ensure_tls_secret() {
    if [ "$TLS_MODE" = "none" ]; then
        return 0
    fi

    print_section "TLS Secret"

    if [ "$TLS_MODE" = "selfsigned" ]; then
        print_info "The Helm chart will generate a self-signed Ingress certificate ($TLS_SECRET_NAME)"
        print_warning "A remote Run:AI control plane will not trust this cert unless you install the CA there"
        return 0
    fi

    local src_ns="${KEYCLOAK_TLS_SECRET_NAMESPACE:-$NAMESPACE}"
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

    if kubectl -n "$NAMESPACE" get secret keycloak-admin >/dev/null 2>&1; then
        ADMIN_USER="$(get_secret_value keycloak-admin username)"
        KEYCLOAK_ADMIN_PASSWORD="$(get_secret_value keycloak-admin password)"
        GENERATED_ADMIN_PASSWORD=false
        print_info "Reusing existing Keycloak admin secret"
    else
        kubectl -n "$NAMESPACE" create secret generic keycloak-admin \
            --from-literal=username="$ADMIN_USER" \
            --from-literal=password="$KEYCLOAK_ADMIN_PASSWORD"
        print_success "Created Keycloak admin secret"
    fi

    local runai_url="$PLACEHOLDER_RUNAI_CTRL_PLANE_URL"
    local runai_user="placeholder"
    local runai_pass="placeholder"
    local runai_type="OIDC"
    if kubectl -n "$NAMESPACE" get secret runai-ctrl-plane-data >/dev/null 2>&1; then
        local existing_url
        existing_url="$(get_secret_value runai-ctrl-plane-data RUNAI_CTRL_PLANE_URL)"
        if ! is_placeholder_url "$existing_url"; then
            runai_url="$existing_url"
            runai_user="$(get_secret_value runai-ctrl-plane-data RUNAI_ADMIN_USERNAME)"
            runai_pass="$(get_secret_value runai-ctrl-plane-data RUNAI_ADMIN_PASSWORD)"
            runai_type="$(get_secret_value runai-ctrl-plane-data RUNAI_IDP_TYPE)"
            print_info "Preserving existing Run:AI control plane settings"
        fi
    fi

    kubectl -n "$NAMESPACE" create secret generic runai-ctrl-plane-data \
        --from-literal=KEYCLOAK_ADMIN="$ADMIN_USER" \
        --from-literal=KEYCLOAK_ADMIN_PASSWORD="$KEYCLOAK_ADMIN_PASSWORD" \
        --from-literal=KC_HOSTNAME="$PUBLIC_URL" \
        --from-literal=RUNAI_CTRL_PLANE_URL="$runai_url" \
        --from-literal=RUNAI_ADMIN_USERNAME="$runai_user" \
        --from-literal=RUNAI_ADMIN_PASSWORD="$runai_pass" \
        --from-literal=RUNAI_IDP_TYPE="$runai_type" \
        --dry-run=client -o yaml | kubectl apply -f -

    print_success "Created / updated job secret"
}

create_configmaps() {
    print_section "ConfigMaps"

    kubectl -n "$NAMESPACE" create configmap keycloak-idp-config \
        --from-literal=NAMESPACE="$NAMESPACE" \
        --from-literal=KEYCLOAK_HOSTNAME="$KEYCLOAK_HOSTNAME" \
        --from-literal=KEYCLOAK_PUBLIC_URL="$PUBLIC_URL" \
        --from-literal=KEYCLOAK_INTERNAL_URL="$INTERNAL_URL" \
        --from-literal=TLS_SECRET_NAME="${TLS_SECRET_NAME:-}" \
        --from-literal=EXPOSE_MODE="$EXPOSE_MODE" \
        --from-literal=HELM_RELEASE="$HELM_RELEASE" \
        --from-literal=PLACEHOLDER_RUNAI_CTRL_PLANE_URL="$PLACEHOLDER_RUNAI_CTRL_PLANE_URL" \
        --dry-run=client -o yaml | kubectl apply -f -

    if [ ! -f "$REPO_ROOT/realm.json" ]; then
        print_error "Shared realm.json not found at $REPO_ROOT/realm.json"
        exit 1
    fi

    kubectl -n "$NAMESPACE" create configmap keycloak-realm-data \
        --from-file=realm.json="$REPO_ROOT/realm.json" \
        --dry-run=client -o yaml | kubectl apply -f -

    kubectl -n "$NAMESPACE" create configmap keycloak-scripts \
        --from-file=01-url-health-check.sh="$SCRIPT_DIR/scripts/01-url-health-check.sh" \
        --from-file=02-keycloak-setup.sh="$REPO_ROOT/runai-backend/scripts/02-keycloak-setup.sh" \
        --from-file=with-tls-bundle.sh="$SCRIPT_DIR/scripts/with-tls-bundle.sh" \
        --dry-run=client -o yaml | kubectl apply -f -

    print_success "Created ConfigMaps (shared realm.json + import scripts)"
}

write_helm_values() {
    local dest="$1"
    local production="false"
    local proxy_headers=""
    local hostname_strict="false"
    local service_type="ClusterIP"
    local ingress_enabled="false"

    if [ "$EXPOSE_MODE" = "loadbalancer" ]; then
        service_type="LoadBalancer"
    else
        ingress_enabled="true"
        proxy_headers="xforwarded"
        if [ "$TLS_MODE" != "none" ]; then
            production="true"
            hostname_strict="true"
        fi
    fi

    {
        echo "global:"
        echo "  security:"
        echo "    allowInsecureImages: true"
        echo "fullnameOverride: keycloak"
        echo "replicaCount: 1"
        echo "cache:"
        echo "  enabled: false"
        echo "image:"
        echo "  registry: docker.io"
        echo "  repository: ${BITNAMI_KEYCLOAK_IMAGE}"
        echo "  pullPolicy: IfNotPresent"
        echo "auth:"
        echo "  adminUser: \"${ADMIN_USER}\""
        echo "  existingSecret: keycloak-admin"
        echo "  passwordSecretKey: password"
        echo "production: ${production}"
        echo "proxyHeaders: \"${proxy_headers}\""
        echo "httpEnabled: true"
        echo "hostnameStrict: ${hostname_strict}"
        echo "httpRelativePath: /"
        echo "keycloakConfigCli:"
        echo "  enabled: false"
        echo "service:"
        echo "  type: ${service_type}"
        echo "  ports:"
        echo "    http: 80"
        echo "postgresql:"
        echo "  enabled: true"
        echo "  image:"
        echo "    repository: ${BITNAMI_POSTGRES_IMAGE}"
        echo "  architecture: standalone"
        echo "  auth:"
        echo "    username: bn_keycloak"
        echo "    database: bitnami_keycloak"
        echo "  primary:"
        echo "    persistence:"
        if [ "$USE_PVC" = true ]; then
            echo "      enabled: true"
            if [ -n "$KEYCLOAK_STORAGE_CLASS" ]; then
                echo "      storageClass: ${KEYCLOAK_STORAGE_CLASS}"
            fi
        else
            echo "      enabled: false"
        fi

        echo "ingress:"
        echo "  enabled: ${ingress_enabled}"
        if [ "$ingress_enabled" = "true" ]; then
            echo "  hostname: ${KEYCLOAK_HOSTNAME}"
            echo "  pathType: Prefix"
            echo "  path: /"
            if [ -n "$INGRESS_CLASS" ]; then
                echo "  ingressClassName: ${INGRESS_CLASS}"
            fi
            if [ -z "$INGRESS_CLASS" ] || [ "$INGRESS_CLASS" = "nginx" ]; then
                echo "  annotations:"
                echo "    nginx.ingress.kubernetes.io/proxy-buffer-size: \"128k\""
            fi
            if [ "$TLS_MODE" = "selfsigned" ]; then
                echo "  tls: true"
                echo "  selfSigned: true"
            elif [ "$TLS_MODE" = "existing" ]; then
                echo "  tls: false"
                echo "  extraTls:"
                echo "    - hosts:"
                echo "        - ${KEYCLOAK_HOSTNAME}"
                echo "      secretName: ${TLS_SECRET_NAME}"
            else
                echo "  tls: false"
            fi
        fi

        echo "extraEnvVars:"
        echo "  - name: KC_HOSTNAME_BACKCHANNEL_DYNAMIC"
        echo "    value: \"true\""
        # bitnamilegacy Keycloak 26 writes an empty cache config when cache.enabled=false
        # (https://github.com/bitnami/charts/issues/36298)
        echo "  - name: KC_CACHE_CONFIG_FILE"
        echo "    value: cache-ispn.xml"
        if [ "$ingress_enabled" != "true" ]; then
            echo "  - name: KC_HOSTNAME"
            echo "    value: \"${PUBLIC_URL}\""
        fi
    } > "$dest"
}

helm_install_keycloak() {
    print_section "Helm: Bitnami Keycloak (bundled PostgreSQL)"

    local values_file
    values_file=$(mktemp)
    write_helm_values "$values_file"

    print_info "Installing release '$HELM_RELEASE' from $KEYCLOAK_CHART"
    if ! helm upgrade --install "$HELM_RELEASE" "$KEYCLOAK_CHART" \
        --namespace "$NAMESPACE" \
        --version "$KEYCLOAK_CHART_VERSION" \
        --values "$values_file" \
        --debug \
        --wait \
        --timeout 10m; then
        print_error "Helm install failed"
        helm status "$HELM_RELEASE" -n "$NAMESPACE" || true
        kubectl -n "$NAMESPACE" get pods || true
        rm -f "$values_file"
        exit 1
    fi
    rm -f "$values_file"

    print_success "Helm release '$HELM_RELEASE' is installed"
    wait_for_keycloak 120s || true

    if [ "$EXPOSE_MODE" = "loadbalancer" ]; then
        print_info "Waiting for LoadBalancer external IP..."
        local ip=""
        local waited=0
        while [ $waited -lt 120 ]; do
            ip=$(kubectl -n "$NAMESPACE" get svc keycloak -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
            if [ -z "$ip" ]; then
                ip=$(kubectl -n "$NAMESPACE" get svc keycloak -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
            fi
            if [ -n "$ip" ]; then
                break
            fi
            sleep 3
            waited=$((waited + 3))
        done
        if [ -n "$ip" ]; then
            print_success "LoadBalancer address: $ip"
            print_info "Point DNS (or /etc/hosts) for $KEYCLOAK_HOSTNAME at $ip"
        else
            print_warning "LoadBalancer address is not ready yet. Check with:"
            print_info "kubectl -n $NAMESPACE get svc keycloak"
        fi
    else
        print_success "Ingress is managed by the Helm chart for host $KEYCLOAK_HOSTNAME"
    fi
}

import_realm() {
    print_section "Importing Realm (placeholder Run:AI URLs)"

    if resource_exists job keycloak-idp-import-realm; then
        print_info "Deleting previous import job"
        kubectl -n "$NAMESPACE" delete job keycloak-idp-import-realm --timeout=60s
        sleep 2
    fi

    apply_rendered "$SCRIPT_DIR/manifests/job-import-realm.yaml"
    monitor_job keycloak-idp-import-realm "url-health-check keycloak-setup"
}

display_summary() {
    print_section "Standalone Keycloak is Ready"

    echo ""
    print_success "Isolated Keycloak is deployed and the mock-idp realm is imported."
    echo ""
    print_info "Keycloak URL:     $PUBLIC_URL"
    print_info "Admin console:    $PUBLIC_URL/admin/"
    print_info "Helm release:     $HELM_RELEASE (ns $NAMESPACE)"
    print_info "Admin user:       $ADMIN_USER"
    if [ "${GENERATED_ADMIN_PASSWORD:-false}" = true ]; then
        print_info "Admin password:   $KEYCLOAK_ADMIN_PASSWORD"
        print_warning "Store this password; it will not be shown again"
    else
        print_info "Admin password:   (from KEYCLOAK_ADMIN_PASSWORD)"
    fi
    echo ""
    print_info "Realm 'mock-idp' uses placeholder control-plane URLs:"
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
    echo "  ./standalone/integrate.sh"
    echo ""
}

main() {
    print_section "Standalone Keycloak Deployment"
    print_info "Installs Keycloak via the Bitnami Helm chart (Postgres included)"
    print_info "and imports the shared realm with placeholder Run:AI URLs."
    echo ""

    check_prerequisites helm
    collect_settings
    create_namespace
    ensure_tls_secret
    create_secrets
    create_configmaps
    helm_install_keycloak
    import_realm
    display_summary
}

main
