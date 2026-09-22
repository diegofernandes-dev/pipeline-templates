#!/usr/bin/env bash
# Minimal chart invariants — no heavy test framework.
#
# Matrix (freeze hardening Item 5):
#   happy: baseline API (no probes by default), IRSA, GCP WIF, IRSA+WIF, ConfigMap, ExternalSecret,
#          PVC, CronJob, PDB, HTTPRoute, probes global/partial
#   fail:  WIF incomplete, PVC+HPA, PVC+replicas>1, persistence:true,
#          cronJob:true, CronJob without command/args, ExternalSecret partial,
#          externalSecret:true, persistence without size,
#          probes:true, probes global+specific, invalid probe path
# Run: helm lint charts/app && ./tests/chart-invariants.sh
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
assert_contains "$OUT" "averageUtilization: 70" "HPA target CPU 70"
assert_not_contains "$OUT" "replicas:" "Deployment omits replicas when HPA enabled"

echo "== PDB default off =="
assert_not_contains "$OUT" "kind: PodDisruptionBudget" "PDB not rendered by default"

echo "== PDB enabled =="
OUT_PDB="$(render develop --set pdb.enabled=true --set pdb.maxUnavailable=1)"
assert_contains "$OUT_PDB" "kind: PodDisruptionBudget" "PDB rendered when enabled"
assert_contains "$OUT_PDB" "name: sample-api" "PDB name"
assert_contains "$OUT_PDB" "maxUnavailable: 1" "PDB maxUnavailable"
assert_contains "$OUT_PDB" "app: sample-api" "PDB selector matches Deployment"

echo "== probes baseline (opt-in) =="
assert_not_contains "$OUT" "startupProbe:" "no startupProbe by default"
assert_not_contains "$OUT" "livenessProbe:" "no livenessProbe by default"
assert_not_contains "$OUT" "readinessProbe:" "no readinessProbe by default"
assert_not_contains "$OUT" "/health-check" "no presumed /health-check"

echo "== probes global path =="
OUT_PROBES_GLOBAL="$(render develop --set-json 'probes={"path":"/health-check"}')"
assert_contains "$OUT_PROBES_GLOBAL" "startupProbe:" "global path renders startupProbe"
assert_contains "$OUT_PROBES_GLOBAL" "livenessProbe:" "global path renders livenessProbe"
assert_contains "$OUT_PROBES_GLOBAL" "readinessProbe:" "global path renders readinessProbe"
GLOBAL_START="$(awk '/startupProbe:/,/livenessProbe:|readinessProbe:|resources:/ {print}' <<<"$OUT_PROBES_GLOBAL")"
GLOBAL_LIVE="$(awk '/livenessProbe:/,/readinessProbe:|resources:/ {print}' <<<"$OUT_PROBES_GLOBAL")"
GLOBAL_READY="$(awk '/readinessProbe:/,/resources:/ {print}' <<<"$OUT_PROBES_GLOBAL")"
assert_contains "$GLOBAL_START" 'path: "/health-check"' "startup uses global path"
assert_contains "$GLOBAL_LIVE" 'path: "/health-check"' "liveness uses global path"
assert_contains "$GLOBAL_READY" 'path: "/health-check"' "readiness uses global path"

echo "== probes three distinct paths =="
OUT_PROBES_3="$(render develop --set-json 'probes={"startup":{"path":"/startup"},"readiness":{"path":"/ready"},"liveness":{"path":"/live"}}')"
P3_START="$(awk '/startupProbe:/,/livenessProbe:|readinessProbe:|resources:/ {print}' <<<"$OUT_PROBES_3")"
P3_LIVE="$(awk '/livenessProbe:/,/readinessProbe:|resources:/ {print}' <<<"$OUT_PROBES_3")"
P3_READY="$(awk '/readinessProbe:/,/resources:/ {print}' <<<"$OUT_PROBES_3")"
assert_contains "$P3_START" 'path: "/startup"' "startup path /startup"
assert_contains "$P3_LIVE" 'path: "/live"' "liveness path /live"
assert_contains "$P3_READY" 'path: "/ready"' "readiness path /ready"

