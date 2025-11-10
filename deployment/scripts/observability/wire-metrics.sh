#!/usr/bin/env bash
#
# wire-metrics.sh
# Idempotently wires UWM Prometheus to Authorino/Limitador without scraping non-metrics ports.
# - Labels OPS namespace for user-workload monitoring
# - Labels the Authorino *metrics* Service only
# - Creates a ServiceMonitor that selects just that Service
# - Removes stray 'monitoring.kuadrant.io/scrape' labels from non-metrics Services (if present)
# Safe to re-run.

set -Eeuo pipefail

OPS_NS="${OPS_NS:-openshift-operators}"
KUADRANT_NS="${KUADRANT_NS:-kuadrant-system}"
APP_NS="${APP_NS:-maas}"

# Flags (for future extensibility)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ops-ns) OPS_NS="$2"; shift 2;;
    --kuadrant-ns) KUADRANT_NS="$2"; shift 2;;
    --app-ns) APP_NS="$2"; shift 2;;
    *) echo "unknown flag: $1" >&2; exit 2;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

need oc
oc whoami >/dev/null 2>&1 || die "not logged in to the cluster (oc whoami failed)"

echo "▶ Wiring metrics in KUADRANT_NS=${KUADRANT_NS} (APP_NS=${APP_NS})"

# 1) Ensure the kuadrant-system namespace is opted into User Workload Monitoring
echo "→ Labeling namespace '${KUADRANT_NS}' with openshift.io/user-monitoring=true"
oc label namespace "${KUADRANT_NS}" openshift.io/user-monitoring=true --overwrite >/dev/null

# 2) Ensure Authorino *metrics* Service is labeled for selection
# Note: authorino-controller-metrics is in kuadrant-system (Authorino instance)
#       authorino-operator-metrics is in openshift-operators (operator itself)
AUTH_SVC="authorino-controller-metrics"
echo "→ Verifying Service '${AUTH_SVC}' exists in ${KUADRANT_NS}"
if ! oc -n "${KUADRANT_NS}" get svc "${AUTH_SVC}" >/dev/null 2>&1; then
  die "Service ${KUADRANT_NS}/${AUTH_SVC} not found. Is Authorino installed?"
fi

echo "→ Labeling ${KUADRANT_NS}/${AUTH_SVC} with maas.observability/authorino-controller=true"
oc -n "${KUADRANT_NS}" label svc "${AUTH_SVC}" maas.observability/authorino-controller=true --overwrite >/dev/null

# 3) Create/Update a focused ServiceMonitor that matches ONLY that metrics Service
SM_NAME="authorino-controller-sm"
echo "→ Applying ServiceMonitor ${KUADRANT_NS}/${SM_NAME} (idempotent)"
cat <<'YAML' | sed "s/{{KUADRANT_NS}}/${KUADRANT_NS}/g" | oc apply -f - >/dev/null
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: authorino-controller-sm
  namespace: {{KUADRANT_NS}}
  labels:
    # make it discoverable by UWM
    openshift.io/user-monitoring: "true"
    # ownership marker (housekeeping)
    maas.observability/owned: "true"
spec:
  namespaceSelector:
    matchNames:
      - {{KUADRANT_NS}}
  selector:
    matchLabels:
      # select only the metrics service we explicitly labeled
      maas.observability/authorino-controller: "true"
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
YAML

# 4) Remove stray scrape labels from non-metrics Services that caused 404s
#    These services don't expose /metrics; leaving the label causes Prometheus to try and fail.
for S in authorino-authorino-authorization authorino-authorino-oidc; do
  if oc -n "${KUADRANT_NS}" get svc "$S" >/dev/null 2>&1; then
    if oc -n "${KUADRANT_NS}" get svc "$S" -o jsonpath='{.metadata.labels.monitoring\.kuadrant\.io/scrape}' 2>/dev/null | grep -q .; then
      echo "→ Removing monitoring.kuadrant.io/scrape from ${KUADRANT_NS}/${S}"
      oc -n "${KUADRANT_NS}" label svc "$S" monitoring.kuadrant.io/scrape- >/dev/null || true
    fi
  fi
done

# 5) (Optional) Limitador is already exposed correctly by its own ServiceMonitor in kuadrant-system.
#    We deliberately don't touch it unless needed.

echo "✅ Metrics wiring complete."
echo "   - Prometheus (UWM) should now scrape ${KUADRANT_NS}/${AUTH_SVC} at /metrics."
echo "   - Non-metrics services won't be scraped (no more 404 targets)."
