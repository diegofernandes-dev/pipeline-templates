#!/usr/bin/env bash
# Platform contract: every area × tier in platform/areas/ must
#   1. satisfy platform/areas.schema.json
#   2. resolve via scripts/resolve-platform-values.sh (required chart keys present)
#   3. render the Application chart with those facts (HTTPRoute/GRPCRoute bind correctly)
# Also: platformArea allowlist ↔ area files parity, and a fictional area via PLATFORM_AREAS_DIR.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_CHART="${ROOT}/charts/asa-application"
AREAS_DIR="${ROOT}/platform/areas"
AREAS_SCHEMA="${ROOT}/platform/areas.schema.json"
RESOLVE="${ROOT}/scripts/resolve-platform-values.sh"
CI_YML="${ROOT}/templates/dotnet/ci.yml"
FAILED=0

for cmd in helm yq python3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "FAIL: ${cmd} is required for platform-contract.sh"
    exit 1
  fi
done

if [[ ! -d "${AREAS_DIR}" ]]; then
  echo "FAIL: ${AREAS_DIR} missing"
  exit 1
fi
if [[ ! -f "${AREAS_SCHEMA}" ]]; then
  echo "FAIL: ${AREAS_SCHEMA} missing"
  exit 1
fi
if [[ ! -x "${RESOLVE}" ]]; then
  echo "FAIL: ${RESOLVE} missing or not executable"
  exit 1
fi

mapfile -t AREA_FILES < <(find "${AREAS_DIR}" -maxdepth 1 -name '*.yml' -type f | sort)
if [[ "${#AREA_FILES[@]}" -eq 0 ]]; then
  echo "FAIL: no area profiles under ${AREAS_DIR}"
  exit 1
fi

