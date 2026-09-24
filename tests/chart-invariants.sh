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

# Always inject image + runtime (pipeline-owned).
render_app() {
  helm template sample-api "${APP_CHART}" \
    --set-string image.repository=example.dkr.ecr.us-east-1.amazonaws.com/sample-api \
    --set-string image.tag=deadbeef \
    --set-string runtime.environment=develop \
    "$@"
}

# Always inject image + required schedule/execution fields.
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

expect_fail() {
  local msg="$1"
  shift
  local out
  if out="$("$@" 2>&1)"; then
    echo "FAIL: $msg (expected failure)"
    FAILED=1
  else
    echo "OK: $msg"
  fi
}

echo "== Application / web minimal (probes:false) =="
OUT_WEB="$(render_app --set probes=false)"
assert_kind_count "$OUT_WEB" Deployment 1 "web: 1 Deployment"
assert_kind_count "$OUT_WEB" Service 1 "web: 1 Service"
assert_kind_count "$OUT_WEB" HTTPRoute 1 "web: 1 HTTPRoute"
assert_kind_count "$OUT_WEB" GRPCRoute 0 "web: 0 GRPCRoute"
assert_kind_count "$OUT_WEB" HorizontalPodAutoscaler 1 "web: default HPA"
assert_kind_count "$OUT_WEB" ServiceAccount 1 "web: ServiceAccount always"
assert_contains "$OUT_WEB" "serviceAccountName: sample-api" "web SA name = release"
assert_contains "$OUT_WEB" "containerPort: 8080" "web port 8080"
assert_contains "$OUT_WEB" "port: 8080" "web Service 8080"
assert_contains "$OUT_WEB" "name: ASPNETCORE_URLS" "web ASPNETCORE_URLS env"
assert_contains "$OUT_WEB" 'value: "http://+:8080"' "web ASPNETCORE_URLS explicit"
assert_not_contains "$OUT_WEB" "appProtocol: kubernetes.io/h2c" "web no h2c"
assert_not_contains "$OUT_WEB" "startupProbe:" "web probes:false no startup"
assert_not_contains "$OUT_WEB" "readinessProbe:" "web probes:false no readiness"
assert_not_contains "$OUT_WEB" "livenessProbe:" "web probes:false no liveness"

echo "== Application / web probes.readiness.path only =="
OUT_WEB_RO="$(render_app --set-json 'probes={"readiness":{"path":"/health/ready"}}')"
assert_contains "$OUT_WEB_RO" "readinessProbe:" "web readiness-only"
assert_contains "$OUT_WEB_RO" 'path: "/health/ready"' "web readiness path"
assert_not_contains "$OUT_WEB_RO" "startupProbe:" "web readiness-only no startup"
assert_not_contains "$OUT_WEB_RO" "livenessProbe:" "web readiness-only no liveness"

echo "== Application / web probes.startup.path only =="
OUT_WEB_SO="$(render_app --set-json 'probes={"startup":{"path":"/health/startup"}}')"
assert_contains "$OUT_WEB_SO" "startupProbe:" "web startup-only"
assert_contains "$OUT_WEB_SO" 'path: "/health/startup"' "web startup path"
assert_not_contains "$OUT_WEB_SO" "readinessProbe:" "web startup-only no readiness"
assert_not_contains "$OUT_WEB_SO" "livenessProbe:" "web startup-only no liveness"

echo "== Application / grpc =="
OUT_GRPC="$(render_app --set-string workload.type=grpc --set probes=false)"
assert_kind_count "$OUT_GRPC" Deployment 1 "grpc: 1 Deployment"
assert_kind_count "$OUT_GRPC" Service 1 "grpc: 1 Service"
assert_kind_count "$OUT_GRPC" HTTPRoute 0 "grpc: 0 HTTPRoute"
assert_kind_count "$OUT_GRPC" GRPCRoute 1 "grpc: 1 GRPCRoute"
assert_kind_count "$OUT_GRPC" HorizontalPodAutoscaler 1 "grpc: default HPA"
assert_contains "$OUT_GRPC" "containerPort: 8080" "grpc port 8080"
assert_contains "$OUT_GRPC" "port: 8080" "grpc Service 8080"
assert_contains "$OUT_GRPC" "appProtocol: kubernetes.io/h2c" "grpc Service h2c"
assert_contains "$OUT_GRPC" "name: Kestrel__EndpointDefaults__Protocols" "grpc Kestrel EndpointDefaults"
assert_contains "$OUT_GRPC" "value: Http2" "grpc Kestrel Http2"
assert_contains "$OUT_GRPC" "name: ASPNETCORE_URLS" "grpc ASPNETCORE_URLS"
assert_contains "$OUT_GRPC" 'value: "http://+:8080"' "grpc ASPNETCORE_URLS value"
assert_not_contains "$OUT_GRPC" "50051" "grpc render has no 50051"

