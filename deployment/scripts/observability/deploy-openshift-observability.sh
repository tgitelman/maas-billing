#!/usr/bin/env bash
#
# deploy-openshift-observability.sh
# Idempotent observability deployment with smart version checking
# Deploys infrastructure, MaaS API, and wires metrics
# Safe to re-run.

set -Eeuo pipefail

# -------- configuration --------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

OPS_NS="${OPS_NS:-openshift-operators}"  # where kuadrant operators live (CSVs)
KUADRANT_NS="${KUADRANT_NS:-kuadrant-system}" # where Kuadrant/Limitador/Authorino instances live
APP_NS="${APP_NS:-maas-api}"             # maas-api namespace
WIRE_SCRIPT="${WIRE_SCRIPT:-${SCRIPT_DIR}/wire-metrics.sh}"
VERSION_HELPERS="${SCRIPT_DIR}/version-check-helpers.sh"

# Required versions
KUADRANT_VERSION="1.3.0"
AUTHORINO_VERSION="0.22.0"
LIMITADOR_VERSION="0.16.0"

# -------- helpers --------
die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# Helper function to wait for CRD to be established
wait_for_crd() {
  local crd="$1"
  local timeout="${2:-60}"  # timeout in seconds
  local interval=2
  local elapsed=0

  echo "   ⏳ Waiting for CRD ${crd} to appear (timeout: ${timeout}s)…"
  while [ $elapsed -lt $timeout ]; do
    if kubectl get crd "$crd" &>/dev/null; then
      echo "   ✅ CRD ${crd} detected, waiting for it to become Established..."
      kubectl wait --for=condition=Established --timeout="${timeout}s" "crd/$crd" 2>/dev/null
      return 0
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo "   ❌ Timed out after ${timeout}s waiting for CRD $crd to appear." >&2
  return 1
}

# Helper function to wait for CSV to reach Succeeded state
wait_for_csv() {
  local csv_name="$1"
  local namespace="${2:-kuadrant-system}"
  local timeout="${3:-180}"  # timeout in seconds
  local interval=5
  local elapsed=0
  local last_status_print=0

  echo "   ⏳ Waiting for CSV ${csv_name} to succeed (timeout: ${timeout}s)..."
  while [ $elapsed -lt $timeout ]; do
    local phase=$(kubectl get csv -n "$namespace" "$csv_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

    case "$phase" in
      "Succeeded")
        echo "   ✅ CSV ${csv_name} succeeded"
        return 0
        ;;
      "Failed")
        echo "   ❌ CSV ${csv_name} failed" >&2
        kubectl get csv -n "$namespace" "$csv_name" -o jsonpath='{.status.message}' 2>/dev/null
        return 1
        ;;
      *)
        if [ $((elapsed - last_status_print)) -ge 30 ]; then
          echo "   CSV ${csv_name} status: ${phase} (${elapsed}s elapsed)"
          last_status_print=$elapsed
        fi
        ;;
    esac

    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo "   ❌ Timed out after ${timeout}s waiting for CSV ${csv_name}" >&2
  return 1
}

# version_compare <version1> <version2>
#   Compares two version strings in semantic version format (e.g., "4.19.9")
#   Returns 0 if version1 >= version2, 1 otherwise
version_compare() {
  local version1="$1"
  local version2="$2"
  
  local v1=$(echo "$version1" | awk -F. '{printf "%d%03d%03d", $1, $2, $3}')
  local v2=$(echo "$version2" | awk -F. '{printf "%d%03d%03d", $1, $2, $3}')
  
  [ "$v1" -ge "$v2" ]
}

# -------- preflight --------
need oc
need kubectl
need kustomize
need envsubst

# Source version checking helpers
if [[ ! -f "${VERSION_HELPERS}" ]]; then
  die "version check helpers not found: ${VERSION_HELPERS}"
fi
source "${VERSION_HELPERS}"

