#!/usr/bin/env bash
# Harness for scripts/preflight-deploy-target.sh (fake kubectl on PATH).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/scripts/preflight-deploy-target.sh"
FAILED=0
HELM_TOUCHED=0

[[ -f "${SCRIPT}" ]] || { echo "FAIL: missing ${SCRIPT}"; exit 1; }
chmod +x "${SCRIPT}"

WORKDIR="$(mktemp -d -t asa-preflight.XXXXXX)"
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

mkdir -p "${WORKDIR}/bin" "${WORKDIR}/renders"

# Fake helm — must never be invoked by the preflight script.
cat > "${WORKDIR}/bin/helm" <<'EOF'
#!/usr/bin/env bash
echo "UNEXPECTED_HELM_CALL $*" >&2
touch "${HELM_MARKER:-/tmp/asa-helm-touched}"
exit 99
EOF
chmod +x "${WORKDIR}/bin/helm"
export HELM_MARKER="${WORKDIR}/helm-touched"

# Configurable fake kubectl via env files written per case.
cat > "${WORKDIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
# Must be bash: Ubuntu /bin/sh is dash and rejects [[ ]].
set -euo pipefail
STATE="${KUBECTL_STATE_DIR:?}"
# Log every invocation for assertions.
printf '%s\n' "$*" >> "${STATE}/calls.log"

cmd="$1"
shift || true
case "${cmd}" in
  get)
    resource="${1:-}"
    case "${resource}" in
      --raw)
        path="${2:-}"
        if [[ -f "${STATE}/raw${path}" ]]; then
          cat "${STATE}/raw${path}"
          exit 0
        fi
        if [[ -f "${STATE}/raw_deny" ]]; then
          echo "Error from server (Forbidden)" >&2
          exit 1
        fi
        echo "Error from server (NotFound): ${path}" >&2
        exit 1
        ;;
      storageclass|storageclasses|sc)
        name="${2:-}"
        if [[ "${name}" == "-o" || -z "${name}" ]]; then
          # list
          if [[ -f "${STATE}/sc-list.json" ]]; then
            cat "${STATE}/sc-list.json"
            exit 0
          fi
          echo "Error from server (Forbidden)" >&2
          exit 1
        fi
        # kubectl get storageclass NAME -o json
        if [[ -f "${STATE}/sc/${name}.json" ]]; then
          cat "${STATE}/sc/${name}.json"
          exit 0
        fi
        if [[ -f "${STATE}/sc-list-ok" && ! -f "${STATE}/sc/${name}.json" ]]; then
          echo "Error from server (NotFound): storageclasses.storage.k8s.io \"${name}\" not found" >&2
          exit 1
        fi
        echo "Error from server (Forbidden)" >&2
        exit 1
        ;;
      csidriver|csidrivers)
        name="${2:-}"
        if [[ -f "${STATE}/csi/${name}" ]]; then
          if printf '%s' "$*" | grep -q jsonpath; then
            printf '%s' "${name}"
          else
            printf '%s\n' "${name}"
          fi
          exit 0
        fi
        if [[ -f "${STATE}/csi-list-ok" ]]; then
          echo "Error from server (NotFound): csidrivers.storage.k8s.io \"${name}\" not found" >&2
          exit 1
        fi
        echo "Error from server (Forbidden)" >&2
        exit 1
        ;;
      *)
        echo "fake kubectl: unhandled get ${resource}" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "fake kubectl: unhandled $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${WORKDIR}/bin/kubectl"

export PATH="${WORKDIR}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

reset_state() {
  rm -rf "${WORKDIR}/state"
  mkdir -p "${WORKDIR}/state/raw/apis" "${WORKDIR}/state/sc" "${WORKDIR}/state/csi"
  : > "${WORKDIR}/state/calls.log"
  rm -f "${HELM_MARKER}"
}

assert_no_helm() {
  if [[ -f "${HELM_MARKER}" ]]; then
    echo "FAIL: helm was invoked during preflight"
    FAILED=1
  fi
}

expect_fail() {
  local name="$1"
  shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    echo "FAIL: ${name} expected non-zero (got 0)"
    echo "${out}"
    FAILED=1
  else
    echo "OK: ${name} failed closed (rc=${rc})"
  fi
  assert_no_helm
}

expect_pass() {
  local name="$1"
  shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    echo "FAIL: ${name} expected pass (rc=${rc})"
    echo "${out}"
    FAILED=1
  else
    echo "OK: ${name}"
  fi
  assert_no_helm
}

