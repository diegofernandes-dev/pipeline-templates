#!/usr/bin/env bash
# Platform-owned promotion topology + public delivery API contract (v6).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0
CI_YML="${ROOT}/templates/dotnet/ci.yml"
DELIVERY_YML="${ROOT}/templates/dotnet/delivery.yml"
HELM_YML="${ROOT}/templates/dotnet/helm-deploy.yml"
LAB_YML="${ROOT}/platform/areas/lab.yml"
EXAMPLE_PIPE="${ROOT}/examples/azure-pipelines.yml"

for cmd in yq python3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "FAIL: ${cmd} is required"
    exit 1
  fi
done

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }

echo "== public API =="
if yq -e '.parameters[] | select(.name == "deployEnvironments")' "${CI_YML}" >/dev/null 2>&1; then
  fail "ci.yml must not declare deployEnvironments"
else
  pass "deployEnvironments absent from public API"
fi
if yq -e '.parameters[] | select(.name == "helmTimeout")' "${CI_YML}" >/dev/null 2>&1; then
  fail "ci.yml must not declare consumer helmTimeout"
else
  pass "helmTimeout absent from public API"
fi
if grep -qE 'variableGroups|ECR_PULL_SECRET|ecrPullSecret|smokeScheduledJob' \
  "${CI_YML}" "${DELIVERY_YML}" "${HELM_YML}"; then
  fail "removed delivery knobs still referenced in templates"
else
  pass "no variableGroups/ECR_PULL_SECRET/smokeScheduledJob in templates"
fi
if ! grep -q "ne(parameters.platformArea, 'none')" "${CI_YML}"; then
  fail "platformArea none ⇒ CI-only gate missing"
else
  pass "platformArea none ⇒ CI-only"
fi
if ! grep -q 'platformArea: lab' "${EXAMPLE_PIPE}"; then
  fail "example pipeline must set platformArea: lab"
elif grep -q 'deployEnvironments' "${EXAMPLE_PIPE}"; then
  fail "example pipeline must not use deployEnvironments"
else
  pass "example pipeline uses platformArea only"
fi

echo "== lab promotion source of truth =="
mapfile -t LAB_PROMO < <(yq -r '
  .parameters[] | select(.name == "platform") | .default.promotion[]
' "${LAB_YML}")
if [[ "${#LAB_PROMO[@]}" -ne 2 || "${LAB_PROMO[0]}" != "develop" || "${LAB_PROMO[1]}" != "homolog" ]]; then
  fail "lab promotion must be exactly develop, homolog (got: ${LAB_PROMO[*]-})"
else
  pass "lab promotion=[develop homolog]"
fi
if yq -e '
  .parameters[] | select(.name == "platform") | .default.promotion[] | select(. == "production")
' "${LAB_YML}" >/dev/null 2>&1; then
  fail "lab must not promote production while deployPool is null"
else
  pass "lab production known but not in promotion"
fi

echo "== stage generation from platform.promotion =="
for i in 0 1 2; do
  if ! grep -q "parameters.platform.promotion\[${i}\]" "${DELIVERY_YML}"; then
    fail "delivery.yml missing promotion[${i}] slot"
  fi
done
if [[ "${FAILED}" -eq 0 ]]; then
  pass "delivery.yml has promotion[0..2] compile-time slots"
fi
if ! grep -q 'gt(length(parameters.platform.promotion), 1)' "${DELIVERY_YML}"; then
  fail "second Deploy stage not gated on promotion length"
else
  pass "Deploy_homolog gated on length(promotion) > 1"
fi
if ! grep -q 'Deploy_\${{ parameters.platform.promotion\[0\] }}' "${DELIVERY_YML}" \
  && ! grep -qF 'Deploy_${{ parameters.platform.promotion[0] }}' "${DELIVERY_YML}"; then
  fail "dependsOn chain must reference Deploy_\${{ parameters.platform.promotion[0] }}"
else
  pass "promotion dependsOn chain present"
fi

echo "== DeployContract reads platform.promotion =="
if ! grep -q "yq -r '.promotion\\[\\]'" "${DELIVERY_YML}" \
  && ! grep -qF "yq -r '.promotion[]'" "${DELIVERY_YML}"; then
  fail "DeployContract must parse platform.promotion[]"
else
  pass "DeployContract uses platform.promotion"
fi
if grep -q 'DEPLOY_ENVIRONMENTS_JSON\|delivery.deployEnvironments' "${DELIVERY_YML}"; then
  fail "DeployContract still references deployEnvironments"
else
  pass "DeployContract has no deployEnvironments residual"
fi

echo "== promotion validation negatives (profile shape) =="
AREAS_SCHEMA="${ROOT}/platform/areas.schema.json"
validate_promo() {
  local label="$1" json="$2" expect="$3"
  tmp="$(mktemp -t asa-promo.XXXXXX.json)"
  printf '%s' "${json}" > "${tmp}"
  set +e
  python3 -c "
import json, jsonschema, sys
schema=json.load(open('${AREAS_SCHEMA}'))
inst=json.load(open('${tmp}'))
try:
  jsonschema.validate(inst, schema)
  sys.exit(0)
except jsonschema.ValidationError:
  sys.exit(1)
"
  rc=$?
  set -e
  rm -f "${tmp}"
  if [[ "${expect}" == "pass" && "${rc}" -eq 0 ]]; then
    pass "schema ${label}"
  elif [[ "${expect}" == "fail" && "${rc}" -ne 0 ]]; then
    pass "schema rejects ${label}"
  else
    fail "schema ${label} (expected ${expect}, rc=${rc})"
  fi
}

BASE='{
  "area":"x","buildPool":"B",
  "registry":{"awsAccountId":"111111111111","awsRegion":"us-east-1"},
  "promotion":["develop"],
  "tiers":{"develop":{
    "order":1,"deployPool":"D","environmentName":"develop",
    "awsAccountId":"111111111111","awsRegion":"us-east-1",
    "expectedKubeContext":"ctx","gatewayName":"g","gatewayNamespace":"ns",
    "dnsZone":"dev.example","defaultMinReplicas":1,
    "scheduledJobSmoke":{"enabled":false},
    "podSecurity":{"enforce":null,"enforceVersion":null}
  }}
}'
validate_promo "minimal valid" "${BASE}" pass
validate_promo "empty promotion" "$(printf '%s' "${BASE}" | yq -o=json -I=0 '.promotion = []')" fail
validate_promo "duplicate promotion" "$(printf '%s' "${BASE}" | yq -o=json -I=0 '.promotion = ["develop","develop"]')" fail

