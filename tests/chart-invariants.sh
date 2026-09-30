#!/usr/bin/env bash
# Contract tests for asa-application + asa-scheduled-job (kind → chart).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_CHART="${ROOT}/charts/asa-application"
JOB_CHART="${ROOT}/charts/asa-scheduled-job"
FAILED=0
WIF_AUD_NEG="//iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/providers/eks"

echo "== toolchain =="
# $BASH_VERSION is the interpreter actually running this script. `bash --version` reports
# whatever is first on PATH, which on macOS can say 5.x while /bin/bash 3.2 runs the script —
# i.e. it would misreport exactly the case this line exists to expose.
echo "bash: ${BASH_VERSION}"
if ! command -v helm >/dev/null 2>&1; then
  echo "FAIL: helm not found in PATH"
  exit 1
fi
HELM_VER="$(helm version --short 2>/dev/null | head -1)"
echo "helm: ${HELM_VER}"
# Floor matches the CI pin (3.16.2). Schema message prose differs across Helm majors —
# expect_schema_fail asserts path + shared preamble, not validator wording. Still require
# at least 3.16 so local runs are not accidentally on something older than the platform.
HELM_NUM="$(printf '%s' "${HELM_VER}" | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1.\2/p')"
HELM_MAJOR="${HELM_NUM%%.*}"
HELM_MINOR="${HELM_NUM#*.}"
if [[ -z "${HELM_MAJOR}" || -z "${HELM_MINOR}" ]]; then
  echo "FAIL: could not parse helm version from: ${HELM_VER}"
  exit 1
fi
if [[ "${HELM_MAJOR}" -lt 3 ]] || { [[ "${HELM_MAJOR}" -eq 3 ]] && [[ "${HELM_MINOR}" -lt 16 ]]; }; then
  echo "FAIL: need Helm >= 3.16 (CI pins v3.16.2); got ${HELM_VER}"
  exit 1
fi
echo "OK: Helm >= 3.16 (CI pins v3.16.2; schema negatives use expect_schema_fail)"
echo

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

# Always inject image + platform facts (pipeline-owned via resolve-platform-values.sh).
# Override with PLATFORM_AREA=<area> and PLATFORM_TIER=<tier> (or PLATFORM_ENV alias).
# Defaults: lab / develop.
render_app() {
  local area="${PLATFORM_AREA:-lab}"
  local tier="${PLATFORM_TIER:-${PLATFORM_ENV:-develop}}"
  local pf rc=0
  pf="$(mktemp -t asa-platform.XXXXXX.yaml)"
  "${ROOT}/scripts/resolve-platform-values.sh" "${area}" "${tier}" "${pf}"
  helm template sample-api "${APP_CHART}" \
    --set-string image.repository=example.dkr.ecr.us-east-1.amazonaws.com/sample-api \
    --set-string image.tag=deadbeef \
    -f "${pf}" \
    "$@" || rc=$?
  rm -f "${pf}"
  return "${rc}"
}

# Always inject image + required schedule/execution fields + platform labels.
render_job() {
  local area="${PLATFORM_AREA:-lab}"
  local tier="${PLATFORM_TIER:-${PLATFORM_ENV:-develop}}"
  local pf rc=0
  pf="$(mktemp -t asa-platform.XXXXXX.yaml)"
  "${ROOT}/scripts/resolve-platform-values.sh" "${area}" "${tier}" "${pf}"
  helm template sample-job "${JOB_CHART}" \
    --set-string image.repository=example.dkr.ecr.us-east-1.amazonaws.com/sample-job \
    --set-string image.tag=deadbeef \
    --set-string platform.area=lab \
    --set-string platform.tier=develop \
    --set-string 'schedule.expression=0 2 * * *' \
    --set-string schedule.timeZone=America/Sao_Paulo \
    --set execution.timeoutSeconds=1800 \
    --set-string 'execution.args[0]=--mode=job' \
    -f "${pf}" \
    "$@" || rc=$?
  rm -f "${pf}"
  return "${rc}"
}

# expect_fail "<description>" "<message substring>" [--] cmd...
# Requires non-zero exit AND that stderr/stdout contains the needle (so a typo
# in --set cannot silently satisfy the test).
expect_fail() {
  local msg="$1"
  local needle="$2"
  shift 2
  if [[ "${1:-}" == "--" ]]; then shift; fi
  local out
  if out="$("$@" 2>&1)"; then
    echo "FAIL: $msg (expected failure)"
    FAILED=1
  elif ! grep -qF -- "$needle" <<<"$out"; then
    echo "FAIL: $msg (expected message containing: $needle)"
    echo "  got: $(head -c 400 <<<"$out" | tr '\n' ' ')"
    FAILED=1
  else
    echo "OK: $msg"
  fi
}

# Same idea as expect_fail, but for rejections that come from values.schema.json rather than a
# template `fail`. Helm's schema validator changed between majors and emits different prose for
# the identical violation:
#   helm 3 (xeipuuv):  "- workload: Additional property port is not allowed"
#   helm 4 (santhosh): "- at '/workload': additional properties 'port' not allowed"
# Matching either wording literally pins the suite to one Helm major, which is how this drifted:
# assertions written against the local helm 4 while CI pins 3.16.2. Both DO name the offending
# path, so assert on that plus the shared preamble — which still proves the schema layer (not
# some unrelated error) rejected the right property.
# Usage: expect_schema_fail "<description>" "<dotted values path>" [--] cmd...
expect_schema_fail() {
  local msg="$1"
  local path="$2"
  shift 2
  if [[ "${1:-}" == "--" ]]; then shift; fi
  local out
  if out="$("$@" 2>&1)"; then
    echo "FAIL: $msg (expected failure)"
    FAILED=1
    return
  fi
  if ! grep -qF "values don't meet the specifications of the schema" <<<"$out"; then
    echo "FAIL: $msg (expected a values.schema.json rejection, got another error)"
    echo "  got: $(head -c 400 <<<"$out" | tr '\n' ' ')"
    FAILED=1
    return
  fi
  # Built with tr, not ${path//./\/}: bash 3.2 (macOS system bash) renders that replacement as
  # a literal backslash-slash, so the pointer match silently never fires there while it works on
  # bash 5 / CI. Same class of trap as the helm-major wording difference.
  local dotted pointer
  dotted="$(printf '%s' "${path}" | sed 's/\./\\./g')"
  pointer="/$(printf '%s' "${path}" | tr '.' '/')"
  if grep -qE "(^|[[:space:]-])${dotted}[.:]" <<<"$out" \
    || grep -qF "at '${pointer}" <<<"$out"; then
    echo "OK: $msg"
  else
    echo "FAIL: $msg (schema rejected, but not at '${path}')"
    echo "  got: $(head -c 400 <<<"$out" | tr '\n' ' ')"
    FAILED=1
  fi
}

# Temporarily move values.schema.json aside so template `fail` paths are reachable.
# Restores the schema even if the command fails. Used to prove the dual lock (schema + template).
with_schema_bypassed() {
  local chart="$1"
  shift
  local schema="${chart}/values.schema.json"
  local off="${schema}.tdd-off.$$"
  if [[ ! -f "${schema}" ]]; then
    echo "FAIL: with_schema_bypassed: missing ${schema}"
    FAILED=1
    return 1
  fi
  mv "${schema}" "${off}"
  local rc=0
  "$@" || rc=$?
  mv "${off}" "${schema}"
  return "${rc}"
}

