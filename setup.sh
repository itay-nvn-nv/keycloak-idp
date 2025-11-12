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
    
    if [ ${#missing_commands[@]} -ne 0 ]; then
        print_error "Missing required commands: ${missing_commands[*]}"
        print_info "Please install the missing commands and try again."
        exit 1
    fi
    
    print_success "All prerequisites are met"
}

# Function to check keycloak pod
check_keycloak_pod() {
    print_section "Verifying Keycloak Instance"
    
    print_info "Checking if Keycloak pod is running..."
    if kubectl -n runai-backend get pod keycloak-0 &>/dev/null; then
        local pod_status=$(kubectl -n runai-backend get pod keycloak-0 -o jsonpath='{.status.phase}')
        if [ "$pod_status" == "Running" ]; then
            print_success "Keycloak pod is running"
        else
            print_error "Keycloak pod is not running (status: $pod_status)"
            exit 1
        fi
    else
        print_error "Keycloak pod not found"
        exit 1
    fi
}

# Function to get keycloak URL
get_keycloak_url() {
    print_info "Getting Keycloak URL..."
    RUNAI_BACKEND_KEYCLOAK_URL="https://$(kubectl -n runai-backend get ingress runai-backend-ingress -o jsonpath='{.spec.rules[0].host}')/auth"
    
    if [ -z "$RUNAI_BACKEND_KEYCLOAK_URL" ] || [ "$RUNAI_BACKEND_KEYCLOAK_URL" == "https:///auth" ]; then
        print_error "Failed to get Keycloak URL"
        exit 1
    fi
    
    print_success "Keycloak URL: $RUNAI_BACKEND_KEYCLOAK_URL"
}

# Function to create configmap for realm data
create_realm_configmap() {
    print_section "Creating Keycloak Realm ConfigMap"
    
    if [ ! -f "realm.json" ]; then
        print_error "realm.json file not found in current directory"
        exit 1
    fi
    
    print_info "Checking if configmap already exists..."
    if kubectl -n runai-backend get configmap keycloak-realm-data &>/dev/null; then
        print_warning "ConfigMap 'keycloak-realm-data' already exists"
        read -p "Do you want to delete and recreate it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kubectl -n runai-backend delete configmap keycloak-realm-data
            print_success "Deleted existing configmap"
        else
            print_info "Skipping configmap creation"
            return
        fi
    fi
    
    print_info "Creating configmap from realm.json..."
    kubectl -n runai-backend create configmap keycloak-realm-data --from-file=realm.json
    print_success "ConfigMap created successfully"
}

# Function to create configmap for scripts
create_scripts_configmap() {
    print_section "Creating Scripts ConfigMap"
    
    if [ ! -d "scripts" ]; then
        print_error "scripts directory not found in current directory"
        exit 1
    fi
    
    print_info "Checking if configmap already exists..."
    if kubectl -n runai-backend get configmap keycloak-scripts &>/dev/null; then
        print_warning "ConfigMap 'keycloak-scripts' already exists"
        read -p "Do you want to delete and recreate it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kubectl -n runai-backend delete configmap keycloak-scripts
            print_success "Deleted existing configmap"
        else
            print_info "Skipping configmap creation"
            return
        fi
    fi
    
    print_info "Creating configmap from scripts directory..."
    kubectl -n runai-backend create configmap keycloak-scripts --from-file=scripts/
    print_success "ConfigMap created successfully"
}

# Function to get RunAI credentials
get_runai_credentials() {
    print_section "Gathering Run:AI Credentials"
    
    print_info "Getting RUNAI_ADMIN_USERNAME..."
    RUNAI_ADMIN_USERNAME=$(kubectl get configmap runai-backend-tenants-manager -n runai-backend -o jsonpath='{.data.ADMIN_USERNAME}' 2>/dev/null)
    if [ -z "$RUNAI_ADMIN_USERNAME" ]; then
        print_error "Failed to get RUNAI_ADMIN_USERNAME"
        exit 1
    fi
    print_success "RUNAI_ADMIN_USERNAME: $RUNAI_ADMIN_USERNAME"
    
    print_info "Getting RUNAI_ADMIN_PASSWORD..."
    RUNAI_ADMIN_PASSWORD=$(kubectl get secret runai-backend-tenants-manager -n runai-backend -o jsonpath='{.data.ADMIN_PASSWORD}' 2>/dev/null | base64 -d)
    if [ -z "$RUNAI_ADMIN_PASSWORD" ]; then
        print_error "Failed to get RUNAI_ADMIN_PASSWORD"
        exit 1
    fi
    print_success "RUNAI_ADMIN_PASSWORD: ********"
    
    print_info "Getting RUNAI_CTRL_PLANE_URL..."
    RUNAI_CTRL_PLANE_URL=$(kubectl get configmap runai-backend-tenants-manager -n runai-backend -o jsonpath='{.data.TENANT_DOMAIN_TEMPLATE}' 2>/dev/null)
    if [ -z "$RUNAI_CTRL_PLANE_URL" ]; then
        print_error "Failed to get RUNAI_CTRL_PLANE_URL"
        exit 1
    fi
    print_success "RUNAI_CTRL_PLANE_URL: $RUNAI_CTRL_PLANE_URL"
}

# Function to get IDP type
get_idp_type() {
    print_section "Configuring IDP Type"
    
    # Check if RUNAI_IDP_TYPE is already set as environment variable
    if [ -n "$RUNAI_IDP_TYPE" ]; then
        print_info "RUNAI_IDP_TYPE already set to: $RUNAI_IDP_TYPE"
        
        # Validate the value
        if [ "$RUNAI_IDP_TYPE" != "OIDC" ] && [ "$RUNAI_IDP_TYPE" != "SAML" ]; then
            print_error "Invalid RUNAI_IDP_TYPE: $RUNAI_IDP_TYPE (must be 'OIDC' or 'SAML')"
            exit 1
        fi
    else
        # Interactive prompt
        print_info "Please select the IDP type:"
        echo "  1) OIDC"
        echo "  2) SAML"
        echo ""
        
        while true; do
            read -p "Enter your choice (1 or 2): " choice
            case $choice in
                1)
                    RUNAI_IDP_TYPE="OIDC"
                    break
                    ;;
                2)
                    RUNAI_IDP_TYPE="SAML"
                    break
                    ;;
                *)
                    print_error "Invalid choice. Please enter 1 or 2."
                    ;;
            esac
        done
    fi
    
    print_success "IDP Type set to: $RUNAI_IDP_TYPE"
}

