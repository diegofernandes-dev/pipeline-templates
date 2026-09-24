#!/usr/bin/env bash
# Assert kind (+ workload.type for Application) is identical across env manifestos.
# Requires yq. Usage: assert-deploy-identity.sh <runtimeConfigPath> <env1> [env2 ...]
set -Eeuo pipefail

if [[ "$#" -lt 2 ]]; then
  echo "usage: $0 <runtimeConfigPath> <env> [env...]" >&2
  exit 2
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "##vso[task.logissue type=error]yq is required for assert-deploy-identity.sh" >&2
  exit 1
fi

CONFIG_PATH="$1"
shift

yaml_get() {
  yq -r "${2} // \"\"" "$1"
}

FIRST_ENV="$1"
FIRST_FILE="${CONFIG_PATH}/${FIRST_ENV}.yaml"
if [[ ! -f "${FIRST_FILE}" ]]; then
  echo "##vso[task.logissue type=error]Missing manifesto ${FIRST_FILE}"
  exit 1
fi

BASE_KIND="$(yaml_get "${FIRST_FILE}" ".kind")"
if [[ -z "${BASE_KIND}" ]]; then
  echo "##vso[task.logissue type=error]${FIRST_FILE}: kind is required"
  exit 1
fi

BASE_TYPE=""
if [[ "${BASE_KIND}" == "Application" ]]; then
  BASE_TYPE="$(yaml_get "${FIRST_FILE}" ".workload.type")"
  if [[ -z "${BASE_TYPE}" ]]; then
    echo "##vso[task.logissue type=error]${FIRST_FILE}: workload.type is required for Application"
    exit 1
  fi
fi

echo "baseline ${FIRST_ENV}: kind=${BASE_KIND} workload.type=${BASE_TYPE:-n/a}"

for env in "$@"; do
  file="${CONFIG_PATH}/${env}.yaml"
  if [[ ! -f "${file}" ]]; then
    echo "##vso[task.logissue type=error]Missing manifesto ${file}"
    exit 1
  fi
  kind="$(yaml_get "${file}" ".kind")"
  if [[ "${kind}" != "${BASE_KIND}" ]]; then
    echo "##vso[task.logissue type=error]Deploy identity drift: ${FIRST_ENV} kind=${BASE_KIND} vs ${env} kind=${kind}"
    exit 1
  fi
  wt=""
  if [[ "${BASE_KIND}" == "Application" ]]; then
    wt="$(yaml_get "${file}" ".workload.type")"
    if [[ "${wt}" != "${BASE_TYPE}" ]]; then
      echo "##vso[task.logissue type=error]Deploy identity drift: ${FIRST_ENV} workload.type=${BASE_TYPE} vs ${env} workload.type=${wt}"
      exit 1
    fi
  fi
  echo "OK ${env}: kind=${kind} workload.type=${wt:-n/a}"
done

echo "Cross-environment deploy identity OK"