# Structural assert: python expression over parsed multi-doc YAML must be truthy.
# Usage: assert_struct "$yaml" "<msg>" 'docs' <<'PY'
# ... python that sets ok=True/False using variable `docs` ...
# PY  — actually simpler: pass a one-liner python snippet that receives docs.
assert_struct() {
  local haystack="$1" msg="$2" py="$3"
  local err
  if ! err="$(MANIFEST="$haystack" python3 -c "
import os, sys, yaml
docs = [d for d in yaml.safe_load_all(os.environ['MANIFEST']) if d]
${py}
" 2>&1)"; then
    echo "FAIL: $msg"
    echo "  $err" | head -c 500
    echo
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

echo "== Application / HPA minReplicas by platform.defaultMinReplicas =="
OUT_DEV="$(PLATFORM_ENV=develop render_app --set probes=false)"
assert_contains "$OUT_DEV" "minReplicas: 1" "HPA minReplicas develop=1"
OUT_HML="$(PLATFORM_ENV=homolog render_app --set probes=false)"
assert_contains "$OUT_HML" "minReplicas: 1" "HPA minReplicas homolog=1"
OUT_PRD="$(PLATFORM_ENV=production render_app --set probes=false)"
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
expect_schema_fail "workload.port rejected" "workload" -- \
  render_app --set probes=false --set-json 'workload={"type":"web","port":9090}'

expect_schema_fail "probes.path rejected" "probes" -- \
  render_app --set-json 'probes={"path":"/health-check"}'

expect_schema_fail "web omit probes (null) fails" "probes" -- \
  render_app --set probes=null

expect_schema_fail "web omit probes (empty map) fails" "probes" -- \
  render_app --set-json 'probes={}'

expect_schema_fail "grpc omit probes fails" "probes" -- \
  render_app --set-string workload.type=grpc --set probes=null

expect_schema_fail "probes:true rejected" "probes" -- \
  render_app --set probes=true

expect_fail "grpc with path rejected" "probes.readiness.path is invalid for grpc" -- \
  render_app --set-string workload.type=grpc --set-json 'probes={"readiness":{"path":"/health"}}'

expect_fail "web with enabled rejected" "probes.<type>.enabled is for grpc only" -- \
  render_app --set-json 'probes={"readiness":{"enabled":true}}'

expect_fail "worker with probes rejected" "probes are not supported for workload.type: worker" -- \
  render_app --set-string workload.type=worker --set-json 'probes={"readiness":{"path":"/x"}}'

expect_fail "config ASPNETCORE_URLS rejected" "config.ASPNETCORE_URLS is platform-owned" -- \
  render_app --set probes=false --set-string 'config.ASPNETCORE_URLS=http://bad'

expect_fail "config ASPNETCORE_HTTP_PORTS rejected" "config.ASPNETCORE_HTTP_PORTS is platform-owned" -- \
  render_app --set probes=false --set-string 'config.ASPNETCORE_HTTP_PORTS=8080'

expect_fail "config ASPNETCORE_HTTPS_PORTS rejected" "config.ASPNETCORE_HTTPS_PORTS is platform-owned" -- \
  render_app --set probes=false --set-string 'config.ASPNETCORE_HTTPS_PORTS=8443'

expect_fail "config Kestrel__Endpoints__X rejected" "platform-owned (Kestrel__*)" -- \
  render_app --set probes=false --set-string 'config.Kestrel__Endpoints__Http__Url=http://+:8080'

expect_fail "config GOOGLE_APPLICATION_CREDENTIALS rejected" "config.GOOGLE_APPLICATION_CREDENTIALS is platform-owned" -- \
  render_app --set probes=false --set-string 'config.GOOGLE_APPLICATION_CREDENTIALS=/tmp/x'

# Missing timeZone / timeoutSeconds — call helm directly so helper defaults do not apply.
expect_schema_fail "missing timeZone fails" "schedule.timeZone" -- \
  helm template sample-job "${JOB_CHART}" \
    --set-string image.repository=example.dkr.ecr.us-east-1.amazonaws.com/sample-job \
    --set-string image.tag=deadbeef \
    --set-string platform.area=lab \
    --set-string platform.tier=develop \
    --set-string 'schedule.expression=0 2 * * *' \
    --set execution.timeoutSeconds=1800 \
    --set-string 'execution.args[0]=--mode=job'

expect_schema_fail "empty timeZone fails" "schedule.timeZone" -- \
  render_job --set-string schedule.timeZone=

expect_fail "missing timeoutSeconds fails" "execution.timeoutSeconds is required" -- \
  helm template sample-job "${JOB_CHART}" \
    --set-string image.repository=example.dkr.ecr.us-east-1.amazonaws.com/sample-job \
    --set-string image.tag=deadbeef \
    --set-string platform.area=lab \
    --set-string platform.tier=develop \
    --set-string 'schedule.expression=0 2 * * *' \
    --set-string schedule.timeZone=America/Sao_Paulo \
    --set-string 'execution.args[0]=--mode=job'

expect_schema_fail "bad concurrencyPolicy fails" "schedule.concurrencyPolicy" -- \
  render_job --set-string schedule.concurrencyPolicy=Nope

# --- Application guards ---
expect_schema_fail "wrong kind rejected" "kind" -- \
  render_app --set probes=false --set-string kind=ScheduledJob

expect_schema_fail "invalid workload.type rejected" "workload.type" -- \
  render_app --set probes=false --set-string workload.type=foo

expect_schema_fail "schedule on Application rejected" "schedule" -- \
  render_app --set probes=false --set-string schedule.expression='0 * * * *'

expect_schema_fail "execution on Application rejected" "execution" -- \
  render_app --set probes=false --set execution.timeoutSeconds=60

expect_schema_fail "history on Application rejected" "history" -- \
  render_app --set probes=false --set history.successful=1

expect_schema_fail "cronJob on Application rejected" "cronJob" -- \
  render_app --set probes=false --set-string cronJob.schedule='0 * * * *'

expect_schema_fail "legacyDns on worker rejected" "legacyDns" -- \
  render_app --set-string workload.type=worker --set legacyDns=true

expect_fail "autoscaling minReplicas > maxReplicas rejected" "must be <= autoscaling.maxReplicas" -- \
  render_app --set probes=false --set autoscaling.minReplicas=9

expect_schema_fail "empty image.repository rejected" "image.repository" -- \
  bash -c '
    pf="$(mktemp -t asa-platform.XXXXXX.yaml)"
    "'"${ROOT}"'/scripts/resolve-platform-values.sh" lab develop "${pf}"
    helm template sample-api "'"${APP_CHART}"'" \
      --set-string image.tag=deadbeef \
      -f "${pf}" \
      --set probes=false
    rc=$?
    rm -f "${pf}"
    exit $rc
  '

# --- persistence ---
expect_fail "persistence:true rejected" "persistence: true is invalid" -- \
  render_app --set probes=false --set persistence=true

expect_fail "persistence + autoscaling rejected" "persistence requires autoscaling: false" -- \
  render_app --set probes=false --set-string persistence.mountPath=/data --set-string persistence.size=1Gi

expect_fail "persistence + replicaCount>1 rejected" "persistence requires replicaCount: 1" -- \
  render_app --set probes=false --set autoscaling=false --set replicaCount=2 \
    --set-string persistence.mountPath=/data --set-string persistence.size=1Gi

# --- externalSecret ---
expect_fail "externalSecret:true rejected" "externalSecret: true is invalid" -- \
  render_app --set probes=false --set externalSecret=true

expect_fail "externalSecret data without store rejected" "requires externalSecret.secretStoreRef.name" -- \
  render_app --set probes=false \
    --set-json 'externalSecret={"data":[{"secretKey":"DB","remoteRef":{"key":"k"}}]}'

expect_fail "externalSecret store without data rejected" "requires externalSecret.data" -- \
  render_app --set probes=false --set-string externalSecret.secretStoreRef.name=aws

expect_schema_fail "externalSecret remoteRef without key rejected" "externalSecret" -- \
  render_app --set probes=false \
    --set-json 'externalSecret={"secretStoreRef":{"name":"aws"},"data":[{"secretKey":"DB","remoteRef":{}}]}'

# --- workloadIdentity ---
expect_fail "WIF expirationSeconds < 600 rejected" "expirationSeconds must be >= 600" -- \
  render_app --set probes=false \
    --set-string workloadIdentity.gcp.audience=//iam.googleapis.com/x \
    --set-string workloadIdentity.gcp.serviceAccountEmail=a@b.iam.gserviceaccount.com \
    --set workloadIdentity.token.expirationSeconds=60

# A volumeMount path must be unique inside the container. The API server rejects a collision
# with "must be unique", and kubeconform does NOT catch it — the constraint is not expressible
# in the OpenAPI schema — so these have to fail at render time.
expect_fail "WIF mountPath /tmp rejected" "must not be /tmp" -- \
  render_app --set probes=false \
    --set-string "workloadIdentity.gcp.audience=${WIF_AUD_NEG}" \
    --set-string workloadIdentity.gcp.serviceAccountEmail=a@b.iam.gserviceaccount.com \
    --set-string workloadIdentity.token.mountPath=/tmp

expect_fail "WIF mountPath on the credentials dir rejected" "must not be /var/run/secrets/google" -- \
  render_app --set probes=false \
    --set-string "workloadIdentity.gcp.audience=${WIF_AUD_NEG}" \
    --set-string workloadIdentity.gcp.serviceAccountEmail=a@b.iam.gserviceaccount.com \
    --set-string workloadIdentity.token.mountPath=/var/run/secrets/google

expect_fail "WIF mountPath colliding with persistence rejected" "collides with persistence.mountPath" -- \
  render_app --set probes=false --set autoscaling=false --set replicaCount=1 \
    --set-string persistence.mountPath=/data --set-string persistence.size=1Gi \
    --set-string "workloadIdentity.gcp.audience=${WIF_AUD_NEG}" \
    --set-string workloadIdentity.gcp.serviceAccountEmail=a@b.iam.gserviceaccount.com \
    --set-string workloadIdentity.token.mountPath=/data

expect_fail "job WIF mountPath /tmp rejected" "must not be /tmp" -- \
  render_job \
    --set-string "workloadIdentity.gcp.audience=${WIF_AUD_NEG}" \
    --set-string workloadIdentity.gcp.serviceAccountEmail=a@b.iam.gserviceaccount.com \
    --set-string workloadIdentity.token.mountPath=/tmp

expect_fail "WIF IRSA-reserved mountPath rejected" "must not use the IRSA reserved path" -- \
  render_app --set probes=false \
    --set-string workloadIdentity.gcp.audience=//iam.googleapis.com/x \
    --set-string workloadIdentity.gcp.serviceAccountEmail=a@b.iam.gserviceaccount.com \
    --set-string workloadIdentity.token.mountPath=/var/run/secrets/eks.amazonaws.com/serviceaccount

# --- probes edge cases ---
expect_schema_fail "worker probes:true rejected" "probes" -- \
  render_app --set-string workload.type=worker --set probes=true

expect_fail "grpc probes object without enabled rejected" "requires at least one of probes.startup|readiness|liveness.enabled" -- \
  render_app --set-string workload.type=grpc --set-json 'probes={"readiness":{}}'

expect_schema_fail "web probe path without leading slash rejected" "probes" -- \
  render_app --set-json 'probes={"readiness":{"path":"health"}}'

expect_schema_fail "probes invalid type (string) rejected" "probes" -- \
  render_app --set-string probes=bogus

# --- ScheduledJob guards ---
expect_schema_fail "ScheduledJob wrong kind rejected" "kind" -- \
  render_job --set-string kind=Application

expect_schema_fail "ScheduledJob workload rejected" "workload" -- \
  render_job --set-json 'workload={"type":"web"}'

expect_schema_fail "ScheduledJob legacyDns rejected" "legacyDns" -- \
  render_job --set legacyDns=true

expect_schema_fail "ScheduledJob probes rejected" "probes" -- \
  render_job --set probes=false

expect_schema_fail "ScheduledJob autoscaling rejected" "autoscaling" -- \
  render_job --set autoscaling=false

expect_schema_fail "ScheduledJob persistence rejected" "persistence" -- \
  render_job --set-string persistence.mountPath=/data

expect_schema_fail "ScheduledJob retries < 0 rejected" "execution.retries" -- \
  render_job --set execution.retries=-1

expect_schema_fail "ScheduledJob history.successful < 0 rejected" "history.successful" -- \
  render_job --set history.successful=-1

expect_schema_fail "ScheduledJob history.failed < 0 rejected" "history.failed" -- \
  render_job --set history.failed=-1

expect_schema_fail "ScheduledJob startingDeadlineSeconds < 0 rejected" "schedule.startingDeadlineSeconds" -- \
  render_job --set schedule.startingDeadlineSeconds=-1

expect_fail "ScheduledJob config reserved key rejected" "config.ASPNETCORE_URLS is platform-owned" -- \
  render_job --set-string 'config.ASPNETCORE_URLS=http://bad'

# Platform-internal podSecurityContext on chart values still renders; public schema tested below.
OUT_JOB_PSC="$(render_job)"
assert_contains "$OUT_JOB_PSC" "runAsNonRoot: true" "job platform podSecurityContext still renders"

echo "== positives (coverage gaps) =="
OUT_LEGACY="$(render_app --set probes=false --set legacyDns=true)"
assert_contains "$OUT_LEGACY" "sample-api.d.asa.com.br" "legacyDns adds legacy hostname on HTTPRoute"
assert_contains "$OUT_LEGACY" "sample-api.dev.asa.corp" "legacyDns keeps corp hostname"

OUT_LEGACY_GRPC="$(render_app --set-string workload.type=grpc --set probes=false --set legacyDns=true)"
assert_contains "$OUT_LEGACY_GRPC" "sample-api.d.asa.com.br" "legacyDns adds legacy hostname on GRPCRoute"

OUT_NO_HPA="$(render_app --set probes=false --set autoscaling=false)"
assert_kind_count "$OUT_NO_HPA" HorizontalPodAutoscaler 0 "autoscaling:false disables HPA for web"
assert_contains "$OUT_NO_HPA" "replicas: 1" "autoscaling:false keeps Deployment replicas"

OUT_NO_SPREAD="$(PLATFORM_ENV=production render_app --set probes=false --set topologySpread.enabled=false)"
assert_not_contains "$OUT_NO_SPREAD" "topologySpreadConstraints:" "topologySpread.enabled=false honoured"

OUT_PVC="$(render_app --set probes=false --set autoscaling=false \
  --set-string persistence.mountPath=/data --set-string persistence.size=1Gi)"
assert_kind_count "$OUT_PVC" PersistentVolumeClaim 1 "persistence renders PVC"
assert_contains "$OUT_PVC" "claimName: sample-api-data" "PVC claim name"
assert_contains "$OUT_PVC" 'sizeLimit: "128Mi"' "tmp emptyDir sizeLimit"

WIF_AUD="//iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/providers/eks"
OUT_WIF_ONLY="$(render_app --set probes=false \
  --set-string "workloadIdentity.gcp.audience=${WIF_AUD}" \
  --set-string workloadIdentity.gcp.serviceAccountEmail=a@b.iam.gserviceaccount.com)"
assert_contains "$OUT_WIF_ONLY" "GOOGLE_APPLICATION_CREDENTIALS" "WIF-only GOOGLE_APPLICATION_CREDENTIALS"
assert_contains "$OUT_WIF_ONLY" "/var/run/secrets/gcp/serviceaccount" "WIF-only token mount"
assert_not_contains "$OUT_WIF_ONLY" "eks.amazonaws.com/role-arn" "WIF-only has no IRSA annotation"

OUT_ES="$(render_app --set probes=false \
  --set-string externalSecret.secretStoreRef.name=aws-secrets \
  --set-json 'externalSecret.data=[{"secretKey":"DB","remoteRef":{"key":"prod/db","property":"password"}}]')"
assert_kind_count "$OUT_ES" ExternalSecret 1 "externalSecret renders ExternalSecret"
assert_contains "$OUT_ES" 'secretKey: "DB"' "externalSecret secretKey"
assert_contains "$OUT_ES" 'key: "prod/db"' "externalSecret remoteRef.key"

OUT_LABELS="$(render_app --set probes=false)"
assert_contains "$OUT_LABELS" 'app.kubernetes.io/version: "deadbeef"' "resource labels include image tag version"
assert_contains "$OUT_LABELS" "app.kubernetes.io/managed-by: Helm" "resource labels include managed-by"
assert_contains "$OUT_LABELS" "helm.sh/chart: asa-application-5.1.0" "resource metadata has helm.sh/chart"
# helm.sh/chart must NOT appear on the pod template (would force rollout on chart bump).
POD_LABELS="$(python3 -c '
import sys, yaml
docs=list(yaml.safe_load_all(sys.stdin))
for d in docs:
  if d and d.get("kind")=="Deployment":
    print(yaml.dump(d["spec"]["template"]["metadata"].get("labels",{})))
' <<<"$OUT_LABELS")"
assert_contains "$POD_LABELS" "app.kubernetes.io/managed-by: Helm" "pod labels include managed-by"
assert_not_contains "$POD_LABELS" "helm.sh/chart:" "pod labels omit helm.sh/chart"
# selector stays only app=
SELECTOR="$(python3 -c '
import sys, yaml
docs=list(yaml.safe_load_all(sys.stdin))
for d in docs:
  if d and d.get("kind")=="Deployment":
    print(yaml.dump(d["spec"]["selector"]["matchLabels"]))
' <<<"$OUT_LABELS")"
assert_contains "$SELECTOR" "app: sample-api" "selector keeps app"
assert_not_contains "$SELECTOR" "app.kubernetes.io/" "selector has no k8s recommended labels"

OUT_JOB_LABELS="$(render_job)"
assert_contains "$OUT_JOB_LABELS" "helm.sh/chart: asa-scheduled-job-4.1.0" "job resource has helm.sh/chart"
assert_contains "$OUT_JOB_LABELS" 'sizeLimit: "128Mi"' "job tmp emptyDir sizeLimit"
# helm.sh/chart must NOT appear on the CronJob pod template (would force Job recreation on chart bump).
JOB_POD_LABELS="$(python3 -c '
import sys, yaml
docs=list(yaml.safe_load_all(sys.stdin))
for d in docs:
  if d and d.get("kind")=="CronJob":
    print(yaml.dump(d["spec"]["jobTemplate"]["spec"]["template"]["metadata"].get("labels",{})))
' <<<"$OUT_JOB_LABELS")"
assert_contains "$JOB_POD_LABELS" "app.kubernetes.io/managed-by: Helm" "job pod labels include managed-by"
assert_not_contains "$JOB_POD_LABELS" "helm.sh/chart:" "job pod labels omit helm.sh/chart"

echo "== agent TDD guardrails (template state) =="
# Properties an agent could delete while "refactoring" — must stay red if removed.

# 1) ScheduledJob without command/args (template-reachable; critical under Forbid).
expect_fail "ScheduledJob without command/args rejected" \
  "execution.command or execution.args is required" -- \
  helm template sample-job "${JOB_CHART}" \
    --set-string image.repository=example.dkr.ecr.us-east-1.amazonaws.com/sample-job \
    --set-string image.tag=deadbeef \
    --set-string platform.area=lab \
    --set-string platform.tier=develop \
    --set-string 'schedule.expression=0 2 * * *' \
    --set-string schedule.timeZone=America/Sao_Paulo \
    --set execution.timeoutSeconds=1800

# 2) Security baseline — structural (wrong nesting / wrong resource would fail).
assert_struct "$OUT_WEB" "web SA automountServiceAccountToken=false" '
sa = next(d for d in docs if d["kind"]=="ServiceAccount")
dep = next(d for d in docs if d["kind"]=="Deployment")
pod = dep["spec"]["template"]["spec"]
ctr = pod["containers"][0]
assert sa.get("automountServiceAccountToken") is False
assert pod.get("automountServiceAccountToken") is False
assert pod.get("enableServiceLinks") is False
assert pod["securityContext"]["seccompProfile"]["type"] == "RuntimeDefault"
assert ctr["securityContext"]["readOnlyRootFilesystem"] is True
assert ctr["securityContext"]["allowPrivilegeEscalation"] is False
assert ctr["securityContext"]["capabilities"]["drop"] == ["ALL"]
'

assert_struct "$OUT_JOB_LABELS" "job SA+pod security baseline" '
sa = next(d for d in docs if d["kind"]=="ServiceAccount")
cj = next(d for d in docs if d["kind"]=="CronJob")
pod = cj["spec"]["jobTemplate"]["spec"]["template"]["spec"]
ctr = pod["containers"][0]
assert sa.get("automountServiceAccountToken") is False
assert pod.get("automountServiceAccountToken") is False
assert pod.get("enableServiceLinks") is False
assert pod["securityContext"]["seccompProfile"]["type"] == "RuntimeDefault"
assert ctr["securityContext"]["readOnlyRootFilesystem"] is True
assert ctr["securityContext"]["allowPrivilegeEscalation"] is False
assert ctr["securityContext"]["capabilities"]["drop"] == ["ALL"]
'

# 3) checksum annotations force rollout when config/WIF change.
OUT_CFG="$(render_app --set probes=false --set-string config.FOO=bar)"
assert_struct "$OUT_CFG" "checksum/config on Deployment pod when config set" '
dep = next(d for d in docs if d["kind"]=="Deployment")
ann = dep["spec"]["template"]["metadata"].get("annotations") or {}
assert "checksum/config" in ann and len(ann["checksum/config"]) > 0
'

OUT_WIF_CS="$(render_app --set probes=false \
  --set-string "workloadIdentity.gcp.audience=${WIF_AUD}" \
  --set-string workloadIdentity.gcp.serviceAccountEmail=a@b.iam.gserviceaccount.com)"
assert_struct "$OUT_WIF_CS" "checksum/wif on Deployment pod when WIF set" '
dep = next(d for d in docs if d["kind"]=="Deployment")
ann = dep["spec"]["template"]["metadata"].get("annotations") or {}
assert "checksum/wif" in ann and len(ann["checksum/wif"]) > 0
'

OUT_JOB_CFG="$(render_job --set-string config.FOO=bar)"
assert_struct "$OUT_JOB_CFG" "checksum/config on CronJob pod when config set" '
cj = next(d for d in docs if d["kind"]=="CronJob")
ann = cj["spec"]["jobTemplate"]["spec"]["template"]["metadata"].get("annotations") or {}
assert "checksum/config" in ann and len(ann["checksum/config"]) > 0
'

OUT_JOB_WIF="$(render_job \
  --set-string "workloadIdentity.gcp.audience=${WIF_AUD}" \
  --set-string workloadIdentity.gcp.serviceAccountEmail=a@b.iam.gserviceaccount.com)"
assert_struct "$OUT_JOB_WIF" "checksum/wif on CronJob pod when WIF set" '
cj = next(d for d in docs if d["kind"]=="CronJob")
ann = cj["spec"]["jobTemplate"]["spec"]["template"]["metadata"].get("annotations") or {}
assert "checksum/wif" in ann and len(ann["checksum/wif"]) > 0
'

# 4) CronJob platform defaults (history + backoff).
assert_struct "$OUT_JOB_LABELS" "CronJob history/backoff defaults" '
cj = next(d for d in docs if d["kind"]=="CronJob")
assert cj["spec"]["successfulJobsHistoryLimit"] == 3
assert cj["spec"]["failedJobsHistoryLimit"] == 1
assert cj["spec"]["jobTemplate"]["spec"]["backoffLimit"] == 2
'

# 5) Service targetPort by name + appProtocol only on grpc.
assert_struct "$OUT_WEB" "web Service targetPort=http, no appProtocol" '
svc = next(d for d in docs if d["kind"]=="Service")
p = svc["spec"]["ports"][0]
assert p["name"] == "http"
assert p["targetPort"] == "http"
assert "appProtocol" not in p
'

OUT_GRPC_PORTS="$(render_app --set-string workload.type=grpc --set probes=false)"
assert_struct "$OUT_GRPC_PORTS" "grpc Service targetPort=grpc + h2c appProtocol" '
svc = next(d for d in docs if d["kind"]=="Service")
p = svc["spec"]["ports"][0]
assert p["name"] == "grpc"
assert p["targetPort"] == "grpc"
assert p.get("appProtocol") == "kubernetes.io/h2c"
'

# 6) Dual lock: template `fail` still fires when schema is bypassed.
# If an agent deletes the template fail as "duplicate of schema", these go red.
expect_fail "template dual-lock: workload.port" "workload.port is not supported" -- \
  with_schema_bypassed "${APP_CHART}" \
  render_app --set probes=false --set-json 'workload={"type":"web","port":9090}'

expect_fail "template dual-lock: schedule on Application" \
  "schedule/execution/history belong to kind: ScheduledJob" -- \
  with_schema_bypassed "${APP_CHART}" \
  render_app --set probes=false --set-string schedule.expression='0 * * * *'

expect_fail "template dual-lock: execution on Application" \
  "schedule/execution/history belong to kind: ScheduledJob" -- \
  with_schema_bypassed "${APP_CHART}" \
  render_app --set probes=false --set execution.timeoutSeconds=60

expect_fail "template dual-lock: history on Application" \
  "schedule/execution/history belong to kind: ScheduledJob" -- \
  with_schema_bypassed "${APP_CHART}" \
  render_app --set probes=false --set history.successful=1

expect_fail "template dual-lock: cronJob on Application" "cronJob is removed" -- \
  with_schema_bypassed "${APP_CHART}" \
  render_app --set probes=false --set-json 'cronJob={"schedule":"0 * * * *"}'

expect_fail "template dual-lock: wrong kind" "asa-application requires kind: Application" -- \
  with_schema_bypassed "${APP_CHART}" \
  render_app --set probes=false --set-string kind=ScheduledJob

expect_fail "template dual-lock: legacyDns on worker" \
  "legacyDns is invalid for workload.type: worker" -- \
  with_schema_bypassed "${APP_CHART}" \
  render_app --set-string workload.type=worker --set legacyDns=true

expect_fail "template dual-lock: workload on ScheduledJob" \
  "workload belongs to kind: Application" -- \
  with_schema_bypassed "${JOB_CHART}" \
  render_job --set-json 'workload={"type":"web"}'

# Ensure bypass never left a schema displaced.
for ch in "${APP_CHART}" "${JOB_CHART}"; do
  if [[ ! -f "${ch}/values.schema.json" ]]; then
    echo "FAIL: values.schema.json missing after dual-lock tests (${ch})"
    FAILED=1
  elif compgen -G "${ch}/values.schema.json.tdd-off.*" >/dev/null; then
    echo "FAIL: leftover schema bypass file in ${ch}"
    ls "${ch}"/values.schema.json.tdd-off.* || true
    FAILED=1
  else
    echo "OK: schema intact after dual-lock (${ch##*/})"
  fi
done

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

  # Needles below are the English Draft7 strings from the pinned jsonschema==4.23.0
  # (see .github/workflows/ci.yml). Unlike Helm schema prose, these are library-owned —
  # re-check all six messages if that pin is bumped.
  schema_reject() {
    local msg="$1" schema="$2" json="$3" needle="$4"
    local out
    if out="$(echo "$json" | python3 "${VALIDATE}" "$schema" --stdin 2>&1)"; then
      echo "FAIL: $msg (expected rejection)"
      FAILED=1
    elif ! grep -qF -- "$needle" <<<"$out"; then
      echo "FAIL: $msg (expected message containing: $needle)"
      echo "  got: $(head -c 400 <<<"$out" | tr '\n' ' ')"
      FAILED=1
    else
      echo "OK: $msg"
    fi
  }

  APP_SCHEMA="${ROOT}/schemas/application.manifest.schema.json"
  JOB_SCHEMA="${ROOT}/schemas/scheduled-job.manifest.schema.json"

  schema_reject "typo legasyDns rejected" "$APP_SCHEMA" \
    '{"kind":"Application","workload":{"type":"web"},"probes":false,"legasyDns":true}' \
    "Additional properties are not allowed ('legasyDns' was unexpected)"
  schema_reject "typo resources.requets rejected" "$APP_SCHEMA" \
    '{"kind":"Application","workload":{"type":"web"},"probes":false,"resources":{"requets":{"cpu":"100m"}}}' \
    "Additional properties are not allowed ('requets' was unexpected)"
  schema_reject "serviceAccount.create rejected" "$APP_SCHEMA" \
    '{"kind":"Application","workload":{"type":"web"},"probes":false,"serviceAccount":{"create":true}}' \
    "Additional properties are not allowed ('create' was unexpected)"
  schema_reject "probes.path rejected by public schema" "$APP_SCHEMA" \
    '{"kind":"Application","workload":{"type":"web"},"probes":{"path":"/health"}}' \
    "is not valid under any of the given schemas"
  schema_reject "ScheduledJob without timeoutSeconds rejected" "$JOB_SCHEMA" \
    '{"kind":"ScheduledJob","schedule":{"expression":"0 2 * * *","timeZone":"America/Sao_Paulo"},"execution":{"args":["x"]}}' \
    "'timeoutSeconds' is a required property"
  schema_reject "podSecurityContext on public ScheduledJob rejected" "$JOB_SCHEMA" \
    '{"kind":"ScheduledJob","schedule":{"expression":"0 2 * * *","timeZone":"America/Sao_Paulo"},"execution":{"timeoutSeconds":60,"args":["x"]},"podSecurityContext":{"runAsNonRoot":true}}' \
    "Additional properties are not allowed ('podSecurityContext' was unexpected)"
fi

echo "== static checks (ADO / helm) =="
if ! grep -q 'convertToJson(parameters.delivery.deployEnvironments)' "${ROOT}/templates/dotnet/delivery.yml"; then
  echo "FAIL: convertToJson(delivery.deployEnvironments) missing in delivery.yml"
  FAILED=1
else
  echo "OK: convertToJson present"
fi
if grep -n 'each env in parameters.deployEnvironments' "${ROOT}/templates/dotnet/ci.yml" \
     "${ROOT}/templates/dotnet/delivery.yml" | grep -q .; then
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
elif ! grep -qF "variables['ECR_PULL_SECRET']" "${ROOT}/templates/dotnet/delivery.yml"; then
  echo "FAIL: delivery.yml must pass variables['ECR_PULL_SECRET'] into ecrPullSecret"
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

# jq-isms are invalid in mikefarah/yq and shipped broken in v3.1.1: `--arg` made every
# web/grpc Gateway preflight exit 1, and `| last |` broke the rollback path. Static-check the
# whole pipeline surface so neither can come back.
# Comment lines are excluded so the notes explaining these very bugs do not trip the check.
yq_code_lines() {
  grep -hn -- "yq" \
    "${ROOT}/templates/dotnet/ci.yml" \
    "${ROOT}/templates/dotnet/delivery.yml" \
    "${ROOT}/templates/dotnet/helm-deploy.yml" \
    | grep -vE '^[0-9]+:[[:space:]]*#'
}
for jqism in "--arg" "| last |" "| first |"; do
  if yq_code_lines | grep -qF -- "${jqism}"; then
    echo "FAIL: jq-only syntax '${jqism}' used with yq (mikefarah/yq does not support it)"
    yq_code_lines | grep -F -- "${jqism}" || true
    FAILED=1
  else
    echo "OK: no jq-only syntax '${jqism}' in yq calls"
  fi
done

# expectedKubeContext must come from the area profile via resolve --facts, never a dead parameter.
if grep -q "expectedKubeContext: ''" "${ROOT}/templates/dotnet/ci.yml"; then
  echo "FAIL: ci.yml pins expectedKubeContext to '' — the cluster-identity guard can never fire"
  FAILED=1
else
  echo "OK: ci.yml does not pin expectedKubeContext to ''"
fi
if ! grep -q "EXPECTED_KUBE_CONTEXT=\"\$(yq -r '.cluster.expectedKubeContext" "${ROOT}/templates/dotnet/helm-deploy.yml"; then
  echo "FAIL: helm-deploy.yml must read expectedKubeContext from resolve-platform-values.sh --facts"
  FAILED=1
else
  echo "OK: expectedKubeContext read from platform facts"
fi

# Chart invariants must run BEFORE the image push, not only at deploy time.
if ! grep -q 'helm template' "${ROOT}/templates/dotnet/delivery.yml"; then
  echo "FAIL: DeployContract must run helm template per tier (chart invariants before the image push)"
  FAILED=1
else
  echo "OK: DeployContract renders each manifest with helm template"
fi

# Preflight must assert the exact group/version the charts apply.
if ! grep -q 'require_api gateway.networking.k8s.io/v1' "${ROOT}/templates/dotnet/helm-deploy.yml"; then
  echo "FAIL: route preflight must assert gateway.networking.k8s.io/v1 exactly"
  FAILED=1
else
  echo "OK: route preflight asserts exact Gateway API version"
fi
if ! grep -q 'require_api external-secrets.io/v1 ' "${ROOT}/templates/dotnet/helm-deploy.yml"; then
  echo "FAIL: ExternalSecret preflight must assert external-secrets.io/v1 exactly"
  FAILED=1
else
  echo "OK: ExternalSecret preflight asserts exact ESO version"
fi

echo "== hardening baseline renders =="
OUT_HARD="$(PLATFORM_ENV=production render_app --set probes=false)"
assert_contains "$OUT_HARD" "revisionHistoryLimit: 3" "app revisionHistoryLimit pinned"
assert_contains "$OUT_HARD" "progressDeadlineSeconds: 240" "app progressDeadlineSeconds pinned"
assert_contains "$OUT_HARD" "enableServiceLinks: false" "app enableServiceLinks disabled"
assert_contains "$OUT_HARD" "terminationMessagePolicy: FallbackToLogsOnError" "app terminationMessagePolicy"
assert_contains "$OUT_HARD" "maxUnavailable: 0" "app rollingUpdate maxUnavailable 0"
assert_contains "$OUT_HARD" "runAsUser: 1654" "app runAsUser pinned to image APP_UID"
assert_contains "$OUT_HARD" "fsGroup: 1654" "app fsGroup pinned to image APP_UID"

# Recreate (RWO PVC) must not carry a rollingUpdate block.
OUT_RECREATE="$(render_app --set probes=false --set autoscaling=false \
  --set-string persistence.mountPath=/data --set-string persistence.size=1Gi)"
assert_contains "$OUT_RECREATE" "type: Recreate" "persistence uses Recreate"
assert_not_contains "$OUT_RECREATE" "rollingUpdate:" "Recreate has no rollingUpdate block"

OUT_JOB_HARD="$(render_job)"
assert_contains "$OUT_JOB_HARD" "enableServiceLinks: false" "job enableServiceLinks disabled"
assert_contains "$OUT_JOB_HARD" "terminationMessagePolicy: FallbackToLogsOnError" "job terminationMessagePolicy"
assert_contains "$OUT_JOB_HARD" "runAsUser: 1654" "job runAsUser pinned to image APP_UID"

# The chart pins runAsUser; the platform Dockerfile must assert the same UID at build time.
if ! grep -q 'EXPECTED_APP_UID' "${ROOT}/docker/dotnet/Dockerfile"; then
  echo "FAIL: docker/dotnet/Dockerfile must assert APP_UID matches the chart runAsUser"
  FAILED=1
else
  echo "OK: Dockerfile asserts APP_UID against the chart runAsUser"
fi

echo "== supply chain of downloaded tooling =="
# Pinning a version does not protect the download; the bytes must be verified too.
#
# Checked per download, not per file: a file that verifies one tool and not another would pass
# a file-level check, and a hand-maintained list of tool names silently fails to cover the next
# tool someone adds.
#
# Two risk classes, two rules:
#   a binary fetched with curl/wget is executed on the runner  -> require a SHA-256 check
#   a manifest handed straight to `kubectl apply -f <url>`      -> cannot be checksummed inline,
#     and lands on a throwaway cluster deleted minutes later, so require a pinned ref instead
DOWNLOAD_HITS=0
for f in "${ROOT}/templates/dotnet/ci.yml" "${ROOT}/.github/workflows/ci.yml"; do
  [[ -f "${f}" ]] || continue
  name="$(basename "$(dirname "${f}")")/$(basename "${f}")"
  # A shell line continuation puts the URL on the line AFTER the curl/wget, so the awk below
  # reports the position of the fetch itself and de-duplicates adjacent hits.
  hits="$(awk '
      /^[[:space:]]*#/ { next }
      /curl|wget/ { cand = NR }
      /releases\/download|raw\.githubusercontent/ {
        start = (cand && NR - cand <= 2) ? cand : NR
        if (start != last) { print start ; last = start }
        cand = 0
      }
    ' "${f}" || true)"
  for lineno in ${hits}; do
    DOWNLOAD_HITS=$((DOWNLOAD_HITS + 1))
    # The window reaches slightly backwards too: with a line continuation the verb
    # (kubectl apply / curl) can sit above the line the URL was found on.
    win_start=$(( lineno > 2 ? lineno - 2 : 1 ))
    window="$(sed -n "${win_start},$((lineno + 6))p" "${f}")"
    # `|| true` throughout: grep exits 1 on no match, which would abort the suite under `set -e`.
    artifact="$(grep -oE '[A-Za-z0-9._-]+(-linux-amd64|_linux_amd64)(\.tar\.gz)?' <<<"${window}" | head -1 || true)"
    if [[ -z "${artifact}" ]]; then
      # Take the name from the URL on THIS line, not from the widened window, or a neighbouring
      # download's name gets reported and the output misleads whoever is debugging.
      url_line="$(sed -n "${lineno},$((lineno + 2))p" "${f}" | grep -oE 'https?://[^"]+' | head -1 || true)"
      artifact="$(sed -n 's#.*github.com/\([^/]*/[^/]*\)/releases.*#\1#p' <<<"${url_line}" | head -1 || true)"
      if [[ -z "${artifact}" ]]; then
        artifact="$(sed -n 's#.*githubusercontent.com/\([^/]*/[^/]*\)/.*#\1#p' <<<"${url_line}" | head -1 || true)"
      fi
    fi
    artifact="${artifact:-<unknown>}"

    if grep -q 'kubectl apply' <<<"${window}"; then
      if grep -qE '(/main/|/master/|/latest/)' <<<"${window}"; then
        echo "FAIL: ${name}:${lineno} applies a remote manifest from a floating ref"
        FAILED=1
      else
        echo "OK: ${name}:${lineno} applies ${artifact} from a pinned ref"
      fi
    elif grep -q 'sha256sum -c' <<<"${window}"; then
      echo "OK: ${name}:${lineno} verifies the ${artifact} download checksum"
    else
      echo "FAIL: ${name}:${lineno} downloads ${artifact} without verifying its SHA-256"
      sed -n "${lineno}p" "${f}" | sed 's/^/    /'
      FAILED=1
    fi
  done
