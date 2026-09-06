#!/bin/bash
# Shared helpers for standalone Keycloak deploy / integrate / cleanup.
# shellcheck disable=SC2034

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PLACEHOLDER_RUNAI_CTRL_PLANE_URL="${PLACEHOLDER_RUNAI_CTRL_PLANE_URL:-https://runai-ctrl-plane.placeholder.invalid}"
DEFAULT_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
DEFAULT_ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
JOB_IMAGE="${JOB_IMAGE:-wbitt/network-multitool}"
HELM_RELEASE="${KEYCLOAK_HELM_RELEASE:-keycloak}"
KEYCLOAK_CHART="${KEYCLOAK_CHART:-oci://registry-1.docker.io/bitnamicharts/keycloak}"
KEYCLOAK_CHART_VERSION="${KEYCLOAK_CHART_VERSION:-25.2.0}"
BITNAMI_KEYCLOAK_IMAGE="${BITNAMI_KEYCLOAK_IMAGE:-bitnamilegacy/keycloak}"
BITNAMI_POSTGRES_IMAGE="${BITNAMI_POSTGRES_IMAGE:-bitnamilegacy/postgresql}"

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

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_prerequisites() {
    local extra_cmds=("$@")
    print_section "Checking Prerequisites"

    local missing_commands=()
    local cmd
    for cmd in kubectl jq "${extra_cmds[@]}"; do
        if ! command_exists "$cmd"; then
            missing_commands+=("$cmd")
        fi
    done

    if [ ${#missing_commands[@]} -ne 0 ]; then
        print_error "Missing required commands: ${missing_commands[*]}"
        print_info "Please install the missing commands and try again."
        exit 1
    fi

    if ! kubectl cluster-info >/dev/null 2>&1; then
        print_error "kubectl cannot reach a cluster. Check your kubeconfig / context."
        exit 1
    fi

    print_success "All prerequisites are met"
    print_info "Kube context: $(kubectl config current-context 2>/dev/null || echo unknown)"
}

render() {
    local src="$1"
    sed \
        -e "s|__NAMESPACE__|${NAMESPACE}|g" \
        -e "s|__HOSTNAME__|${KEYCLOAK_HOSTNAME}|g" \
        -e "s|__PUBLIC_URL__|${PUBLIC_URL}|g" \
        -e "s|__INTERNAL_URL__|${INTERNAL_URL}|g" \
        -e "s|__JOB_IMAGE__|${JOB_IMAGE}|g" \
        -e "s|__ADMIN_USER__|${ADMIN_USER}|g" \
        -e "s|__TLS_SECRET__|${TLS_SECRET_NAME}|g" \
        "$src"
}

apply_rendered() {
    local src="$1"
    render "$src" | kubectl apply -f -
}

resource_exists() {
    local kind="$1"
    local name="$2"
    kubectl -n "$NAMESPACE" get "$kind" "$name" >/dev/null 2>&1
}

delete_if_exists() {
    local kind="$1"
    local name="$2"
    if resource_exists "$kind" "$name"; then
        kubectl -n "$NAMESPACE" delete "$kind" "$name" --timeout=60s
    fi
}

confirm_recreate() {
    local kind="$1"
    local name="$2"
    if ! resource_exists "$kind" "$name"; then
        return 0
    fi
    print_warning "$kind '$name' already exists in namespace '$NAMESPACE'"
    if [ -n "$KEYCLOAK_FORCE" ]; then
        print_info "KEYCLOAK_FORCE is set; deleting and recreating"
        delete_if_exists "$kind" "$name"
        return 0
    fi
    if [ ! -t 0 ]; then
        print_info "Non-interactive session: leaving existing $kind '$name' in place"
        return 1
    fi
    read -r -p "Delete and recreate it? (y/N): " reply
    if [[ $reply =~ ^[Yy]$ ]]; then
        delete_if_exists "$kind" "$name"
        return 0
    fi
    print_info "Keeping existing $kind '$name'"
    return 1
}

get_secret_value() {
    local secret_name="$1"
    local key="$2"
    kubectl -n "$NAMESPACE" get secret "$secret_name" -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d
}

get_configmap_value() {
    local cm_name="$1"
    local key="$2"
    kubectl -n "$NAMESPACE" get configmap "$cm_name" -o jsonpath="{.data.$key}" 2>/dev/null
}

wait_for_deployment() {
    local name="$1"
    local timeout="${2:-300s}"
    print_info "Waiting for deployment '$name' to become ready..."
    if kubectl -n "$NAMESPACE" rollout status "deployment/$name" --timeout="$timeout"; then
        print_success "Deployment '$name' is ready"
    else
        print_error "Deployment '$name' did not become ready within $timeout"
        kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=$name"
        kubectl -n "$NAMESPACE" describe deployment "$name" | tail -n 40
        exit 1
    fi
}

wait_for_keycloak() {
    local timeout="${1:-360s}"
    print_info "Waiting for Keycloak to become ready..."
    if kubectl -n "$NAMESPACE" wait --for=condition=ready pod \
        -l "app.kubernetes.io/name=keycloak,app.kubernetes.io/instance=${HELM_RELEASE}" \
        --timeout="$timeout"; then
        print_success "Keycloak is ready"
        return 0
    fi
    print_warning "Keycloak pod wait timed out; check: kubectl -n $NAMESPACE get pods"
    kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/instance=${HELM_RELEASE}" || true
    return 1
}

keycloak_is_installed() {
    if command_exists helm && helm status "$HELM_RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
        return 0
    fi
    if kubectl -n "$NAMESPACE" get statefulset keycloak >/dev/null 2>&1; then
        return 0
    fi
    kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=keycloak --no-headers 2>/dev/null | grep -q .
}

get_job_pod() {
    local job_name="$1"
    kubectl -n "$NAMESPACE" get pods -l "job-name=$job_name" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

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
            state=$(kubectl -n "$NAMESPACE" get pod "$pod_name" -o jsonpath="{.status.initContainerStatuses[?(@.name==\"$container\")].state}" 2>/dev/null)
        else
            state=$(kubectl -n "$NAMESPACE" get pod "$pod_name" -o jsonpath="{.status.containerStatuses[?(@.name==\"$container\")].state}" 2>/dev/null)
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
    kubectl -n "$NAMESPACE" logs "$pod_name" -c "$container" -f 2>/dev/null || true
    echo -e "${YELLOW}--- [$container] end ---${NC}"
    echo ""

    local exit_code=""
    if [ "$is_init" = "true" ]; then
        exit_code=$(kubectl -n "$NAMESPACE" get pod "$pod_name" -o jsonpath="{.status.initContainerStatuses[?(@.name==\"$container\")].state.terminated.exitCode}" 2>/dev/null)
    else
        exit_code=$(kubectl -n "$NAMESPACE" get pod "$pod_name" -o jsonpath="{.status.containerStatuses[?(@.name==\"$container\")].state.terminated.exitCode}" 2>/dev/null)
    fi

    if [ "$exit_code" = "0" ]; then
        print_success "Container '$container' completed successfully"
    elif [ -n "$exit_code" ]; then
        print_error "Container '$container' failed with exit code $exit_code"
        exit 1
    fi
}

monitor_job() {
    local job_name="$1"
    local init_containers="$2"

    print_section "Monitoring Job '$job_name'"

    print_info "Waiting for job pod to be created..."
    local max_wait=120
    local waited=0
    local pod_name=""

    while [ $waited -lt $max_wait ]; do
        pod_name=$(get_job_pod "$job_name")
        if [ -n "$pod_name" ]; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    if [ -z "$pod_name" ]; then
        print_error "Job pod was not created within $max_wait seconds"
        kubectl -n "$NAMESPACE" get job "$job_name" || true
        exit 1
    fi

    print_success "Job pod created: $pod_name"
    echo ""

    local container
    for container in $init_containers; do
        stream_container_logs "$pod_name" "$container" "true"
    done

    stream_container_logs "$pod_name" "main-container" "false"

    local job_status
    local job_failed
    job_status=$(kubectl -n "$NAMESPACE" get job "$job_name" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)
    job_failed=$(kubectl -n "$NAMESPACE" get job "$job_name" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null)

    if [ "$job_status" == "True" ]; then
        print_success "Job completed successfully!"
    elif [ "$job_failed" == "True" ]; then
        print_error "Job failed!"
        exit 1
    else
        print_warning "Job finished but status is unclear. Check manually:"
        print_info "kubectl -n $NAMESPACE get job $job_name"
    fi
}

strip_host() {
    local raw="$1"
    raw="${raw#https://}"
    raw="${raw#http://}"
    raw="${raw%%/*}"
    echo "$raw"
}

has_default_storage_class() {
    kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -q .
}

detect_ingress_class() {
    local named
    named=$(kubectl get ingressclass -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    if [ -z "$named" ]; then
        return 1
    fi
    local default_class
    default_class=$(kubectl get ingressclass -o jsonpath='{range .items[?(@.metadata.annotations.ingressclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1)
    if [ -n "$default_class" ]; then
        echo "$default_class"
        return 0
    fi
    echo "$named" | head -n1
}

is_placeholder_url() {
    local url="$1"
    [ -z "$url" ] || [[ "$url" == *placeholder.invalid* ]] || [ "$url" = "placeholder" ]
}

load_standalone_config() {
    NAMESPACE="${KEYCLOAK_NAMESPACE:-$DEFAULT_NAMESPACE}"
    if resource_exists configmap keycloak-idp-config; then
        local stored_ns
        stored_ns=$(get_configmap_value keycloak-idp-config NAMESPACE)
        if [ -z "$KEYCLOAK_NAMESPACE" ] && [ -n "$stored_ns" ]; then
            NAMESPACE="$stored_ns"
        fi
        KEYCLOAK_HOSTNAME="${KEYCLOAK_HOSTNAME:-$(get_configmap_value keycloak-idp-config KEYCLOAK_HOSTNAME)}"
        PUBLIC_URL="${PUBLIC_URL:-$(get_configmap_value keycloak-idp-config KEYCLOAK_PUBLIC_URL)}"
        INTERNAL_URL="${INTERNAL_URL:-$(get_configmap_value keycloak-idp-config KEYCLOAK_INTERNAL_URL)}"
        TLS_SECRET_NAME="${KEYCLOAK_TLS_SECRET:-$(get_configmap_value keycloak-idp-config TLS_SECRET_NAME)}"
        HELM_RELEASE="${KEYCLOAK_HELM_RELEASE:-$(get_configmap_value keycloak-idp-config HELM_RELEASE)}"
        HELM_RELEASE="${HELM_RELEASE:-keycloak}"
    fi
    if resource_exists secret keycloak-admin; then
        ADMIN_USER="${KEYCLOAK_ADMIN:-$(get_secret_value keycloak-admin username)}"
    fi
    ADMIN_USER="${ADMIN_USER:-$DEFAULT_ADMIN_USER}"
}
