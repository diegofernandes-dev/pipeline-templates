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

echo "== workload identity baseline =="
assert_not_contains "$OUT_DEV" "eks.amazonaws.com/role-arn" "no IRSA annotation by default"
assert_not_contains "$OUT_DEV" "serviceAccountToken:" "no projected WI token by default"
assert_not_contains "$OUT_DEV" "GOOGLE_APPLICATION_CREDENTIALS" "no GCP ADC env by default"

echo "== IRSA (EKS → AWS) =="
OUT_IRSA="$(render develop --set-string 'serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::123456789012:role/sample-api')"
assert_contains "$OUT_IRSA" "eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/sample-api" "IRSA annotation on ServiceAccount"
assert_contains "$OUT_IRSA" "kind: ServiceAccount" "ServiceAccount rendered with IRSA"

echo "== GCP WIF (EKS → GCP) =="
OUT_GCP="$(render develop \
  --set workloadIdentity.enabled=true \
  --set-string workloadIdentity.gcp.credentialsConfigMapName=gcp-external-account-config \
  --set-string workloadIdentity.gcp.projectId=my-gcp-project)"
assert_contains "$OUT_GCP" "serviceAccountToken:" "projected ServiceAccount token"
assert_contains "$OUT_GCP" 'audience: "sts.amazonaws.com"' "WIF token audience"
assert_contains "$OUT_GCP" "expirationSeconds: 3600" "WIF token expiration"
assert_contains "$OUT_GCP" 'mountPath: "/var/run/secrets/eks.amazonaws.com/serviceaccount"' "WIF token mountPath"
assert_contains "$OUT_GCP" 'name: "gcp-external-account-config"' "GCP credentials ConfigMap volume"
assert_contains "$OUT_GCP" "mountPath: /var/run/secrets/google" "GCP credentials mount"
assert_contains "$OUT_GCP" "GOOGLE_APPLICATION_CREDENTIALS" "GOOGLE_APPLICATION_CREDENTIALS set"
assert_contains "$OUT_GCP" 'value: "/var/run/secrets/google/external-account.json"' "ADC path"
assert_contains "$OUT_GCP" "GOOGLE_CLOUD_PROJECT" "GOOGLE_CLOUD_PROJECT set"
assert_contains "$OUT_GCP" 'value: "my-gcp-project"' "projectId value"

echo "== IRSA + GCP WIF composition =="
OUT_BOTH="$(render develop \
  --set-string 'serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::123456789012:role/sample-api' \
  --set workloadIdentity.enabled=true \
  --set-string workloadIdentity.gcp.credentialsConfigMapName=gcp-external-account-config)"
SA_COUNT="$(grep -c 'kind: ServiceAccount' <<<"$OUT_BOTH" || true)"
assert_contains "$OUT_BOTH" "eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/sample-api" "composed IRSA annotation"
assert_contains "$OUT_BOTH" "serviceAccountToken:" "composed projected token"
assert_contains "$OUT_BOTH" "GOOGLE_APPLICATION_CREDENTIALS" "composed GCP ADC"
if [[ "$SA_COUNT" -ne 1 ]]; then
  echo "FAIL: expected exactly one ServiceAccount (got ${SA_COUNT})"
  FAILED=1
else
  echo "OK: single ServiceAccount with IRSA + GCP WIF"
fi

echo "== runtime config baseline =="
assert_not_contains "$OUT_DEV" "kind: ConfigMap" "no ConfigMap by default"
assert_not_contains "$OUT_DEV" "kind: ExternalSecret" "no ExternalSecret by default"
assert_not_contains "$OUT_DEV" "envFrom:" "no envFrom by default"

echo "== config ConfigMap + envFrom =="
OUT_CFG="$(render develop \
  --set-string config.API_URL=https://api.dev.example \
  --set-string config.FEATURE_FLAG=true)"
assert_contains "$OUT_CFG" "kind: ConfigMap" "ConfigMap rendered"
assert_contains "$OUT_CFG" "name: sample-api-config" "ConfigMap name"
assert_contains "$OUT_CFG" "API_URL:" "config key API_URL"
assert_contains "$OUT_CFG" "configMapRef:" "envFrom configMapRef"
assert_contains "$OUT_CFG" "checksum/config:" "config checksum annotation"

echo "== externalSecret + secretRef =="
OUT_ES="$(render develop \
  --set-string externalSecret.secretStoreRef.name=aws-secretsmanager \
  --set-string 'externalSecret.data[0].secretKey=ConnectionStrings__Default' \
  --set-string 'externalSecret.data[0].remoteRef.key=asa/sample-api/develop/cs')"
assert_contains "$OUT_ES" "kind: ExternalSecret" "ExternalSecret rendered"
assert_contains "$OUT_ES" "name: sample-api-secret" "target Secret name"
assert_contains "$OUT_ES" "secretRef:" "envFrom secretRef"
assert_not_contains "$OUT_ES" "kind: ConfigMap" "no ConfigMap when only externalSecret"

echo "== config + externalSecret composition =="
OUT_RT="$(render develop \
  --set-string config.API_URL=https://api.dev.example \
  --set-string externalSecret.secretStoreRef.name=aws-secretsmanager \
  --set-string 'externalSecret.data[0].secretKey=DB_PASSWORD' \
  --set-string 'externalSecret.data[0].remoteRef.key=asa/sample-api/develop/db')"
assert_contains "$OUT_RT" "configMapRef:" "composed configMapRef"
assert_contains "$OUT_RT" "secretRef:" "composed secretRef"

echo "== manifesto-style HPA override =="
OUT_HPA="$(render develop --set autoscaling.minReplicas=2 --set autoscaling.maxReplicas=5)"
assert_contains "$OUT_HPA" "minReplicas: 2" "HPA minReplicas from overlay"
assert_contains "$OUT_HPA" "maxReplicas: 5" "HPA maxReplicas from overlay"

echo "== autoscaling opt-out =="
OUT_NO_HPA="$(render develop --set autoscaling=false)"
assert_not_contains "$OUT_NO_HPA" "kind: HorizontalPodAutoscaler" "HPA off when autoscaling: false"
assert_contains "$OUT_NO_HPA" "replicas:" "Deployment uses replicas when HPA off"

if [[ "$FAILED" -ne 0 ]]; then
  echo "Some invariants failed"
  exit 1
fi
echo "All chart invariants passed"
