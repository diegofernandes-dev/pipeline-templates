#!/usr/bin/env bash
# Server-side validation: render, then have a real API server validate without persisting.
#
# This is the only layer that sees the constraints Kubernetes enforces but does not express in
# its OpenAPI schema. Two real bugs in this repo lived exactly there, and kubeconform reported
# both as valid:
#   - app.kubernetes.io/version built from image.tag: a digest (sha256:...) or semver build
#     metadata (1.2.3+build.5) is rejected with "metadata.labels: Invalid value"
#   - workloadIdentity.token.mountPath colliding with /tmp or the persistence mount: rejected
#     with "must be unique"
# Both are now guarded earlier (sanitisation and fail-fast), and this suite is the backstop
# that would catch the next one of that class.
#
# Needs a reachable cluster with the Gateway API and external-secrets.io CRDs installed.
# CI creates a throwaway one; locally, point KUBE_CONTEXT at any cluster that has them.
#   KUBE_CONTEXT=k3d-asa-dryrun ./tests/chart-apply.sh
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_CHART="${ROOT}/charts/asa-application"
JOB_CHART="${ROOT}/charts/asa-scheduled-job"
CTX="${KUBE_CONTEXT:-$(kubectl config current-context 2>/dev/null || true)}"
NS="${APPLY_NAMESPACE:-asa-dryrun-probe}"
FAILED=0
CHECKS=0

WIF_AUD="//iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/providers/eks"

for cmd in helm kubectl; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "FAIL: ${cmd} is required for chart-apply.sh"
    exit 1
  fi
done
if [[ -z "${CTX}" ]]; then
  echo "FAIL: no kube context (set KUBE_CONTEXT)"
  exit 1
fi
if ! kubectl --context="${CTX}" --request-timeout=20s get --raw /version >/dev/null 2>&1; then
  echo "FAIL: cannot reach the API server for context '${CTX}'"
  exit 1
fi
echo "context: ${CTX}"
echo "  server: $(kubectl --context="${CTX}" get --raw /version 2>/dev/null \
  | tr ',' '\n' | sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p' | head -1)"

# A dry-run still resolves the namespace, so it has to exist. It is left in place afterwards:
# a dry-run creates nothing, so it stays empty, and deleting it would leave it Terminating and
# make the next run fail every apply with "namespace is being terminated".
kubectl --context="${CTX}" create namespace "${NS}" --dry-run=client -o yaml \
  | kubectl --context="${CTX}" apply -f - >/dev/null
# If a previous run left it Terminating, wait it out rather than reporting phantom failures.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  phase="$(kubectl --context="${CTX}" get namespace "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "${phase}" != "Terminating" ]] && break
  sleep 2
done

# The charts apply these; without the CRDs a dry-run would pass by simply skipping them.
for gv in gateway.networking.k8s.io/v1 external-secrets.io/v1; do
  if ! kubectl --context="${CTX}" get --raw "/apis/${gv}" >/dev/null 2>&1; then
    echo "FAIL: cluster does not serve ${gv} — install the CRDs or the dry-run silently proves nothing"
    FAILED=1
  fi
done
[[ "${FAILED}" -ne 0 ]] && exit 1

# dry_run <label> -- render-cmd...
dry_run() {
  local label="$1"
  shift
  [[ "${1:-}" == "--" ]] && shift
  CHECKS=$((CHECKS + 1))
  local rendered out
  if ! rendered="$("$@" 2>&1)"; then
    echo "FAIL: ${label} (helm template failed)"
    printf '%s\n' "${rendered}" | head -3 | sed 's/^/    /'
    FAILED=1
    return
  fi
  if ! out="$(printf '%s' "${rendered}" \
    | kubectl --context="${CTX}" -n "${NS}" apply --dry-run=server -f - 2>&1)"; then
    echo "FAIL: ${label} (API server rejected)"
    printf '%s\n' "${out}" | grep -iE 'error|invalid|must be|forbidden' | head -4 | sed 's/^/    /'
    FAILED=1
  else
    echo "OK: ${label}"
  fi
}

