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

verify_standalone_install() {
    print_section "Verifying Standalone authentik"

    load_standalone_config

    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        print_error "Namespace '$NAMESPACE' not found. Run ./deploy.sh first."
        exit 1
    fi

    if ! authentik_is_installed; then
        print_error "authentik Helm release was not found in '$NAMESPACE'. Run ./deploy.sh first."
        exit 1
    fi

    if ! resource_exists secret runai-ctrl-plane-data || ! resource_exists secret authentik-admin; then
        print_error "Standalone authentik secrets are missing. Run ./deploy.sh first."
        exit 1
    fi

    if [ -z "$PUBLIC_URL" ] || [ -z "$AUTHENTIK_HOSTNAME" ]; then
        print_error "Could not read the authentik URL from configmap authentik-idp-config"
        exit 1
    fi

    AK_TOKEN="$(get_secret_value authentik-admin AUTHENTIK_BOOTSTRAP_TOKEN)"
    if [ -z "$AK_TOKEN" ]; then
        print_error "No API token found in secret 'authentik-admin'"
        exit 1
    fi

    print_success "Found authentik in namespace '$NAMESPACE'"
    print_info "Public URL: $PUBLIC_URL"
}

get_runai_settings() {
    print_section "Run:AI Control Plane"

    prompt_if_empty RUNAI_CTRL_PLANE_URL "Run:AI control plane URL (e.g. https://runai.example.com): "
    RUNAI_CTRL_PLANE_URL="${RUNAI_CTRL_PLANE_URL%/}"
    case "$RUNAI_CTRL_PLANE_URL" in
        http://*|https://*) ;;
        *)
            print_error "RUNAI_CTRL_PLANE_URL must include http:// or https://"
            exit 1
            ;;
    esac

    if is_placeholder_url "$RUNAI_CTRL_PLANE_URL"; then
        print_error "That still looks like the placeholder URL. Pass the real control plane URL."
        exit 1
    fi

    prompt_if_empty RUNAI_ADMIN_USERNAME "Run:AI admin username [${DEFAULT_RUNAI_ADMIN_USERNAME}]: " "$DEFAULT_RUNAI_ADMIN_USERNAME"
    prompt_if_empty RUNAI_ADMIN_PASSWORD "Run:AI admin password [${DEFAULT_RUNAI_ADMIN_PASSWORD}]: " "$DEFAULT_RUNAI_ADMIN_PASSWORD" true

    if [ -n "$RUNAI_IDP_TYPE" ]; then
        if [ "$RUNAI_IDP_TYPE" != "OIDC" ] && [ "$RUNAI_IDP_TYPE" != "SAML" ]; then
            print_error "Invalid RUNAI_IDP_TYPE: $RUNAI_IDP_TYPE (must be 'OIDC' or 'SAML')"
            exit 1
        fi
        print_info "RUNAI_IDP_TYPE already set to: $RUNAI_IDP_TYPE"
    elif [ -t 0 ]; then
        print_info "Please select the IDP type:"
        echo "  1) OIDC"
        echo "  2) SAML"
        echo ""
        while true; do
            local choice
            read -r -p "Enter your choice (1 or 2): " choice
            case $choice in
                1) RUNAI_IDP_TYPE="OIDC"; break ;;
                2) RUNAI_IDP_TYPE="SAML"; break ;;
                *) print_error "Invalid choice. Please enter 1 or 2." ;;
            esac
        done
    else
        print_error "RUNAI_IDP_TYPE is required in non-interactive mode (OIDC or SAML)"
        exit 1
    fi

    print_success "Control plane: $RUNAI_CTRL_PLANE_URL"
    print_success "IDP type:      $RUNAI_IDP_TYPE"
}

update_job_secret() {
    print_section "Updating Job Secret"

    kubectl -n "$NAMESPACE" create secret generic runai-ctrl-plane-data \
        --from-literal=AK_TOKEN="$AK_TOKEN" \
        --from-literal=AK_HOSTNAME="$PUBLIC_URL" \
        --from-literal=AK_PUBLIC_URL="$PUBLIC_URL" \
        --from-literal=OIDC_APP_SLUG="$OIDC_APP_SLUG" \
        --from-literal=SAML_APP_SLUG="$SAML_APP_SLUG" \
        --from-literal=OIDC_CLIENT_ID="$OIDC_CLIENT_ID" \
        --from-literal=RUNAI_SCOPE_NAME="$RUNAI_SCOPE_NAME" \
        --from-literal=RUNAI_CTRL_PLANE_URL="$RUNAI_CTRL_PLANE_URL" \
        --from-literal=RUNAI_ADMIN_USERNAME="$RUNAI_ADMIN_USERNAME" \
        --from-literal=RUNAI_ADMIN_PASSWORD="$RUNAI_ADMIN_PASSWORD" \
        --from-literal=RUNAI_IDP_TYPE="$RUNAI_IDP_TYPE" \
        --dry-run=client -o yaml | kubectl apply -f -

    print_success "Secret now points at $RUNAI_CTRL_PLANE_URL"
}

