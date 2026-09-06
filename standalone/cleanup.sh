#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

MODE="${1:-}"
SKIP_RUNAI=false

usage() {
    echo "Usage: $0 [--integration-only | --all]"
    echo ""
    echo "  --integration-only  Remove the Run:AI IDP, project, and access rules."
    echo "                      Keeps the standalone Keycloak instance."
    echo "  --all               Delete the Keycloak namespace (default)."
}

confirm_cleanup() {
    print_section "Cleanup Confirmation"

    if [ "$MODE" = "integration-only" ]; then
        print_warning "This will DELETE the Run:AI integration only:"
        echo ""
        echo "  Run:AI resources:"
        echo "    - Access rules for 'developer-group'"
        echo "    - Project: dev-team"
        echo "    - IDP configuration"
        echo ""
        echo "  Keycloak stays running. Client redirect URIs are left as-is."
    else
        print_warning "This will DELETE the standalone Keycloak install:"
        echo ""
        echo "  Kubernetes:"
        echo "    - Namespace: $NAMESPACE (Helm release '$HELM_RELEASE', jobs, secrets)"
        echo ""
        echo "  Run:AI (if this instance was integrated):"
        echo "    - Access rules for 'developer-group'"
        echo "    - Project: dev-team"
        echo "    - IDP configuration"
        echo ""
        print_warning "This operation CANNOT be undone!"
    fi
    echo ""

    if [ -n "$KEYCLOAK_FORCE" ]; then
        print_info "KEYCLOAK_FORCE is set; skipping prompt"
        return 0
    fi

    local confirmation
    read -r -p "Are you sure you want to proceed? Type 'yes' to confirm: " confirmation
    if [ "$confirmation" != "yes" ]; then
        print_info "Cleanup cancelled by user"
        exit 0
    fi
}

load_runai_from_secret() {
    print_section "Gathering Run:AI Credentials"

    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        print_warning "Namespace '$NAMESPACE' not found; nothing to clean up on the cluster"
        SKIP_RUNAI=true
        return 0
    fi

    if ! resource_exists secret runai-ctrl-plane-data; then
        print_info "No integration secret found; skipping Run:AI API cleanup"
        SKIP_RUNAI=true
        return 0
    fi

    RUNAI_ADMIN_USERNAME="$(get_secret_value runai-ctrl-plane-data RUNAI_ADMIN_USERNAME)"
    RUNAI_ADMIN_PASSWORD="$(get_secret_value runai-ctrl-plane-data RUNAI_ADMIN_PASSWORD)"
    RUNAI_CTRL_PLANE_URL="$(get_secret_value runai-ctrl-plane-data RUNAI_CTRL_PLANE_URL)"

    if is_placeholder_url "$RUNAI_CTRL_PLANE_URL"; then
        print_info "Run:AI was never integrated (placeholder URL still set)"
        SKIP_RUNAI=true
        return 0
    fi

    if [ -z "$RUNAI_ADMIN_USERNAME" ] || [ -z "$RUNAI_ADMIN_PASSWORD" ] || [ -z "$RUNAI_CTRL_PLANE_URL" ]; then
        print_warning "Incomplete Run:AI credentials; skipping Run:AI API cleanup"
        SKIP_RUNAI=true
        return 0
    fi

    print_success "Will clean Run:AI resources at $RUNAI_CTRL_PLANE_URL"
}

