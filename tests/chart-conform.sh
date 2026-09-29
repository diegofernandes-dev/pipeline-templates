#!/usr/bin/env bash
# Validate rendered chart manifests against Kubernetes + CRD JSON schemas (kubeconform).
# Catches malformed fields that grep-based invariants miss.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_CHART="${ROOT}/charts/asa-application"
JOB_CHART="${ROOT}/charts/asa-scheduled-job"
SCHEMA_DIR="${ROOT}/tests/schemas"
FAILED=0

if ! command -v kubeconform >/dev/null 2>&1; then
  echo "FAIL: kubeconform not found in PATH"
  exit 1
fi

render_app() {
  helm template sample-api "${APP_CHART}" \
    --set-string image.repository=example.dkr.ecr.us-east-1.amazonaws.com/sample-api \
    --set-string image.tag=deadbeef \
    --set-string runtime.environment=develop \
    "$@"
}

render_job() {
  helm template sample-job "${JOB_CHART}" \
    --set-string image.repository=example.dkr.ecr.us-east-1.amazonaws.com/sample-job \
    --set-string image.tag=deadbeef \
    --set-string 'schedule.expression=0 2 * * *' \
    --set-string schedule.timeZone=America/Sao_Paulo \
    --set execution.timeoutSeconds=1800 \
    --set-string 'execution.args[0]=--mode=job' \
    "$@"
}

conform() {
  local label="$1"
  shift
  local rendered out
  if ! rendered="$("$@" 2>/dev/null)"; then
    echo "FAIL: kubeconform ${label} (helm template failed)"
    FAILED=1
    return
  fi
  if ! out="$(kubeconform -strict -summary \
    -kubernetes-version 1.27.0 \
    -schema-location default \
    -schema-location "${SCHEMA_DIR}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
    <<<"$rendered" 2>&1)"; then
    echo "FAIL: kubeconform ${label}"
    echo "$out"
    FAILED=1
  else
    echo "OK: kubeconform ${label}"
  fi
}

echo "== kubeconform (strict, k8s 1.27) =="

conform "web probes:false" \
  render_app --set probes=false

conform "web readiness probe" \
  render_app --set-json 'probes={"readiness":{"path":"/health/ready"}}'

conform "grpc probes:false" \
  render_app --set-string workload.type=grpc --set probes=false

conform "grpc readiness enabled" \
  render_app --set-string workload.type=grpc --set-json 'probes={"readiness":{"enabled":true}}'

conform "worker" \
  render_app --set-string workload.type=worker

conform "production (PDB + topology)" \
  render_app --set probes=false --set-string runtime.environment=production

conform "persistence Recreate" \
  render_app --set probes=false --set autoscaling=false \
    --set-string persistence.mountPath=/data --set-string persistence.size=1Gi

conform "externalSecret" \
  render_app --set probes=false \
    --set-string externalSecret.secretStoreRef.name=aws-secrets \
    --set-json 'externalSecret.data=[{"secretKey":"DB","remoteRef":{"key":"prod/db","property":"password"}}]'

WIF_AUD="//iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/providers/eks"
conform "IRSA + WIF" \
  render_app --set probes=false \
    --set-string 'serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::1:role/r' \
    --set-string "workloadIdentity.gcp.audience=${WIF_AUD}" \
    --set-string workloadIdentity.gcp.serviceAccountEmail=a@b.iam.gserviceaccount.com

conform "ScheduledJob minimal" \
  render_job

conform "ScheduledJob + WIF" \
  render_job \
    --set-string "workloadIdentity.gcp.audience=${WIF_AUD}" \
    --set-string workloadIdentity.gcp.serviceAccountEmail=a@b.iam.gserviceaccount.com

conform "example Application" \
  render_app -f "${ROOT}/examples/deploy/config/develop.yaml"

conform "example ScheduledJob" \
  render_job -f "${ROOT}/examples/deploy/config/scheduled-job.example.yaml"

if [[ "$FAILED" -ne 0 ]]; then
  echo "kubeconform validation failed"
  exit 1
fi
echo "All rendered manifests conform to Kubernetes/CRD schemas"
