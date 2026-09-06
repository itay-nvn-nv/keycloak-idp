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
    # Run:AI 2.26+ stores ADMIN_PASSWORD in runai-backend-credentials;
    # older versions kept it on runai-backend-tenants-manager.
    RUNAI_ADMIN_PASSWORD=$(kubectl get secret runai-backend-credentials -n runai-backend -o jsonpath='{.data.ADMIN_PASSWORD}' 2>/dev/null | base64 -d)
    if [ -z "$RUNAI_ADMIN_PASSWORD" ]; then
        RUNAI_ADMIN_PASSWORD=$(kubectl get secret runai-backend-tenants-manager -n runai-backend -o jsonpath='{.data.ADMIN_PASSWORD}' 2>/dev/null | base64 -d)
    fi
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

    print_info "Getting KEYCLOAK_ADMIN_PASSWORD..."
    # Run:AI 2.26+ stores it as admin-password in runai-backend-credentials;
    # older versions kept KEYCLOAK_ADMIN_PASSWORD on runai-backend-keycloakx.
    KEYCLOAK_ADMIN_PASSWORD=$(kubectl get secret runai-backend-credentials -n runai-backend -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)
    if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
        KEYCLOAK_ADMIN_PASSWORD=$(kubectl get secret runai-backend-keycloakx -n runai-backend -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' 2>/dev/null | base64 -d)
    fi
    if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
        print_error "Failed to get KEYCLOAK_ADMIN_PASSWORD"
        exit 1
    fi
    print_success "KEYCLOAK_ADMIN_PASSWORD: ********"
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
        --from-literal=RUNAI_IDP_TYPE="$RUNAI_IDP_TYPE" \
        --from-literal=KEYCLOAK_ADMIN_PASSWORD="$KEYCLOAK_ADMIN_PASSWORD"
    
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
    if kubectl -n runai-backend get job keycloak-idp-setup &>/dev/null; then
        print_warning "Job 'keycloak-idp-setup' already exists"
        read -p "Do you want to delete and recreate it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kubectl -n runai-backend delete job keycloak-idp-setup
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

# Function to get the pod name for the job
get_job_pod() {
    kubectl -n runai-backend get pods -l job-name=keycloak-idp-setup -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Function to wait for a container to reach a terminal or running state, then stream its logs
stream_container_logs() {
    local pod_name="$1"
    local container="$2"
    local is_init="$3"
    local timeout=300
    local elapsed=0

    print_info "Waiting for container '$container' to start..."

    while [ $elapsed -lt $timeout ]; do
        local state=""
        if [ "$is_init" = "true" ]; then
            state=$(kubectl -n runai-backend get pod "$pod_name" -o jsonpath="{.status.initContainerStatuses[?(@.name==\"$container\")].state}" 2>/dev/null)
        else
            state=$(kubectl -n runai-backend get pod "$pod_name" -o jsonpath="{.status.containerStatuses[?(@.name==\"$container\")].state}" 2>/dev/null)
        fi

        if echo "$state" | grep -q "running\|terminated"; then
            break
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [ $elapsed -ge $timeout ]; then
        print_error "Container '$container' did not start within $timeout seconds"
        exit 1
    fi

    echo ""
    echo -e "${YELLOW}--- [$container] logs ---${NC}"
    kubectl -n runai-backend logs "$pod_name" -c "$container" -f 2>/dev/null || true
    echo -e "${YELLOW}--- [$container] end ---${NC}"
    echo ""

    # Check exit code
    local exit_code=""
    if [ "$is_init" = "true" ]; then
        exit_code=$(kubectl -n runai-backend get pod "$pod_name" -o jsonpath="{.status.initContainerStatuses[?(@.name==\"$container\")].state.terminated.exitCode}" 2>/dev/null)
    else
        exit_code=$(kubectl -n runai-backend get pod "$pod_name" -o jsonpath="{.status.containerStatuses[?(@.name==\"$container\")].state.terminated.exitCode}" 2>/dev/null)
    fi

    if [ "$exit_code" = "0" ]; then
        print_success "Container '$container' completed successfully"
    elif [ -n "$exit_code" ]; then
        print_error "Container '$container' failed with exit code $exit_code"
        exit 1
    fi
}

# Function to monitor job
monitor_job() {
    print_section "Monitoring Job Progress"

    local containers="url-health-check keycloak-setup runai-setup"

    # Wait for the pod to be created
    print_info "Waiting for job pod to be created..."
    local max_wait=120
    local waited=0
    local pod_name=""

    while [ $waited -lt $max_wait ]; do
        pod_name=$(get_job_pod)
        if [ -n "$pod_name" ] && [ "$pod_name" != "" ]; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    if [ -z "$pod_name" ]; then
        print_error "Job pod was not created within $max_wait seconds"
        exit 1
    fi

    print_success "Job pod created: $pod_name"
    echo ""

    # Stream logs from each init container in order
    for container in $containers; do
        stream_container_logs "$pod_name" "$container" "true"
    done

    # Stream logs from the main container
    stream_container_logs "$pod_name" "main-container" "false"

    # Final job status check
    local job_status=$(kubectl -n runai-backend get job keycloak-idp-setup -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)
    local job_failed=$(kubectl -n runai-backend get job keycloak-idp-setup -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null)

    if [ "$job_status" == "True" ]; then
        print_success "Job completed successfully!"
    elif [ "$job_failed" == "True" ]; then
        print_error "Job failed!"
        exit 1
    else
        print_warning "Job finished but status is unclear. Check manually:"
        print_info "kubectl -n runai-backend get job keycloak-idp-setup"
    fi
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
    echo "  kubectl -n runai-backend get job keycloak-idp-setup"
    echo "  kubectl -n runai-backend logs job/keycloak-idp-setup"
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

