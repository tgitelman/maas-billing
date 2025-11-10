#!/usr/bin/env bash
#
# version-check-helpers-enhanced.sh
# Enhanced version that returns detailed status codes

# Check operator version with detailed status
# Returns via global variable OPERATOR_STATUS:
#   "OK" = version meets requirements
#   "MISSING" = operator not found
#   "UNHEALTHY" = operator exists but not in Succeeded state
#   "OUTDATED" = operator version < required
check_operator_version_detailed() {
  local operator_prefix="$1"
  local required_version="$2"
  local namespace="${3:-kuadrant-system}"
  
  # Find CSV
  local csv_name=$(kubectl get csv -n "$namespace" -o jsonpath="{.items[?(@.metadata.name=~'${operator_prefix}.*')].metadata.name}" 2>/dev/null | awk '{print $1}')
  
  if [ -z "$csv_name" ]; then
    echo "   ℹ️  $operator_prefix not found in $namespace"
    OPERATOR_STATUS="MISSING"
    return 1
  fi
  
  # Check health
  local phase=$(kubectl get csv "$csv_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "$phase" != "Succeeded" ]; then
    echo "   ⚠️  $csv_name exists but phase is: $phase"
    OPERATOR_STATUS="UNHEALTHY"
    return 1
  fi
  
  # Compare versions
  local installed_version=$(extract_csv_version "$csv_name")
  
  if [ -z "$installed_version" ]; then
    echo "   ⚠️  Could not parse version from $csv_name"
    OPERATOR_STATUS="UNHEALTHY"
    return 1
  fi
  
  if version_gte "$installed_version" "$required_version"; then
    echo "   ✅ $csv_name (v$installed_version) >= required (v$required_version) - SKIPPING"
    OPERATOR_STATUS="OK"
    return 0
  else
    echo "   ⚠️  $csv_name (v$installed_version) < required (v$required_version)"
    OPERATOR_STATUS="OUTDATED"
    return 1
  fi
}

# Usage example:
# if check_operator_version_detailed "kuadrant-operator" "1.3.0"; then
#   echo "All good!"
# else
#   case "$OPERATOR_STATUS" in
#     MISSING)   echo "Installing fresh...";;
#     OUTDATED)  echo "Upgrading...";;
#     UNHEALTHY) echo "Repairing...";;
#   esac
# fi