OUT_GRPC_P="$(render_app --set-string workload.type=grpc --set-json 'probes={"readiness":{"enabled":true}}')"
assert_contains "$OUT_GRPC_P" "readinessProbe:" "grpc readiness when enabled"
assert_contains "$OUT_GRPC_P" "grpc:" "grpc native probe"
assert_not_contains "$OUT_GRPC_P" "httpGet:" "grpc probe has no httpGet"

echo "== Application / worker =="
OUT_WORKER="$(render_app --set-string workload.type=worker)"
assert_kind_count "$OUT_WORKER" Deployment 1 "worker: 1 Deployment"
assert_kind_count "$OUT_WORKER" Service 0 "worker: 0 Service"
assert_kind_count "$OUT_WORKER" HTTPRoute 0 "worker: 0 HTTPRoute"
assert_kind_count "$OUT_WORKER" GRPCRoute 0 "worker: 0 GRPCRoute"
assert_kind_count "$OUT_WORKER" HorizontalPodAutoscaler 0 "worker: no HPA by default"
assert_kind_count "$OUT_WORKER" ServiceAccount 1 "worker: ServiceAccount always"
assert_contains "$OUT_WORKER" "serviceAccountName: sample-api" "worker SA name = release"

echo "== Application / worker explicit autoscaling → HPA =="
OUT_WORKER_HPA="$(render_app --set-string workload.type=worker \
  --set autoscaling.minReplicas=1 --set autoscaling.maxReplicas=2 --set autoscaling.cpu.target=70)"
assert_kind_count "$OUT_WORKER_HPA" HorizontalPodAutoscaler 1 "worker: HPA when autoscaling explicit"
assert_contains "$OUT_WORKER_HPA" "minReplicas: 1" "worker HPA minReplicas"

echo "== Application / HPA minReplicas by runtime.environment =="
OUT_DEV="$(render_app --set probes=false --set-string runtime.environment=develop)"
assert_contains "$OUT_DEV" "minReplicas: 1" "HPA minReplicas develop=1"
OUT_HML="$(render_app --set probes=false --set-string runtime.environment=homolog)"
assert_contains "$OUT_HML" "minReplicas: 1" "HPA minReplicas homolog=1"
OUT_PRD="$(render_app --set probes=false --set-string runtime.environment=production)"
assert_contains "$OUT_PRD" "minReplicas: 2" "HPA minReplicas production=2"

echo "== ScheduledJob timeZone + timeoutSeconds =="
OUT_JOB="$(render_job)"
assert_kind_count "$OUT_JOB" CronJob 1 "job: 1 CronJob"
assert_kind_count "$OUT_JOB" Deployment 0 "job: 0 Deployment"
assert_kind_count "$OUT_JOB" ServiceAccount 1 "job: ServiceAccount always"
assert_contains "$OUT_JOB" "serviceAccountName: sample-job" "job SA name = release"
assert_contains "$OUT_JOB" 'timeZone: "America/Sao_Paulo"' "job timeZone"
assert_contains "$OUT_JOB" "activeDeadlineSeconds: 1800" "job activeDeadlineSeconds"
assert_contains "$OUT_JOB" "concurrencyPolicy: Forbid" "job default Forbid"
assert_contains "$OUT_JOB" "restartPolicy: Never" "job restartPolicy Never"

echo "== IRSA + WIF combined =="
WIF_AUD="//iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/providers/eks"
OUT_IRSA_WIF="$(render_app --set probes=false \
  --set-string 'serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::1:role/r' \
  --set-string "workloadIdentity.gcp.audience=${WIF_AUD}" \
  --set-string workloadIdentity.gcp.serviceAccountEmail=a@b.iam.gserviceaccount.com)"
assert_contains "$OUT_IRSA_WIF" "eks.amazonaws.com/role-arn" "IRSA role-arn annotation"
assert_contains "$OUT_IRSA_WIF" "/var/run/secrets/gcp/serviceaccount" "WIF token mount gcp path"
assert_not_contains "$OUT_IRSA_WIF" 'mountPath: "/var/run/secrets/eks.amazonaws.com/serviceaccount"' \
  "WIF token not on IRSA path"
