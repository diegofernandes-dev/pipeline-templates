#!/usr/bin/env bash
# scheduledJobSmoke.enabled platform policy (v6) — structural + decision harness.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0
HELM_YML="${ROOT}/templates/dotnet/helm-deploy.yml"
DELIVERY_YML="${ROOT}/templates/dotnet/delivery.yml"
CI_YML="${ROOT}/templates/dotnet/ci.yml"
LAB_YML="${ROOT}/platform/areas/lab.yml"

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }

echo "== public API: no consumer smoke knob =="
if yq -e '.parameters[] | select(.name == "smokeScheduledJob")' "${CI_YML}" >/dev/null 2>&1; then
  fail "ci.yml must not declare smokeScheduledJob"
else
  pass "smokeScheduledJob absent from public API"
fi
if grep -qE 'smokeAllowed|smokeScheduledJob' "${CI_YML}" "${DELIVERY_YML}"; then
  fail "legacy smokeAllowed/smokeScheduledJob still in ci/delivery"
else
  pass "no legacy smoke knobs in ci/delivery"
fi

echo "== platform profile defaults =="
for tier in develop homolog production; do
  en="$(yq -r "
    .parameters[] | select(.name == \"platform\") | .default.tiers.\"${tier}\".scheduledJobSmoke.enabled
  " "${LAB_YML}")"
  if [[ "${en}" != "false" ]]; then
    fail "lab/${tier} scheduledJobSmoke.enabled must be false (got '${en}')"
  else
    pass "lab/${tier} scheduledJobSmoke.enabled=false"
  fi
done
if yq -e '
  .parameters[] | select(.name == "platform") | .default.tiers.*.smokeAllowed
' "${LAB_YML}" >/dev/null 2>&1; then
  fail "smokeAllowed must be removed from lab profile"
else
  pass "smokeAllowed removed from lab"
fi

echo "== delivery wires compile-time policy =="
if ! grep -q 'scheduledJobSmokeEnabled: \${{ parameters.platform.tiers\[parameters.platform.promotion\[[0-2]\]\].scheduledJobSmoke.enabled }}' \
  "${DELIVERY_YML}" \
  && ! grep -qF 'scheduledJobSmoke.enabled' "${DELIVERY_YML}"; then
  fail "delivery.yml must pass scheduledJobSmokeEnabled from platform.tiers"
else
  COUNT="$(grep -c 'scheduledJobSmoke.enabled' "${DELIVERY_YML}" || true)"
  if [[ "${COUNT}" -lt 3 ]]; then
    fail "expected scheduledJobSmoke.enabled at all 3 slots (found ${COUNT})"
  else
    pass "scheduledJobSmokeEnabled wired at ${COUNT} call sites"
  fi
fi

echo "== helm-deploy decision semantics =="
if ! grep -q 'scheduledJobSmoke.enabled=true is only valid for ScheduledJob' "${HELM_YML}"; then
  fail "Application + enabled=true must fail-closed with explicit message"
else
  pass "Application + enabled=true fail-closed message present"
fi
if ! grep -q 'create job' "${HELM_YML}" || ! grep -q 'cronjob/' "${HELM_YML}"; then
  fail "enabled=true path must create Job from CronJob"
else
  pass "create job --from=cronjob path present"
fi
# Smoke create must be gated by SCHEDULED_JOB_SMOKE_ENABLED / SMOKE_ON.
BLOCK="$(awk '/SMOKE_ON=false/,/^[[:space:]]*fi[[:space:]]*$/' "${HELM_YML}" | head -40)"
if ! grep -q 'SCHEDULED_JOB_SMOKE_ENABLED' <<<"${BLOCK}"; then
  fail "smoke block must read SCHEDULED_JOB_SMOKE_ENABLED"
else
  pass "smoke gated by SCHEDULED_JOB_SMOKE_ENABLED"
fi
if grep -q 'SMOKE_ALLOWED\|smokeAllowed' "${HELM_YML}"; then
  fail "helm-deploy must not use smokeAllowed"
else
  pass "helm-deploy has no smokeAllowed residual"
fi

echo "== decision harness (no kubectl) =="
# Mirror the gate used in helm-deploy.yml without executing cluster commands.
decide_smoke() {
  local kind="$1" enabled="$2"
  local smoke_on=false
  case "${enabled}" in
    True|true|TRUE|1) smoke_on=true ;;
  esac
  if [[ "${smoke_on}" == "true" ]]; then
    if [[ "${kind}" != "ScheduledJob" ]]; then
      echo "FAIL_POLICY"
      return 2
    fi
    echo "CREATE_JOB"
    return 0
  fi
  echo "NO_SMOKE"
  return 0
}

out="$(decide_smoke ScheduledJob false)"; [[ "${out}" == "NO_SMOKE" ]] && pass "ScheduledJob+false → no smoke" || fail "ScheduledJob+false → ${out}"
out="$(decide_smoke ScheduledJob true)"; [[ "${out}" == "CREATE_JOB" ]] && pass "ScheduledJob+true → create job" || fail "ScheduledJob+true → ${out}"
set +e
out="$(decide_smoke Application true)"; rc=$?
set -e
[[ "${rc}" -eq 2 && "${out}" == "FAIL_POLICY" ]] && pass "Application+true → FAIL" || fail "Application+true → out=${out} rc=${rc}"
out="$(decide_smoke ScheduledJob '')"; [[ "${out}" == "NO_SMOKE" ]] && pass "missing/empty → no smoke" || fail "missing → ${out}"

if [[ "${FAILED}" -ne 0 ]]; then
  echo "SCHEDULED JOB SMOKE: FAILED"
  exit 1
fi
echo "SCHEDULED JOB SMOKE: OK"
