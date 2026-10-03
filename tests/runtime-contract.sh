#!/usr/bin/env bash
# Runtime profile contract: schema + resolve(workload) + render + reservedConfig isolation.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIMES_DIR="${ROOT}/platform/runtimes"
SCHEMA="${ROOT}/platform/runtimes.schema.json"
APP_CHART="${ROOT}/charts/asa-application"
JOB_CHART="${ROOT}/charts/asa-scheduled-job"
FAILED=0
WORKLOADS=(web grpc worker scheduledJob)

need() { command -v "$1" >/dev/null 2>&1 || { echo "FAIL: missing $1"; exit 1; }; }
need yq
need helm
need python3

echo "== runtime profiles on disk =="
mapfile -t RUNTIMES < <(find "${RUNTIMES_DIR}" -maxdepth 1 -name '*.yml' -printf '%f\n' 2>/dev/null \
  | sed 's/\.yml$//' | sort)
if [[ "${#RUNTIMES[@]}" -eq 0 ]]; then
  # macOS find lacks -printf
  mapfile -t RUNTIMES < <(find "${RUNTIMES_DIR}" -maxdepth 1 -name '*.yml' | xargs -n1 basename | sed 's/\.yml$//' | sort)
fi
if [[ "${#RUNTIMES[@]}" -eq 0 ]]; then
  echo "FAIL: no platform/runtimes/*.yml"
  exit 1
fi
echo "OK: runtimes [${RUNTIMES[*]}]"

CONTRACT_KEYS=(PORT APP_PROTOCOL SHUTDOWN_TIMEOUT_SECONDS CPU_REQUEST_MILLICORES GOOGLE_APPLICATION_CREDENTIALS)

for rt in "${RUNTIMES[@]}"; do
  profile="${RUNTIMES_DIR}/${rt}.yml"
  echo "== schema ${rt} =="
  if ! python3 "${ROOT}/scripts/validate-manifest.py" "${SCHEMA}" "${profile}"; then
    echo "FAIL: ${rt} failed schema"
    FAILED=1
    continue
  fi
  if ! yq -e '.chart.defaults | type == "!!map"' "${profile}" >/dev/null 2>&1; then
    echo "FAIL: ${rt} missing chart.defaults"
    FAILED=1
    continue
  fi
  echo "OK: ${rt} schema"

  echo "== reservedConfig must not collide with chart contract (${rt}) =="
  while IFS= read -r key; do
    [[ -z "${key}" || "${key}" == "null" ]] && continue
    for c in "${CONTRACT_KEYS[@]}"; do
      if [[ "${key}" == "${c}" ]]; then
        echo "FAIL: ${rt} reservedConfig.exact contains chart contract key ${c}"
        FAILED=1
      fi
    done
  done < <(yq -r '.reservedConfig.exact[]' "${profile}" 2>/dev/null || true)
  while IFS= read -r prefix; do
    [[ -z "${prefix}" || "${prefix}" == "null" ]] && continue
    for c in "${CONTRACT_KEYS[@]}"; do
      if [[ "${c}" == "${prefix}"* ]]; then
        echo "FAIL: ${rt} reservedConfig.prefixes '${prefix}' would match chart contract key ${c}"
        FAILED=1
      fi
    done
  done < <(yq -r '.reservedConfig.prefixes[]' "${profile}" 2>/dev/null || true)
  echo "OK: ${rt} reservedConfig isolated from chart contract"

  echo "== resolve + render ${rt} × workloads =="
  pf="$(mktemp -t asa-platform.XXXXXX.yaml)"
  bash "${ROOT}/scripts/resolve-platform-values.sh" lab develop "${pf}"
  for wl in "${WORKLOADS[@]}"; do
    rf="$(mktemp -t asa-runtime.XXXXXX.yaml)"
    if ! bash "${ROOT}/scripts/resolve-runtime-values.sh" "${rt}" "${wl}" "${rf}"; then
      echo "FAIL: resolve-runtime-values.sh ${rt} ${wl}"
      FAILED=1
      rm -f "${rf}"
      continue
    fi
    if [[ "${wl}" == "scheduledJob" ]]; then
      if ! helm template sample-job "${JOB_CHART}" \
          -f "${rf}" -f "${pf}" \
          --set-string image.repository=example.invalid/sample-job \
          --set-string image.tag=deadbeef \
          --set-string schedule.expression='0 2 * * *' \
          --set-string schedule.timeZone=UTC \
          --set execution.timeoutSeconds=60 \
          --set-string 'execution.args[0]=--mode=job' >/dev/null; then
        echo "FAIL: ${rt}/${wl} + job chart render"
        FAILED=1
      else
        echo "OK: ${rt}/${wl} + job chart render"
      fi
    else
      WT_SET=(--set-string "workload.type=${wl}")
      [[ "${wl}" == "worker" ]] || WT_SET+=(--set probes=false)
      if ! helm template sample "${APP_CHART}" \
          -f "${rf}" -f "${pf}" \
          --set-string image.repository=example.invalid/sample \
          --set-string image.tag=deadbeef \
          "${WT_SET[@]}" >/dev/null; then
        echo "FAIL: ${rt}/${wl} + app chart render"
        FAILED=1
      else
        echo "OK: ${rt}/${wl} + app chart render"
      fi
    fi
    rm -f "${rf}"
  done
  rm -f "${pf}"
