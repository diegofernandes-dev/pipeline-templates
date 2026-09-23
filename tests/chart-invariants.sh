#!/usr/bin/env bash
# Contract tests for asa-application + asa-scheduled-job (kind → chart).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_CHART="${ROOT}/charts/asa-application"
JOB_CHART="${ROOT}/charts/asa-scheduled-job"
FAILED=0

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if ! grep -qF -- "$needle" <<<"$haystack"; then
    echo "FAIL: $msg (missing: $needle)"
    FAILED=1
  else
    echo "OK: $msg"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    echo "FAIL: $msg (unexpected: $needle)"
    FAILED=1
  else
    echo "OK: $msg"
  fi
}

count_kind() {
  local haystack="$1" kind="$2"
  grep -c "^kind: ${kind}$" <<<"$haystack" || true
}

assert_kind_count() {
  local haystack="$1" kind="$2" expected="$3" msg="$4"
  local got
  got="$(count_kind "$haystack" "$kind")"
  if [[ "$got" -ne "$expected" ]]; then
    echo "FAIL: $msg (expected ${expected} kind: ${kind}, got ${got})"
    FAILED=1
  else
    echo "OK: $msg"
  fi
}

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
    "$@"
}

echo "== Application / web minimal =="
OUT_WEB="$(render_app)"
assert_kind_count "$OUT_WEB" Deployment 1 "web: 1 Deployment"
assert_kind_count "$OUT_WEB" Service 1 "web: 1 Service"
assert_kind_count "$OUT_WEB" HTTPRoute 1 "web: 1 HTTPRoute"
assert_kind_count "$OUT_WEB" GRPCRoute 0 "web: 0 GRPCRoute"
assert_kind_count "$OUT_WEB" CronJob 0 "web: 0 CronJob"
assert_contains "$OUT_WEB" "containerPort: 8080" "web port 8080"
assert_contains "$OUT_WEB" "sample-api.dev.asa.corp" "web corp DNS"
assert_not_contains "$OUT_WEB" "sample-api.d.asa.com.br" "web no legacy DNS by default"
assert_not_contains "$OUT_WEB" "startupProbe:" "web no probes by default"
assert_kind_count "$OUT_WEB" HorizontalPodAutoscaler 1 "web: default HPA"
assert_not_contains "$OUT_WEB" "appProtocol: kubernetes.io/h2c" "web no h2c"

echo "== Application / web + probes =="
OUT_WEB_P="$(render_app --set-json 'probes={"path":"/health-check"}')"
assert_contains "$OUT_WEB_P" "startupProbe:" "web probes startup"
assert_contains "$OUT_WEB_P" 'path: "/health-check"' "web probe path"

echo "== Application / web + legacyDns =="
OUT_WEB_L="$(render_app --set legacyDns=true)"
assert_contains "$OUT_WEB_L" "sample-api.d.asa.com.br" "web legacy DNS"

echo "== Application / grpc minimal =="
OUT_GRPC="$(render_app --set-string workload.type=grpc)"
assert_kind_count "$OUT_GRPC" Deployment 1 "grpc: 1 Deployment"
assert_kind_count "$OUT_GRPC" Service 1 "grpc: 1 Service"
assert_kind_count "$OUT_GRPC" HTTPRoute 0 "grpc: 0 HTTPRoute"
assert_kind_count "$OUT_GRPC" GRPCRoute 1 "grpc: 1 GRPCRoute"
assert_kind_count "$OUT_GRPC" CronJob 0 "grpc: 0 CronJob"
assert_contains "$OUT_GRPC" "containerPort: 50051" "grpc port 50051"
assert_contains "$OUT_GRPC" "appProtocol: kubernetes.io/h2c" "grpc Service h2c"
assert_contains "$OUT_GRPC" "name: ASPNETCORE_URLS" "grpc ASPNETCORE_URLS override"
assert_contains "$OUT_GRPC" "value: Http2" "grpc Kestrel Http2"
assert_kind_count "$OUT_GRPC" HorizontalPodAutoscaler 1 "grpc: default HPA"

echo "== Application / grpc + probes =="
OUT_GRPC_P="$(render_app --set-string workload.type=grpc --set-json 'probes={"readiness":{"enabled":true}}')"
assert_contains "$OUT_GRPC_P" "readinessProbe:" "grpc readiness"
assert_contains "$OUT_GRPC_P" "grpc:" "grpc probe type"
assert_not_contains "$OUT_GRPC_P" "httpGet:" "grpc probe has no httpGet"