echo "== platformArea allowlist ↔ platform/areas/*.yml =="
# Extract values: under platformArea (skip the empty CI-only entry).
mapfile -t ALLOWLIST < <(yq -r '
  .parameters[]
  | select(.name == "platformArea")
  | .values[]
  | select(. != "none")
' "${CI_YML}" | sort)
mapfile -t ON_DISK < <(printf '%s\n' "${AREA_FILES[@]}" | xargs -n1 basename | sed 's/\.yml$//' | sort)
if [[ "${ALLOWLIST[*]}" != "${ON_DISK[*]}" ]]; then
  echo "FAIL: platformArea values [${ALLOWLIST[*]}] != area files [${ON_DISK[*]}]"
  FAILED=1
else
  echo "OK: allowlist matches area files (${ON_DISK[*]})"
fi

echo "== schema + resolve + render for every area × tier =="
for profile in "${AREA_FILES[@]}"; do
  area="$(basename "${profile}" .yml)"
  PLATFORM_JSON="$(yq -o=json -I=0 '
    .parameters[]
    | select(.name == "platform")
    | .default
  ' "${profile}")"
  if [[ -z "${PLATFORM_JSON}" || "${PLATFORM_JSON}" == "null" ]]; then
    echo "FAIL: ${profile} has no platform parameter default"
    FAILED=1
    continue
  fi

  tmpj="$(mktemp -t asa-platform.XXXXXX.json)"
  printf '%s' "${PLATFORM_JSON}" > "${tmpj}"
  if python3 -c "
import json, jsonschema
schema = json.load(open('${AREAS_SCHEMA}'))
instance = json.load(open('${tmpj}'))
jsonschema.validate(instance, schema)
print('OK: ${area} schema')
"; then
    :
  else
    echo "FAIL: ${area} failed areas.schema.json"
    FAILED=1
    rm -f "${tmpj}"
    continue
  fi
  rm -f "${tmpj}"

  # platform.promotion: non-empty, unique, known tiers, deploy-complete for each entry.
  mapfile -t PROMO < <(printf '%s' "${PLATFORM_JSON}" | yq -r '.promotion[]')
  if [[ "${#PROMO[@]}" -eq 0 ]]; then
    echo "FAIL: ${area} platform.promotion is empty"
    FAILED=1
  elif [[ "${#PROMO[@]}" -gt 3 ]]; then
    echo "FAIL: ${area} platform.promotion has ${#PROMO[@]} entries (max 3)"
    FAILED=1
  else
    uniq_count="$(printf '%s\n' "${PROMO[@]}" | sort -u | wc -l | tr -d ' ')"
    if [[ "${uniq_count}" -ne "${#PROMO[@]}" ]]; then
      echo "FAIL: ${area} platform.promotion has duplicate tiers"
      FAILED=1
    else
      echo "OK: ${area} promotion=[${PROMO[*]}]"
    fi
  fi
  prev_order=0
  for tier in "${PROMO[@]+"${PROMO[@]}"}"; do
    if [[ "$(printf '%s' "${PLATFORM_JSON}" | yq -r ".tiers | has(\"${tier}\")")" != "true" ]]; then
      echo "FAIL: ${area} promotion tier '${tier}' missing from platform.tiers"
      FAILED=1
      continue
    fi
    order="$(printf '%s' "${PLATFORM_JSON}" | yq -r ".tiers.\"${tier}\".order")"
    if (( order < prev_order )); then
      echo "FAIL: ${area} promotion order inverted at '${tier}'"
      FAILED=1
    fi
    prev_order="${order}"
    pool="$(printf '%s' "${PLATFORM_JSON}" | yq -r ".tiers.\"${tier}\".deployPool // \"null\"")"
    ctx="$(printf '%s' "${PLATFORM_JSON}" | yq -r ".tiers.\"${tier}\".expectedKubeContext // \"null\"")"
    acct="$(printf '%s' "${PLATFORM_JSON}" | yq -r ".tiers.\"${tier}\".awsAccountId // \"null\"")"
    if [[ "${pool}" == "null" || -z "${pool}" ]]; then
      echo "FAIL: ${area}/${tier} in promotion but deployPool is null"
      FAILED=1
    fi
    if [[ "${ctx}" == "null" || -z "${ctx}" ]]; then
      echo "FAIL: ${area}/${tier} in promotion but expectedKubeContext is null"
      FAILED=1
    fi
    if [[ "${acct}" == "null" || -z "${acct}" ]]; then
      echo "FAIL: ${area}/${tier} in promotion but awsAccountId is null"
      FAILED=1
    fi
  done

  mapfile -t TIERS < <(printf '%s' "${PLATFORM_JSON}" | yq -r '.tiers | keys | .[]')
  for tier in "${TIERS[@]}"; do
    pf="$(mktemp -t asa-platform.XXXXXX.yaml)"
    if ! "${RESOLVE}" "${area}" "${tier}" "${pf}"; then
      echo "FAIL: resolve-platform-values.sh rejected '${area}/${tier}'"
      FAILED=1
      rm -f "${pf}"
      continue
    fi
    echo "OK: ${area}/${tier} resolves"

    want_name="$(yq -r ".platform.gatewayName" "${pf}")"
    want_ns="$(yq -r ".platform.gatewayNamespace" "${pf}")"
    want_min="$(yq -r ".platform.defaultMinReplicas" "${pf}")"
    want_dns="$(yq -r ".platform.dnsZone" "${pf}")"
    want_area="$(yq -r ".platform.area" "${pf}")"
    want_tier="$(yq -r ".platform.tier" "${pf}")"

    if [[ "${want_area}" != "${area}" || "${want_tier}" != "${tier}" ]]; then
      echo "FAIL: ${area}/${tier}: resolved area/tier '${want_area}/${want_tier}' mismatch"
      FAILED=1
    fi

    for pair in "web:HTTPRoute" "grpc:GRPCRoute"; do
      wt="${pair%%:*}"
      kind="${pair##*:}"

      rendered="$(helm template sample "${APP_CHART}" \
        --set-string image.repository=example.invalid/sample \
        --set-string image.tag=deadbeef \
        --set-string "workload.type=${wt}" \
        --set probes=false \
        -f "${pf}" 2>/dev/null)" || {
        echo "FAIL: ${area}/${tier}/${wt}: helm template failed"
        FAILED=1
        continue
      }

      # eval-all (ea) + first non-empty line: on a multi-doc render plain `yq` emits document
      # separators and blank lines for the documents that `select` filters out, so the value
      # arrives buried in them. Capture yq fully, then select without a pipe (avoids SIGPIPE under pipefail).
      # Do not mask yq failures with `|| true` — parser/runtime errors must fail the suite.
      pick() {
        local lines
        lines="$(printf '%s' "${rendered}" | yq ea -r "$1")"
        awk 'NF { print; exit }' <<< "${lines}"
      }
      got_name="$(pick "select(.kind == \"${kind}\") | .spec.parentRefs[0].name // \"\"")"
      got_ns="$(pick "select(.kind == \"${kind}\") | .spec.parentRefs[0].namespace // \"\"")"
      got_host="$(pick "select(.kind == \"${kind}\") | .spec.hostnames[0] // \"\"")"
      got_min="$(pick 'select(.kind == "HorizontalPodAutoscaler") | .spec.minReplicas // ""')"
      got_label_area="$(pick 'select(.kind == "Service") | .metadata.labels["asa.platform/area"] // ""')"
      got_label_tier="$(pick 'select(.kind == "Service") | .metadata.labels["asa.platform/tier"] // ""')"

      if [[ "${got_name}" != "${want_name}" ]]; then
        echo "FAIL: ${area}/${tier}/${kind}: gateway name '${got_name}' != resolved '${want_name}'"
        FAILED=1
      else
        echo "OK: ${area}/${tier}/${kind} gateway name = ${got_name}"
      fi
      if [[ "${got_ns}" != "${want_ns}" ]]; then
        echo "FAIL: ${area}/${tier}/${kind}: gateway namespace '${got_ns}' != resolved '${want_ns}'"
        FAILED=1
      fi
      if [[ "${got_host}" != "sample.${want_dns}" ]]; then
        echo "FAIL: ${area}/${tier}/${kind}: hostname '${got_host}' != sample.${want_dns}"
        FAILED=1
      fi
      if [[ -n "${got_min}" && "${got_min}" != "${want_min}" ]]; then
        echo "FAIL: ${area}/${tier}/${wt}: HPA minReplicas '${got_min}' != '${want_min}'"
        FAILED=1
      elif [[ -n "${got_min}" ]]; then
        echo "OK: ${area}/${tier}/${wt} minReplicas = ${got_min}"
      fi
      if [[ "${got_label_area}" != "${area}" || "${got_label_tier}" != "${tier}" ]]; then
        echo "FAIL: ${area}/${tier}: labels asa.platform/area|tier = '${got_label_area}/${got_label_tier}'"
        FAILED=1
      else
        echo "OK: ${area}/${tier} labels asa.platform/area|tier"
      fi
    done
    rm -f "${pf}"
  done
