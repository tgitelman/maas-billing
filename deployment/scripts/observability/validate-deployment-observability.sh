#!/usr/bin/env bash
set -euo pipefail

#############################################################
# MaaS Billing • Observability • Validate Deployment Health
# File: deployment/scripts/observability/validate-deployment-observability.sh
#############################################################

### ─────────────────────────────────────────────────────────────────────────────
### 0) BOOTSTRAP & DEFAULTS
### ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(realpath "$SCRIPT_DIR/../../../")"
NAMESPACE="${NAMESPACE:-observability-hub}"

### ─────────────────────────────────────────────────────────────────────────────
### 1) USAGE
### ─────────────────────────────────────────────────────────────────────────────
usage() {
  cat <<USAGE
Validate Observability deployment state.

Environment overrides:
  NAMESPACE    Target namespace (default: $NAMESPACE)

Examples:
  ./validate-deployment-observability.sh
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    *) echo "[ERROR] Unknown arg: $1"; usage; exit 2 ;;
  esac
done

### ─────────────────────────────────────────────────────────────────────────────
### 2) CHECKS
### ─────────────────────────────────────────────────────────────────────────────
oc whoami >/dev/null 2>&1 || { echo "[ERROR] Not logged into OpenShift"; exit 3; }

echo "[INFO] Namespace: $NAMESPACE"
oc get ns "$NAMESPACE" >/dev/null 2>&1 || { echo "[ERROR] Namespace not found"; exit 4; }

echo "─ Pods:"
oc -n "$NAMESPACE" get pods -o wide || true

echo "─ Deployments (Available desired/ready):"
oc -n "$NAMESPACE" get deploy -o custom-columns=NAME:.metadata.name,DESIRED:.status.replicas,AVAILABLE:.status.availableReplicas --no-headers || true

echo "─ Recent events:"
oc -n "$NAMESPACE" get events --sort-by=.lastTimestamp | tail -n 30 || true

echo "[DONE] Validation finished."
