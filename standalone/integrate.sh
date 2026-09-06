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

verify_standalone_install() {
    print_section "Verifying Standalone Keycloak"

    load_standalone_config

    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        print_error "Namespace '$NAMESPACE' not found. Run ./standalone/deploy.sh first."
        exit 1
    fi

    if ! keycloak_is_installed; then
        print_error "Keycloak Helm release was not found in '$NAMESPACE'. Run ./standalone/deploy.sh first."
        exit 1
    fi

    if ! resource_exists secret runai-ctrl-plane-data || ! resource_exists secret keycloak-admin; then
        print_error "Standalone Keycloak secrets are missing. Run ./standalone/deploy.sh first."
        exit 1
    fi

    if [ -z "$PUBLIC_URL" ] || [ -z "$KEYCLOAK_HOSTNAME" ]; then
        print_error "Could not read Keycloak URL from configmap keycloak-idp-config"
        exit 1
    fi

    ADMIN_USER="$(get_secret_value keycloak-admin username)"
    KEYCLOAK_ADMIN_PASSWORD="$(get_secret_value keycloak-admin password)"
    INTERNAL_URL="${INTERNAL_URL:-http://keycloak.${NAMESPACE}.svc.cluster.local}"

    print_success "Found Keycloak in namespace '$NAMESPACE'"
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

    prompt_if_empty RUNAI_ADMIN_USERNAME "Run:AI admin username: "
    if [ -z "$RUNAI_ADMIN_PASSWORD" ]; then
        if [ -t 0 ]; then
            prompt_if_empty RUNAI_ADMIN_PASSWORD "Run:AI admin password: " "" true
        else
            print_error "RUNAI_ADMIN_PASSWORD is required in non-interactive mode"
            exit 1
        fi
    fi

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
        --from-literal=KEYCLOAK_ADMIN="$ADMIN_USER" \
        --from-literal=KEYCLOAK_ADMIN_PASSWORD="$KEYCLOAK_ADMIN_PASSWORD" \
        --from-literal=KC_HOSTNAME="$PUBLIC_URL" \
        --from-literal=RUNAI_CTRL_PLANE_URL="$RUNAI_CTRL_PLANE_URL" \
        --from-literal=RUNAI_ADMIN_USERNAME="$RUNAI_ADMIN_USERNAME" \
        --from-literal=RUNAI_ADMIN_PASSWORD="$RUNAI_ADMIN_PASSWORD" \
        --from-literal=RUNAI_IDP_TYPE="$RUNAI_IDP_TYPE" \
        --dry-run=client -o yaml | kubectl apply -f -

    print_success "Secret now points at $RUNAI_CTRL_PLANE_URL"
}

create_integrate_configmaps() {
    print_section "Refreshing ConfigMaps"

    if [ ! -f "$REPO_ROOT/realm.json" ]; then
        print_error "Shared realm.json not found at $REPO_ROOT/realm.json"
        exit 1
    fi

    kubectl -n "$NAMESPACE" create configmap keycloak-realm-data \
        --from-file=realm.json="$REPO_ROOT/realm.json" \
        --dry-run=client -o yaml | kubectl apply -f -

    # Health-check both sides, then reuse the bundled realm import / Run:AI scripts.
    kubectl -n "$NAMESPACE" create configmap keycloak-scripts \
        --from-file=01-url-health-check.sh="$REPO_ROOT/runai-backend/scripts/01-url-health-check.sh" \
        --from-file=02-keycloak-setup.sh="$REPO_ROOT/runai-backend/scripts/02-keycloak-setup.sh" \
        --from-file=02-patch-clients.sh="$SCRIPT_DIR/scripts/02-patch-clients.sh" \
        --from-file=03-runai-setup.sh="$REPO_ROOT/runai-backend/scripts/03-runai-setup.sh" \
        --from-file=with-tls-bundle.sh="$SCRIPT_DIR/scripts/with-tls-bundle.sh" \
        --dry-run=client -o yaml | kubectl apply -f -

    print_success "ConfigMaps updated"
}

apply_integrate_job() {
    print_section "Applying Integration Job"

    if resource_exists job keycloak-idp-integrate-runai; then
        print_info "Deleting previous integrate job"
        kubectl -n "$NAMESPACE" delete job keycloak-idp-integrate-runai --timeout=60s
        sleep 2
    fi

    local job_manifest="$SCRIPT_DIR/manifests/job-integrate.yaml"
    if [ -n "$TLS_SECRET_NAME" ] && kubectl -n "$NAMESPACE" get secret "$TLS_SECRET_NAME" >/dev/null 2>&1; then
        job_manifest="$SCRIPT_DIR/manifests/job-integrate-tls.yaml"
        print_info "Mounting TLS secret '$TLS_SECRET_NAME' so curl trusts Keycloak"
    fi

    apply_rendered "$job_manifest"
    monitor_job keycloak-idp-integrate-runai "url-health-check keycloak-setup patch-clients runai-setup"
}

display_summary() {
    print_section "Run:AI Integration Complete"

    echo ""
    print_success "Standalone Keycloak is now the IDP for $RUNAI_CTRL_PLANE_URL"
    echo ""
    print_info "Summary:"
    echo "  • Keycloak URL:          $PUBLIC_URL"
    echo "  • Run:AI control plane:  $RUNAI_CTRL_PLANE_URL"
    echo "  • IDP type:              $RUNAI_IDP_TYPE"
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
    print_info "To verify:"
    echo "  kubectl -n $NAMESPACE get job keycloak-idp-integrate-runai"
    echo "  kubectl -n $NAMESPACE logs job/keycloak-idp-integrate-runai"
    echo ""
}

main() {
    print_section "Standalone Keycloak → Run:AI Integration"
    print_info "Configures this Keycloak realm/clients and a remote Run:AI control plane"
    echo ""

    check_prerequisites
    verify_standalone_install
    get_runai_settings
    update_job_secret
    create_integrate_configmaps
    apply_integrate_job
    display_summary
}

main
