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
assert_contains "$OUT" "startupProbe:" "startupProbe present"
assert_contains "$OUT" "livenessProbe:" "livenessProbe present"
assert_contains "$OUT" "readinessProbe:" "readinessProbe present"

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

WIF_AUD="//iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/pool/providers/eks"
WIF_SA="app-sa@my-gcp-project.iam.gserviceaccount.com"

echo "== GCP WIF (EKS → GCP) =="
OUT_GCP="$(render develop \
  --set-string "workloadIdentity.gcp.audience=${WIF_AUD}" \
  --set-string "workloadIdentity.gcp.serviceAccountEmail=${WIF_SA}" \
  --set-string workloadIdentity.gcp.projectId=my-gcp-project)"
assert_contains "$OUT_GCP" "name: sample-api-wif-credentials" "chart-owned WIF ConfigMap"
assert_contains "$OUT_GCP" '"type": "external_account"' "external_account type"
assert_contains "$OUT_GCP" "\"audience\": \"${WIF_AUD}\"" "external_account audience"
assert_contains "$OUT_GCP" "\"file\": \"/var/run/secrets/eks.amazonaws.com/serviceaccount/token\"" "credential_source.file"
assert_contains "$OUT_GCP" "serviceAccounts/${WIF_SA}:generateAccessToken" "SA impersonation URL"
assert_contains "$OUT_GCP" "serviceAccountToken:" "projected ServiceAccount token"
assert_contains "$OUT_GCP" "audience: \"${WIF_AUD}\"" "projected token audience = gcp.audience"
assert_contains "$OUT_GCP" "expirationSeconds: 3600" "WIF token expiration"
assert_contains "$OUT_GCP" 'mountPath: "/var/run/secrets/eks.amazonaws.com/serviceaccount"' "WIF token mountPath"
assert_contains "$OUT_GCP" 'name: "sample-api-wif-credentials"' "GCP credentials ConfigMap volume"
assert_contains "$OUT_GCP" "mountPath: /var/run/secrets/google" "GCP credentials mount"
assert_contains "$OUT_GCP" "GOOGLE_APPLICATION_CREDENTIALS" "GOOGLE_APPLICATION_CREDENTIALS set"
assert_contains "$OUT_GCP" 'value: "/var/run/secrets/google/external-account.json"' "ADC path"
assert_contains "$OUT_GCP" "GOOGLE_CLOUD_PROJECT" "GOOGLE_CLOUD_PROJECT set"
assert_contains "$OUT_GCP" 'value: "my-gcp-project"' "projectId value"
assert_contains "$OUT_GCP" "checksum/wif:" "pod rolls on WIF ConfigMap change"

echo "== IRSA + GCP WIF composition =="
OUT_BOTH="$(render develop \
  --set-string 'serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::123456789012:role/sample-api' \
  --set-string "workloadIdentity.gcp.audience=${WIF_AUD}" \
  --set-string "workloadIdentity.gcp.serviceAccountEmail=${WIF_SA}")"
SA_COUNT="$(grep -c 'kind: ServiceAccount' <<<"$OUT_BOTH" || true)"
assert_contains "$OUT_BOTH" "eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/sample-api" "composed IRSA annotation"
assert_contains "$OUT_BOTH" "serviceAccountToken:" "composed projected token"
assert_contains "$OUT_BOTH" "GOOGLE_APPLICATION_CREDENTIALS" "composed GCP ADC"
assert_contains "$OUT_BOTH" "name: sample-api-wif-credentials" "composed chart-owned WIF ConfigMap"
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

echo "== persistence baseline =="
assert_not_contains "$OUT_DEV" "kind: PersistentVolumeClaim" "no PVC by default"

echo "== persistence PVC + mount =="
OUT_PVC="$(render develop \
  --set autoscaling=false \
  --set replicaCount=1 \
  --set-string persistence.mountPath=/data \
  --set-string persistence.size=1Gi \
  --set-string persistence.storageClassName=gp3)"
assert_contains "$OUT_PVC" "kind: PersistentVolumeClaim" "PVC rendered"
assert_contains "$OUT_PVC" "name: sample-api-data" "PVC name"
assert_contains "$OUT_PVC" "helm.sh/resource-policy: keep" "PVC keep on uninstall"
assert_contains "$OUT_PVC" "ReadWriteOnce" "RWO access mode"
assert_contains "$OUT_PVC" 'storage: "1Gi"' "PVC size"
assert_contains "$OUT_PVC" 'storageClassName: "gp3"' "storageClassName"
assert_contains "$OUT_PVC" "claimName: sample-api-data" "Deployment PVC volume"
assert_contains "$OUT_PVC" 'mountPath: "/data"' "Deployment mountPath"
assert_not_contains "$OUT_PVC" "kind: HorizontalPodAutoscaler" "HPA off with persistence"