echo "========================================="
echo "📊 MaaS Observability Deployment"
echo "========================================="
echo ""
echo "Using:"
echo "  - OPS_NS: ${OPS_NS} (operators)"
echo "  - KUADRANT_NS: ${KUADRANT_NS} (Kuadrant/Limitador/Authorino instances)"
echo "  - APP_NS: ${APP_NS} (MaaS API)"
echo "  - PROJECT_ROOT: ${PROJECT_ROOT}"
echo ""

# -------- [Step 0] Ensure Required Namespaces --------
echo "[Step 0] Checking OpenShift version and Gateway API requirements..."

# Get OpenShift version
OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
echo "   OpenShift version: $OCP_VERSION"

# Check if version is 4.19.9 or higher
if [[ "$OCP_VERSION" == "unknown" ]]; then
    echo "   ⚠️  Could not determine OpenShift version, applying feature gates to be safe"
    oc patch featuregate/cluster --type='merge' \
      -p '{"spec":{"featureSet":"CustomNoUpgrade","customNoUpgrade":{"enabled":["GatewayAPI","GatewayAPIController"]}}}' || true
    echo "   Waiting for feature gates to reconcile (30 seconds)..."
    sleep 30
elif version_compare "$OCP_VERSION" "4.19.9"; then
    echo "   ✅ OpenShift $OCP_VERSION supports Gateway API via GatewayClass (no feature gates needed)"
else
    echo "   Applying Gateway API feature gates for OpenShift < 4.19.9"
    oc patch featuregate/cluster --type='merge' \
      -p '{"spec":{"featureSet":"CustomNoUpgrade","customNoUpgrade":{"enabled":["GatewayAPI","GatewayAPIController"]}}}' || true
    echo "   Waiting for feature gates to reconcile (30 seconds)..."
    sleep 30
fi

echo ""
echo "[Step 1] Ensuring required namespaces exist..."

# Required namespaces for MaaS platform
REQUIRED_NAMESPACES=(
  "$OPS_NS"        # openshift-operators - where operator CSVs live
  "$KUADRANT_NS"   # kuadrant-system - where Kuadrant/Limitador/Authorino instances live
  "$APP_NS"        # maas-api - application
  "openshift-ingress"  # Gateway resources
  "llm"            # Model serving (optional)
)

for ns in "${REQUIRED_NAMESPACES[@]}"; do
  ensure_namespace "$ns" || echo "   ⚠️  Continuing despite namespace issue..."
done

# -------- [Step 1] Install Cert-Manager --------
echo ""
echo "[Step 2] Installing Cert-Manager (if needed)..."

if check_crd_exists "certificates.cert-manager.io"; then
  echo "   ✅ Cert-Manager already installed, skipping"
else
  echo "   📦 Installing Cert-Manager..."
  "$SCRIPT_DIR/../installers/install-cert-manager.sh"
  echo "   ⏳ Waiting for cert-manager CRDs to be established..."
  sleep 10
  check_crd_exists "certificates.cert-manager.io" || echo "   ⚠️  Cert-Manager CRD not yet available"
fi

# -------- [Step 3] Check for OpenDataHub/RHOAI KServe --------
echo ""
echo "[Step 3] Checking for OpenDataHub/RHOAI KServe..."

if kubectl get crd llminferenceservices.serving.kserve.io &>/dev/null 2>&1; then
    echo "   ✅ KServe CRDs already present (ODH/RHOAI detected)"
else
    echo "   ⚠️  KServe not detected. Deploying ODH KServe components..."
    "$SCRIPT_DIR/../install-dependencies.sh" --ocp --odh
fi

# -------- [Step 2] Check Kuadrant Operators --------
echo ""
echo "[Step 4] Checking Kuadrant operators..."

# Only clean up leftover CRDs if Kuadrant operators are NOT already installed
echo "   Checking for existing Kuadrant installation..."
if ! kubectl get csv -n "$OPS_NS" -o name 2>/dev/null | grep -q "kuadrant-operator"; then
    echo "   No existing installation found, checking for leftover CRDs..."
    LEFTOVER_CRDS=$(kubectl get crd 2>/dev/null | grep -E "kuadrant|authorino|limitador" | awk '{print $1}' || true)
    if [ -n "$LEFTOVER_CRDS" ]; then
        echo "   ⚠️  Found leftover CRDs from previous installations, cleaning up..."
        echo "$LEFTOVER_CRDS" | xargs -r kubectl delete crd --timeout=30s 2>/dev/null || true
        echo "   ✅ Cleanup complete, waiting for stabilization..."
        sleep 5
    else
        echo "   ✅ No leftover CRDs found"
    fi