# --- identity ---
echo "== identity =="
expect_fail "missing context" \
  bash "${SCRIPT}" identity --area lab --tier develop \
  --expected-context null --actual-context sample-template-pg \
  --expected-account 448003890252 --actual-account 448003890252

expect_fail "empty context" \
  bash "${SCRIPT}" identity --area lab --tier develop \
  --expected-context "" --actual-context sample-template-pg \
  --expected-account 448003890252 --actual-account 448003890252

expect_fail "context mismatch" \
  bash "${SCRIPT}" identity --area lab --tier develop \
  --expected-context eks-prod-a --actual-context eks-hml-a \
  --expected-account 448003890252 --actual-account 448003890252

expect_fail "missing account" \
  bash "${SCRIPT}" identity --area lab --tier develop \
  --expected-context sample-template-pg --actual-context sample-template-pg \
  --expected-account null --actual-account 448003890252

expect_fail "account mismatch" \
  bash "${SCRIPT}" identity --area lab --tier develop \
  --expected-context sample-template-pg --actual-context sample-template-pg \
  --expected-account 448003890252 --actual-account 999999999999

expect_pass "exact match" \
  bash "${SCRIPT}" identity --area lab --tier develop \
  --expected-context sample-template-pg --actual-context sample-template-pg \
  --expected-account 448003890252 --actual-account 448003890252

# --- capabilities helpers ---
write_hpa_render() {
  cat > "${WORKDIR}/renders/hpa.yaml" <<'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: demo
spec: {}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo
EOF
}

write_no_hpa_render() {
  cat > "${WORKDIR}/renders/no-hpa.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo
EOF
}

write_pvc_render() {
  local sc="${1:-}"
  if [[ -n "${sc}" ]]; then
    cat > "${WORKDIR}/renders/pvc.yaml" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: demo-data
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ${sc}
  resources:
    requests:
      storage: 1Gi
EOF
  else
    cat > "${WORKDIR}/renders/pvc.yaml" <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: demo-data
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
EOF
  fi
}

write_job_render() {
  cat > "${WORKDIR}/renders/job.yaml" <<'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: demo
spec:
  schedule: "*/5 * * * *"
EOF
}

enable_metrics() {
  mkdir -p "${WORKDIR}/state/raw/apis/metrics.k8s.io"
  cat > "${WORKDIR}/state/raw/apis/metrics.k8s.io/v1beta1" <<'EOF'
{"kind":"APIResourceList","apiVersion":"v1","groupVersion":"metrics.k8s.io/v1beta1","resources":[{"name":"nodes","kind":"NodeMetrics"}]}
EOF
}

write_sc() {
  local name="$1" provisioner="$2" is_default="${3:-false}"
  mkdir -p "${WORKDIR}/state/sc"
  if [[ "${is_default}" == "true" ]]; then
    cat > "${WORKDIR}/state/sc/${name}.json" <<EOF
{"apiVersion":"storage.k8s.io/v1","kind":"StorageClass","metadata":{"name":"${name}","annotations":{"storageclass.kubernetes.io/is-default-class":"true"}},"provisioner":"${provisioner}"}
EOF
  else
    cat > "${WORKDIR}/state/sc/${name}.json" <<EOF
{"apiVersion":"storage.k8s.io/v1","kind":"StorageClass","metadata":{"name":"${name}"},"provisioner":"${provisioner}"}
EOF
  fi
  # list for default discovery
  cat > "${WORKDIR}/state/sc-list.json" <<EOF
{"apiVersion":"v1","kind":"List","items":[$(cat "${WORKDIR}/state/sc/${name}.json")]}
EOF
  : > "${WORKDIR}/state/sc-list-ok"
}

enable_csi() {
  local name="$1"
  mkdir -p "${WORKDIR}/state/csi"
  : > "${WORKDIR}/state/csi/${name}"
  : > "${WORKDIR}/state/csi-list-ok"
}

echo "== capabilities: HPA =="
reset_state
export KUBECTL_STATE_DIR="${WORKDIR}/state"
write_hpa_render
expect_fail "HPA + metrics absent" \
  env KUBECTL_STATE_DIR="${WORKDIR}/state" bash "${SCRIPT}" capabilities --render "${WORKDIR}/renders/hpa.yaml"

reset_state
export KUBECTL_STATE_DIR="${WORKDIR}/state"
enable_metrics
write_hpa_render
expect_pass "HPA + metrics present" \
  env KUBECTL_STATE_DIR="${WORKDIR}/state" bash "${SCRIPT}" capabilities --render "${WORKDIR}/renders/hpa.yaml"