echo "== persistence rejects HPA =="
if OUT_PVC_HPA="$(render develop \
  --set-string persistence.mountPath=/data \
  --set-string persistence.size=1Gi 2>&1)"; then
  echo "FAIL: persistence+HPA should fail template"
  FAILED=1
else
  assert_contains "$OUT_PVC_HPA" "persistence requires autoscaling: false" "fail message for HPA+persistence"
fi

echo "== persistence rejects replicaCount > 1 =="
if OUT_PVC_REP="$(render develop \
  --set autoscaling=false \
  --set replicaCount=2 \
  --set-string persistence.mountPath=/data \
  --set-string persistence.size=1Gi 2>&1)"; then
  echo "FAIL: persistence+replicaCount>1 should fail template"
  FAILED=1
else
  assert_contains "$OUT_PVC_REP" "persistence requires replicaCount: 1" "fail message for replicas+persistence"
fi

echo "== cronJob baseline =="
assert_not_contains "$OUT_DEV" "kind: CronJob" "no CronJob by default"

echo "== cronJob additional to API =="
OUT_CRON="$(render develop \
  --set-string 'cronJob.schedule=0 6 * * *' \
  --set-string 'cronJob.args[0]=--mode=job')"
assert_contains "$OUT_CRON" "kind: CronJob" "CronJob rendered"
assert_contains "$OUT_CRON" "name: sample-api-cron" "CronJob name"
assert_contains "$OUT_CRON" 'schedule: "0 6 * * *"' "CronJob schedule"
assert_contains "$OUT_CRON" "concurrencyPolicy: Forbid" "CronJob concurrency Forbid"
assert_contains "$OUT_CRON" "restartPolicy: OnFailure" "CronJob restartPolicy"
assert_contains "$OUT_CRON" "--mode=job" "CronJob args"
assert_contains "$OUT_CRON" "kind: Deployment" "Deployment still present with CronJob"
assert_contains "$OUT_CRON" "kind: Service" "Service still present with CronJob"
assert_contains "$OUT_CRON" "kind: HorizontalPodAutoscaler" "HPA still present with CronJob"
assert_contains "$OUT_CRON" "kind: HTTPRoute" "HTTPRoute still present with CronJob"
# CronJob must not share Service selector label app=<release>
CRON_SECTION="$(awk '/kind: CronJob/,/^---$/ {print}' <<<"$OUT_CRON")"
assert_not_contains "$CRON_SECTION" "app: sample-api" "CronJob pods not selected by Service"
assert_not_contains "$CRON_SECTION" "health-check" "CronJob has no HTTP probes"
assert_not_contains "$CRON_SECTION" "persistentVolumeClaim:" "CronJob does not mount PVC"
assert_not_contains "$CRON_SECTION" "startupProbe:" "CronJob has no startupProbe"
assert_not_contains "$CRON_SECTION" "livenessProbe:" "CronJob has no livenessProbe"
assert_not_contains "$CRON_SECTION" "readinessProbe:" "CronJob has no readinessProbe"

echo "== cronJob reuses config + WIF =="
WIF_AUD="//iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/pool/providers/eks"
WIF_SA="app-sa@my-gcp-project.iam.gserviceaccount.com"
OUT_CRON_ID="$(render develop \
  --set-string 'cronJob.schedule=*/15 * * * *' \
  --set-string config.JOB_FLAG=true \
  --set-string "workloadIdentity.gcp.audience=${WIF_AUD}" \
  --set-string "workloadIdentity.gcp.serviceAccountEmail=${WIF_SA}")"
assert_contains "$OUT_CRON_ID" "kind: CronJob" "CronJob with identity"
assert_contains "$OUT_CRON_ID" "configMapRef:" "CronJob envFrom config"
assert_contains "$OUT_CRON_ID" "GOOGLE_APPLICATION_CREDENTIALS" "CronJob WIF env"
assert_contains "$OUT_CRON_ID" "serviceAccountToken:" "CronJob projected token"
assert_contains "$OUT_CRON_ID" "name: sample-api-wif-credentials" "CronJob WIF ConfigMap volume"

echo "== cronJob opt-out =="
OUT_NO_CRON="$(render develop --set cronJob=false)"
assert_not_contains "$OUT_NO_CRON" "kind: CronJob" "CronJob off when cronJob: false"

if [[ "$FAILED" -ne 0 ]]; then
  echo "Some invariants failed"
  exit 1
fi
echo "All chart invariants passed"
