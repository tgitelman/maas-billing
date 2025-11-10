#!/usr/bin/env bash
#
# version-check-helpers.sh
# Smart version checking for idempotent deployments
# Skips deployment if installed version >= required version

set -Eeuo pipefail

# Extract version from CSV name like "kuadrant-operator.v1.3.0" -> "1.3.0"
extract_csv_version() {
  local csv_name="$1"
  echo "$csv_name" | sed -n 's/.*\.v\([0-9.]*\).*/\1/p'
}

# Compare semantic versions: returns 0 if v1 >= v2, 1 otherwise
version_gte() {
  local version1="$1"
  local version2="$2"
  
  # Convert to comparable integers: 1.3.0 -> 001003000
  local v1=$(echo "$version1" | awk -F. '{printf "%03d%03d%03d", $1, $2, $3}')
  local v2=$(echo "$version2" | awk -F. '{printf "%03d%03d%03d", $1, $2, $3}')
  
  [ "$v1" -ge "$v2" ]
}

# Check if operator CSV exists and meets minimum version
# Returns:
#   0 = operator exists with version >= required (SKIP deployment)
#   1 = operator missing or version < required (DEPLOY needed)
check_operator_version() {
  local operator_prefix="$1"
  local required_version="$2"
  local namespace="${3:-kuadrant-system}"
  
  # Find CSV matching the operator name pattern
  # Use grep instead of JSONPath regex for better compatibility
  local csv_name=$(kubectl get csv -n "$namespace" -o name 2>/dev/null | grep "/${operator_prefix}" | head -n1 | cut -d'/' -f2)
  
  if [ -z "$csv_name" ]; then
    echo "   ℹ️  $operator_prefix not found in $namespace"
    return 1  # Not installed, needs deployment
  fi
  
  # Check if it's in Succeeded state
  local phase=$(kubectl get csv "$csv_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "$phase" != "Succeeded" ]; then
    echo "   ⚠️  $csv_name exists but phase is: $phase (not Succeeded)"
    return 1  # Exists but not healthy
  fi
  
  # Extract and compare versions
  local installed_version=$(extract_csv_version "$csv_name")
  
  if [ -z "$installed_version" ]; then
    echo "   ⚠️  Could not parse version from $csv_name"
    return 1
  fi
  
  if version_gte "$installed_version" "$required_version"; then
    echo "   ✅ $csv_name (v$installed_version) >= required (v$required_version) - SKIPPING"
    return 0  # Version is good, skip deployment
  else
    echo "   ⚠️  $csv_name (v$installed_version) < required (v$required_version) - needs upgrade"
    return 1  # Older version, might need upgrade
  fi
}

# Check if CRD exists (simple check, no version)
check_crd_exists() {
  local crd_name="$1"
  if kubectl get crd "$crd_name" &>/dev/null; then
    echo "   ✅ CRD $crd_name exists"
    return 0
  else
    echo "   ℹ️  CRD $crd_name not found"
    return 1
  fi
}

# Check if CRD exists and has required version
# CRD versions are in spec.versions[].name (e.g., "v1", "v1beta1", "v1alpha1")
# Returns:
#   0 = CRD exists with version >= required (SKIP)
#   1 = CRD missing or doesn't have required version (DEPLOY needed)
check_crd_version() {
  local crd_name="$1"
  local required_version="$2"  # e.g., "v1", "v1beta1"
  
  if ! kubectl get crd "$crd_name" &>/dev/null; then
    echo "   ℹ️  CRD $crd_name not found"
    return 1
  fi
  
  # Get all versions supported by the CRD
  local versions=$(kubectl get crd "$crd_name" -o jsonpath='{.spec.versions[*].name}' 2>/dev/null)
  
  if [ -z "$versions" ]; then
    echo "   ⚠️  Could not get versions for CRD $crd_name"
    return 1
  fi
  
  # Check if required version is in the list
  if echo "$versions" | grep -qw "$required_version"; then
    echo "   ✅ CRD $crd_name supports version $required_version"
    return 0
  else
    echo "   ⚠️  CRD $crd_name exists but doesn't support version $required_version (has: $versions)"
    return 1
  fi
}

# Check if resource exists in namespace
check_resource_exists() {
  local resource_type="$1"
  local resource_name="$2"
  local namespace="$3"
  
  if kubectl get "$resource_type" "$resource_name" -n "$namespace" &>/dev/null 2>&1; then
    echo "   ✅ $resource_type/$resource_name exists in $namespace"
    return 0
  else
    echo "   ℹ️  $resource_type/$resource_name not found in $namespace"
    return 1
  fi
}

# Check if deployment is ready
check_deployment_ready() {
  local deployment="$1"
  local namespace="$2"
  
  if ! kubectl get deployment "$deployment" -n "$namespace" &>/dev/null 2>&1; then
    echo "   ℹ️  Deployment $deployment not found in $namespace"
    return 1
  fi
  
  local ready=$(kubectl get deployment "$deployment" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
  
  if [ "$ready" = "True" ]; then
    echo "   ✅ Deployment $deployment is ready"
    return 0
  else
    echo "   ⚠️  Deployment $deployment exists but not ready"
    return 1
  fi
}

# Check if namespace exists, create if missing
# Returns:
#   0 = namespace exists or was created successfully
#   1 = failed to create namespace
ensure_namespace() {
  local namespace="$1"
  
  if kubectl get namespace "$namespace" &>/dev/null 2>&1; then
    echo "   ✅ Namespace $namespace already exists"
    return 0
  else
    echo "   📦 Creating namespace $namespace..."
    if kubectl create namespace "$namespace" 2>/dev/null; then
      echo "   ✅ Namespace $namespace created"
      return 0
    else
      echo "   ❌ Failed to create namespace $namespace"
      return 1
    fi
  fi
}