echo "== Application / worker minimal =="
OUT_WORKER="$(render_app --set-string workload.type=worker)"
assert_kind_count "$OUT_WORKER" Deployment 1 "worker: 1 Deployment"
assert_kind_count "$OUT_WORKER" Service 0 "worker: 0 Service"
assert_kind_count "$OUT_WORKER" HTTPRoute 0 "worker: 0 HTTPRoute"
assert_kind_count "$OUT_WORKER" GRPCRoute 0 "worker: 0 GRPCRoute"
assert_kind_count "$OUT_WORKER" CronJob 0 "worker: 0 CronJob"
assert_kind_count "$OUT_WORKER" HorizontalPodAutoscaler 0 "worker: no HPA by default"
assert_not_contains "$OUT_WORKER" "kind: HorizontalPodAutoscaler" "worker: no HPA resource"

echo "== Application / worker + explicit autoscaling =="
OUT_WORKER_HPA="$(render_app --set-string workload.type=worker \
  --set autoscaling.minReplicas=1 --set autoscaling.maxReplicas=2 --set autoscaling.cpu.target=70)"
assert_kind_count "$OUT_WORKER_HPA" HorizontalPodAutoscaler 1 "worker: HPA when autoscaling explicit"

echo "== ScheduledJob minimal =="
OUT_JOB="$(render_job \
  --set-string 'schedule.expression=0 2 * * *' \
  --set-string 'execution.args[0]=--mode=job')"
assert_kind_count "$OUT_JOB" CronJob 1 "job: 1 CronJob"
assert_kind_count "$OUT_JOB" Deployment 0 "job: 0 Deployment"
assert_kind_count "$OUT_JOB" Service 0 "job: 0 Service"
assert_kind_count "$OUT_JOB" HTTPRoute 0 "job: 0 HTTPRoute"
assert_kind_count "$OUT_JOB" GRPCRoute 0 "job: 0 GRPCRoute"
assert_contains "$OUT_JOB" "restartPolicy: Never" "job restartPolicy Never"
assert_contains "$OUT_JOB" 'timeZone: "America/Sao_Paulo"' "job default timeZone"
assert_contains "$OUT_JOB" "concurrencyPolicy: Forbid" "job default Forbid"

echo "== ScheduledJob completo =="
OUT_JOB_FULL="$(render_job \
  --set-string 'schedule.expression=0 2 * * *' \
  --set-string schedule.timeZone=America/Sao_Paulo \
  --set schedule.startingDeadlineSeconds=600 \
  --set execution.timeoutSeconds=1800 \
  --set execution.retries=2 \
  --set history.successful=2 \
  --set history.failed=3 \
  --set-string 'execution.args[0]=--mode=job')"
assert_contains "$OUT_JOB_FULL" 'timeZone: "America/Sao_Paulo"' "job timeZone"
assert_contains "$OUT_JOB_FULL" "startingDeadlineSeconds: 600" "job startingDeadline"
assert_contains "$OUT_JOB_FULL" "activeDeadlineSeconds: 1800" "job timeout"
assert_contains "$OUT_JOB_FULL" "backoffLimit: 2" "job retries"
assert_contains "$OUT_JOB_FULL" "successfulJobsHistoryLimit: 2" "job history success"
assert_contains "$OUT_JOB_FULL" "failedJobsHistoryLimit: 3" "job history failed"

echo "== Application / web readiness-only =="
OUT_WEB_RO="$(render_app --set-json 'probes={"readiness":{"path":"/healthz"}}')"
assert_contains "$OUT_WEB_RO" "readinessProbe:" "web readiness-only"
assert_not_contains "$OUT_WEB_RO" "startupProbe:" "web readiness-only no startup"
assert_not_contains "$OUT_WEB_RO" "livenessProbe:" "web readiness-only no liveness"

echo "== Application / grpc + legacyDns =="
OUT_GRPC_L="$(render_app --set-string workload.type=grpc --set legacyDns=true)"
assert_contains "$OUT_GRPC_L" "kind: GRPCRoute" "grpc legacy has GRPCRoute"
assert_contains "$OUT_GRPC_L" "sample-api.d.asa.com.br" "grpc legacy hostname"
assert_kind_count "$OUT_GRPC_L" HTTPRoute 0 "grpc legacy no HTTPRoute"

