#!/bin/bash

# MaaS Observability Stack Installation Script
# Installs Grafana, Perses, or both with dashboards and Prometheus integration
#
# This script is idempotent - safe to run multiple times
#
# Usage: ./install-observability.sh [--namespace NAMESPACE] [--stack grafana|perses|both]

set -e

# Parse arguments
NAMESPACE="${MAAS_API_NAMESPACE:-maas-api}"
OBSERVABILITY_STACK=""  # Empty = prompt if interactive

show_help() {
    echo "Usage: $0 [--namespace NAMESPACE] [--stack STACK]"
    echo ""
    echo "Options:"
    echo "  -n, --namespace    Target namespace for observability (default: maas-api)"
    echo "  -s, --stack        Observability stack to install: grafana, perses, or both"
    echo "                     If not specified, prompts interactively"
    echo ""
    echo "Examples:"
    echo "  $0                              # Interactive mode, prompts for stack"
    echo "  $0 --stack grafana              # Install Grafana only"
    echo "  $0 --stack perses               # Install Perses only"
    echo "  $0 --stack both                 # Install both Grafana and Perses"
    echo "  $0 --namespace my-ns --stack grafana"
    echo ""
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace|-n)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: --namespace requires a non-empty value"
                exit 1
            fi
            NAMESPACE="$2"
            shift 2
            ;;
        --stack|-s)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: --stack requires a value (grafana, perses, or both)"
                exit 1
            fi
            case "$2" in
                grafana|perses|both)
                    OBSERVABILITY_STACK="$2"
                    ;;
                *)
                    echo "Error: --stack must be 'grafana', 'perses', or 'both'"
                    exit 1
                    ;;
            esac
            shift 2
            ;;
        --help|-h)
            show_help
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OBSERVABILITY_DIR="$PROJECT_ROOT/deployment/components/observability"

# ==========================================
# Stack Selection (interactive if not specified)
# ==========================================
select_stack() {
    while true; do
        echo "" >&2
        echo "Select observability stack to install:" >&2
        echo "  1) grafana  - Grafana dashboards (established, feature-rich)" >&2
        echo "  2) perses   - Perses dashboards (CNCF native, lightweight)" >&2
        echo "  3) both     - Install both visualization platforms" >&2
        echo "" >&2
        read -p "Enter choice [1-3]: " choice
        
        case "$choice" in
            1|grafana)  echo "grafana"; return ;;
            2|perses)   echo "perses"; return ;;
            3|both)     echo "both"; return ;;
            "")         echo "⚠️  Please enter a valid choice (1, 2, or 3)" >&2 ;;
            *)          echo "⚠️  Invalid choice '$choice'. Please enter 1, 2, or 3" >&2 ;;
        esac
    done
}

# If no stack specified, prompt interactively
if [ -z "$OBSERVABILITY_STACK" ]; then
    if [ -t 0 ]; then
        OBSERVABILITY_STACK=$(select_stack)
    else
        echo "Non-interactive mode: --stack not specified. Defaulting to 'grafana'"
        OBSERVABILITY_STACK="grafana"
    fi
fi

echo "========================================="
echo "📊 MaaS Observability Stack Installation"
echo "========================================="
echo ""
echo "Target namespace: $NAMESPACE"
echo "Stack: $OBSERVABILITY_STACK"
echo ""

# Helper function
wait_for_crd() {
    local crd="$1"
    local timeout="${2:-120}"
    echo "⏳ Waiting for CRD $crd (timeout: ${timeout}s)..."
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if kubectl get crd "$crd" &>/dev/null; then
            kubectl wait --for=condition=Established --timeout="${timeout}s" "crd/$crd" 2>/dev/null
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    echo "❌ Timed out waiting for CRD $crd"
    return 1
}

# ==========================================
# Step 1: Enable user-workload-monitoring
# ==========================================
echo "1️⃣ Enabling user-workload-monitoring..."