assert_contains "$OUT_IRSA_WIF" "GOOGLE_APPLICATION_CREDENTIALS" "WIF GOOGLE_APPLICATION_CREDENTIALS"
assert_contains "$OUT_IRSA_WIF" "/var/run/secrets/google" "WIF credentials mount"
# Duplicate mountPath guard
DUP_MOUNTS="$(grep -E '^\s+mountPath:' <<<"$OUT_IRSA_WIF" | sed 's/^[[:space:]]*//' | sort | uniq -d || true)"
if [[ -n "$DUP_MOUNTS" ]]; then
  echo "FAIL: duplicate mountPath values:"
  echo "$DUP_MOUNTS"
  FAILED=1
else
  echo "OK: no duplicate mountPath"
fi

echo "== negatives (chart fail-fast) =="
expect_fail "workload.port rejected" \
  render_app --set probes=false --set-json 'workload={"type":"web","port":9090}'

expect_fail "probes.path rejected" \
  render_app --set-json 'probes={"path":"/health-check"}'

expect_fail "web omit probes (null) fails" \
  render_app --set probes=null

expect_fail "web omit probes (empty map) fails" \
  render_app --set-json 'probes={}'

expect_fail "grpc omit probes fails" \
  render_app --set-string workload.type=grpc --set probes=null

expect_fail "probes:true rejected" \
  render_app --set probes=true

expect_fail "grpc with path rejected" \
  render_app --set-string workload.type=grpc --set-json 'probes={"readiness":{"path":"/health"}}'

expect_fail "web with enabled rejected" \
  render_app --set-json 'probes={"readiness":{"enabled":true}}'

expect_fail "worker with probes rejected" \
  render_app --set-string workload.type=worker --set-json 'probes={"readiness":{"path":"/x"}}'

expect_fail "config ASPNETCORE_URLS rejected" \
  render_app --set probes=false --set-string 'config.ASPNETCORE_URLS=http://bad'

expect_fail "config ASPNETCORE_HTTP_PORTS rejected" \
  render_app --set probes=false --set-string 'config.ASPNETCORE_HTTP_PORTS=8080'

expect_fail "config ASPNETCORE_HTTPS_PORTS rejected" \
  render_app --set probes=false --set-string 'config.ASPNETCORE_HTTPS_PORTS=8443'

expect_fail "config Kestrel__Endpoints__X rejected" \
  render_app --set probes=false --set-string 'config.Kestrel__Endpoints__Http__Url=http://+:8080'

expect_fail "config GOOGLE_APPLICATION_CREDENTIALS rejected" \
  render_app --set probes=false --set-string 'config.GOOGLE_APPLICATION_CREDENTIALS=/tmp/x'

# Missing timeZone / timeoutSeconds — call helm directly so helper defaults do not apply.
expect_fail "missing timeZone fails" \
  helm template sample-job "${JOB_CHART}" \
    --set-string image.repository=example.dkr.ecr.us-east-1.amazonaws.com/sample-job \
    --set-string image.tag=deadbeef \
    --set-string 'schedule.expression=0 2 * * *' \
    --set execution.timeoutSeconds=1800 \
    --set-string 'execution.args[0]=--mode=job'

expect_fail "empty timeZone fails" \
  render_job --set-string schedule.timeZone=

expect_fail "missing timeoutSeconds fails" \
  helm template sample-job "${JOB_CHART}" \
    --set-string image.repository=example.dkr.ecr.us-east-1.amazonaws.com/sample-job \
    --set-string image.tag=deadbeef \
    --set-string 'schedule.expression=0 2 * * *' \
    --set-string schedule.timeZone=America/Sao_Paulo \
    --set-string 'execution.args[0]=--mode=job'

expect_fail "bad concurrencyPolicy fails" \
  render_job --set-string schedule.concurrencyPolicy=Nope

# Platform-internal podSecurityContext on chart values still renders; public schema tested below.
OUT_JOB_PSC="$(render_job)"
assert_contains "$OUT_JOB_PSC" "runAsNonRoot: true" "job platform podSecurityContext still renders"

echo "== public manifesto schema =="
VALIDATE="${ROOT}/scripts/validate-manifest.py"
python3 -m pip install --user --break-system-packages pyyaml jsonschema >/dev/null 2>&1 \
  || pip3 install --user pyyaml jsonschema >/dev/null 2>&1 \
  || true
export PATH="${HOME}/.local/bin:${PATH}"
if ! python3 -c 'import yaml, jsonschema' >/dev/null 2>&1; then
  echo "FAIL: PyYAML/jsonschema required for public schema tests"
  FAILED=1