# Function to create secret
create_runai_secret() {
    print_section "Creating Run:AI Secret"
    
    print_info "Checking if secret already exists..."
    if kubectl -n runai-backend get secret runai-ctrl-plane-data &>/dev/null; then
        print_warning "Secret 'runai-ctrl-plane-data' already exists"
        read -p "Do you want to delete and recreate it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kubectl -n runai-backend delete secret runai-ctrl-plane-data
            print_success "Deleted existing secret"
        else
            print_info "Skipping secret creation"
            return
        fi
    fi
    
    print_info "Creating secret with gathered credentials..."
    kubectl create secret generic runai-ctrl-plane-data \
        --namespace=runai-backend \
        --from-literal=RUNAI_ADMIN_USERNAME="$RUNAI_ADMIN_USERNAME" \
        --from-literal=RUNAI_ADMIN_PASSWORD="$RUNAI_ADMIN_PASSWORD" \
        --from-literal=RUNAI_CTRL_PLANE_URL="$RUNAI_CTRL_PLANE_URL" \
        --from-literal=RUNAI_IDP_TYPE="$RUNAI_IDP_TYPE"
    
    print_success "Secret created successfully"
}

# Function to apply job
apply_job() {
    print_section "Applying Post-Install Job"
    
    if [ ! -f "job.yaml" ]; then
        print_error "job.yaml file not found in current directory"
        exit 1
    fi
    
    print_info "Checking if job already exists..."
    if kubectl -n runai-backend get job keycloak-post-install &>/dev/null; then
        print_warning "Job 'keycloak-post-install' already exists"
        read -p "Do you want to delete and recreate it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kubectl -n runai-backend delete job keycloak-post-install
            print_success "Deleted existing job"
            # Wait a moment for the job to be fully deleted
            sleep 2
        else
            print_info "Skipping job application"
            return
        fi
    fi
    
    print_info "Applying job.yaml..."
    kubectl apply -f job.yaml
    print_success "Job applied successfully"
}

