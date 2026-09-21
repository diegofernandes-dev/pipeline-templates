#!/usr/bin/env bash
# Minimal chart invariants — no heavy test framework.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="${ROOT}/charts/app"
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

render() {
  local env="$1"
  shift
  helm template sample-api "${CHART}" \
    --set-string image.repository=example.dkr.ecr.us-east-1.amazonaws.com/sample-api \
    --set-string image.tag=deadbeef \
    --set-string "httpRoute.environment=${env}" \
    "$@"
}

echo "== resources =="
VALUES="$(cat "${CHART}/values.yaml")"
assert_contains "$VALUES" "cpu: 150m" "CPU request 150m"
assert_contains "$VALUES" "memory: 256Mi" "memory request 256Mi"
assert_contains "$VALUES" "memory: 512Mi" "memory limit 512Mi"
assert_not_contains "$VALUES" "cpu: 500m" "no legacy CPU limit 500m"
# limits block must not set cpu
LIMITS="$(awk '/^  limits:/{p=1;next} p && /^[^ ]/{exit} p' "${CHART}/values.yaml")"
assert_not_contains "$LIMITS" "cpu:" "no CPU under limits"

echo "== HPA / Deployment replicas =="
OUT="$(render develop)"
assert_contains "$OUT" "kind: HorizontalPodAutoscaler" "HPA rendered when enabled"
assert_not_contains "$OUT" "replicas:" "Deployment omits replicas when HPA enabled"

echo "== PDB default off =="
assert_not_contains "$OUT" "kind: PodDisruptionBudget" "PDB not rendered by default"

echo "== probes contract =="
assert_contains "$OUT" "path: /health-check" "probes use /health-check"

echo "== hostnames by environment =="
OUT_DEV="$(render develop)"
assert_contains "$OUT_DEV" "sample-api.dev.asa.corp" "develop corp hostname"
assert_not_contains "$OUT_DEV" "sample-api.d.asa.com.br" "develop without asa.com.br by default"

OUT_HML="$(render homolog)"
assert_contains "$OUT_HML" "sample-api.hml.asa.corp" "homolog corp hostname"

OUT_PRD="$(render production)"
assert_contains "$OUT_PRD" "sample-api.prd.asa.corp" "production corp hostname"

OUT_EXPOSE="$(render develop --set httpRoute.exposeAsaComBr=true)"
assert_contains "$OUT_EXPOSE" "sample-api.dev.asa.corp" "expose keeps corp"
assert_contains "$OUT_EXPOSE" "sample-api.d.asa.com.br" "expose adds asa.com.br"
assert_not_contains "$OUT_EXPOSE" "external-dns.alpha.kubernetes.io/hostname" "no ExternalDNS annotation duplicate"

echo "== Gateway by environment =="
assert_contains "$OUT_DEV" "name: d-asa-com-br-internal-gateway" "develop gateway"
assert_contains "$OUT_HML" "name: h-asa-com-br-internal-gateway" "homolog gateway"
assert_contains "$OUT_PRD" "name: p-asa-com-br-internal-gateway" "production gateway"
assert_contains "$OUT_DEV" "namespace: asa-infra-nginx-gateway" "gateway namespace"

echo "== applicationName-derived names =="
assert_contains "$OUT_DEV" "name: sample-api" "release name on resources"

if [[ "$FAILED" -ne 0 ]]; then
  echo "Some invariants failed"
  exit 1
fi
echo "All chart invariants passed"
