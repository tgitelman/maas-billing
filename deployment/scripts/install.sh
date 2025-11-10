#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# Pretty logging
log()  { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }

export SKIP_KUADRANT="${SKIP_KUADRANT:-false}"
export FORCE_KUADRANT_INSTALL="${FORCE_KUADRANT_INSTALL:-false}"

log "Starting MaaS install (SKIP_KUADRANT=${SKIP_KUADRANT}, FORCE_KUADRANT_INSTALL=${FORCE_KUADRANT_INSTALL})"

"${SCRIPT_DIR}/deploy-openshift.sh" "$@"

log "Validating deployment..."
"${SCRIPT_DIR}/validate-deployment.sh"

log "✅ MaaS install/validation complete."