done
# If the detector ever stops finding the downloads that exist, it is broken, not clean.
if [[ "${DOWNLOAD_HITS}" -lt 4 ]]; then
  echo "FAIL: supply-chain check found only ${DOWNLOAD_HITS} downloads (expected at least 4) — the detector is broken"
  FAILED=1
else
  echo "OK: ${DOWNLOAD_HITS} tool/manifest download(s) inspected"
fi

# The same yq version and checksum must be used everywhere, or one path validates
# different bytes than the other.
YQ_SHAS="$(grep -ho 'YQ_SHA256[:=] *"\?[a-f0-9]\{64\}' "${ROOT}/templates/dotnet/ci.yml" "${ROOT}/.github/workflows/ci.yml" \
  | grep -o '[a-f0-9]\{64\}' | sort -u | wc -l | tr -d ' ')"
if [[ "${YQ_SHAS}" == "1" ]]; then
  echo "OK: a single yq checksum across ci.yml and the repo workflow"
else
  echo "FAIL: ci.yml and .github/workflows/ci.yml disagree on the yq checksum (${YQ_SHAS} distinct)"
  FAILED=1
fi

# Tags are mutable; a compromised tag silently changes what runs in CI.
UNPINNED="$(grep -n 'uses: .*@v[0-9]' "${ROOT}/.github/workflows/ci.yml" || true)"
if [[ -n "${UNPINNED//[[:space:]]/}" ]]; then
  echo "FAIL: GitHub actions referenced by mutable tag instead of commit SHA:"
  sed 's/^/    /' <<<"${UNPINNED}"
  FAILED=1
