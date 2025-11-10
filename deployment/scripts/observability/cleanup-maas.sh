#!/usr/bin/env bash
#
# cleanup-maas.sh
# Cleanup script for MaaS Platform resources
# Use this to clean up orphaned resources from failed or incomplete deployments

set -Eeo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

OPS_NS="${OPS_NS:-openshift-operators}"
KUADRANT_NS="${KUADRANT_NS:-kuadrant-system}"
APP_NS="${APP_NS:-maas-api}"

echo "========================================="
echo "🧹 MaaS Platform Cleanup"
echo "========================================="
echo ""
echo -e "${YELLOW}⚠️  WARNING: This will remove MaaS platform resources!${NC}"
echo ""
echo "Namespaces:"
echo "  - OPS_NS: ${OPS_NS}"
echo "  - KUADRANT_NS: ${KUADRANT_NS}"
echo "  - APP_NS: ${APP_NS}"
echo ""

# Ask for confirmation
read -p "Are you sure you want to proceed? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo ""
echo "[1/7] Removing observability resources..."
kubectl delete servicemonitor limitador-metrics -n kuadrant-system 2>/dev/null && echo "  ✅ Limitador ServiceMonitor deleted" || echo "  ⚠️  No Limitador ServiceMonitor found"
kubectl delete servicemonitor authorino-controller-sm -n "$OPS_NS" 2>/dev/null && echo "  ✅ Authorino ServiceMonitor deleted" || echo "  ⚠️  No Authorino ServiceMonitor found"
kubectl delete telemetrypolicy user-group -n openshift-ingress 2>/dev/null && echo "  ✅ TelemetryPolicy deleted" || echo "  ⚠️  No TelemetryPolicy found"

echo ""
echo "[2/7] Removing all policies..."
kubectl delete authpolicies --all -A 2>/dev/null && echo "  ✅ AuthPolicies deleted" || echo "  ⚠️  No AuthPolicies found"
kubectl delete ratelimitpolicies --all -A 2>/dev/null && echo "  ✅ RateLimitPolicies deleted" || echo "  ⚠️  No RateLimitPolicies found"
kubectl delete tokenratelimitpolicies --all -A 2>/dev/null && echo "  ✅ TokenRateLimitPolicies deleted" || echo "  ⚠️  No TokenRateLimitPolicies found"
kubectl delete telemetrypolicies --all -A 2>/dev/null && echo "  ✅ TelemetryPolicies deleted" || echo "  ⚠️  No TelemetryPolicies found"

echo ""
echo "[3/7] Removing MaaS API..."
kubectl delete deployment maas-api -n "$APP_NS" 2>/dev/null && echo "  ✅ MaaS API deployment deleted" || echo "  ⚠️  No MaaS API deployment found"
kubectl delete service maas-api -n "$APP_NS" 2>/dev/null && echo "  ✅ MaaS API service deleted" || echo "  ⚠️  No MaaS API service found"
kubectl delete httproute maas-api-route -n "$APP_NS" 2>/dev/null && echo "  ✅ MaaS API HTTPRoute deleted" || echo "  ⚠️  No MaaS API HTTPRoute found"

echo ""
echo "[4/7] Removing Gateway resources..."
kubectl delete gateway maas-default-gateway -n openshift-ingress 2>/dev/null && echo "  ✅ Gateway deleted" || echo "  ⚠️  No Gateway found"

echo ""
echo "[5/7] Removing Kuadrant instance..."
kubectl delete kuadrant kuadrant -n "$KUADRANT_NS" 2>/dev/null && echo "  ✅ Kuadrant instance deleted" || echo "  ⚠️  No Kuadrant instance found"
echo "  ⏳ Waiting for Limitador and Authorino to be removed..."
sleep 5

echo ""
echo "[6/7] Checking for leftover Limitador/Authorino instances..."
kubectl delete limitador --all -n "$KUADRANT_NS" 2>/dev/null && echo "  ✅ Limitador instances deleted" || echo "  ⚠️  No Limitador instances found"
kubectl delete authorino --all -n "$KUADRANT_NS" 2>/dev/null && echo "  ✅ Authorino instances deleted" || echo "  ⚠️  No Authorino instances found"

echo ""
echo "[7/7] Cleanup complete!"
echo ""
echo "========================================="
echo "✅ Cleanup Complete!"
echo "========================================="
echo ""
echo "📝 Notes:"
echo "  - Namespaces were NOT deleted (may contain other resources)"
echo "  - Operators were NOT removed (ready for re-deployment)"
echo "  - CRDs were NOT removed (operators need them)"
echo "  - Cert-Manager was NOT removed"
echo "  - ODH/KServe was NOT removed"
echo ""
echo "ℹ️  You can now re-run the deployment script:"
echo "   ./deploy-openshift-observability.sh"
echo ""
echo "⚠️  If you want to fully uninstall operators and CRDs:"
echo "   kubectl delete csv -n openshift-operators -l operators.coreos.com/kuadrant-operator.openshift-operators"
echo "   kubectl get crd | grep -E 'kuadrant|authorino|limitador' | awk '{print \$1}' | xargs kubectl delete crd"
echo ""