# Function to monitor job
monitor_job() {
    print_section "Monitoring Job Progress"
    
    print_info "Waiting for job to start..."
    local max_wait=60
    local waited=0
    
    while [ $waited -lt $max_wait ]; do
        if kubectl -n runai-backend get job keycloak-post-install &>/dev/null; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    
    if [ $waited -eq $max_wait ]; then
        print_error "Job did not start within $max_wait seconds"
        exit 1
    fi
    
    print_info "Job started. Monitoring status..."
    print_info "To view logs, run: kubectl -n runai-backend logs -f job/keycloak-post-install"
    echo ""
    
    # Monitor job status
    local timeout=600
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        local status=$(kubectl -n runai-backend get job keycloak-post-install -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)
        local failed=$(kubectl -n runai-backend get job keycloak-post-install -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null)
        
        if [ "$status" == "True" ]; then
            print_success "Job completed successfully!"
            return 0
        elif [ "$failed" == "True" ]; then
            print_error "Job failed!"
            print_info "Fetching job logs..."
            echo ""
            kubectl -n runai-backend logs job/keycloak-post-install --tail=50
            exit 1
        fi
        
        # Show progress
        local active=$(kubectl -n runai-backend get job keycloak-post-install -o jsonpath='{.status.active}' 2>/dev/null)
        if [ -n "$active" ] && [ "$active" != "0" ]; then
            printf "\r${BLUE}[INFO]${NC} Job is running... (elapsed: ${elapsed}s)"
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    echo "" # New line after progress indicator
    print_error "Job did not complete within $timeout seconds"
    print_info "You can continue monitoring with: kubectl -n runai-backend get job keycloak-post-install -w"
    exit 1
}

# Function to display summary
display_summary() {
    print_section "Setup Complete!"
    
    echo ""
    print_success "Keycloak IDP has been successfully configured!"
    echo ""
    print_info "Summary:"
    echo "  • Keycloak URL: $RUNAI_BACKEND_KEYCLOAK_URL"
    echo "  • Run:AI Control Plane: $RUNAI_CTRL_PLANE_URL"
    echo "  • IDP Type: $RUNAI_IDP_TYPE"
    echo ""
    print_info "Pre-configured users (password: 123456):"
    echo "  • john.doe@acme.zzz (admin-group)"
    echo "  • jane.smith@acme.zzz (developer-group)"
    echo "  • steve.johnson@acme.zzz (read-only-group)"
    echo "  • jacky.fox@acme.zzz (read-only-group)"
    echo "  • blip.blop@acme.zzz (read-only-group)"
    echo ""
    print_info "To verify the setup:"
    echo "  kubectl -n runai-backend get job keycloak-post-install"
    echo "  kubectl -n runai-backend logs job/keycloak-post-install"
    echo ""
}

# Main execution
main() {
    print_section "Keycloak IDP Setup for Run:AI"
    print_info "This script will automate the complete setup process"
    echo ""
    
    check_prerequisites
    check_keycloak_pod
    get_keycloak_url
    create_realm_configmap
    create_scripts_configmap
    get_runai_credentials
    get_idp_type
    create_runai_secret
    apply_job
    monitor_job
    display_summary
}

# Run main function
main