delete_runai_resources() {
    if [ "$SKIP_RUNAI" = true ]; then
        print_warning "Skipping Run:AI resource cleanup"
        return 0
    fi

    if ! command_exists curl; then
        print_warning "curl is not installed; skipping Run:AI API cleanup"
        return 0
    fi

    print_section "Deleting Run:AI Resources"

    local token_response runai_token
    token_response=$(curl -s -f --connect-timeout 10 --max-time 30 -X POST "$RUNAI_CTRL_PLANE_URL/api/v1/token" \
        --header 'accept: application/json, text/plain, */*' \
        --header 'Content-Type: application/json' \
        --data-raw "{
            \"grantType\": \"password\",
            \"clientID\": \"cli\",
            \"username\": \"$RUNAI_ADMIN_USERNAME\",
            \"password\": \"$RUNAI_ADMIN_PASSWORD\"}" 2>&1) || {
        print_error "Failed to connect to Run:AI API"
        print_warning "Skipping Run:AI resource cleanup"
        return 0
    }

    runai_token=$(echo "$token_response" | jq -r '.accessToken // empty' 2>/dev/null)
    if [ -z "$runai_token" ]; then
        print_error "Failed to authenticate with Run:AI"
        print_warning "Skipping Run:AI resource cleanup"
        return 0
    fi
    print_success "Authenticated with Run:AI"

    local existing_projects project_id
    existing_projects=$(curl -s --connect-timeout 10 --max-time 30 "$RUNAI_CTRL_PLANE_URL/api/v1/org-unit/projects" \
        -H "authorization: Bearer $runai_token")

    if echo "$existing_projects" | jq -e 'type == "array"' >/dev/null 2>&1; then
        project_id=$(echo "$existing_projects" | jq -r '.[] | select(.name=="dev-team") | .id // empty')
    else
        project_id=$(echo "$existing_projects" | jq -r '.projects[]? | select(.name=="dev-team") | .id // empty')
        if [ -z "$project_id" ] || [ "$project_id" = "null" ]; then
            project_id=$(echo "$existing_projects" | jq -r '.data[]? | select(.name=="dev-team") | .id // empty')
        fi
    fi

    if [ -n "$project_id" ] && [ "$project_id" != "null" ]; then
        print_info "Deleting access rules for project 'dev-team'..."
        local existing_rules rule_ids
        existing_rules=$(curl -s --connect-timeout 10 --max-time 30 "$RUNAI_CTRL_PLANE_URL/api/v1/authorization/access-rules" \
            -H "authorization: Bearer $runai_token")

        if echo "$existing_rules" | jq -e 'type == "array"' >/dev/null 2>&1; then
            rule_ids=$(echo "$existing_rules" | jq -r ".[] | select(.scopeId==\"$project_id\") | .id")
        else
            rule_ids=$(echo "$existing_rules" | jq -r ".rules[]? | select(.scopeId==\"$project_id\") | .id")
            if [ -z "$rule_ids" ]; then
                rule_ids=$(echo "$existing_rules" | jq -r ".data[]? | select(.scopeId==\"$project_id\") | .id")
            fi
        fi

        if [ -n "$rule_ids" ]; then
            while IFS= read -r rule_id; do
                if [ -n "$rule_id" ] && [ "$rule_id" != "null" ]; then
                    local http_code
                    http_code=$(curl -s --connect-timeout 10 --max-time 30 -o /dev/null -w "%{http_code}" -X DELETE \
                        "$RUNAI_CTRL_PLANE_URL/api/v1/authorization/access-rules/$rule_id" \
                        -H "authorization: Bearer $runai_token")
                    if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
                        print_success "Deleted access rule: $rule_id"
                    else
                        print_warning "Failed to delete access rule: $rule_id (HTTP $http_code)"
                    fi
                fi
            done <<< "$rule_ids"
        fi

        print_info "Deleting project 'dev-team'..."
        local http_code
        http_code=$(curl -s --connect-timeout 10 --max-time 30 -o /dev/null -w "%{http_code}" -X DELETE \
            "$RUNAI_CTRL_PLANE_URL/api/v1/org-unit/projects/$project_id" \
            -H "authorization: Bearer $runai_token")
        if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
            print_success "Deleted project 'dev-team'"
        else
            print_warning "Failed to delete project (HTTP $http_code)"
        fi
    else
        print_info "Project 'dev-team' not found"
    fi

    print_info "Deleting IDP configuration..."
    local idp_list idp_alias http_code
    idp_list=$(curl -s --connect-timeout 10 --max-time 30 "$RUNAI_CTRL_PLANE_URL/api/v1/idps" \
        -H "authorization: Bearer $runai_token")
    idp_alias=$(echo "$idp_list" | jq -r '.[0].alias // empty' 2>/dev/null)

    if [ -n "$idp_alias" ] && [ "$idp_alias" != "null" ]; then
        http_code=$(curl -s --connect-timeout 10 --max-time 30 -o /dev/null -w "%{http_code}" -X DELETE \
            "$RUNAI_CTRL_PLANE_URL/api/v1/idps/$idp_alias" \
            -H "authorization: Bearer $runai_token")
        if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
            print_success "Deleted IDP '$idp_alias'"
        else
            print_warning "Failed to delete IDP (HTTP $http_code)"
        fi
    else
        print_info "No IDP found"
    fi
}

