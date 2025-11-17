#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

KUADRANT_NS="openshift-operators"
CAT_NAME="kuadrant-operator-catalog"
CAT_IMAGE="${CAT_IMAGE:-quay.io/kuadrant/kuadrant-operator-catalog:v1.3.0}"

REQ_KUADRANT_CSV="${REQ_KUADRANT_CSV:-kuadrant-operator.v1.3.0}"
REQ_AUTHORINO_CSV="${REQ_AUTHORINO_CSV:-authorino-operator.v0.22.0}"
REQ_LIMITADOR_CSV="${REQ_LIMITADOR_CSV:-limitador-operator.v0.16.0}"
REQ_DNS_CSV="${REQ_DNS_CSV:-dns-operator.v0.15.0}"

log()  { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }

usage() {
  cat <<EOF
Usage: $0 [--kuadrant]

Environment:
  CAT_IMAGE            CatalogSource image (default: ${CAT_IMAGE})
  KUADRANT_NS          Namespace for operators (default: ${KUADRANT_NS})
  REQ_*_CSV            Exact CSV names to pin
EOF
}

ensure_catalogsource() {
  log "Ensuring CatalogSource ${CAT_NAME} in ${KUADRANT_NS} -> ${CAT_IMAGE}"
  cat <<YAML | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CAT_NAME}
  namespace: ${KUADRANT_NS}
  labels:
    managed-by: maas-installer
spec:
  sourceType: grpc
  image: ${CAT_IMAGE}
  displayName: Kuadrant Operators
  publisher: Kuadrant
YAML

  # Optional, but helps OLM discovery on some clusters: stable Service
  cat <<YAML | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${CAT_NAME}
  namespace: ${KUADRANT_NS}
  labels:
    olm.catalogSource: ${CAT_NAME}
    managed-by: maas-installer
spec:
  selector:
    olm.catalogSource: ${CAT_NAME}
  ports:
  - name: grpc
    port: 50051
    targetPort: 50051
YAML

  # Nudge: OLM sometimes wants a poke
  oc -n "${KUADRANT_NS}" get pod -l "olm.catalogSource=${CAT_NAME}" >/dev/null 2>&1 || true
}

patch_or_create_subscription() {
  local name="$1" package="$2" source="$3" source_ns="$4" channel="$5" starting_csv="$6"

  if oc -n "${KUADRANT_NS}" get subscription "${name}" >/dev/null 2>&1; then
    log "Patching Subscription ${name}"
    oc -n "${KUADRANT_NS}" patch subscription "${name}" --type merge -p "{
      \"spec\":{
        \"source\":\"${source}\",
        \"sourceNamespace\":\"${source_ns}\",
        \"channel\":\"${channel}\",
        \"startingCSV\":\"${starting_csv}\"
      }
    }"
  else
    log "Creating Subscription ${name}"
    cat <<YAML | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${name}
  namespace: ${KUADRANT_NS}
  labels:
    managed-by: maas-installer
spec:
  channel: ${channel}
  name: ${package}
  source: ${source}
  sourceNamespace: ${source_ns}
  startingCSV: ${starting_csv}
  installPlanApproval: Automatic
YAML
  fi
}

annotate_resolver_nudge() {
  for s in "$@"; do
    oc -n "${KUADRANT_NS}" annotate subscription "$s" "olm.resolvedAt=$(date +%s)" --overwrite || true
  done
}

install_kuadrant_stack() {
  # Check for existing Kuadrant installations in ANY namespace
  local existing_kuadrant
  existing_kuadrant="$(oc get csv -A -o json | jq -r '.items[] | select(.metadata.name | startswith("kuadrant-operator") or startswith("rhcl-operator")) | "\(.metadata.namespace)/\(.metadata.name)"' | head -1)"
  
  if [[ -n "${existing_kuadrant}" ]]; then
    local existing_ns="${existing_kuadrant%%/*}"
    local existing_csv="${existing_kuadrant##*/}"
    
    if [[ "${existing_ns}" != "${KUADRANT_NS}" ]]; then
      err "Found existing Kuadrant operator in namespace '${existing_ns}' (CSV: ${existing_csv})"
      err "This conflicts with installing in '${KUADRANT_NS}'"
      err "Please delete the conflicting installation first:"
      err "  oc delete csv ${existing_csv} -n ${existing_ns}"
      err "  # OR delete the entire namespace: oc delete namespace ${existing_ns}"
      exit 1
    else
      log "Found existing Kuadrant in target namespace ${KUADRANT_NS}, will upgrade/patch if needed"
    fi
  fi

  ensure_catalogsource

  # Find the current dns-operator subscription name (the long one on OCP)
  local dns_sub
  dns_sub="$(oc -n "${KUADRANT_NS}" get subscription -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.name}{"\n"}{end}' \
            | awk '$2=="dns-operator"{print $1; exit}')"
  if [[ -z "${dns_sub}" ]]; then
    # Fallback name if nothing exists (rare on vanilla OCP) — we'll create one
    dns_sub="dns-operator"
  fi

  # Subscriptions pinned to our catalog & versions
  patch_or_create_subscription "authorino-operator" "authorino-operator" "${CAT_NAME}" "${KUADRANT_NS}" "stable" "${REQ_AUTHORINO_CSV}"
  patch_or_create_subscription "limitador-operator" "limitador-operator" "${CAT_NAME}" "${KUADRANT_NS}" "stable" "${REQ_LIMITADOR_CSV}"
  patch_or_create_subscription "${dns_sub}"         "dns-operator"       "${CAT_NAME}" "${KUADRANT_NS}" "stable" "${REQ_DNS_CSV}"
  patch_or_create_subscription "kuadrant-operator"  "kuadrant-operator"  "${CAT_NAME}" "${KUADRANT_NS}" "stable" "${REQ_KUADRANT_CSV}"

  annotate_resolver_nudge authorino-operator limitador-operator kuadrant-operator "${dns_sub}"
}

main() {
  [[ "${1:-}" == "--help" ]] && { usage; exit 0; }
  case "${1:-}" in
    --kuadrant)
      install_kuadrant_stack
      ;;
    "" )
      usage; exit 1;;
    *)
      err "Unknown flag: $1"; usage; exit 2;;
  esac
}

main "$@"
