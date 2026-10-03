#!/usr/bin/env bash
# Golden render gate for chart refactors.
#
#   ./tests/chart-golden.sh record   # write/overwrite tests/golden/*.yaml
#   ./tests/chart-golden.sh check    # compare current renders to golden (default)
#
# Phase 1 (environment decoupling) intentionally changes values injection — re-record
# after that phase. Phases 2+ (probes/toggles, preflight) must keep check green with
# zero render diff.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_CHART="${ROOT}/charts/asa-application"
JOB_CHART="${ROOT}/charts/asa-scheduled-job"
GOLDEN_DIR="${ROOT}/tests/golden"
RESOLVE="${ROOT}/scripts/resolve-platform-values.sh"
MODE="${1:-check}"
FAILED=0

mkdir -p "${GOLDEN_DIR}"

# Prefer the platform resolver when present (post Phase 1). Fall back to the
# legacy --set-string so Phase 0 can record a baseline before the resolver exists.
platform_args() {
  local tier="$1"
  local area="${PLATFORM_AREA:-lab}"
  if [[ -x "${RESOLVE}" ]]; then
    local f
    f="$(mktemp -t asa-platform.XXXXXX.yaml)"
    "${RESOLVE}" "${area}" "${tier}" "${f}"
    echo "-f" "${f}"
  else
    echo "--set-string" "runtime.environment=${tier}"
  fi
}

render_named() {
  local name="$1"
  shift
  local out
  out="$("$@" 2>&1)" || {
    echo "FAIL: render ${name}: ${out}" >&2
    return 1
  }
  # Drop helm NOTES / blank trailing noise; keep deterministic YAML docs.
  printf '%s\n' "${out}" | sed -e '/^$/N;/^\n$/D'
}

app() {
  local env="$1"
  shift
  # shellcheck disable=SC2046
  helm template golden-app "${APP_CHART}" \
    --set-string image.repository=example.invalid/app \
    --set-string image.tag=deadbeef \
    $(platform_args "${env}") \
    "$@"
}

job() {
  # shellcheck disable=SC2046
  helm template golden-job "${JOB_CHART}" \
    --set-string image.repository=example.invalid/job \
    --set-string image.tag=deadbeef \
    --set-string 'schedule.expression=0 2 * * *' \
    --set-string schedule.timeZone=America/Sao_Paulo \
    --set execution.timeoutSeconds=1800 \
    --set-string 'execution.args[0]=--mode=job' \
    $(platform_args develop) \
    "$@"
}

# name → render command (as a function call string evaluated below)
SCENARIOS=(
  "app-web-develop"
  "app-web-production"
  "app-grpc-develop"
  "app-worker-develop"
  "app-web-probes-http"
  "app-grpc-probes"
  "job-minimal"
)

render_scenario() {
  local name="$1"
  case "${name}" in
    app-web-develop)
      app develop --set-string workload.type=web --set probes=false
      ;;
    app-web-production)
      app production --set-string workload.type=web --set probes=false
      ;;
    app-grpc-develop)
      app develop --set-string workload.type=grpc --set probes=false
      ;;
    app-worker-develop)
      app develop --set-string workload.type=worker
      ;;
    app-web-probes-http)
      app develop --set-string workload.type=web \
        --set-json 'probes={"startup":{"path":"/s"},"readiness":{"path":"/r"},"liveness":{"path":"/l"}}'
      ;;
    app-grpc-probes)
      app develop --set-string workload.type=grpc \
        --set-json 'probes={"readiness":{"enabled":true},"liveness":{"enabled":true}}'
      ;;
    job-minimal)
      job
      ;;
    *)
      echo "unknown scenario: ${name}" >&2
      return 1
      ;;
  esac
}

record_all() {
  local name path
  for name in "${SCENARIOS[@]}"; do
    path="${GOLDEN_DIR}/${name}.yaml"
    render_scenario "${name}" > "${path}"
    echo "recorded ${path}"
  done
}

check_all() {
  local name path got tmp
  tmp="$(mktemp -d -t asa-golden.XXXXXX)"
  for name in "${SCENARIOS[@]}"; do
    path="${GOLDEN_DIR}/${name}.yaml"
    if [[ ! -f "${path}" ]]; then
      echo "FAIL: missing golden ${path} — run: ./tests/chart-golden.sh record"
      FAILED=1
      continue
    fi
    if ! render_scenario "${name}" > "${tmp}/${name}.yaml"; then
      FAILED=1
      continue
    fi
    if ! diff -u "${path}" "${tmp}/${name}.yaml" > "${tmp}/${name}.diff"; then
      echo "FAIL: golden drift for ${name}"
      head -80 "${tmp}/${name}.diff" || true
      FAILED=1
    else
      echo "OK: ${name}"
    fi
  done
  rm -rf "${tmp}"
}

case "${MODE}" in
  record) record_all ;;
  check)  check_all ;;
  *)
    echo "usage: $0 record|check" >&2
    exit 2
    ;;
esac

if [[ "${FAILED}" -ne 0 ]]; then
  echo "Golden render check failed"
  exit 1
fi
echo "Golden render ${MODE} ok"