else
  echo "OK: all GitHub actions pinned to commit SHAs"
fi

# ECR_PULL_SECRET must survive both ways a consumer can define it.
for v in ECR_PULL_SECRET_PARAM ECR_PULL_SECRET_RUNTIME; do
  if ! grep -q "${v}" "${ROOT}/templates/dotnet/helm-deploy.yml"; then
    echo "FAIL: helm-deploy.yml must read ${v} (compile-time param and runtime macro cover different sources)"
    FAILED=1
  else
    echo "OK: helm-deploy.yml reads ${v}"
  fi
done
if ! grep -qF "== '\$('*" "${ROOT}/templates/dotnet/helm-deploy.yml"; then
  echo "FAIL: helm-deploy.yml must treat an unexpanded \$(NAME) macro as absent"
  FAILED=1
else
  echo "OK: unexpanded ADO macro treated as absent"
fi

echo "== deploy pool: platform.tiers lookup at all 3 call sites =="
LOOKUP_OK=$(grep -c 'parameters.platform.tiers\[parameters.delivery.deployEnvironments\[[0-2]\].name\].deployPool' \
  "${ROOT}/templates/dotnet/delivery.yml" || true)
if [[ "${LOOKUP_OK}" -ne 3 ]]; then
  echo "FAIL: delivery.yml must resolve deployPool via platform.tiers[...] at all 3 call sites (found ${LOOKUP_OK}/3)"
  FAILED=1