done

echo "== fictional area via PLATFORM_AREAS_DIR =="
FIXTURE_DIR="$(mktemp -d -t asa-fictional-areas.XXXXXX)"
cat > "${FIXTURE_DIR}/preview.yml" <<'EOF'
parameters:
  - name: delivery
    type: object
  - name: platform
    type: object
    default:
      area: preview
      buildPool: PREVIEW-BUILD
      registry:
        awsAccountId: "999999999999"
        awsRegion: us-east-1
      # Schema requires promotion[]; this fixture is only used for resolve/render +
      # null-identity fail-closed (not the on-disk promotion completeness gate).
      promotion:
        - develop
      tiers:
        develop:
          order: 1
          deployPool: PREVIEW-DEPLOY
          environmentName: preview-develop
          awsAccountId: "888888888888"
          awsRegion: us-east-1
          expectedKubeContext: null
          gatewayName: preview-gateway
          gatewayNamespace: asa-infra-nginx-gateway
          dnsZone: preview.asa.corp
          legacyDnsZone: preview.asa.com.br
          defaultMinReplicas: 1
          smokeAllowed: true
          podSecurity:
            enforce: null
            enforceVersion: null
stages:
  - template: ../../templates/dotnet/delivery.yml
    parameters:
      delivery: ${{ parameters.delivery }}
      platform: ${{ parameters.platform }}
