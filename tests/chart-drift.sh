#!/usr/bin/env bash
# Fail if identical shared templates drift between asa-application and asa-scheduled-job.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${ROOT}/charts/asa-application/templates"
JOB="${ROOT}/charts/asa-scheduled-job/templates"
FAILED=0

# Shared primitives that must stay byte-identical until a library chart is extracted.
SHARED=(
  _workloadidentity.tpl
  serviceaccount.yaml
  externalsecret.yaml
  configmap.yaml
  wif-credentials.yaml
)

for f in "${SHARED[@]}"; do
  if ! diff -q "${APP}/${f}" "${JOB}/${f}" >/dev/null; then
    echo "FAIL: drift between charts for ${f}"
    diff -u "${APP}/${f}" "${JOB}/${f}" | head -40 || true
    FAILED=1
  else
    echo "OK: ${f} identical across charts"
  fi
done

if [[ "$FAILED" -ne 0 ]]; then
  echo "Chart drift detected — sync both charts or extract asa-runtime-common (third chart / repeated fix trigger)."
  exit 1
fi
echo "All shared chart primitives in sync"