else
  echo "OK: deployPool resolved via platform.tiers lookup at all 3 call sites"
fi
ENV_LOOKUP_OK=$(grep -c 'parameters.platform.tiers\[parameters.delivery.deployEnvironments\[[0-2]\].name\].environmentName' \
  "${ROOT}/templates/dotnet/delivery.yml" || true)
if [[ "${ENV_LOOKUP_OK}" -ne 3 ]]; then
  echo "FAIL: delivery.yml must resolve environmentName via platform.tiers[...] at all 3 call sites (found ${ENV_LOOKUP_OK}/3)"
  FAILED=1
else
  echo "OK: environmentName resolved via platform.tiers lookup at all 3 call sites"
fi
if grep -qE 'iif\(eq\(parameters\.deployEnvironments' "${ROOT}/templates/dotnet/ci.yml" \
  "${ROOT}/templates/dotnet/delivery.yml"; then
  echo "FAIL: iif pool chain must be removed (pools come from area profile)"
  FAILED=1
else
  echo "OK: no iif pool chain in ci/delivery"
fi

echo "== kubeVersion floor (derived from chart content) =="
for ch in "${APP_CHART}" "${JOB_CHART}"; do
  if ! grep -q 'kubeVersion: ">=1.27.0-0"' "${ch}/Chart.yaml"; then
    echo "FAIL: $(basename "${ch}") missing derived kubeVersion >=1.27.0-0 (CronJob .spec.timeZone is stable from v1.27)"
    FAILED=1
  else
    echo "OK: $(basename "${ch}") declares kubeVersion >=1.27.0-0"
  fi
