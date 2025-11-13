#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_section() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if required commands are available
check_prerequisites() {
    print_section "Checking Prerequisites"
    
    local missing_commands=()
    
    if ! command_exists kubectl; then
        missing_commands+=("kubectl")
    fi
    
    if ! command_exists jq; then
        missing_commands+=("jq")
    fi
    
    if ! command_exists curl; then
        missing_commands+=("curl")
    fi
    
    if [ ${#missing_commands[@]} -ne 0 ]; then
        print_error "Missing required commands: ${missing_commands[*]}"
        print_info "Please install the missing commands and try again."
        exit 1
    fi
    
    print_success "All prerequisites are met"
}

# Function to confirm cleanup
confirm_cleanup() {
    print_section "Cleanup Confirmation"
    
    print_warning "This script will DELETE the following resources:"
    echo ""
    echo "  Kubernetes Resources (namespace: runai-backend):"
    echo "    - Job: keycloak-post-install"
    echo "    - ConfigMap: keycloak-realm-data"
    echo "    - ConfigMap: keycloak-scripts"
    echo "    - Secret: runai-ctrl-plane-data"
    echo ""
    echo "  Run:AI Resources:"
    echo "    - Access rules for 'developer-group'"
    echo "    - Project: dev-team"
    echo "    - IDP configuration"
    echo ""
    echo "  Keycloak Resources:"
    echo "    - Realm: mock-idp (includes all users and groups)"
    echo ""
    print_warning "This operation CANNOT be undone!"
    echo ""
    
    read -p "Are you sure you want to proceed? Type 'yes' to confirm: " confirmation
    
    if [ "$confirmation" != "yes" ]; then
        print_info "Cleanup cancelled by user"
        exit 0
    fi
    
    print_success "Cleanup confirmed"
}

# Function to get Run:AI credentials
get_runai_credentials() {
    print_section "Gathering Run:AI Credentials"
    
    # Try to get from secret first
    if kubectl -n runai-backend get secret runai-ctrl-plane-data &>/dev/null; then
        print_info "Getting credentials from existing secret..."
        RUNAI_ADMIN_USERNAME=$(kubectl -n runai-backend get secret runai-ctrl-plane-data -o jsonpath='{.data.RUNAI_ADMIN_USERNAME}' 2>/dev/null | base64 -d)
        RUNAI_ADMIN_PASSWORD=$(kubectl -n runai-backend get secret runai-ctrl-plane-data -o jsonpath='{.data.RUNAI_ADMIN_PASSWORD}' 2>/dev/null | base64 -d)
        RUNAI_CTRL_PLANE_URL=$(kubectl -n runai-backend get secret runai-ctrl-plane-data -o jsonpath='{.data.RUNAI_CTRL_PLANE_URL}' 2>/dev/null | base64 -d)
    else
        print_info "Secret not found, getting from configmaps..."
        RUNAI_ADMIN_USERNAME=$(kubectl get configmap runai-backend-tenants-manager -n runai-backend -o jsonpath='{.data.ADMIN_USERNAME}' 2>/dev/null)
        RUNAI_ADMIN_PASSWORD=$(kubectl get secret runai-backend-tenants-manager -n runai-backend -o jsonpath='{.data.ADMIN_PASSWORD}' 2>/dev/null | base64 -d)
        RUNAI_CTRL_PLANE_URL=$(kubectl get configmap runai-backend-tenants-manager -n runai-backend -o jsonpath='{.data.TENANT_DOMAIN_TEMPLATE}' 2>/dev/null)
    fi
    
    if [ -z "$RUNAI_ADMIN_USERNAME" ] || [ -z "$RUNAI_ADMIN_PASSWORD" ] || [ -z "$RUNAI_CTRL_PLANE_URL" ]; then
        print_error "Failed to get Run:AI credentials"
        print_warning "Skipping Run:AI resource cleanup"
        SKIP_RUNAI=true
    else
        print_success "Successfully obtained Run:AI credentials"
        print_info "Control Plane URL: $RUNAI_CTRL_PLANE_URL"
        SKIP_RUNAI=false
    fi
}

# Function to get Keycloak credentials
get_keycloak_credentials() {
    print_section "Gathering Keycloak Credentials"
    
    print_info "Getting Keycloak credentials..."
    KC_HOSTNAME=$(kubectl -n runai-backend get configmap runai-backend-keycloakx -o jsonpath='{.data.KC_HOSTNAME}' 2>/dev/null)
    KEYCLOAK_ADMIN=$(kubectl -n runai-backend get secret runai-backend-keycloakx -o jsonpath='{.data.KEYCLOAK_ADMIN}' 2>/dev/null | base64 -d)
    KEYCLOAK_ADMIN_PASSWORD=$(kubectl -n runai-backend get secret runai-backend-keycloakx -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' 2>/dev/null | base64 -d)
    
    if [ -z "$KC_HOSTNAME" ] || [ -z "$KEYCLOAK_ADMIN" ] || [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
        print_error "Failed to get Keycloak credentials"
        print_warning "Skipping Keycloak realm cleanup"
        SKIP_KEYCLOAK=true
    else
        print_success "Successfully obtained Keycloak credentials"
        print_info "Keycloak URL: $KC_HOSTNAME"
        SKIP_KEYCLOAK=false
    fi
}

# Function to delete Run:AI resources
delete_runai_resources() {
    if [ "$SKIP_RUNAI" = true ]; then
        print_warning "Skipping Run:AI resource cleanup (credentials not available)"
        return
    fi
    
    print_section "Deleting Run:AI Resources"
    
    # Authenticate with Run:AI
    print_info "Authenticating with Run:AI..."
    RUNAI_TOKEN=$(curl -s -X POST "$RUNAI_CTRL_PLANE_URL/api/v1/token" \
        --header 'accept: application/json, text/plain, */*' \
        --header 'Content-Type: application/json' \
        --data-raw "{
            \"grantType\": \"password\",
            \"clientID\": \"cli\",
            \"username\": \"$RUNAI_ADMIN_USERNAME\",
            \"password\": \"$RUNAI_ADMIN_PASSWORD\"}" 2>/dev/null | jq -r .accessToken)
    
    if [ -z "$RUNAI_TOKEN" ] || [ "$RUNAI_TOKEN" = "null" ]; then
        print_error "Failed to authenticate with Run:AI"
        print_warning "Skipping Run:AI resource cleanup"
        return
    fi
    
    print_success "Authenticated with Run:AI"
    
    # Get project ID
    print_info "Looking for 'dev-team' project..."
    EXISTING_PROJECTS=$(curl -s "$RUNAI_CTRL_PLANE_URL/api/v1/org-unit/projects" \
        -H "authorization: Bearer $RUNAI_TOKEN")
    
    PROJECT_ID=$(echo "$EXISTING_PROJECTS" | jq -r '.[] | select(.name=="dev-team") | .id')
    
    if [ -n "$PROJECT_ID" ] && [ "$PROJECT_ID" != "null" ]; then
        # Delete access rules for this project
        print_info "Deleting access rules for project 'dev-team'..."
        EXISTING_RULES=$(curl -s "$RUNAI_CTRL_PLANE_URL/api/v1/authorization/access-rules" \
            -H "authorization: Bearer $RUNAI_TOKEN")
        
        RULE_IDS=$(echo "$EXISTING_RULES" | jq -r ".[] | select(.scopeId==\"$PROJECT_ID\") | .id")
        
        if [ -n "$RULE_IDS" ]; then
            while IFS= read -r rule_id; do
                if [ -n "$rule_id" ] && [ "$rule_id" != "null" ]; then
                    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
                        "$RUNAI_CTRL_PLANE_URL/api/v1/authorization/access-rules/$rule_id" \
                        -H "authorization: Bearer $RUNAI_TOKEN")
                    
                    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
                        print_success "Deleted access rule: $rule_id"
                    else
                        print_warning "Failed to delete access rule: $rule_id (HTTP $HTTP_CODE)"
                    fi
                fi
            done <<< "$RULE_IDS"
        else
            print_info "No access rules found for project 'dev-team'"
        fi
        
        # Delete project
        print_info "Deleting project 'dev-team'..."
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
            "$RUNAI_CTRL_PLANE_URL/api/v1/org-unit/projects/$PROJECT_ID" \
            -H "authorization: Bearer $RUNAI_TOKEN")
        
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
            print_success "Deleted project 'dev-team'"
        else
            print_warning "Failed to delete project (HTTP $HTTP_CODE)"
        fi
    else
        print_info "Project 'dev-team' not found (already deleted or never created)"
    fi
    
    # Delete IDP
    print_info "Deleting IDP configuration..."
    IDP_LIST=$(curl -s "$RUNAI_CTRL_PLANE_URL/api/v1/idps" \
        -H "authorization: Bearer $RUNAI_TOKEN")
    
    IDP_ID=$(echo "$IDP_LIST" | jq -r '.[0].id // empty')
    
    if [ -n "$IDP_ID" ] && [ "$IDP_ID" != "null" ]; then
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
            "$RUNAI_CTRL_PLANE_URL/api/v1/idps/$IDP_ID" \
            -H "authorization: Bearer $RUNAI_TOKEN")
        
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
            print_success "Deleted IDP configuration"
        else
            print_warning "Failed to delete IDP (HTTP $HTTP_CODE)"
        fi
    else
        print_info "No IDP found (already deleted or never created)"
    fi
}

# Function to delete Keycloak realm
delete_keycloak_realm() {
    if [ "$SKIP_KEYCLOAK" = true ]; then
        print_warning "Skipping Keycloak realm cleanup (credentials not available)"
        return
    fi
    
    print_section "Deleting Keycloak Realm"
    
    # Authenticate with Keycloak
    print_info "Authenticating with Keycloak..."
    KEYCLOAK_TOKEN=$(curl -s -X POST "$KC_HOSTNAME/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=$KEYCLOAK_ADMIN" \
        -d "password=$KEYCLOAK_ADMIN_PASSWORD" \
        -d 'grant_type=password' \
        -d 'client_id=admin-cli' 2>/dev/null | jq -r '.access_token')
    
    if [ -z "$KEYCLOAK_TOKEN" ] || [ "$KEYCLOAK_TOKEN" = "null" ]; then
        print_error "Failed to authenticate with Keycloak"
        print_warning "Skipping Keycloak realm cleanup"
        return
    fi
    
    print_success "Authenticated with Keycloak"
    
    # Delete realm
    print_info "Deleting realm 'mock-idp'..."
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        "$KC_HOSTNAME/admin/realms/mock-idp" \
        -H "authorization: Bearer $KEYCLOAK_TOKEN")
    
    if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
        print_success "Deleted Keycloak realm 'mock-idp'"
    elif [ "$HTTP_CODE" = "404" ]; then
        print_info "Realm 'mock-idp' not found (already deleted or never created)"
    else
        print_warning "Failed to delete realm (HTTP $HTTP_CODE)"
    fi
}