echo "== Application / HPA cpu.target + env hostnames =="
OUT_HPA="$(render_app --set autoscaling.minReplicas=2 --set autoscaling.maxReplicas=5 --set autoscaling.cpu.target=55)"
assert_contains "$OUT_HPA" "averageUtilization: 55" "HPA maps cpu.target"
OUT_HML="$(render_app --set-string runtime.environment=homolog)"
assert_contains "$OUT_HML" "sample-api.hml.asa.corp" "homolog hostname"
assert_contains "$OUT_HML" "h-asa-com-br-internal-gateway" "homolog gateway"

echo "== Application / opt-ins IRSA WIF PVC =="
OUT_IRSA="$(render_app --set-string 'serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::1:role/r')"
assert_contains "$OUT_IRSA" "eks.amazonaws.com/role-arn" "IRSA"
WIF_AUD="//iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/providers/eks"
OUT_WIF="$(render_app \
  --set-string "workloadIdentity.gcp.audience=${WIF_AUD}" \
  --set-string workloadIdentity.gcp.serviceAccountEmail=a@b.iam.gserviceaccount.com)"
assert_contains "$OUT_WIF" "GOOGLE_APPLICATION_CREDENTIALS" "WIF"
assert_contains "$OUT_WIF" 'audience: "sts.amazonaws.com"' "WIF projected aud"
OUT_PVC="$(render_app --set autoscaling=false --set replicaCount=1 \
  --set-string persistence.mountPath=/data --set-string persistence.size=1Gi)"
assert_contains "$OUT_PVC" "kind: PersistentVolumeClaim" "PVC"
assert_contains "$OUT_PVC" "type: Recreate" "PVC Recreate"

echo "== examples render =="
OUT_EX_APP="$(render_app -f "${ROOT}/examples/deploy/config/develop.yaml")"
assert_kind_count "$OUT_EX_APP" Deployment 1 "example Application Deployment"
assert_kind_count "$OUT_EX_APP" HTTPRoute 1 "example Application HTTPRoute"
OUT_EX_JOB="$(render_job -f "${ROOT}/examples/deploy/config/scheduled-job.example.yaml")"
assert_kind_count "$OUT_EX_JOB" CronJob 1 "example ScheduledJob CronJob"
assert_kind_count "$OUT_EX_JOB" Deployment 0 "example ScheduledJob no Deployment"

echo "== negatives =="
if render_app --set-string workload.type=worker --set legacyDns=true >/dev/null 2>&1; then
  echo "FAIL: worker + legacyDns should fail"; FAILED=1
else
  echo "OK: worker + legacyDns fails"
fi

if render_app --set-json 'workload={"type":"worker","port":8080}' >/dev/null 2>&1; then
  echo "FAIL: worker + port should fail"; FAILED=1
else
  echo "OK: worker + port / workload.port rejected"
fi

if render_app --set-json 'workload={"type":"web","port":9090}' >/dev/null 2>&1; then
  echo "FAIL: workload.port should fail"; FAILED=1
else
  echo "OK: workload.port rejected for web"
fi

if OUT_BAD="$(render_app --set-string workload.type=grpc --set-json 'probes={"readiness":{"path":"/health"}}' 2>&1)"; then
  echo "FAIL: grpc + HTTP path should fail"; FAILED=1
else
  assert_contains "$OUT_BAD" "invalid for grpc" "grpc + path fail message"
fi

if OUT_BAD2="$(render_app --set-json 'probes={"readiness":{"enabled":true}}' 2>&1)"; then
  echo "FAIL: web + enabled-only should fail"; FAILED=1
else
  assert_contains "$OUT_BAD2" "enabled is for grpc only" "web + enabled fail message"
fi

if render_app --set-string workload.type=banana >/dev/null 2>&1; then
  echo "FAIL: unknown workload.type should fail"; FAILED=1
else
  echo "OK: unknown workload.type fails"
fi

if render_app --set-string kind=ScheduledJob >/dev/null 2>&1; then
  echo "FAIL: Application chart + kind ScheduledJob should fail"; FAILED=1
else
  echo "OK: wrong kind on Application fails"
fi

if render_job --set-string 'schedule.expression=0 2 * * *' --set-string 'execution.args[0]=x' --set-string workload.type=web >/dev/null 2>&1; then
  echo "FAIL: ScheduledJob + workload should fail"; FAILED=1
else
  echo "OK: ScheduledJob + workload fails"
fi

if render_job --set-string kind=Application --set-string 'schedule.expression=0 2 * * *' --set-string 'execution.args[0]=x' >/dev/null 2>&1; then
  echo "FAIL: ScheduledJob chart + kind Application should fail"; FAILED=1
