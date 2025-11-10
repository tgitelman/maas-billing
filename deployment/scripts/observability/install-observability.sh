#!/usr/bin/env bash
set -euo pipefail

##########################################################
# MaaS Billing • Observability • Install (manifests only)
# File: deployment/scripts/observability/install-observability.sh
##########################################################

### ─────────────────────────────────────────────────────────────────────────────
### 0) BOOTSTRAP & DEFAULTS
### ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(realpath "$SCRIPT_DIR/../../../")"
MANIFESTS_DIR_DEFAULT="$ROOT_DIR/manifests/observability"

NAMESPACE="${NAMESPACE:-observability-hub}"
MANIFESTS_DIR="${MANIFESTS_DIR:-$MANIFESTS_DIR_DEFAULT}"
YES="${YES:-false}"

### ─────────────────────────────────────────────────────────────────────────────
### 1) USAGE
### ─────────────────────────────────────────────────────────────────────────────
usage() {
  cat <<USAGE
Install Observability components (CRDs/objs via manifests).

Environment overrides:
  NAMESPACE        Target namespace (default: $NAMESPACE)
  MANIFESTS_DIR    Path to manifests (default: $MANIFESTS_DIR_DEFAULT)
  YES=true         Non-interactive

Examples:
  ./install-observability.sh --yes
USAGE
}

### ─────────────────────────────────────────────────────────────────────────────
### 2) ARG PARSE
### ─────────────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --yes) YES=true; shift ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --manifests) MANIFESTS_DIR="$2"; shift 2 ;;
    *) echo "[ERROR] Unknown arg: $1"; usage; exit 2 ;;
  esac
done

### ─────────────────────────────────────────────────────────────────────────────
### 3) SANITY & CONFIRM
### ─────────────────────────────────────────────────────────────────────────────
[[ -d "$MANIFESTS_DIR" ]] || { echo "[ERROR] Manifests dir not found: $MANIFESTS_DIR"; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "[ERROR] Not logged into OpenShift"; exit 3; }

echo "[INFO] Namespace       : $NAMESPACE"
echo "[INFO] Manifests dir   : $MANIFESTS_DIR"
if [[ "$YES" != "true" ]]; then
  read -r -p "Proceed applying manifests? [y/N] " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || { echo "Aborted."; exit 1; }
fi

### ─────────────────────────────────────────────────────────────────────────────
### 4) CREATE NAMESPACE (idempotent)
### ─────────────────────────────────────────────────────────────────────────────
oc get ns "$NAMESPACE" >/dev/null 2>&1 || oc create ns "$NAMESPACE"

### ─────────────────────────────────────────────────────────────────────────────
### 5) APPLY MANIFESTS (kustomize if present)
### ─────────────────────────────────────────────────────────────────────────────
if [[ -f "$MANIFESTS_DIR/kustomization.yaml" ]]; then
  echo "[INFO] Applying kustomize: $MANIFESTS_DIR"
  oc -n "$NAMESPACE" apply -k "$MANIFESTS_DIR"
else
  echo "[INFO] Applying raw YAMLs: $MANIFESTS_DIR"
  oc -n "$NAMESPACE" apply -f "$MANIFESTS_DIR"
fi

echo "[DONE] Observability manifests applied."