else
    echo "   ✅ Kuadrant operator already installed, skipping CRD cleanup"
fi

DEPLOY_KUADRANT=false

if check_operator_version "kuadrant-operator" "$KUADRANT_VERSION" "$OPS_NS"; then
  echo "   Kuadrant operator meets requirements"
else
  DEPLOY_KUADRANT=true
fi

if check_operator_version "authorino-operator" "$AUTHORINO_VERSION" "$OPS_NS"; then
  echo "   Authorino operator meets requirements"
else
  DEPLOY_KUADRANT=true
fi

if check_operator_version "limitador-operator" "$LIMITADOR_VERSION" "$OPS_NS"; then
  echo "   Limitador operator meets requirements"
else
  DEPLOY_KUADRANT=true
fi

# Deploy if needed
if [ "$DEPLOY_KUADRANT" = true ]; then
  echo ""
  echo "   📦 Installing/upgrading Kuadrant operators..."
  "$SCRIPT_DIR/../install-dependencies.sh" --kuadrant
  echo "   ⏳ Waiting for operators to be installed by OLM..."
  
  # Wait for CSVs to reach Succeeded state
  wait_for_csv "kuadrant-operator.v${KUADRANT_VERSION}" "$OPS_NS" 300 || \
    echo "   ⚠️  Kuadrant operator CSV did not succeed, continuing anyway..."
  
  wait_for_csv "authorino-operator.v${AUTHORINO_VERSION}" "$OPS_NS" 60 || \
    echo "   ⚠️  Authorino operator CSV did not succeed"
  
  wait_for_csv "limitador-operator.v${LIMITADOR_VERSION}" "$OPS_NS" 60 || \
    echo "   ⚠️  Limitador operator CSV did not succeed"
  
  echo "   ⏳ Waiting for operators to stabilize..."
  sleep 15
else
  echo "   ✅ All Kuadrant operators meet requirements, skipping deployment"
fi

# -------- [Step 3] Check Required CRDs --------
echo ""
echo "[Step 5] Checking required CRDs..."

# Define CRDs with their required versions
declare -A REQUIRED_CRDS=(
  ["authpolicies.kuadrant.io"]="v1"
  ["ratelimitpolicies.kuadrant.io"]="v1"
  ["tokenratelimitpolicies.kuadrant.io"]="v1alpha1"  # Fixed: actual version is v1alpha1
  ["telemetrypolicies.extensions.kuadrant.io"]="v1alpha1"
)

CRDS_OK=true
for crd_name in "${!REQUIRED_CRDS[@]}"; do
  required_version="${REQUIRED_CRDS[$crd_name]}"
  
  if check_crd_version "$crd_name" "$required_version"; then
    # CRD exists with correct version
    :
  else
    CRDS_OK=false
  fi
done

if [ "$CRDS_OK" = false ]; then
  echo "   ⚠️  Some CRDs missing or wrong version, waiting for operator installation..."
  sleep 10
  echo "   Rechecking CRDs..."
  for crd_name in "${!REQUIRED_CRDS[@]}"; do
    required_version="${REQUIRED_CRDS[$crd_name]}"
    check_crd_version "$crd_name" "$required_version" || echo "   ❌ Still issues with: $crd_name"
  done
fi

# -------- [Step 4] Deploy Gateway Infrastructure --------
echo ""
echo "[Step 6] Deploying Gateway infrastructure..."

# Get cluster domain
CLUSTER_DOMAIN=$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)
if [ -z "$CLUSTER_DOMAIN" ]; then
  echo "   ⚠️  Could not retrieve cluster domain, using default"
  CLUSTER_DOMAIN="apps.example.com"
fi
export CLUSTER_DOMAIN
echo "   Cluster domain: $CLUSTER_DOMAIN"

