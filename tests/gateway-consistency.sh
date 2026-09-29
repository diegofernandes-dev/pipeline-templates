#!/usr/bin/env bash
# The env → Gateway mapping lives in three places that must agree:
#   1. charts/asa-application/templates/_networking.tpl   (gateway NAME per env)
#   2. charts/asa-application/templates/{http,grpc}route.yaml (parentRef NAMESPACE)
#   3. config/platform-environments.json                  (name + namespace, used by the deploy preflight)
# If they drift, the preflight validates one Gateway while the chart attaches the route to
# another: the route silently binds to nothing. This already happened once (asa-infra vs
# asa-infra-nginx-gateway), so it is guarded here.
#
# Asserts the RENDERED output, not the template text, so refactors stay free.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_CHART="${ROOT}/charts/asa-application"
PLATFORM_ENVS="${ROOT}/config/platform-environments.json"
FAILED=0

for cmd in helm yq; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "FAIL: ${cmd} is required for gateway-consistency.sh"
    exit 1
  fi
done

# route_field <workload.type> <kind> <env> <yq path>
route_field() {
  local wt="$1" kind="$2" env="$3" path="$4"
  helm template sample "${APP_CHART}" \
    --set-string image.repository=example.invalid/sample \
    --set-string image.tag=deadbeef \
    --set-string "runtime.environment=${env}" \
    --set-string "workload.type=${wt}" \
    --set probes=false 2>/dev/null \
    | yq -r "select(.kind == \"${kind}\") | ${path}"
}

for env in develop homolog production; do
  want_name="$(yq -r ".${env}.gatewayName // \"\"" "${PLATFORM_ENVS}")"
  want_ns="$(yq -r ".${env}.gatewayNamespace // \"\"" "${PLATFORM_ENVS}")"

  if [[ -z "${want_name}" || "${want_name}" == "null" ]]; then
    echo "FAIL: ${env}: gatewayName missing from config/platform-environments.json"
    FAILED=1
    continue
  fi
  if [[ -z "${want_ns}" || "${want_ns}" == "null" ]]; then
    echo "FAIL: ${env}: gatewayNamespace missing from config/platform-environments.json"
    FAILED=1
    continue
  fi

  for pair in "web:HTTPRoute" "grpc:GRPCRoute"; do
    wt="${pair%%:*}"
    kind="${pair##*:}"

    got_name="$(route_field "${wt}" "${kind}" "${env}" '.spec.parentRefs[0].name')"
    got_ns="$(route_field "${wt}" "${kind}" "${env}" '.spec.parentRefs[0].namespace')"

    if [[ "${got_name}" != "${want_name}" ]]; then
      echo "FAIL: ${env}/${kind}: parentRef name '${got_name}' != platform-environments.json '${want_name}'"
      FAILED=1
    else
      echo "OK: ${env}/${kind} parentRef name = ${got_name}"
    fi

    if [[ "${got_ns}" != "${want_ns}" ]]; then
      echo "FAIL: ${env}/${kind}: parentRef namespace '${got_ns}' != platform-environments.json '${want_ns}'"
      FAILED=1
    else
      echo "OK: ${env}/${kind} parentRef namespace = ${got_ns}"
    fi
  done
done

if [[ "${FAILED}" -ne 0 ]]; then
  echo "Gateway mapping drift — sync _networking.tpl / route templates / platform-environments.json"
  exit 1
fi
echo "Gateway mapping consistent across chart and platform-environments.json"