# Function to delete Kubernetes resources
delete_kubernetes_resources() {
    print_section "Deleting Kubernetes Resources"
    
    # Delete job
    print_info "Deleting job 'keycloak-post-install'..."
    if kubectl -n runai-backend get job keycloak-post-install &>/dev/null; then
        kubectl -n runai-backend delete job keycloak-post-install
        print_success "Deleted job"
    else
        print_info "Job not found (already deleted or never created)"
    fi
    
    # Delete ConfigMaps
    print_info "Deleting ConfigMap 'keycloak-realm-data'..."
    if kubectl -n runai-backend get configmap keycloak-realm-data &>/dev/null; then
        kubectl -n runai-backend delete configmap keycloak-realm-data
        print_success "Deleted ConfigMap 'keycloak-realm-data'"
    else
        print_info "ConfigMap 'keycloak-realm-data' not found"
    fi
    
    print_info "Deleting ConfigMap 'keycloak-scripts'..."
    if kubectl -n runai-backend get configmap keycloak-scripts &>/dev/null; then
        kubectl -n runai-backend delete configmap keycloak-scripts
        print_success "Deleted ConfigMap 'keycloak-scripts'"
    else
        print_info "ConfigMap 'keycloak-scripts' not found"
    fi
    
    # Delete Secret
    print_info "Deleting Secret 'runai-ctrl-plane-data'..."
    if kubectl -n runai-backend get secret runai-ctrl-plane-data &>/dev/null; then
        kubectl -n runai-backend delete secret runai-ctrl-plane-data
        print_success "Deleted Secret 'runai-ctrl-plane-data'"
    else
        print_info "Secret 'runai-ctrl-plane-data' not found"
    fi
}

# Function to display summary
display_summary() {
    print_section "Cleanup Complete!"
    
    echo ""
    print_success "All resources have been cleaned up"
    echo ""
    print_info "Summary of deleted resources:"
    echo "  • Kubernetes Job, ConfigMaps, and Secret"
    
    if [ "$SKIP_RUNAI" != true ]; then
        echo "  • Run:AI IDP, project 'dev-team', and access rules"
    else
        echo "  • Run:AI resources (skipped - credentials not available)"
    fi
    
    if [ "$SKIP_KEYCLOAK" != true ]; then
        echo "  • Keycloak realm 'mock-idp'"
    else
        echo "  • Keycloak realm (skipped - credentials not available)"
    fi
    
    echo ""
    print_info "The environment has been restored to its previous state"
    echo ""
}

# Main execution
main() {
    print_section "Keycloak IDP Cleanup for Run:AI"
    print_info "This script will remove all resources created by setup.sh"
    echo ""
    
    check_prerequisites
    confirm_cleanup
    get_runai_credentials
    get_keycloak_credentials
    delete_runai_resources
    delete_keycloak_realm
    delete_kubernetes_resources
    display_summary
}

# Run main function
main

