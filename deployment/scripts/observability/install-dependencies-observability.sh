#!/usr/bin/env bash
set -euo pipefail

#############################################
# MaaS Billing • Observability • Dependencies
# File: deployment/scripts/observability/install-dependencies-observability.sh
#############################################

### ─────────────────────────────────────────────────────────────────────────────
### 0) BOOTSTRAP & DEFAULTS
### ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(realpath "$SCRIPT_DIR/../../../")"

# tools we need
REQUIRED_TOOLS=(oc jq kustomize)
YES="${YES:-false}"

### ─────────────────────────────────────────────────────────────────────────────
### 1) USAGE
### ─────────────────────────────────────────────────────────────────────────────
usage() {
  cat <<'USAGE'
Install prerequisites for Observability deployment.

Options:
  --yes            Non-interactive mode (assumes "yes" to prompts)
  -h, --help       Show help

Examples:
  ./install-dependencies-observability.sh --yes
USAGE
}

### ─────────────────────────────────────────────────────────────────────────────
### 2) ARG PARSE
### ─────────────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[ERROR] Unknown arg: $1"; usage; exit 2 ;;
  case_esac=true; done
done 2>/dev/null || true

### ─────────────────────────────────────────────────────────────────────────────
### 3) CONFIRM
### ─────────────────────────────────────────────────────────────────────────────
if [[ "$YES" != "true" ]]; then
  read -r -p "Proceed installing dependencies? [y/N] " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || { echo "Aborted."; exit 1; }
fi

### ─────────────────────────────────────────────────────────────────────────────
### 4) CHECK TOOLS
### ─────────────────────────────────────────────────────────────────────────────
missing=()
for t in "${REQUIRED_TOOLS[@]}"; do
  command -v "$t" >/dev/null 2>&1 || missing+=("$t")
done
if (( ${#missing[@]} )); then
  echo "[ERROR] Missing tools: ${missing[*]}"
  echo "Install them and re-run."
  exit 2
fi

echo "[OK] Tools present: ${REQUIRED_TOOLS[*]}"

### ─────────────────────────────────────────────────────────────────────────────
### 5) CLUSTER ACCESS
### ─────────────────────────────────────────────────────────────────────────────
oc whoami >/dev/null 2>&1 || { echo "[ERROR] Not logged into OpenShift (oc)"; exit 3; }
echo "[OK] Logged in as: $(oc whoami)"

echo "[DONE] Dependencies look good."