reset_state
export KUBECTL_STATE_DIR="${WORKDIR}/state"
write_no_hpa_render
expect_pass "no HPA + metrics absent" \
  env KUBECTL_STATE_DIR="${WORKDIR}/state" bash "${SCRIPT}" capabilities --render "${WORKDIR}/renders/no-hpa.yaml"

echo "== capabilities: PVC =="
reset_state
export KUBECTL_STATE_DIR="${WORKDIR}/state"
: > "${WORKDIR}/state/sc-list-ok"
write_pvc_render gp2
expect_fail "PVC + SC missing" \
  env KUBECTL_STATE_DIR="${WORKDIR}/state" bash "${SCRIPT}" capabilities --render "${WORKDIR}/renders/pvc.yaml"

reset_state
export KUBECTL_STATE_DIR="${WORKDIR}/state"
write_sc gp2 kubernetes.io/aws-ebs false
: > "${WORKDIR}/state/csi-list-ok"
write_pvc_render gp2
expect_fail "PVC + AWS EBS provisioner + CSI missing" \
  env KUBECTL_STATE_DIR="${WORKDIR}/state" bash "${SCRIPT}" capabilities --render "${WORKDIR}/renders/pvc.yaml"

reset_state
export KUBECTL_STATE_DIR="${WORKDIR}/state"
write_sc gp2 kubernetes.io/aws-ebs false
enable_csi ebs.csi.aws.com
write_pvc_render gp2
expect_pass "PVC + kubernetes.io/aws-ebs + ebs.csi.aws.com" \
  env KUBECTL_STATE_DIR="${WORKDIR}/state" bash "${SCRIPT}" capabilities --render "${WORKDIR}/renders/pvc.yaml"

reset_state
export KUBECTL_STATE_DIR="${WORKDIR}/state"
write_sc gp2 ebs.csi.aws.com true
enable_csi ebs.csi.aws.com
write_pvc_render ""
expect_pass "PVC + no SC name + default SC exists" \
  env KUBECTL_STATE_DIR="${WORKDIR}/state" bash "${SCRIPT}" capabilities --render "${WORKDIR}/renders/pvc.yaml"

reset_state
export KUBECTL_STATE_DIR="${WORKDIR}/state"
cat > "${WORKDIR}/state/sc-list.json" <<'EOF'
{"apiVersion":"v1","kind":"List","items":[]}
EOF
: > "${WORKDIR}/state/sc-list-ok"
write_pvc_render ""
expect_fail "PVC + no SC name + no default" \
  env KUBECTL_STATE_DIR="${WORKDIR}/state" bash "${SCRIPT}" capabilities --render "${WORKDIR}/renders/pvc.yaml"

echo "== critical regressions =="
# web + persistence (no HPA) + metrics absent + EBS present → PASS
reset_state
export KUBECTL_STATE_DIR="${WORKDIR}/state"
write_sc gp2 kubernetes.io/aws-ebs false
enable_csi ebs.csi.aws.com
cat > "${WORKDIR}/renders/web-pvc.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: demo-data
spec:
  storageClassName: gp2
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
EOF
expect_pass "persistence web: no HPA + metrics absent + EBS ok" \
  env KUBECTL_STATE_DIR="${WORKDIR}/state" bash "${SCRIPT}" capabilities --render "${WORKDIR}/renders/web-pvc.yaml"

# web default HPA + metrics absent → FAIL
reset_state
export KUBECTL_STATE_DIR="${WORKDIR}/state"
write_hpa_render
expect_fail "web HPA + metrics absent" \
  env KUBECTL_STATE_DIR="${WORKDIR}/state" bash "${SCRIPT}" capabilities --render "${WORKDIR}/renders/hpa.yaml"

# ScheduledJob-like: no HPA/PVC
reset_state
export KUBECTL_STATE_DIR="${WORKDIR}/state"
write_job_render
expect_pass "ScheduledJob: metrics/CSI absent skipped" \
  env KUBECTL_STATE_DIR="${WORKDIR}/state" bash "${SCRIPT}" capabilities --render "${WORKDIR}/renders/job.yaml"

if [[ "${FAILED}" -ne 0 ]]; then
  echo "DEPLOY TARGET PREFLIGHT: FAILED"
  exit 1
fi
echo "DEPLOY TARGET PREFLIGHT: OK"