app() {
  local area="${PLATFORM_AREA:-lab}"
  local tier="${PLATFORM_TIER:-${PLATFORM_ENV:-develop}}"
  local pf rc=0
  pf="$(mktemp -t asa-platform.XXXXXX.yaml)"
  "${ROOT}/scripts/resolve-platform-values.sh" "${area}" "${tier}" "${pf}"
  helm template probe "${APP_CHART}" \
    --set-string image.repository=example.invalid/app \
    --set-string image.tag=deadbeef \
    -f "${pf}" \
    "$@" || rc=$?
  rm -f "${pf}"
  return "${rc}"
}
job() {
  local area="${PLATFORM_AREA:-lab}"
  local tier="${PLATFORM_TIER:-${PLATFORM_ENV:-develop}}"
  local pf rc=0
  pf="$(mktemp -t asa-platform.XXXXXX.yaml)"
  "${ROOT}/scripts/resolve-platform-values.sh" "${area}" "${tier}" "${pf}"
  helm template probe "${JOB_CHART}" \
    --set-string image.repository=example.invalid/job \
    --set-string image.tag=deadbeef \
    --set-string 'schedule.expression=0 2 * * *' \
    --set-string schedule.timeZone=America/Sao_Paulo \
    --set execution.timeoutSeconds=1800 \
    --set-string 'execution.args[0]=--mode=job' \
    -f "${pf}" \
    "$@" || rc=$?
  rm -f "${pf}"
  return "${rc}"
}

ALL_ON=(
  --set-string "workloadIdentity.gcp.audience=${WIF_AUD}"
  --set-string workloadIdentity.gcp.serviceAccountEmail=a@b.iam.gserviceaccount.com
  --set-string externalSecret.secretStoreRef.name=store
  --set-json 'externalSecret.data=[{"secretKey":"K","remoteRef":{"key":"r"}}]'
  --set-string config.FOO=bar
)

echo "== server-side apply --dry-run =="
dry_run "web / develop" -- app --set-string workload.type=web \
  --set-json 'probes={"readiness":{"path":"/h"}}'
PLATFORM_ENV=production dry_run "web / production (PDB + topology spread)" -- app --set-string workload.type=web \
  --set-json 'probes={"readiness":{"path":"/h"}}'
dry_run "web / all probes" -- app --set-string workload.type=web \
  --set-json 'probes={"startup":{"path":"/s"},"readiness":{"path":"/r"},"liveness":{"path":"/l"}}'
dry_run "grpc / h2c + native probes" -- app --set-string workload.type=grpc \
  --set-json 'probes={"readiness":{"enabled":true},"liveness":{"enabled":true}}'
dry_run "worker" -- app --set-string workload.type=worker
dry_run "worker / explicit autoscaling" -- app --set-string workload.type=worker \
  --set autoscaling.minReplicas=2 --set autoscaling.maxReplicas=4
dry_run "web / persistence (RWO, Recreate)" -- app --set-string workload.type=web \
  --set-json 'probes={"readiness":{"path":"/h"}}' --set autoscaling=false --set replicaCount=1 \
  --set-string persistence.mountPath=/data --set-string persistence.size=1Gi
dry_run "web / legacyDns" -- app --set-string workload.type=web \
  --set-json 'probes={"readiness":{"path":"/h"}}' --set legacyDns=true
PLATFORM_ENV=production dry_run "web / everything on" -- app --set-string workload.type=web \
  --set-json 'probes={"readiness":{"path":"/h"}}' "${ALL_ON[@]}"
dry_run "grpc / everything on" -- app --set-string workload.type=grpc \
  --set-json 'probes={"readiness":{"enabled":true}}' "${ALL_ON[@]}"
dry_run "worker / everything on" -- app --set-string workload.type=worker "${ALL_ON[@]}"
dry_run "ScheduledJob / minimal" -- job
dry_run "ScheduledJob / everything on" -- job "${ALL_ON[@]}"
dry_run "ScheduledJob / command entrypoint" -- job --set-string 'execution.command[0]=/app/start.sh'
dry_run "example Application" -- app -f "${ROOT}/examples/deploy/config/develop.yaml"
dry_run "example ScheduledJob" -- job -f "${ROOT}/examples/deploy/config/scheduled-job.example.yaml"

# Label values come from image.tag, which the pipeline sets per build. These forms all reach a
# label and must survive the API server's label syntax check.
echo "== image.tag forms that reach app.kubernetes.io/version =="
for TAG in "deadbeef1234" "sha256:abc123def456789" "1.2.3+build.5" "-leading.dash-"; do
  dry_run "app / image.tag=${TAG}" -- app --set-string workload.type=worker --set-string "image.tag=${TAG}"
  dry_run "job / image.tag=${TAG}" -- job --set-string "image.tag=${TAG}"
done

echo
if [[ "${FAILED}" -ne 0 ]]; then
  echo "Server-side validation failed (${CHECKS} manifests)"
  exit 1
fi
echo "Server-side validation clean: ${CHECKS} manifests accepted by a real API server"