if kubectl get configmap cluster-monitoring-config -n openshift-monitoring &>/dev/null; then
    CURRENT_CONFIG=$(kubectl get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
    if echo "$CURRENT_CONFIG" | grep -q "enableUserWorkload: true"; then
        echo "   ✅ user-workload-monitoring already enabled"
    else
        echo "   Updating cluster-monitoring-config..."
        kubectl apply -f "$OBSERVABILITY_DIR/cluster-monitoring-config.yaml"
        echo "   ✅ user-workload-monitoring enabled"
    fi
else
    echo "   Creating cluster-monitoring-config..."
    kubectl apply -f "$OBSERVABILITY_DIR/cluster-monitoring-config.yaml"
    echo "   ✅ user-workload-monitoring enabled"
fi

# Wait for user-workload-monitoring pods
echo "   Waiting for user-workload-monitoring pods..."
sleep 5
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=prometheus \
    -n openshift-user-workload-monitoring --timeout=120s 2>/dev/null || \
    echo "   ⚠️  Pods still starting, continuing..."

# ==========================================
# Step 2: Label namespaces for monitoring
# ==========================================
echo ""
echo "2️⃣ Labeling namespaces for monitoring..."

for ns in kuadrant-system "$NAMESPACE" llm; do
    if kubectl get namespace "$ns" &>/dev/null; then
        kubectl label namespace "$ns" openshift.io/cluster-monitoring=true --overwrite 2>/dev/null || true
        echo "   ✅ Labeled namespace: $ns"
    fi
done

# ==========================================
# Step 3: Deploy TelemetryPolicy and Base ServiceMonitors
# ==========================================
echo ""
echo "3️⃣ Deploying TelemetryPolicy and ServiceMonitors..."

# Deploy base observability resources (TelemetryPolicy + ServiceMonitors)
# TelemetryPolicy is CRITICAL - it extracts user/tier/model labels for Limitador metrics
BASE_OBSERVABILITY_DIR="$PROJECT_ROOT/deployment/base/observability"
if [ -d "$BASE_OBSERVABILITY_DIR" ]; then
    kustomize build "$BASE_OBSERVABILITY_DIR" | kubectl apply -f -
    echo "   ✅ TelemetryPolicy and base ServiceMonitors deployed"
else
    echo "   ⚠️  Base observability directory not found - TelemetryPolicy may be missing!"
fi

# Deploy Istio Gateway metrics (if gateway exists)
if kubectl get deploy -n openshift-ingress maas-default-gateway-openshift-default &>/dev/null; then
    kubectl apply -f "$OBSERVABILITY_DIR/monitors/istio-gateway-service.yaml"
    kubectl apply -f "$OBSERVABILITY_DIR/monitors/istio-gateway-servicemonitor.yaml"
    echo "   ✅ Istio Gateway metrics configured"
else
    echo "   ⚠️  Istio Gateway not found - skipping Istio metrics"
fi

# Deploy LLM models ServiceMonitor (for vLLM metrics)
if kubectl get ns llm &>/dev/null; then
    kubectl apply -f "$OBSERVABILITY_DIR/monitors/kserve-llm-models-servicemonitor.yaml"
    echo "   ✅ LLM models metrics configured"
else
    echo "   ⚠️  llm namespace not found - skipping LLM metrics"
fi

# ==========================================
# Install Grafana (if selected)
# ==========================================
install_grafana() {
    echo ""
    echo "4️⃣ Installing Grafana..."

    # Install Grafana Operator
    if kubectl get csv -n openshift-operators 2>/dev/null | grep -q "grafana-operator"; then
        echo "   ✅ Grafana Operator already installed"
    else
        "$SCRIPT_DIR/installers/install-grafana.sh"
    fi

    # Wait for CRDs
    echo "   Waiting for Grafana CRDs..."
    wait_for_crd "grafanas.grafana.integreatly.org" 120 || {
        echo "   ❌ Grafana CRDs not available. Please install Grafana Operator manually."
        return 1
    }

    # Ensure namespace exists
    kubectl create namespace "$NAMESPACE" 2>/dev/null || true

    # Deploy Grafana instance
    echo "   Deploying Grafana instance to $NAMESPACE..."
    kustomize build "$OBSERVABILITY_DIR/grafana" | \
        sed "s/namespace: maas-api/namespace: $NAMESPACE/g" | \
        kubectl apply -f -

    echo "   ✅ Grafana instance deployed"

    # Wait for Grafana pod
    echo "   Waiting for Grafana pod..."
    kubectl wait --for=condition=Ready pods -l app=grafana -n "$NAMESPACE" --timeout=120s 2>/dev/null || \
        echo "   ⚠️  Grafana pod still starting, continuing..."

    # Configure Prometheus Datasource
    echo "   Configuring Prometheus datasource..."
    TOKEN=$(kubectl create token grafana-sa -n "$NAMESPACE" --duration=720h 2>/dev/null || echo "")

    if [ -z "$TOKEN" ]; then
        echo "   ⚠️  Could not create token for grafana-sa ServiceAccount"
        cat <<EOF | kubectl apply -f -
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: prometheus
  namespace: $NAMESPACE
  labels:
    app: grafana
    component: observability
spec:
  instanceSelector:
    matchLabels:
      app: grafana
  datasource:
    name: Prometheus
    type: prometheus
    access: proxy
    url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
    isDefault: true
    jsonData:
      tlsSkipVerify: true
EOF
    else
        cat <<EOF | kubectl apply -f -
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: prometheus
  namespace: $NAMESPACE
  labels:
    app: grafana
    component: observability
spec:
  instanceSelector:
    matchLabels:
      app: grafana
  datasource:
    name: Prometheus
    type: prometheus
    access: proxy
    url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
    isDefault: true
    jsonData:
      tlsSkipVerify: true
      httpHeaderName1: Authorization
    secureJsonData:
      httpHeaderValue1: "Bearer $TOKEN"
EOF
        echo "   ✅ Prometheus datasource configured with authentication"
    fi

    # Deploy Grafana Dashboards
    echo "   Deploying Grafana dashboards..."
    kustomize build "$OBSERVABILITY_DIR/dashboards" | \
        sed "s/namespace: maas-api/namespace: $NAMESPACE/g" | \
        kubectl apply -f -

    # Validate Grafana dashboards are synced
    echo "   Validating Grafana dashboards..."
    VALIDATION_PASSED=true
    for attempt in $(seq 1 12); do
        sleep 3
        DASHBOARD_COUNT=$(kubectl get grafanadashboard -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        
        if [ "$DASHBOARD_COUNT" -ge 1 ] 2>/dev/null; then
            # Check sync status - condition type is "DashboardSynchronized"
            SYNC_OUTPUT=$(kubectl get grafanadashboard -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="DashboardSynchronized")].status}{" "}{end}' 2>/dev/null || echo "")
            SYNCED_COUNT=$(echo "$SYNC_OUTPUT" | tr ' ' '\n' | grep -c "True" 2>/dev/null || echo "0")
            
            # Check for errors in messages
            ERROR_OUTPUT=$(kubectl get grafanadashboard -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}:{.status.conditions[?(@.type=="DashboardSynchronized")].message}{"\n"}{end}' 2>/dev/null || echo "")
            ERROR_STATUS=$(echo "$ERROR_OUTPUT" | grep -i "error\|failed" || true)
            
            if [ -n "$ERROR_STATUS" ]; then
                echo "   ❌ Dashboard sync failed:"
                echo "$ERROR_STATUS" | head -3
                VALIDATION_PASSED=false
                break
            fi
            
            if [ "$SYNCED_COUNT" -eq "$DASHBOARD_COUNT" ] 2>/dev/null; then
                echo "   ✅ Grafana dashboards validated ($SYNCED_COUNT/$DASHBOARD_COUNT synced)"
                VALIDATION_PASSED=true
                break
            fi
        fi
        
        echo "   Waiting for dashboards to sync... (attempt $attempt/12)"
    done

    if [ "$VALIDATION_PASSED" = "false" ]; then
        echo "   ⚠️  Some dashboards may have issues. Check: kubectl get grafanadashboard -n $NAMESPACE"
    fi

    # Show Grafana URL
    GRAFANA_HOST=$(kubectl get route grafana-ingress -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
    if [ -n "$GRAFANA_HOST" ]; then
        echo ""
        echo "   🌐 Grafana UI: https://$GRAFANA_HOST"
    fi
}

# ==========================================
# Install Perses (if selected)
# ==========================================
install_perses() {
    echo ""
    echo "5️⃣ Installing Perses..."

    # Check if Cluster Observability Operator is already installed
    OPERATOR_INSTALLED=false
    if kubectl get csv -n openshift-operators 2>/dev/null | grep -q "cluster-observability-operator.*Succeeded"; then
        echo "   ✅ Cluster Observability Operator already installed"
        OPERATOR_INSTALLED=true
    fi

    if [ "$OPERATOR_INSTALLED" = "false" ]; then
        # Install Cluster Observability Operator (includes Perses)
        "$SCRIPT_DIR/installers/install-perses.sh"
    fi

    # Verify operator is now installed
    if ! kubectl get csv -n openshift-operators 2>/dev/null | grep -q "cluster-observability-operator.*Succeeded"; then
        echo "   ❌ Cluster Observability Operator not installed, cannot deploy Perses"
        return 1
    fi

    # Deploy UIPlugin (creates Perses instance in openshift-operators)
    echo "   Enabling Monitoring UIPlugin with Perses..."
    kubectl apply -f "$OBSERVABILITY_DIR/perses/uiplugin.yaml"
    echo "   ✅ UIPlugin enabled"

    # Wait for UIPlugin's Perses instance to be ready
    echo "   Waiting for Perses instance (created by UIPlugin)..."
    for i in $(seq 1 30); do
        PERSES_PODS=$(kubectl get pods -n openshift-operators -l app.kubernetes.io/name=perses --no-headers 2>/dev/null | grep -c Running || echo "0")
        if [ "$PERSES_PODS" -ge 1 ] 2>/dev/null; then
            echo "   ✅ Perses pod is running in openshift-operators"
            break
        fi
        echo "   Waiting for Perses pod... (attempt $i/30)"
        sleep 5
    done

    # Deploy dashboards to openshift-operators (where UIPlugin's Perses lives)
    echo "   Deploying Perses dashboards to openshift-operators..."
    kubectl apply -f "$OBSERVABILITY_DIR/perses/dashboards/dashboard-ai-engineer.yaml" -n openshift-operators
    kubectl apply -f "$OBSERVABILITY_DIR/perses/dashboards/dashboard-platform-admin.yaml" -n openshift-operators
    
    # Deploy datasource to openshift-operators
    echo "   Configuring Prometheus datasource..."
    kubectl apply -f "$OBSERVABILITY_DIR/perses/perses-datasource.yaml" -n openshift-operators 2>/dev/null || \
        echo "   ⚠️  Datasource already configured by operator"

    # Validate Perses dashboards are reconciled
    echo "   Validating Perses dashboards..."
    VALIDATION_PASSED=true
    for attempt in $(seq 1 12); do
        sleep 5
        DASHBOARD_STATUS=$(kubectl get persesdashboard -n openshift-operators -o custom-columns=NAME:.metadata.name,MESSAGE:.status.conditions[0].message --no-headers 2>/dev/null || echo "")
        
        # Check if all dashboards created successfully
        if echo "$DASHBOARD_STATUS" | grep -q "created successfully"; then
            FAILED=$(echo "$DASHBOARD_STATUS" | grep -v "created successfully" | grep -v "^$" || true)
            if [ -z "$FAILED" ]; then
                echo "   ✅ Perses dashboards validated successfully"
                VALIDATION_PASSED=true
                break
            fi
        fi
        
        # Check for errors
        if echo "$DASHBOARD_STATUS" | grep -qi "error\|invalid\|failed"; then
            echo "   ❌ Dashboard validation failed:"
            echo "$DASHBOARD_STATUS" | grep -i "error\|invalid\|failed" | head -3
            VALIDATION_PASSED=false
            break
        fi
        
        echo "   Waiting for dashboards to reconcile... (attempt $attempt/12)"
    done

    if [ "$VALIDATION_PASSED" = "false" ]; then
        echo "   ⚠️  Some dashboards may have issues. Check: kubectl get persesdashboard -n openshift-operators"
    fi

    echo ""
    echo "   ℹ️  Dashboards accessible via: OpenShift Console → Observe → Dashboards (Perses)"
    echo "   ✅ Perses installation complete"
}

# ==========================================
# Execute based on stack selection
# ==========================================
case "$OBSERVABILITY_STACK" in
    grafana)
        install_grafana
        ;;
    perses)
        install_perses
        ;;
    both)
        install_grafana
        install_perses
        ;;