done

echo "== invalid workload rejected =="
if bash "${ROOT}/scripts/resolve-runtime-values.sh" dotnet bogus >/dev/null 2>&1; then
  echo "FAIL: expected non-zero for workload=bogus"
  FAILED=1
else
  echo "OK: invalid workload rejected"
fi

echo "== workload override wins over defaults =="
FIXTURE="$(mktemp -d -t asa-runtimes.XXXXXX)"
cat > "${FIXTURE}/preview.yml" <<'EOF'
chart:
  defaults:
    shutdownTimeoutSeconds: 25
    terminationGracePeriodSeconds: 40
    tmp:
      sizeLimit: 64Mi
  workloads:
    web:
      shutdownTimeoutSeconds: 15
reservedConfig:
  exact:
    - PREVIEW_RESERVED
  prefixes: []
EOF
export PLATFORM_RUNTIMES_DIR="${FIXTURE}"
rf="$(mktemp -t asa-runtime.XXXXXX.yaml)"
pf="$(mktemp -t asa-platform.XXXXXX.yaml)"
bash "${ROOT}/scripts/resolve-runtime-values.sh" preview web "${rf}"
bash "${ROOT}/scripts/resolve-platform-values.sh" lab develop "${pf}"
got="$(yq -r '.shutdownTimeoutSeconds' "${rf}")"
if [[ "${got}" == "15" ]]; then
  echo "OK: workloads.web.shutdownTimeoutSeconds overrides defaults (15)"
else
  echo "FAIL: expected shutdownTimeoutSeconds=15 after merge (got '${got}')"
  FAILED=1
fi
# grpc has no override → defaults
bash "${ROOT}/scripts/resolve-runtime-values.sh" preview grpc "${rf}"
got="$(yq -r '.shutdownTimeoutSeconds' "${rf}")"
if [[ "${got}" == "25" ]]; then
  echo "OK: missing workloads.grpc falls back to defaults (25)"
else
  echo "FAIL: expected defaults shutdownTimeoutSeconds=25 for grpc (got '${got}')"
  FAILED=1
fi
out="$(helm template sample "${APP_CHART}" -f "${rf}" -f "${pf}" \
  --set-string image.repository=x --set-string image.tag=y --set probes=false)"
if printf '%s' "${out}" | grep -q 'value: "25"'; then
  echo "OK: fictional runtime preview renders shutdownTimeoutSeconds"
else
  echo "FAIL: fictional runtime override not applied in render"
  FAILED=1
fi
rm -rf "${FIXTURE}" "${rf}" "${pf}"
unset PLATFORM_RUNTIMES_DIR

echo "== charts must stay free of runtime tokens =="
if grep -RInE 'ASPNETCORE|Kestrel|DOTNET_|JAVA_|SPRING_|dotnet' "${ROOT}/charts" \
    --include='*.yaml' --include='*.yml' --include='*.tpl' --include='*.json' \
    | grep -viE 'dnsZone|legacyDns|scheduled-job|Application' >/tmp/runtime-hits.txt 2>/dev/null; then
  if grep -E 'ASPNETCORE|Kestrel__|DOTNET_|JAVA_|SPRING_' /tmp/runtime-hits.txt >/dev/null; then
    echo "FAIL: runtime-specific tokens found under charts/:"
    grep -E 'ASPNETCORE|Kestrel__|DOTNET_|JAVA_|SPRING_' /tmp/runtime-hits.txt || true
    FAILED=1
  else
    echo "OK: no ASPNETCORE/Kestrel/DOTNET_/JAVA_/SPRING_ under charts/"
  fi
else
  echo "OK: no ASPNETCORE/Kestrel/DOTNET_/JAVA_/SPRING_ under charts/"
fi
rm -f /tmp/runtime-hits.txt

echo "== PLATFORM_UID parity =="
CHART_UID="$(yq -r '.podSecurityContext.runAsUser' "${ROOT}/charts/asa-application/values.yaml")"
JOB_UID="$(yq -r '.podSecurityContext.runAsUser' "${ROOT}/charts/asa-scheduled-job/values.yaml")"
DOCKER_UID="$(grep -E '^\s*ARG PLATFORM_UID=' "${ROOT}/docker/dotnet/Dockerfile" | head -1 | sed 's/.*=//')"
if [[ "${CHART_UID}" == "${JOB_UID}" && "${CHART_UID}" == "${DOCKER_UID}" ]]; then
  echo "OK: PLATFORM_UID=${DOCKER_UID} matches both charts"
else
  echo "FAIL: UID mismatch chart=${CHART_UID} job=${JOB_UID} docker=${DOCKER_UID}"
  FAILED=1
fi

if [[ "${FAILED}" -ne 0 ]]; then
  echo "Runtime contract FAILED"
  exit 1
fi
echo "Runtime contract ok (${#RUNTIMES[@]} runtimes × ${#WORKLOADS[@]} workloads)"