# Check if Gateway exists
if check_resource_exists "gateway" "maas-default-gateway" "openshift-ingress"; then
  echo "   Gateway infrastructure already exists, ensuring it's up to date..."
else
  echo "   📦 Creating Gateway infrastructure..."
fi

cd "$PROJECT_ROOT"
kubectl apply --server-side=true --force-conflicts -f <(envsubst '$CLUSTER_DOMAIN' < deployment/base/networking/gateway-api.yaml) || \
  echo "   ⚠️  Gateway deployment had issues, continuing..."

# -------- [Step 5] Deploy Kuadrant Instance --------
echo ""
echo "[Step 7] Deploying Kuadrant instance..."

if check_resource_exists "kuadrant" "kuadrant" "$KUADRANT_NS"; then
  echo "   Kuadrant instance already exists, ensuring it's up to date..."
else
  echo "   📦 Creating Kuadrant instance (will create Limitador/Authorino)..."
fi

cd "$PROJECT_ROOT"
kubectl apply -f deployment/base/networking/kuadrant.yaml || \
  echo "   ⚠️  Kuadrant instance deployment had issues, continuing..."

echo "   ⏳ Waiting for Limitador and Authorino to be created..."
sleep 10

# -------- [Step 6] Check MaaS API Service --------
echo ""
echo "[Step 8] Checking MaaS API Service..."

if check_deployment_ready "maas-api" "$APP_NS"; then
  echo "   MaaS API already deployed and ready"
else
  echo "   📦 Deploying MaaS API Service..."
  cd "$PROJECT_ROOT"
  kustomize build deployment/base/maas-api | envsubst | kubectl apply -f -
  echo "   ⏳ Waiting for MaaS API to be ready..."
  kubectl rollout status deployment/maas-api -n "$APP_NS" --timeout=60s || \
    echo "   ⚠️  MaaS API taking longer than expected"
fi

# -------- [Step 7] Restart Kuadrant Operator --------
echo ""
echo "[Step 9] Restarting Kuadrant operator for Gateway API recognition..."

if kubectl rollout restart deployment/kuadrant-operator-controller-manager -n "$KUADRANT_NS" 2>&1; then
  echo "   ✅ Kuadrant operator restarted"
else
  echo "   ⚠️  Could not restart Kuadrant operator (deployment may not exist yet)"
fi

echo "   ⏳ Waiting for operator to be ready..."
if kubectl rollout status deployment/kuadrant-operator-controller-manager -n "$KUADRANT_NS" --timeout=60s 2>&1; then
  echo "   ✅ Operator ready"
else
  echo "   ⚠️  Operator not ready after 60s (this is OK if deployment is still being created)"
fi

# -------- [Step 8] Wait for Gateway Ready --------
echo ""
echo "[Step 10] Waiting for Gateway to be ready..."
echo "   Note: This may take a few minutes if Service Mesh is being automatically installed..."

# Wait for Service Mesh CRDs to be established
if kubectl get crd istios.sailoperator.io &>/dev/null 2>&1; then
    echo "   ✅ Service Mesh operator already detected"
else
    echo "   Waiting for automatic Service Mesh installation..."
    if wait_for_crd "istios.sailoperator.io" 300; then
        echo "   ✅ Service Mesh operator installed"
    else
        echo "   ⚠️  Service Mesh CRD not detected within timeout"
        echo "      Gateway may take longer to become ready or require manual Service Mesh installation"
    fi
fi

echo "   ⏳ Checking Gateway status..."
GW_STATUS=$(kubectl get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "Unknown")
GW_REASON=$(kubectl get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].reason}' 2>/dev/null || echo "")
GW_MESSAGE=$(kubectl get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].message}' 2>/dev/null || echo "")

if [[ "$GW_STATUS" == "True" ]]; then
  echo "   ✅ Gateway is Programmed and ready"
