#!/bin/bash
# Shared helpers for standalone authentik deploy / integrate / cleanup.
# Deliberately self-contained so ../standalone (Keycloak) stays untouched.
# shellcheck disable=SC2034

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PLACEHOLDER_RUNAI_CTRL_PLANE_URL="${PLACEHOLDER_RUNAI_CTRL_PLANE_URL:-https://runai-ctrl-plane.placeholder.invalid}"
DEFAULT_NAMESPACE="${AUTHENTIK_NAMESPACE:-authentik}"
DEFAULT_ADMIN_EMAIL="${AUTHENTIK_ADMIN_EMAIL:-admin@acme.zzz}"
DEFAULT_RUNAI_ADMIN_USERNAME="test@run.ai"
DEFAULT_RUNAI_ADMIN_PASSWORD="Abcd!234"
JOB_IMAGE="${JOB_IMAGE:-wbitt/network-multitool}"
HELM_RELEASE="${AUTHENTIK_HELM_RELEASE:-authentik}"
AUTHENTIK_CHART="${AUTHENTIK_CHART:-authentik}"
AUTHENTIK_CHART_REPO="${AUTHENTIK_CHART_REPO:-https://charts.goauthentik.io}"
AUTHENTIK_CHART_VERSION="${AUTHENTIK_CHART_VERSION:-2026.8.6}"

# authentik object names the scripts create and look up again on re-runs.
OIDC_APP_SLUG="${OIDC_APP_SLUG:-runai-oidc}"
SAML_APP_SLUG="${SAML_APP_SLUG:-runai-saml}"
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-lab-oidc-client}"
RUNAI_SCOPE_NAME="${RUNAI_SCOPE_NAME:-runai}"

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
        -e "s|__HOSTNAME__|${AUTHENTIK_HOSTNAME}|g" \
        -e "s|__PUBLIC_URL__|${PUBLIC_URL}|g" \
        -e "s|__INTERNAL_URL__|${INTERNAL_URL}|g" \
        -e "s|__JOB_IMAGE__|${JOB_IMAGE}|g" \
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

random_secret() {
    local bytes="${1:-32}"
    if command_exists openssl; then
        openssl rand -hex "$bytes"
    else
        head -c "$((bytes * 2))" /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c "1-$((bytes * 2))"
    fi
}

wait_for_authentik() {
    local timeout="${1:-360s}"
    print_info "Waiting for authentik server to become ready..."
    if kubectl -n "$NAMESPACE" wait --for=condition=ready pod \
        -l "app.kubernetes.io/name=authentik,app.kubernetes.io/component=server" \
        --timeout="$timeout"; then
        print_success "authentik server is ready"
        return 0
    fi
    print_warning "authentik pod wait timed out; check: kubectl -n $NAMESPACE get pods"
    kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/instance=${HELM_RELEASE}" || true
    return 1
}

authentik_is_installed() {
    if command_exists helm && helm status "$HELM_RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
        return 0
    fi
    kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=authentik --no-headers 2>/dev/null | grep -q .
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
    NAMESPACE="${AUTHENTIK_NAMESPACE:-$DEFAULT_NAMESPACE}"
    if resource_exists configmap authentik-idp-config; then
        local stored_ns
        stored_ns=$(get_configmap_value authentik-idp-config NAMESPACE)
        if [ -z "$AUTHENTIK_NAMESPACE" ] && [ -n "$stored_ns" ]; then
            NAMESPACE="$stored_ns"
        fi
        AUTHENTIK_HOSTNAME="${AUTHENTIK_HOSTNAME:-$(get_configmap_value authentik-idp-config AUTHENTIK_HOSTNAME)}"
        PUBLIC_URL="${PUBLIC_URL:-$(get_configmap_value authentik-idp-config AUTHENTIK_PUBLIC_URL)}"
        INTERNAL_URL="${INTERNAL_URL:-$(get_configmap_value authentik-idp-config AUTHENTIK_INTERNAL_URL)}"
        TLS_SECRET_NAME="${AUTHENTIK_TLS_SECRET:-$(get_configmap_value authentik-idp-config TLS_SECRET_NAME)}"
        HELM_RELEASE="${AUTHENTIK_HELM_RELEASE:-$(get_configmap_value authentik-idp-config HELM_RELEASE)}"
        HELM_RELEASE="${HELM_RELEASE:-authentik}"
    fi
}