echo "== completeness helper (unknown / incomplete) =="
# Mirror DeployContract/platform-contract rules outside schema.
check_complete() {
  local json="$1"
  mapfile -t P < <(printf '%s' "${json}" | yq -r '.promotion[]')
  [[ "${#P[@]}" -ge 1 ]] || return 1
  uniq="$(printf '%s\n' "${P[@]}" | sort -u | wc -l | tr -d ' ')"
  [[ "${uniq}" -eq "${#P[@]}" ]] || return 1
  for t in "${P[@]}"; do
    [[ "$(printf '%s' "${json}" | yq -r ".tiers | has(\"${t}\")")" == "true" ]] || return 1
    pool="$(printf '%s' "${json}" | yq -r ".tiers.\"${t}\".deployPool // \"null\"")"
    ctx="$(printf '%s' "${json}" | yq -r ".tiers.\"${t}\".expectedKubeContext // \"null\"")"
    acct="$(printf '%s' "${json}" | yq -r ".tiers.\"${t}\".awsAccountId // \"null\"")"
    [[ "${pool}" != "null" && -n "${pool}" ]] || return 1
    [[ "${ctx}" != "null" && -n "${ctx}" ]] || return 1
    [[ "${acct}" != "null" && -n "${acct}" ]] || return 1
  done
  return 0
}
UNKNOWN="$(printf '%s' "${BASE}" | yq -o=json -I=0 '.promotion = ["develop","homolog"]')"
if check_complete "${UNKNOWN}"; then
  fail "unknown promotion tier must fail completeness"
else
  pass "unknown promotion tier fails completeness"
fi
INCOMPLETE="$(printf '%s' "${BASE}" | yq -o=json -I=0 '.tiers.develop.deployPool = null')"
if check_complete "${INCOMPLETE}"; then
  fail "null deployPool in promotion must fail"
else
  pass "null deployPool in promotion fails completeness"
fi
if check_complete "${BASE}"; then
  pass "complete promotion passes"
else
  fail "complete promotion unexpectedly failed"
fi

echo "== manifest completeness (assert-deploy-identity) =="
CFG="$(mktemp -d -t asa-promo-cfg.XXXXXX)"
cp "${ROOT}/examples/deploy/config/develop.yaml" "${CFG}/develop.yaml"
if bash "${ROOT}/scripts/assert-deploy-identity.sh" "${CFG}" develop homolog 2>/dev/null; then
  fail "missing homolog.yaml must fail before Container"
else
  pass "missing homolog.yaml fails assert-deploy-identity"
fi
cp "${ROOT}/examples/deploy/config/homolog.yaml" "${CFG}/homolog.yaml"
if bash "${ROOT}/scripts/assert-deploy-identity.sh" "${CFG}" develop homolog; then
  pass "develop+homolog manifests complete"
else
  fail "develop+homolog manifests should pass identity assert"
fi
rm -rf "${CFG}"

if [[ "${FAILED}" -ne 0 ]]; then
  echo "PROMOTION CONTRACT: FAILED"
  exit 1
fi
echo "PROMOTION CONTRACT: OK"
