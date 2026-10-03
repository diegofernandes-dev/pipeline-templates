#!/usr/bin/env bash
# Fail-closed target identity + render-driven cluster capability preflight.
# Used by templates/dotnet/helm-deploy.yml (and tested via fake kubectl on PATH).
#
# Subcommands:
#   identity      — expectedKubeContext + awsAccountId must be set and exact-match
#   capabilities  — from helm render: HPA→metrics API; PVC→StorageClass + CSI
set -Eeuo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  preflight-deploy-target.sh identity \
    --area AREA --tier TIER \
    --expected-context CTX --actual-context CTX \
    --expected-account ID --actual-account ID

  preflight-deploy-target.sh capabilities --render RENDER.yaml
EOF
  exit 2
}

die() {
  echo "error: $*" >&2
  exit 1
}

is_missing() {
  local v="${1:-}"
  [[ -z "${v}" || "${v}" == "null" ]]
}

cmd_identity() {
  local area="" tier="" expected_context="" actual_context="" expected_account="" actual_account=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --area) area="${2:-}"; shift 2 ;;
      --tier) tier="${2:-}"; shift 2 ;;
      --expected-context) expected_context="${2:-}"; shift 2 ;;
      --actual-context) actual_context="${2:-}"; shift 2 ;;
      --expected-account) expected_account="${2:-}"; shift 2 ;;
      --actual-account) actual_account="${2:-}"; shift 2 ;;
      -h|--help) usage ;;
      *) die "unknown identity flag: $1" ;;
    esac
  done
  [[ -n "${area}" && -n "${tier}" ]] || die "identity requires --area and --tier"

  if is_missing "${expected_context}"; then
    cat >&2 <<EOF
Target identity validation failed:
area=${area}
tier=${tier}
expectedKubeContext is not configured in platform/areas/${area}.yml
deployment refused
EOF
    exit 1
  fi
  if [[ "${actual_context}" != "${expected_context}" ]]; then
    cat >&2 <<EOF
Target identity validation failed:
expected Kubernetes context: ${expected_context}
actual Kubernetes context: ${actual_context:-<empty>}
deployment refused
EOF
    exit 1
  fi
  echo "kubectl context matches expectedKubeContext for ${area}/${tier}"

  if is_missing "${expected_account}"; then
    cat >&2 <<EOF
Target identity validation failed:
area=${area}
tier=${tier}
awsAccountId is not configured in platform/areas/${area}.yml
deployment refused
EOF
    exit 1
  fi
  if [[ "${actual_account}" != "${expected_account}" ]]; then
    cat >&2 <<EOF
Expected AWS account ${expected_account}
Actual AWS account ${actual_account:-<empty>}
deployment refused
EOF
    exit 1
  fi
  echo "sts account matches cluster awsAccountId ${expected_account}"
}

# Returns 0 if metrics.k8s.io/v1beta1 is served.
metrics_api_available() {
  local raw
  if ! raw="$(kubectl get --raw /apis/metrics.k8s.io/v1beta1 2>/dev/null)"; then
    return 1
  fi
  [[ -n "${raw}" ]]
}

# Resolve StorageClass name for a PVC: explicit field or exactly one cluster default.
resolve_storage_class_for_pvc() {
  local sc_name="$1"
  if [[ -n "${sc_name}" && "${sc_name}" != "null" ]]; then
    printf '%s' "${sc_name}"
    return 0
  fi
  local sc_list names count joined
  if ! sc_list="$(kubectl get storageclass -o json 2>/dev/null)"; then
    die "preflight cannot verify required capability due to RBAC or API error (get storageclasses)"
  fi
  # Sorted for deterministic error messages / tests.
  names="$(printf '%s' "${sc_list}" | yq -r '[.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name] | sort | .[]')"
  count=0
  if [[ -n "${names}" ]]; then
    count="$(printf '%s\n' "${names}" | grep -c .)"
  fi
  case "${count}" in
    0)
      die "Persistence requested but no storageClassName was specified and cluster has no default StorageClass"
      ;;
    1)
      printf '%s' "${names}"
      ;;
    *)
      joined="$(printf '%s\n' "${names}" | paste -sd, -)"
      die "Persistence requested without storageClassName but cluster has multiple default StorageClasses: ${joined}