EOF

pf="$(mktemp -t asa-platform.XXXXXX.yaml)"
if PLATFORM_AREAS_DIR="${FIXTURE_DIR}" "${RESOLVE}" preview develop "${pf}"; then
  if helm template sample "${APP_CHART}" \
    --set-string image.repository=example.invalid/sample \
    --set-string image.tag=deadbeef \
    --set-string workload.type=web \
    --set probes=false \
    -f "${pf}" >/dev/null; then
    echo "OK: fictional area preview/develop resolves + renders via PLATFORM_AREAS_DIR"
  else
    echo "FAIL: fictional area rendered values rejected by chart"
    FAILED=1
  fi
  # Chart path may resolve with null identity; deployable identity must still fail closed.
  if bash "${ROOT}/scripts/preflight-deploy-target.sh" identity \
       --area preview --tier develop \
       --expected-context null --actual-context null \
       --expected-account 888888888888 --actual-account 888888888888 2>/dev/null; then
    echo "FAIL: null expectedKubeContext must fail closed for deployable identity"
    FAILED=1
  else
    echo "OK: null expectedKubeContext fails closed (fictional deployable tier)"
  fi
else
  echo "FAIL: fictional area did not resolve via PLATFORM_AREAS_DIR"
  FAILED=1
fi
rm -f "${pf}"
rm -rf "${FIXTURE_DIR}"

echo "== no corporate pool/account literals outside platform/areas =="
# Pools and 12-digit accounts that belong in area profiles must not appear as
# hardcoded defaults in templates/ (except comments). Scan delivery/ci/helm-deploy.
LEAK_HITS="$(grep -RInE 'PG-AWS-EKS(-HML)?|"[0-9]{12}"' \
  "${ROOT}/templates/dotnet/ci.yml" \
  "${ROOT}/templates/dotnet/delivery.yml" \
  "${ROOT}/templates/dotnet/helm-deploy.yml" \
  2>/dev/null \
  | grep -vE '^\s*#' \
  | grep -vE 'displayName:|description:|comment' \
  || true)"
# Allow empty — pool names should only come from platform lookups / parameters without defaults.
if [[ -n "${LEAK_HITS}" ]]; then
  # Filter: ignore lines that are clearly documentation in comments inside bash strings is hard;
  # fail only on YAML default: lines or literal pool assignments outside lookups.
  BAD="$(printf '%s\n' "${LEAK_HITS}" | grep -E 'default:|containerPool:.*PG-AWS|iif\(' || true)"
  if [[ -n "${BAD}" ]]; then
    echo "FAIL: pool/account literals leaked into templates:"
    printf '%s\n' "${BAD}"
    FAILED=1
  else
    echo "OK: no default pool/account literals in delivery templates"
  fi
else
  echo "OK: no pool/account literals in delivery templates"
fi

echo "== yq fail-fast (no || true mask on mandatory parse) =="
# Regression guard: invalid yq must fail closed, not become empty success.
set +e
_yq_out="$(printf 'kind: Service\n' | yq ea -r '[[[[invalid' 2>/dev/null)"
_yq_rc=$?
set -e
if [[ ${_yq_rc} -eq 0 ]]; then
  echo "FAIL: expected yq invalid expression to exit non-zero (got rc=0, out='${_yq_out}')"
  FAILED=1
else
  echo "OK: yq invalid expression fails closed (rc=${_yq_rc})"
fi

if [[ "${FAILED}" -ne 0 ]]; then
  echo "Platform contract failed"
  exit 1
fi
echo "Platform contract ok (${#AREA_FILES[@]} areas)"