reset_integration_secret() {
    if ! resource_exists secret runai-ctrl-plane-data; then
        return 0
    fi

    print_section "Resetting Integration Secret"
    local admin_user admin_password public_url
    admin_user="$(get_secret_value runai-ctrl-plane-data KEYCLOAK_ADMIN)"
    admin_password="$(get_secret_value runai-ctrl-plane-data KEYCLOAK_ADMIN_PASSWORD)"
    public_url="$(get_secret_value runai-ctrl-plane-data KC_HOSTNAME)"

    kubectl -n "$NAMESPACE" create secret generic runai-ctrl-plane-data \
        --from-literal=KEYCLOAK_ADMIN="$admin_user" \
        --from-literal=KEYCLOAK_ADMIN_PASSWORD="$admin_password" \
        --from-literal=KC_HOSTNAME="$public_url" \
        --from-literal=RUNAI_CTRL_PLANE_URL="$PLACEHOLDER_RUNAI_CTRL_PLANE_URL" \
        --from-literal=RUNAI_ADMIN_USERNAME=placeholder \
        --from-literal=RUNAI_ADMIN_PASSWORD=placeholder \
        --from-literal=RUNAI_IDP_TYPE=OIDC \
        --dry-run=client -o yaml | kubectl apply -f -

    delete_if_exists job keycloak-idp-integrate-runai
    print_success "Run:AI fields restored to placeholders"
}

delete_namespace() {
    print_section "Deleting Namespace '$NAMESPACE'"
    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        print_info "Namespace already gone"
        return 0
    fi
    if command_exists helm && helm status "$HELM_RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
        print_info "Uninstalling Helm release '$HELM_RELEASE'"
        helm uninstall "$HELM_RELEASE" -n "$NAMESPACE" --wait --timeout 3m || true
    fi
    kubectl delete namespace "$NAMESPACE" --timeout=180s
    print_success "Deleted namespace '$NAMESPACE'"
}

display_summary() {
    print_section "Cleanup Complete!"
    echo ""
    if [ "$MODE" = "integration-only" ]; then
        print_success "Run:AI integration removed. Standalone Keycloak is still running."
    else
        print_success "Standalone Keycloak namespace removed"
        if [ "$SKIP_RUNAI" != true ]; then
            echo "  • Run:AI IDP, project 'dev-team', and access rules"
        fi
    fi
    echo ""
}

main() {
    case "$MODE" in
        --help|-h)
            usage
            exit 0
            ;;
        --integration-only)
            MODE="integration-only"
            ;;
        --all|"")
            MODE="all"
            ;;
        *)
            usage
            exit 1
            ;;
    esac

    print_section "Standalone Keycloak Cleanup"
    check_prerequisites
    NAMESPACE="${KEYCLOAK_NAMESPACE:-$DEFAULT_NAMESPACE}"
    if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        load_standalone_config
    fi

    confirm_cleanup
    load_runai_from_secret
    delete_runai_resources

    if [ "$MODE" = "integration-only" ]; then
        reset_integration_secret
    else
        delete_namespace
    fi
    display_summary
}

main