echo "== probes readiness only =="
OUT_PROBES_READY="$(render develop --set-json 'probes={"readiness":{"path":"/healthz"}}')"
assert_contains "$OUT_PROBES_READY" "readinessProbe:" "readiness-only renders readiness"
assert_contains "$OUT_PROBES_READY" 'path: "/healthz"' "readiness path /healthz"
assert_not_contains "$OUT_PROBES_READY" "startupProbe:" "readiness-only has no startup"
assert_not_contains "$OUT_PROBES_READY" "livenessProbe:" "readiness-only has no liveness"

echo "== probes liveness only =="
OUT_PROBES_LIVE="$(render develop --set-json 'probes={"liveness":{"path":"/live"}}')"
assert_contains "$OUT_PROBES_LIVE" "livenessProbe:" "liveness-only renders liveness"
assert_contains "$OUT_PROBES_LIVE" 'path: "/live"' "liveness path /live"
assert_not_contains "$OUT_PROBES_LIVE" "startupProbe:" "liveness-only has no startup"
assert_not_contains "$OUT_PROBES_LIVE" "readinessProbe:" "liveness-only has no readiness"

echo "== probes rejects global + specific =="
if OUT_PROBES_AMBIG="$(render develop --set-json 'probes={"path":"/health-check","readiness":{"path":"/ready"}}' 2>&1)"; then
  echo "FAIL: probes.path + specific path should fail template"
  FAILED=1
else
  assert_contains "$OUT_PROBES_AMBIG" "cannot coexist" "fail message for global+specific"
fi

echo "== probes rejects invalid path =="
if OUT_PROBES_BADPATH="$(render develop --set-json 'probes={"path":"healthz"}' 2>&1)"; then
  echo "FAIL: probe path without leading / should fail template"
  FAILED=1
else
  assert_contains "$OUT_PROBES_BADPATH" "must start with /" "fail message for invalid path"
fi

echo "== probes rejects bare true =="
if OUT_PROBES_TRUE="$(render develop --set probes=true 2>&1)"; then
  echo "FAIL: probes: true should fail template"
  FAILED=1
else
  assert_contains "$OUT_PROBES_TRUE" "probes: true is invalid" "fail message for probes: true"
fi

echo "== security + service contract =="
assert_contains "$OUT" "runAsNonRoot: true" "pod runAsNonRoot"
assert_contains "$OUT" "readOnlyRootFilesystem: true" "readOnlyRootFilesystem"
assert_contains "$OUT" "allowPrivilegeEscalation: false" "no privilege escalation"
assert_contains "$OUT" "type: RuntimeDefault" "seccomp RuntimeDefault"
assert_contains "$OUT" "- ALL" "capabilities drop ALL"
assert_contains "$OUT" "kind: Service" "Service rendered"
assert_contains "$OUT" "targetPort: http" "Service targetPort http"
assert_contains "$OUT" "containerPort: 8080" "containerPort 8080"
assert_contains "$OUT" "automountServiceAccountToken: false" "SA token not automounted"
assert_contains "$OUT" "mountPath: /tmp" "tmp emptyDir mount"

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

echo "== HTTPRoute hostnames override =="
OUT_HOSTS="$(render develop \
  --set-string 'httpRoute.hostnames[0]=custom.example.com' \
  --set-string 'httpRoute.hostnames[1]=alt.example.com')"
assert_contains "$OUT_HOSTS" "custom.example.com" "custom hostname override"
assert_contains "$OUT_HOSTS" "alt.example.com" "second custom hostname"
assert_not_contains "$OUT_HOSTS" "sample-api.dev.asa.corp" "derived corp hostname skipped when hostnames set"

echo "== HTTPRoute disabled =="
OUT_NO_ROUTE="$(render develop --set httpRoute.enabled=false)"
assert_not_contains "$OUT_NO_ROUTE" "kind: HTTPRoute" "HTTPRoute off when enabled=false"

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
assert_contains "$OUT_GCP" 'audience: "sts.amazonaws.com"' "projected token audience = sts.amazonaws.com"
assert_contains "$OUT_GCP" "expirationSeconds: 3600" "WIF token expiration"
assert_contains "$OUT_GCP" 'mountPath: "/var/run/secrets/eks.amazonaws.com/serviceaccount"' "WIF token mountPath"
assert_contains "$OUT_GCP" 'name: "sample-api-wif-credentials"' "GCP credentials ConfigMap volume"
assert_contains "$OUT_GCP" "mountPath: /var/run/secrets/google" "GCP credentials mount"
assert_contains "$OUT_GCP" "GOOGLE_APPLICATION_CREDENTIALS" "GOOGLE_APPLICATION_CREDENTIALS set"
assert_contains "$OUT_GCP" 'value: "/var/run/secrets/google/external-account.json"' "ADC path"
assert_contains "$OUT_GCP" "GOOGLE_CLOUD_PROJECT" "GOOGLE_CLOUD_PROJECT set"
assert_contains "$OUT_GCP" 'value: "my-gcp-project"' "projectId value"
assert_contains "$OUT_GCP" "checksum/wif:" "pod rolls on WIF ConfigMap change"