else
  if python3 "${VALIDATE}" "${ROOT}/schemas/application.manifest.schema.json" \
      "${ROOT}/examples/deploy/config/develop.yaml"; then
    echo "OK: example Application manifesto"
  else
    echo "FAIL: example Application manifesto"
    FAILED=1
  fi
  if python3 "${VALIDATE}" "${ROOT}/schemas/scheduled-job.manifest.schema.json" \
      "${ROOT}/examples/deploy/config/scheduled-job.example.yaml"; then
    echo "OK: example ScheduledJob manifesto"
  else
    echo "FAIL: example ScheduledJob manifesto"
    FAILED=1
  fi

  schema_reject() {
    local msg="$1" schema="$2" json="$3"
    if echo "$json" | python3 "${VALIDATE}" "$schema" --stdin >/dev/null 2>&1; then
      echo "FAIL: $msg"
      FAILED=1
    else
      echo "OK: $msg"
    fi
  }

  APP_SCHEMA="${ROOT}/schemas/application.manifest.schema.json"
  JOB_SCHEMA="${ROOT}/schemas/scheduled-job.manifest.schema.json"

  schema_reject "typo legasyDns rejected" "$APP_SCHEMA" \
    '{"kind":"Application","workload":{"type":"web"},"probes":false,"legasyDns":true}'
  schema_reject "typo resources.requets rejected" "$APP_SCHEMA" \
    '{"kind":"Application","workload":{"type":"web"},"probes":false,"resources":{"requets":{"cpu":"100m"}}}'
  schema_reject "serviceAccount.create rejected" "$APP_SCHEMA" \
    '{"kind":"Application","workload":{"type":"web"},"probes":false,"serviceAccount":{"create":true}}'
  schema_reject "probes.path rejected by public schema" "$APP_SCHEMA" \
    '{"kind":"Application","workload":{"type":"web"},"probes":{"path":"/health"}}'
  schema_reject "ScheduledJob without timeoutSeconds rejected" "$JOB_SCHEMA" \
    '{"kind":"ScheduledJob","schedule":{"expression":"0 2 * * *","timeZone":"America/Sao_Paulo"},"execution":{"args":["x"]}}'
  schema_reject "podSecurityContext on public ScheduledJob rejected" "$JOB_SCHEMA" \
    '{"kind":"ScheduledJob","schedule":{"expression":"0 2 * * *","timeZone":"America/Sao_Paulo"},"execution":{"timeoutSeconds":60,"args":["x"]},"podSecurityContext":{"runAsNonRoot":true}}'
fi

echo "== static checks (ADO / helm) =="
if ! grep -q 'convertToJson(parameters.deployEnvironments)' "${ROOT}/templates/dotnet/ci.yml"; then
  echo "FAIL: convertToJson(deployEnvironments) missing"
  FAILED=1
else
  echo "OK: convertToJson present"
fi
if grep -n 'each env in parameters.deployEnvironments' "${ROOT}/templates/dotnet/ci.yml" | grep -q .; then
  echo "FAIL: invalid each-env DeployContract loop still present"
  FAILED=1
else
  echo "OK: no each-env loop"
fi
RECOVERY_BLOCK="$(awk '/pending-upgrade\|pending-rollback/,/^[[:space:]]*esac/' "${ROOT}/templates/dotnet/helm-deploy.yml")"
if grep -q 'helm uninstall' <<<"$RECOVERY_BLOCK"; then
  echo "FAIL: pending-upgrade block has helm uninstall"
  FAILED=1
else
  echo "OK: pending-upgrade block has no helm uninstall"
fi
# ECR_PULL_SECRET: compile-time parameter ecrPullSecret (deployment jobs drop runtime $(VAR))
if ! grep -q 'ecrPullSecret' "${ROOT}/templates/dotnet/helm-deploy.yml"; then
  echo "FAIL: ecrPullSecret parameter missing in helm-deploy.yml"
  FAILED=1
elif ! grep -q "ecrPullSecret: \${{ coalesce(variables\['ECR_PULL_SECRET'\], '') }}" "${ROOT}/templates/dotnet/ci.yml" \
  && ! grep -qF "variables['ECR_PULL_SECRET']" "${ROOT}/templates/dotnet/ci.yml"; then
  echo "FAIL: ci.yml must pass variables['ECR_PULL_SECRET'] into ecrPullSecret"
  FAILED=1
else
  echo "OK: ECR_PULL_SECRET wired via ecrPullSecret parameter"