elif [[ "$GW_STATUS" == "False" ]]; then
  echo "   ⚠️  Gateway Programmed=False (Reason: $GW_REASON)"
  [[ -n "$GW_MESSAGE" ]] && echo "      Message: $GW_MESSAGE"
  echo "   ⏳ Waiting up to 5 minutes for Gateway to become ready..."
  if kubectl wait --for=condition=Programmed gateway maas-default-gateway -n openshift-ingress --timeout=300s 2>&1; then
    echo "   ✅ Gateway is now ready"
  else
    echo "   ⚠️  Gateway still not ready after 5 minutes, continuing anyway"
    echo "      Check with: kubectl describe gateway maas-default-gateway -n openshift-ingress"
  fi
elif [[ "$GW_STATUS" == "Unknown" ]]; then
  echo "   ⚠️  Gateway status is Unknown (Reason: $GW_REASON)"
  [[ -n "$GW_MESSAGE" ]] && echo "      Message: $GW_MESSAGE"
  echo "      Gateway may still be initializing, continuing..."
else
  echo "   ⚠️  Gateway Programmed condition not found, continuing anyway"
fi

# -------- [Step 9] Deploy Gateway Policies --------
echo ""
echo "[Step 11] Deploying Gateway policies (Auth, RateLimit, TokenRateLimit)..."

if check_resource_exists "authpolicy" "gateway-auth-policy" "openshift-ingress"; then
  echo "   Gateway policies exist, ensuring they're up to date..."
else
  echo "   📦 Creating Gateway policies..."
fi

cd "$PROJECT_ROOT"
kustomize build deployment/base/policies | kubectl apply --server-side=true --force-conflicts -f - || \
  echo "   ⚠️  Policy deployment had issues, continuing..."

# -------- [Step 10] Patch AuthPolicy with Correct Audience --------
echo ""
echo "[Step 12] Patching AuthPolicy with correct audience..."

# Temporarily disable exit-on-error for this complex command
set +e
AUD="$(kubectl create token default --duration=10m 2>/dev/null | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '.aud[0]' 2>/dev/null)"
AUD_EXIT_CODE=$?
set -e

if [ $AUD_EXIT_CODE -ne 0 ]; then
  echo "   ⚠️  Could not detect audience (token command failed), skipping AuthPolicy patch"
elif [ -n "$AUD" ] && [ "$AUD" != "null" ]; then
  echo "   Detected audience: $AUD"
  kubectl patch authpolicy maas-api-auth-policy -n "$APP_NS" \
    --type='json' \
    -p "$(jq -nc --arg aud "$AUD" '[{
      op:"replace",
      path:"/spec/rules/authentication/openshift-identities/kubernetesTokenReview/audiences/0",
      value:$aud
    }]')" 2>/dev/null && \
    echo "   ✅ AuthPolicy patched" || \
    echo "   ⚠️  Could not patch AuthPolicy (may need manual configuration)"
else
  echo "   ⚠️  Could not detect audience (empty or null), skipping AuthPolicy patch"
fi

# -------- [Step 11] Update Limitador Image for Metrics --------
echo ""
echo "[Step 13] Updating Limitador image for metrics exposure..."

kubectl -n "$KUADRANT_NS" patch limitador limitador --type merge \
  -p '{"spec":{"image":"quay.io/kuadrant/limitador:1a28eac1b42c63658a291056a62b5d940596fd4c","version":""}}' 2>/dev/null && \
  echo "   ✅ Limitador image updated" || \
  echo "   ⚠️  Could not update Limitador image (may not be critical)"

echo "   ⏳ Waiting for Limitador to restart with new image..."
sleep 5

# -------- [Step 11.5] Operator Restart Workarounds --------
echo ""
echo "   🔧 Applying temporary workarounds - restarting all operators to refresh webhook configurations..."

kubectl delete pod -n "$KUADRANT_NS" -l control-plane=controller-manager 2>/dev/null && \
  echo "   ✅ Kuadrant operator pods deleted" || \
  echo "   ⚠️  Could not delete Kuadrant operator pods"

kubectl rollout restart deployment authorino-operator -n "$KUADRANT_NS" 2>/dev/null && \
  echo "   ✅ Authorino operator restarted" || \
  echo "   ⚠️  Could not restart Authorino operator"