done
expect_fail "app chart rejects Kubernetes 1.26" "kubeVersion: >=1.27.0-0" -- \
  render_app --set probes=false --kube-version 1.26.0
if render_app --set probes=false --kube-version 1.27.0 >/dev/null 2>&1; then
  echo "OK: app chart accepts Kubernetes 1.27"
else
  echo "FAIL: app chart rejects Kubernetes 1.27"
  FAILED=1
fi

echo "== PDB only where it can protect something =="
OUT_PDB_DEV="$(PLATFORM_ENV=develop render_app --set probes=false)"
assert_kind_count "$OUT_PDB_DEV" PodDisruptionBudget 0 "develop (1 replica): no PDB"
assert_not_contains "$OUT_PDB_DEV" "topologySpreadConstraints:" "develop (1 replica): no topology spread"

OUT_PDB_PRD="$(PLATFORM_ENV=production render_app --set probes=false)"
assert_kind_count "$OUT_PDB_PRD" PodDisruptionBudget 1 "production (2 replicas): PDB rendered"
assert_contains "$OUT_PDB_PRD" "unhealthyPodEvictionPolicy: AlwaysAllow" "PDB AlwaysAllow (upstream recommendation)"
assert_contains "$OUT_PDB_PRD" "maxUnavailable: 1" "PDB maxUnavailable 1"
# minAvailable percentages round UP: 90% of 2 replicas = 2, which would block every drain.
assert_not_contains "$OUT_PDB_PRD" "minAvailable:" "PDB does not use minAvailable percentages"