fi
if grep -E -- '--atomic' "${ROOT}/templates/dotnet/helm-deploy.yml" | grep -q .; then
  echo "FAIL: --atomic still present in helm-deploy"
  FAILED=1
else
  echo "OK: no --atomic"
fi
if ! grep -q 'helm_has_deployed_revision' "${ROOT}/templates/dotnet/helm-deploy.yml"; then
  echo "FAIL: helm_has_deployed_revision guard missing"
  FAILED=1
else
  echo "OK: deployed-revision guard present"
fi
if grep -qE '\| last \|' "${ROOT}/templates/dotnet/helm-deploy.yml"; then
  echo "FAIL: jq-style yq 'last' still present (use .[-1] for mikefarah/yq)"
  FAILED=1
elif ! grep -q '\[\.\[-1\]\.revision' "${ROOT}/templates/dotnet/helm-deploy.yml" \
  && ! grep -qF '.[-1].revision' "${ROOT}/templates/dotnet/helm-deploy.yml"; then
  echo "FAIL: rollback revision selector .[-1].revision missing"
  FAILED=1
else
  echo "OK: rollback uses mikefarah/yq .[-1].revision"
fi
if ! grep -q 'create secret docker-registry' "${ROOT}/templates/dotnet/helm-deploy.yml"; then
  echo "FAIL: ECR_PULL_SECRET refresh (create secret docker-registry) missing"
  FAILED=1
else
  echo "OK: ECR_PULL_SECRET refresh present"
fi
if ! grep -q 'Accepted' "${ROOT}/templates/dotnet/helm-deploy.yml"; then
  echo "FAIL: Route Accepted check missing"
  FAILED=1
else
  echo "OK: Route Accepted check present"
fi
if ! grep -q 'metrics.k8s.io' "${ROOT}/templates/dotnet/helm-deploy.yml"; then
  echo "FAIL: metrics.k8s.io preflight missing"
  FAILED=1
else
  echo "OK: metrics.k8s.io preflight present"
fi

echo "== no magic port 50051 outside this file =="
if grep -RIn --exclude-dir=.git --exclude='*.plan.md' --exclude='chart-invariants.sh' '50051' \
  "${ROOT}/charts" "${ROOT}/templates" "${ROOT}/schemas" "${ROOT}/scripts" "${ROOT}/tests" \
  "${ROOT}/examples" "${ROOT}/docker" 2>/dev/null | grep -q .; then
  echo "FAIL: residual 50051 found:"
  grep -RIn --exclude-dir=.git --exclude='*.plan.md' --exclude='chart-invariants.sh' '50051' \
    "${ROOT}/charts" "${ROOT}/templates" "${ROOT}/schemas" "${ROOT}/scripts" "${ROOT}/tests" \
    "${ROOT}/examples" "${ROOT}/docker" 2>/dev/null || true
  FAILED=1
else
  echo "OK: 50051 only allowed in chart-invariants.sh itself"
fi

echo "== chart drift =="
if ! bash "${ROOT}/tests/chart-drift.sh"; then
  echo "FAIL: chart-drift.sh"
  FAILED=1
fi

echo "== helm lint =="
if ! helm lint "${APP_CHART}"; then
  echo "FAIL: helm lint asa-application"
  FAILED=1
else
  echo "OK: helm lint asa-application"
fi
if ! helm lint "${JOB_CHART}" \
  --set-string schedule.expression='0 2 * * *' \
  --set-string schedule.timeZone=America/Sao_Paulo \
  --set execution.timeoutSeconds=1800 \
  --set-string 'execution.args[0]=--mode=job'; then
  echo "FAIL: helm lint asa-scheduled-job"
  FAILED=1
else
  echo "OK: helm lint asa-scheduled-job"
fi

echo "== examples render =="
OUT_EX_APP="$(render_app -f "${ROOT}/examples/deploy/config/develop.yaml")"
assert_kind_count "$OUT_EX_APP" Deployment 1 "example Application Deployment"
assert_kind_count "$OUT_EX_APP" HTTPRoute 1 "example Application HTTPRoute"
OUT_EX_JOB="$(render_job -f "${ROOT}/examples/deploy/config/scheduled-job.example.yaml")"
assert_kind_count "$OUT_EX_JOB" CronJob 1 "example ScheduledJob CronJob"
assert_kind_count "$OUT_EX_JOB" Deployment 0 "example ScheduledJob no Deployment"

if [[ "$FAILED" -ne 0 ]]; then
  echo "Some invariants failed"
  exit 1
fi
echo "All chart invariants passed"