kubectl rollout restart deployment limitador-operator-controller-manager -n "$KUADRANT_NS" 2>/dev/null && \
  echo "   ✅ Limitador operator restarted" || \
  echo "   ⚠️  Could not restart Limitador operator"

echo "   ⏳ Waiting for operators to be ready..."
kubectl rollout status deployment kuadrant-operator-controller-manager -n "$KUADRANT_NS" --timeout=60s 2>/dev/null || \
  echo "   ⚠️  Kuadrant operator taking longer than expected"
kubectl rollout status deployment authorino-operator -n "$KUADRANT_NS" --timeout=60s 2>/dev/null || \
  echo "   ⚠️  Authorino operator taking longer than expected"
kubectl rollout status deployment limitador-operator-controller-manager -n "$KUADRANT_NS" --timeout=60s 2>/dev/null || \
  echo "   ⚠️  Limitador operator taking longer than expected"

# -------- [Step 12] Deploy Observability Resources --------
echo ""
echo "[Step 14] Deploying observability resources..."

# Check Limitador ServiceMonitor (in kuadrant-system)
if check_resource_exists "servicemonitor" "limitador-metrics" "kuadrant-system"; then
  echo "   Limitador ServiceMonitor exists, ensuring it's up to date..."
else
  echo "   Creating Limitador ServiceMonitor..."
fi

# Check TelemetryPolicy
if check_resource_exists "telemetrypolicy" "user-group" "openshift-ingress"; then
  echo "   TelemetryPolicy exists, ensuring it's up to date..."
else
  echo "   Creating TelemetryPolicy..."
fi

cd "$PROJECT_ROOT"
kustomize build deployment/base/observability | kubectl apply -f -
echo "   ✅ Observability resources applied"

# -------- [Step 13] Wire Authorino Metrics --------
echo ""
echo "[Step 15] Wiring Authorino metrics to User Workload Monitoring..."

if [[ ! -x "${WIRE_SCRIPT}" ]]; then
  die "wire script not found or not executable: ${WIRE_SCRIPT} (chmod +x wire-metrics.sh)"
fi

"${WIRE_SCRIPT}" --ops-ns "${OPS_NS}" --kuadrant-ns "${KUADRANT_NS}" --app-ns "${APP_NS}"

# -------- [Step 14] Validate Deployment --------
echo ""
echo "[Step 16] Validating deployment..."

VALIDATE_SCRIPT="${PROJECT_ROOT}/deployment/scripts/validate-deployment.sh"
if [[ -x "${VALIDATE_SCRIPT}" ]]; then
  echo "   Running comprehensive deployment validation..."
  "${VALIDATE_SCRIPT}" || echo "   ⚠️  Some validation checks failed (see above)"
else
  echo "   ⚠️  Validation script not found or not executable: ${VALIDATE_SCRIPT}"
  echo "   Skipping detailed validation..."
fi

# -------- [Step 15] Deployment Summary --------
echo ""
echo "========================================="
echo "✅ MaaS Platform Deployment Complete!"
echo "========================================="
echo ""
echo "📝 Cleanup Information:"
echo "========================================="
echo ""
echo "The script automatically cleaned up orphaned Kuadrant CRDs before installation."
echo ""
echo "If you need to manually clean up resources from failed deployments:"
echo ""
echo "1. Remove all policies:"
echo "   kubectl delete authpolicies,ratelimitpolicies,tokenratelimitpolicies,telemetrypolicies --all -A"
echo ""
echo "2. Remove Gateway resources:"
echo "   kubectl delete gateway maas-default-gateway -n openshift-ingress"
echo "   kubectl delete gatewayclass openshift-default"
echo ""
echo "3. Remove Kuadrant instance:"
echo "   kubectl delete kuadrant kuadrant -n $KUADRANT_NS"
echo ""
echo "4. Remove operators (if needed):"
echo "   kubectl delete csv -n $OPS_NS -l operators.coreos.com/kuadrant-operator.$OPS_NS"
echo ""
echo "5. Remove all Kuadrant CRDs (nuclear option):"
echo "   kubectl get crd | grep -E 'kuadrant|authorino|limitador' | awk '{print \$1}' | xargs kubectl delete crd"
echo ""