create_integrate_configmaps() {
    print_section "Refreshing ConfigMaps"

    if [ ! -f "$SCRIPT_DIR/realm.json" ]; then
        print_error "Shared realm.json not found at $SCRIPT_DIR/realm.json"
        exit 1
    fi

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

    print_success "ConfigMaps updated"
}

run_integrate_locally() {
    print_section "Running Integration From This Machine"

    print_info "Calling authentik and the Run:AI control plane from this machine."
    print_info "A cluster job would fail here: pods in the authentik cluster time out reaching a remote control plane."
    print_info "Set INTEGRATE_MODE=in-cluster to force the Kubernetes job anyway."
    echo ""

    local work shared seed
    work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN
    shared="$work/shared-files"
    seed="$work/authentik-seed"
    mkdir -p "$shared" "$seed"
    cp "$SCRIPT_DIR/realm.json" "$seed/realm.json"

    export SHARED_DIR="$shared"
    export SEED_FILE="$seed/realm.json"
    export AK_HOSTNAME="$PUBLIC_URL"
    export AK_PUBLIC_URL="$PUBLIC_URL"
    export AK_TOKEN
    export OIDC_APP_SLUG
    export SAML_APP_SLUG
    export OIDC_CLIENT_ID
    export RUNAI_SCOPE_NAME
    export RUNAI_CTRL_PLANE_URL
    export RUNAI_ADMIN_USERNAME
    export RUNAI_ADMIN_PASSWORD
    export RUNAI_IDP_TYPE
    export CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-5}"
    export MAX_ATTEMPTS="${MAX_ATTEMPTS:-4}"

    print_info "1/3 Health-check authentik + Run:AI"
    sh "$SCRIPT_DIR/scripts/01-integrate-health-check.sh"
    print_info "2/3 Reconcile authentik providers with the real control plane URL"
    sh "$SCRIPT_DIR/scripts/02-authentik-setup.sh"
    print_info "3/3 Run:AI IDP + project"
    sh "$SCRIPT_DIR/scripts/03-runai-setup.sh"
}

apply_integrate_job() {
    print_section "Applying Integration Job"

    if resource_exists job authentik-idp-integrate-runai; then
        print_info "Deleting previous integrate job"
        kubectl -n "$NAMESPACE" delete job authentik-idp-integrate-runai --timeout=60s
        sleep 2
    fi

    local job_manifest="$SCRIPT_DIR/manifests/job-integrate.yaml"
    if [ -n "$TLS_SECRET_NAME" ] && kubectl -n "$NAMESPACE" get secret "$TLS_SECRET_NAME" >/dev/null 2>&1; then
        job_manifest="$SCRIPT_DIR/manifests/job-integrate-tls.yaml"
        print_info "Mounting TLS secret '$TLS_SECRET_NAME' so curl trusts authentik"
    fi

    apply_rendered "$job_manifest"
    monitor_job authentik-idp-integrate-runai "url-health-check authentik-setup runai-setup"
}

display_summary() {
    print_section "Run:AI Integration Complete"

    echo ""
    print_success "Standalone authentik is now the IDP for $RUNAI_CTRL_PLANE_URL"
    echo ""
    print_info "Summary:"
    echo "  • authentik URL:         $PUBLIC_URL"
    echo "  • Run:AI control plane:  $RUNAI_CTRL_PLANE_URL"
    echo "  • IDP type:              $RUNAI_IDP_TYPE"
    if [ "$RUNAI_IDP_TYPE" = "OIDC" ]; then
        echo "  • Discovery document:    $PUBLIC_URL/application/o/$OIDC_APP_SLUG/.well-known/openid-configuration"
    else
        echo "  • SAML metadata:         $PUBLIC_URL/application/saml/$SAML_APP_SLUG/metadata/"
    fi
    echo ""
    print_info "Pre-configured users (password: 123456):"
    echo "  • john.doe@acme.zzz (admin-group)"
    echo "  • jane.smith@acme.zzz (developer-group)"
    echo "  • steve.johnson@acme.zzz (read-only-group)"
    echo "  • jacky.fox@acme.zzz (read-only-group)"
    echo "  • blip.blop@acme.zzz (read-only-group)"
    echo ""
    print_info "The developer-group is granted the AI practitioner role on project 'dev-team'."
    echo ""
    if [ "${INTEGRATE_MODE:-local}" = "in-cluster" ]; then
        print_info "To verify:"
        echo "  kubectl -n $NAMESPACE get job authentik-idp-integrate-runai"
        echo "  kubectl -n $NAMESPACE logs job/authentik-idp-integrate-runai"
    fi
    echo ""
}

main() {
    print_section "Standalone authentik → Run:AI Integration"
    print_info "Points this authentik instance at a remote Run:AI control plane"
    echo ""

    INTEGRATE_MODE="${INTEGRATE_MODE:-local}"
    if [ "$INTEGRATE_MODE" = "in-cluster" ]; then
        check_prerequisites
    else
        check_prerequisites curl
    fi
    verify_standalone_install
    get_runai_settings
    update_job_secret
    if [ "$INTEGRATE_MODE" = "in-cluster" ]; then
        create_integrate_configmaps
        apply_integrate_job
    else
        run_integrate_locally
    fi
    display_summary
}

main