echo "== WIF token.audience override =="
OUT_AUD_OVR="$(render develop \
  --set-string "workloadIdentity.gcp.audience=${WIF_AUD}" \
  --set-string "workloadIdentity.gcp.serviceAccountEmail=${WIF_SA}" \
  --set-string workloadIdentity.token.audience=custom-token-audience)"
assert_contains "$OUT_AUD_OVR" 'audience: "custom-token-audience"' "projected token uses token.audience override"
assert_contains "$OUT_AUD_OVR" "\"audience\": \"${WIF_AUD}\"" "external_account audience unchanged by token override"

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
  --set-string 'externalSecret.data[0].remoteRef.key=asa/sample-api/develop/cs' \
  --set-string 'externalSecret.data[0].remoteRef.property=password')"
assert_contains "$OUT_ES" "kind: ExternalSecret" "ExternalSecret rendered"
assert_contains "$OUT_ES" "kind: ClusterSecretStore" "default SecretStore kind"
assert_contains "$OUT_ES" "name: sample-api-secret" "target Secret name"
assert_contains "$OUT_ES" "secretRef:" "envFrom secretRef"
assert_contains "$OUT_ES" 'property: "password"' "remoteRef.property rendered"
assert_not_contains "$OUT_ES" "kind: ConfigMap" "no ConfigMap when only externalSecret"

echo "== config + externalSecret composition =="
OUT_RT="$(render develop \
  --set-string config.API_URL=https://api.dev.example \
  --set-string externalSecret.secretStoreRef.name=aws-secretsmanager \
  --set-string 'externalSecret.data[0].secretKey=DB_PASSWORD' \
  --set-string 'externalSecret.data[0].remoteRef.key=asa/sample-api/develop/db')"
assert_contains "$OUT_RT" "configMapRef:" "composed configMapRef"
assert_contains "$OUT_RT" "secretRef:" "composed secretRef"

echo "== externalSecret rejects data without store ==="
if OUT_ES_DATA="$(render develop \
  --set-string 'externalSecret.data[0].secretKey=DB_PASSWORD' \
  --set-string 'externalSecret.data[0].remoteRef.key=asa/sample-api/develop/db' 2>&1)"; then
  echo "FAIL: externalSecret data without store should fail"
  FAILED=1
else
  assert_contains "$OUT_ES_DATA" "secretStoreRef.name" "fail message for data without store"
fi

echo "== externalSecret rejects store without data =="
if OUT_ES_STORE="$(render develop \
  --set-string externalSecret.secretStoreRef.name=aws-secretsmanager 2>&1)"; then
  echo "FAIL: externalSecret store without data should fail"
  FAILED=1
else
  assert_contains "$OUT_ES_STORE" "externalSecret.data" "fail message for store without data"
fi

echo "== externalSecret rejects bare true =="
if OUT_ES_TRUE="$(render develop --set externalSecret=true 2>&1)"; then
  echo "FAIL: externalSecret: true should fail template"
  FAILED=1
else
  assert_contains "$OUT_ES_TRUE" "externalSecret: true is invalid" "fail message for externalSecret: true"
fi

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
assert_contains "$OUT_DEV" "type: RollingUpdate" "RollingUpdate when persistence off"
assert_not_contains "$OUT_DEV" "type: Recreate" "no Recreate when persistence off"

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
assert_contains "$OUT_PVC" "type: Recreate" "Recreate strategy when persistence on"
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

echo "== cronJob accepts command without args =="
OUT_CRON_CMD="$(render develop \
  --set-string 'cronJob.schedule=0 7 * * *' \
  --set-string 'cronJob.command[0]=dotnet' \
  --set-string 'cronJob.command[1]=Sample.Api.dll')"