deployment refused"
      ;;
  esac
}

require_csidriver() {
  local driver="$1"
  local out
  if out="$(kubectl get csidriver "${driver}" -o jsonpath='{.metadata.name}' 2>/dev/null)" \
     && [[ "${out}" == "${driver}" ]]; then
    echo "CSIDriver ${driver} present"
    return 0
  fi
  # Distinguish NotFound (can list drivers) from RBAC/API failure (cannot verify).
  if kubectl get csidriver >/dev/null 2>&1; then
    die "CSIDriver '${driver}' is not registered (required by StorageClass provisioner capability)
deployment refused"
  fi
  die "preflight cannot verify required capability due to RBAC or API error (get csidriver ${driver})"
}

# AWS-only: in-tree kubernetes.io/aws-ebs migrates to ebs.csi.aws.com.
require_provisioner_capability() {
  local provisioner="$1"
  case "${provisioner}" in
    ebs.csi.aws.com|kubernetes.io/aws-ebs)
      require_csidriver "ebs.csi.aws.com"
      ;;
    *.csi.*)
      require_csidriver "${provisioner}"
      ;;
    "")
      die "StorageClass has empty provisioner"
      ;;
    *)
      die "StorageClass provisioner '${provisioner}' is not a known CSI provisioner for this AWS-only platform — refusing deploy"
      ;;
  esac
}

check_pvc_storage() {
  local render="$1"
  local sc_names sc_name sc_json provisioner
  # Collect storageClassName from each PVC (empty string if omitted).
  sc_names="$(yq ea -r 'select(.kind == "PersistentVolumeClaim") | .spec.storageClassName // ""' "${render}")"
  while IFS= read -r sc_name || [[ -n "${sc_name}" ]]; do
    local resolved
    resolved="$(resolve_storage_class_for_pvc "${sc_name}")"
    if ! sc_json="$(kubectl get storageclass "${resolved}" -o json 2>/dev/null)"; then
      # Distinguish missing vs RBAC: try list
      if ! kubectl get storageclass >/dev/null 2>&1; then
        die "preflight cannot verify required capability due to RBAC or API error (get storageclass)"
      fi
      die "StorageClass '${resolved}' not found (required by rendered PersistentVolumeClaim)"
    fi
    provisioner="$(printf '%s' "${sc_json}" | yq -r '.provisioner // ""')"
    echo "StorageClass ${resolved} provisioner=${provisioner}"
    require_provisioner_capability "${provisioner}"
  done <<< "${sc_names}"
}

cmd_capabilities() {
  local render=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --render) render="${2:-}"; shift 2 ;;
      -h|--help) usage ;;
      *) die "unknown capabilities flag: $1" ;;
    esac
  done
  [[ -n "${render}" && -f "${render}" ]] || die "capabilities requires --render <file>"

  if grep -qx 'kind: HorizontalPodAutoscaler' "${render}"; then
    if ! metrics_api_available; then
      die "metrics.k8s.io/v1beta1 unavailable but HorizontalPodAutoscaler will be rendered — deployment refused"
    fi
    echo "metrics.k8s.io available (HPA present in render)"
  else
    echo "metrics.k8s.io check skipped (no HPA in render)"
  fi

  if grep -qx 'kind: PersistentVolumeClaim' "${render}"; then
    check_pvc_storage "${render}"
  else
    echo "storage capability check skipped (no PVC in render)"
  fi
}

main() {
  [[ $# -ge 1 ]] || usage
  local sub="$1"
  shift
  case "${sub}" in
    identity) cmd_identity "$@" ;;
    capabilities) cmd_capabilities "$@" ;;
    -h|--help) usage ;;
    *) die "unknown subcommand: ${sub}" ;;
  esac
}

main "$@"