esac

# ==========================================
# Summary
# ==========================================
echo ""
echo "========================================="
echo "✅ Observability Stack Installed!"
echo "========================================="
echo ""

# Show Grafana info if installed
if [ "$OBSERVABILITY_STACK" = "grafana" ] || [ "$OBSERVABILITY_STACK" = "both" ]; then
    GRAFANA_ROUTE=$(kubectl get route grafana-ingress -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "$GRAFANA_ROUTE" ]; then
        echo "📊 Grafana URL: https://$GRAFANA_ROUTE"
        echo "   🔐 Default Credentials: admin / admin"
        echo ""
    fi
fi

# Show Perses info if installed
if [ "$OBSERVABILITY_STACK" = "perses" ] || [ "$OBSERVABILITY_STACK" = "both" ]; then
    # Get OpenShift Console URL (Red Hat Perses integrates via console plugin)
    CONSOLE_URL=$(oc whoami --show-console 2>/dev/null || echo "")
    if [ -n "$CONSOLE_URL" ]; then
        echo "📊 Perses Dashboards: $CONSOLE_URL"
        echo "   Navigate to: Observe → Dashboards (Perses) → Select 'openshift-operators' project"
    else
        echo "📊 Perses Dashboards: OpenShift Console → Observe → Dashboards (Perses)"
    fi
    echo ""
fi

echo "📈 Available Dashboards:"
echo "   - Platform Admin Dashboard"
echo "   - AI Engineer Dashboard"
echo ""
echo "📝 Metrics available:"
echo "   Limitador: authorized_hits, authorized_calls, limited_calls, limitador_up"
echo "   Istio:     istio_requests_total, istio_request_duration_milliseconds"
echo "   vLLM:      vllm:num_requests_running, vllm:num_requests_waiting, vllm:gpu_cache_usage_perc"
echo "   K8s:       kube_pod_status_phase"
echo "   Alerts:    ALERTS{alertstate=\"firing\"}"
echo ""