echo "== topology spread is soft (cluster-agnostic) =="
assert_contains "$OUT_PDB_PRD" "topologySpreadConstraints:" "production: topology spread rendered"
assert_contains "$OUT_PDB_PRD" "whenUnsatisfiable: ScheduleAnyway" "topology spread is ScheduleAnyway"
assert_contains "$OUT_PDB_PRD" "topologyKey: topology.kubernetes.io/zone" "topology spread on well-known zone label"
assert_not_contains "$OUT_PDB_PRD" "whenUnsatisfiable: DoNotSchedule" "no hard DoNotSchedule (breaks single-zone clusters)"

# Explicit opt-out still honoured.
OUT_PDB_OFF="$(PLATFORM_ENV=production render_app --set probes=false --set pdb.enabled=false)"
assert_kind_count "$OUT_PDB_OFF" PodDisruptionBudget 0 "pdb.enabled=false honoured"

echo "== hostname composition =="
# The hostname list is composed from two inputs of different origin: legacyDns is consumer
# intent (public manifest) and legacyDnsZone is a platform fact (area profile). Both route
# kinds need the identical list, so it is composed once in chart.hostnames and the route
# templates stay purely structural.
hostnames_of() {
  local kind="$1" rendered="$2"
  printf '%s' "${rendered}" | yq ea -r "select(.kind == \"${kind}\") | .spec.hostnames[]" 2>/dev/null | awk 'NF'
}
assert_hostnames() {
  local msg="$1" kind="$2" rendered="$3" expected="$4"
  local got
  got="$(hostnames_of "${kind}" "${rendered}" | tr '\n' ',' | sed 's/,$//')"
  if [[ "${got}" == "${expected}" ]]; then
    echo "OK: ${msg}"
  else
    echo "FAIL: ${msg} (got '${got}', want '${expected}')"
    FAILED=1
  fi
}