else
  echo "OK: wrong kind on ScheduledJob fails"
fi

if render_app --set-json 'probes={"path":"/health-check","readiness":{"path":"/ready"}}' >/dev/null 2>&1; then
  echo "FAIL: probes global+specific should fail"; FAILED=1
else
  echo "OK: probes global+specific fails"
fi

if render_app --set-json 'probes={"path":"healthz"}' >/dev/null 2>&1; then
  echo "FAIL: invalid probe path should fail"; FAILED=1
else
  echo "OK: invalid probe path fails"
fi

if render_app --set probes=true >/dev/null 2>&1; then
  echo "FAIL: probes: true should fail"; FAILED=1
else
  echo "OK: probes: true fails"
fi

if render_app --set-string workload.type=worker --set-json 'probes={"path":"/x"}' >/dev/null 2>&1; then
  echo "FAIL: worker + probes should fail"; FAILED=1
else
  echo "OK: worker + probes fails"
fi

if render_job --set-string 'schedule.expression=0 2 * * *' >/dev/null 2>&1; then
  echo "FAIL: job without command/args should fail"; FAILED=1
else
  echo "OK: job without command/args fails"
fi

if render_job --set-string 'schedule.expression=0 * * * *' --set-string 'execution.args[0]=x' --set legacyDns=true >/dev/null 2>&1; then
  echo "FAIL: job + legacyDns should fail"; FAILED=1
else
  echo "OK: job + legacyDns fails"
fi

if render_app --set-string persistence.mountPath=/data --set-string persistence.size=1Gi >/dev/null 2>&1; then
  echo "FAIL: PVC + HPA should fail"; FAILED=1
else
  echo "OK: PVC + HPA fails"
fi

if [[ -d "${ROOT}/charts/app" ]]; then
  echo "FAIL: charts/app should be removed"; FAILED=1
else
  echo "OK: charts/app removed"
fi

if grep -q exposeAsaComBr "${ROOT}/templates/dotnet/"*.yml 2>/dev/null; then
  echo "FAIL: exposeAsaComBr still in pipeline templates"; FAILED=1
else
  echo "OK: exposeAsaComBr removed from pipeline"
fi

if render_job --set-string 'schedule.expression=0 * * * *' --set-string 'execution.args[0]=x' --set-string schedule.concurrencyPolicy=Nope >/dev/null 2>&1; then
  echo "FAIL: bad concurrencyPolicy should fail"; FAILED=1
else
  echo "OK: bad concurrencyPolicy fails"
fi

if render_job --set-string 'schedule.expression=0 * * * *' --set-string 'execution.args[0]=x' --set-string schedule.timeZone= >/dev/null 2>&1; then
  echo "FAIL: empty timeZone should fail"; FAILED=1
else
  echo "OK: empty timeZone fails"
fi

echo "== public manifesto schema =="
VALIDATE="${ROOT}/scripts/validate-manifest.py"
if python3 -c 'import yaml' >/dev/null 2>&1; then
  python3 "${VALIDATE}" "${ROOT}/schemas/application.manifest.schema.json" \
    "${ROOT}/examples/deploy/config/develop.yaml"
  python3 "${VALIDATE}" "${ROOT}/schemas/scheduled-job.manifest.schema.json" \
    "${ROOT}/examples/deploy/config/scheduled-job.example.yaml"
  if echo '{"kind":"Application","workload":{"type":"web"},"legasyDns":true}' \
    | python3 "${VALIDATE}" "${ROOT}/schemas/application.manifest.schema.json" --stdin >/dev/null 2>&1; then
    echo "FAIL: legasyDns should be rejected"; FAILED=1
  else
    echo "OK: legasyDns rejected"
  fi
  if echo '{"kind":"Application","workload":{"type":"web"},"image":{"repository":"x"}}' \
    | python3 "${VALIDATE}" "${ROOT}/schemas/application.manifest.schema.json" --stdin >/dev/null 2>&1; then
    echo "FAIL: image in public manifesto should be rejected"; FAILED=1
  else
    echo "OK: image rejected on public manifesto"
  fi
else
  echo "SKIP: public schema tests (PyYAML missing)"
fi

echo "== chart drift =="
bash "${ROOT}/tests/chart-drift.sh"

echo "== helm lint =="
helm lint "${APP_CHART}"
helm lint "${JOB_CHART}"

if [[ "$FAILED" -ne 0 ]]; then
  echo "Some invariants failed"
  exit 1
fi
echo "All chart invariants passed"