assert_contains "$OUT_CRON_CMD" "kind: CronJob" "CronJob rendered with command only"
assert_contains "$OUT_CRON_CMD" "dotnet" "CronJob command"

echo "== cronJob + PVC: CronJob still without PVC mount =="
OUT_CRON_PVC="$(render develop \
  --set autoscaling=false \
  --set replicaCount=1 \
  --set-string persistence.mountPath=/data \
  --set-string persistence.size=1Gi \
  --set-string 'cronJob.schedule=0 8 * * *' \
  --set-string 'cronJob.args[0]=--mode=job')"
assert_contains "$OUT_CRON_PVC" "kind: PersistentVolumeClaim" "PVC present with CronJob"
assert_contains "$OUT_CRON_PVC" "kind: CronJob" "CronJob present with PVC"
CRON_PVC_SECTION="$(awk '/kind: CronJob/,/^---$/ {print}' <<<"$OUT_CRON_PVC")"
assert_not_contains "$CRON_PVC_SECTION" "persistentVolumeClaim:" "CronJob does not mount PVC when persistence on"
assert_contains "$OUT_CRON_PVC" 'mountPath: "/data"' "Deployment still mounts PVC with CronJob"

echo "== cronJob reuses config + WIF =="
WIF_AUD="//iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/pool/providers/eks"
WIF_SA="app-sa@my-gcp-project.iam.gserviceaccount.com"
OUT_CRON_ID="$(render develop \
  --set-string 'cronJob.schedule=*/15 * * * *' \
  --set-string 'cronJob.args[0]=--mode=job' \
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

echo "== WIF rejects missing serviceAccountEmail =="
if OUT_WIF_BAD="$(render develop \
  --set-string "workloadIdentity.gcp.audience=${WIF_AUD}" 2>&1)"; then
  echo "FAIL: WIF without serviceAccountEmail should fail template"
  FAILED=1
else
  assert_contains "$OUT_WIF_BAD" "serviceAccountEmail" "fail message for WIF without email"
fi

echo "== WIF opt-out =="
OUT_NO_WIF="$(render develop --set workloadIdentity=false)"
assert_not_contains "$OUT_NO_WIF" "GOOGLE_APPLICATION_CREDENTIALS" "WIF off when workloadIdentity: false"
assert_not_contains "$OUT_NO_WIF" "name: sample-api-wif-credentials" "no WIF ConfigMap when opted out"

echo "== persistence rejects bare true =="
if OUT_PVC_TRUE="$(render develop --set persistence=true 2>&1)"; then
  echo "FAIL: persistence: true should fail template"
  FAILED=1
else
  assert_contains "$OUT_PVC_TRUE" "persistence: true is invalid" "fail message for persistence: true"
fi

echo "== persistence rejects mountPath without size =="
if OUT_PVC_NOSIZE="$(render develop \
  --set autoscaling=false \
  --set-string persistence.mountPath=/data 2>&1)"; then
  echo "FAIL: persistence mountPath without size should fail template"
  FAILED=1
else
  assert_contains "$OUT_PVC_NOSIZE" "persistence.size" "fail message for mountPath without size"
fi

echo "== cronJob rejects bare true =="
if OUT_CRON_TRUE="$(render develop --set cronJob=true 2>&1)"; then
  echo "FAIL: cronJob: true should fail template"
  FAILED=1
else
  assert_contains "$OUT_CRON_TRUE" "cronJob: true is invalid" "fail message for cronJob: true"
fi

echo "== cronJob rejects schedule without command/args =="
if OUT_CRON_NO_ENTRY="$(render develop \
  --set-string 'cronJob.schedule=0 6 * * *' 2>&1)"; then
  echo "FAIL: cronJob schedule without command/args should fail template"
  FAILED=1
else
  assert_contains "$OUT_CRON_NO_ENTRY" "cronJob requires command or args" "fail message for schedule without entrypoint"
fi

echo "== persistence opt-out =="
OUT_NO_PVC="$(render develop --set persistence=false)"
assert_not_contains "$OUT_NO_PVC" "kind: PersistentVolumeClaim" "PVC off when persistence: false"

if [[ "$FAILED" -ne 0 ]]; then
  echo "Some invariants failed"
  exit 1
fi
echo "All chart invariants passed"