OUT_H_WEB="$(render_app --set-string workload.type=web --set-json 'probes={"readiness":{"path":"/h"}}')"
assert_hostnames "web: corp hostname only when legacyDns is off" HTTPRoute "$OUT_H_WEB" \
  "sample-api.dev.asa.corp"

OUT_H_WEB_L="$(render_app --set-string workload.type=web --set-json 'probes={"readiness":{"path":"/h"}}' --set legacyDns=true)"
assert_hostnames "web: corp then legacy when legacyDns is on" HTTPRoute "$OUT_H_WEB_L" \
  "sample-api.dev.asa.corp,sample-api.d.asa.com.br"

OUT_H_GRPC="$(render_app --set-string workload.type=grpc --set-json 'probes={"readiness":{"enabled":true}}')"
assert_hostnames "grpc: corp hostname only when legacyDns is off" GRPCRoute "$OUT_H_GRPC" \
  "sample-api.dev.asa.corp"

OUT_H_GRPC_L="$(render_app --set-string workload.type=grpc --set-json 'probes={"readiness":{"enabled":true}}' --set legacyDns=true)"
assert_hostnames "grpc: corp then legacy when legacyDns is on" GRPCRoute "$OUT_H_GRPC_L" \
  "sample-api.dev.asa.corp,sample-api.d.asa.com.br"

# An area whose legacy zone equals its corp zone must not emit the hostname twice. The API
# server accepts a duplicate silently, so nothing downstream would catch it.
OUT_H_SAME="$(render_app --set-string workload.type=web --set-json 'probes={"readiness":{"path":"/h"}}' \
  --set legacyDns=true --set-string platform.legacyDnsZone=dev.asa.corp)"
assert_hostnames "identical corp and legacy zones collapse to one hostname" HTTPRoute "$OUT_H_SAME" \
  "sample-api.dev.asa.corp"

OUT_H_SAME_GRPC="$(render_app --set-string workload.type=grpc --set-json 'probes={"readiness":{"enabled":true}}' \
  --set legacyDns=true --set-string platform.legacyDnsZone=dev.asa.corp)"
assert_hostnames "grpc: identical zones collapse to one hostname" GRPCRoute "$OUT_H_SAME_GRPC" \
  "sample-api.dev.asa.corp"

# legacyDns without a zone is a misconfiguration, and both route kinds must reject it with
# the same message from the same place — not from whichever route template happens to render.
expect_fail "legacyDns without a legacy zone rejected (web)" "legacyDns=true requires platform.legacyDnsZone" -- \
  render_app --set-string workload.type=web --set-json 'probes={"readiness":{"path":"/h"}}' \
    --set legacyDns=true --set-string platform.legacyDnsZone=
expect_fail "legacyDns without a legacy zone rejected (grpc)" "legacyDns=true requires platform.legacyDnsZone" -- \
  render_app --set-string workload.type=grpc --set-json 'probes={"readiness":{"enabled":true}}' \
    --set legacyDns=true --set-string platform.legacyDnsZone=

# Route templates must not re-implement the rule; they consume the composed list.
for rt in httproute grpcroute; do
  if grep -q 'legacyDns' "${APP_CHART}/templates/${rt}.yaml"; then
    echo "FAIL: ${rt}.yaml decides hostname policy — it must include chart.hostnames instead"
    FAILED=1
  else
    echo "OK: ${rt}.yaml consumes the composed hostname list"
  fi
done

echo "== label values satisfy the Kubernetes label syntax =="
# kubeconform validates structure and types but NOT label value syntax, so a tag like a
# digest (sha256:...) or semver build metadata (1.2.3+build.5) rendered straight into
# app.kubernetes.io/version passes every schema and is then rejected by the API server with
# "metadata.labels: Invalid value", failing the whole apply. Assert the regex here.
# k8s rule: empty, or <=63 chars of [A-Za-z0-9._-] starting and ending alphanumeric.
assert_labels_valid() {
  local rendered="$1" msg="$2"
  local bad
  bad="$(grep -oE '^[[:space:]]+[a-zA-Z0-9./_-]+:[[:space:]]*"?[^"]*"?$' <<<"$rendered" \
    | grep -E '(app\.kubernetes\.io/|helm\.sh/chart|^[[:space:]]+app:)' \
    | sed 's/^[[:space:]]*//; s/"//g' \
    | while IFS= read -r line; do
        local key="${line%%:*}" val="${line#*: }"
        [[ "${val}" == "${line}" ]] && val=""
        if [[ -n "${val}" ]] && ! grep -qE '^[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$' <<<"${val}"; then
          echo "${key}=${val}"
        fi
      done)"
  if [[ -n "${bad//[[:space:]]/}" ]]; then
    echo "FAIL: ${msg} (invalid label values)"
    sed 's/^/    /' <<<"${bad}"
    FAILED=1
  else
    echo "OK: ${msg}"
  fi
}

# Tag forms that are realistic and previously produced an invalid label. The digest form is
# on the path of the gitops branch, which pins images by digest.
for TAG in "deadbeef1234" "sha256:abc123def456789" "1.2.3+build.5" "-leading.dash-"; do
  assert_labels_valid "$(render_app --set probes=false --set-string "image.tag=${TAG}")" \
    "app labels valid for image.tag=${TAG}"
  assert_labels_valid "$(render_job --set-string "image.tag=${TAG}")" \
    "job labels valid for image.tag=${TAG}"
done
# 70 chars must be truncated to 63, not rejected.
LONG_TAG="$(printf 'a%.0s' $(seq 1 70))"
LONG_OUT="$(render_app --set probes=false --set-string "image.tag=${LONG_TAG}")"
assert_labels_valid "${LONG_OUT}" "app labels valid for a 70-char image.tag"
if grep -qE 'app\.kubernetes\.io/version: "a{63}"' <<<"${LONG_OUT}"; then
  echo "OK: long image.tag truncated to 63 chars"
else
  echo "FAIL: long image.tag not truncated to exactly 63 chars"
  FAILED=1
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

echo "== platform contract =="
if ! bash "${ROOT}/tests/platform-contract.sh"; then
  echo "FAIL: platform-contract.sh"
  FAILED=1
fi

echo "== chart conform (kubeconform) =="
if ! bash "${ROOT}/tests/chart-conform.sh"; then
  echo "FAIL: chart-conform.sh"
  FAILED=1
fi

echo "== helm lint =="
pf_lint="$(mktemp -t asa-platform.XXXXXX.yaml)"
"${ROOT}/scripts/resolve-platform-values.sh" lab develop "${pf_lint}"
if ! helm lint "${APP_CHART}" \
  -f "${pf_lint}" \
  --set-string image.repository=example.dkr.ecr.us-east-1.amazonaws.com/sample-api; then
  echo "FAIL: helm lint asa-application"
  FAILED=1
else
  echo "OK: helm lint asa-application"
fi
rm -f "${pf_lint}"
pf_lint="$(mktemp -t asa-platform.XXXXXX.yaml)"
"${ROOT}/scripts/resolve-platform-values.sh" lab develop "${pf_lint}"
if ! helm lint "${JOB_CHART}" \
  -f "${pf_lint}" \
  --set-string image.repository=example.dkr.ecr.us-east-1.amazonaws.com/sample-job \
  --set-string schedule.expression='0 2 * * *' \
  --set-string schedule.timeZone=America/Sao_Paulo \
  --set execution.timeoutSeconds=1800 \
  --set-string 'execution.args[0]=--mode=job'; then
  echo "FAIL: helm lint asa-scheduled-job"
  FAILED=1
else
  echo "OK: helm lint asa-scheduled-job"
fi
rm -f "${pf_lint}"

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
