#!/usr/bin/env bash
#
# deploy-openshift-observability.sh
# Thin orchestrator that delegates *all* metrics wiring to wire-metrics.sh
# Safe to re-run. Does not duplicate logic.

set -Eeuo pipefail

# -------- configuration --------
OPS_NS="${OPS_NS:-openshift-operators}"  # where authorino/limitador live
APP_NS="${APP_NS:-maas}"                 # your app namespace (optional for wiring)
WIRE_SCRIPT="${WIRE_SCRIPT:-./wire-metrics.sh}"

# -------- helpers --------
die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# -------- preflight --------
need oc
oc whoami >/dev/null 2>&1 || die "not logged in to the cluster (oc whoami failed)"

echo "▶ Using OPS_NS=${OPS_NS}  APP_NS=${APP_NS}"
echo "▶ Wire script: ${WIRE_SCRIPT}"

# -------- delegate to wiring --------
if [[ ! -x "${WIRE_SCRIPT}" ]]; then
  die "wire script not found or not executable: ${WIRE_SCRIPT} (chmod +x wire-metrics.sh)"
fi

# Always idempotent – the wire script itself guarantees it.
"${WIRE_SCRIPT}" --ops-ns "${OPS_NS}" --app-ns "${APP_NS}"

echo "✅ Observability wiring completed successfully."
