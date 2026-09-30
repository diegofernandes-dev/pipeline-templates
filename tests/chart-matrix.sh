#!/usr/bin/env bash
# Interaction matrix: every feature toggle crossed with every other, on BOTH charts.
#
# The rest of the suite exercises one dimension at a time (a web render, a WIF render, a
# persistence render). That leaves the class of bug where a change made for one workload
# breaks another — most dangerously through the templates the two charts SHARE
# (_labels.tpl, _workloadidentity.tpl, externalsecret.yaml, configmap.yaml,
# serviceaccount.yaml, wif-credentials.yaml). tests/chart-drift.sh proves those files are
# byte-identical, which is NOT the same as proving they render correctly in both charts:
# the charts have different _runtime.tpl and different values, so `workload` exists in one
# and not the other.
#
# Concretely, before this file existed no suite ever rendered the ScheduledJob chart with
# ExternalSecret enabled, despite sharing externalsecret.yaml with the Application chart.
#
# Asserts only properties that an INTERACTION can break: volume/mountPath collisions between
# tmp, persistence and the WIF projected token; envFrom composition when config and
# ExternalSecret are both on; checksum annotations tracking their source; and label validity.
# Structural validity via kubeconform runs over a representative subset to keep this fast.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_CHART="${ROOT}/charts/asa-application"
JOB_CHART="${ROOT}/charts/asa-scheduled-job"
SCHEMA_DIR="${ROOT}/tests/schemas"
FAILED=0
COMBOS=0
CONFORMED=0

WIF_AUD="//iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/providers/eks"

for cmd in helm yq; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "FAIL: ${cmd} is required for chart-matrix.sh"
    exit 1
  fi
done
HAVE_CONFORM=0
command -v kubeconform >/dev/null 2>&1 && HAVE_CONFORM=1

bad() { echo "FAIL: $1"; FAILED=1; }

# Pod spec path differs per kind; everything else about the assertions is identical.
pod_path() {
  case "$1" in
    Deployment) echo '.spec.template.spec' ;;
    CronJob)    echo '.spec.jobTemplate.spec.template.spec' ;;
  esac
}
pod_meta_path() {
  case "$1" in
    Deployment) echo '.spec.template.metadata' ;;
    CronJob)    echo '.spec.jobTemplate.spec.template.metadata' ;;
  esac
}

# check_combo <label> <workload-kind> <wif 0|1> <eso 0|1> <cfg 0|1> <persist 0|1> -- helm args...
check_combo() {
  local label="$1" wkind="$2" wif="$3" eso="$4" cfg="$5" persist="$6"
  shift 6
  [ "${1:-}" = "--" ] && shift
  COMBOS=$((COMBOS + 1))

  local out
  if ! out="$("$@" 2>&1)"; then
    bad "${label}: helm template failed"
    printf '%s\n' "${out}" | head -3 | sed 's/^/    /'
    return
  fi

  local pp mp
  pp="$(pod_path "${wkind}")"
  mp="$(pod_meta_path "${wkind}")"

  # --- volume names must be unique: tmp + data (persistence) + aws-token + gcp-credentials
  local vols dupv
  vols="$(yq -r -N "select(.kind == \"${wkind}\") | ${pp}.volumes // [] | .[].name" <<<"${out}" 2>/dev/null || true)"
  dupv="$(printf '%s\n' "${vols}" | grep -v '^$' | sort | uniq -d || true)"
  [ -n "${dupv}" ] && bad "${label}: duplicate volume names: $(printf '%s' "${dupv}" | tr '\n' ' ')"

  # --- mountPaths must be unique; WIF must not land on the IRSA path
  local mounts dupm
  mounts="$(yq -r -N "select(.kind == \"${wkind}\") | ${pp}.containers[0].volumeMounts // [] | .[].mountPath" <<<"${out}" 2>/dev/null || true)"
  dupm="$(printf '%s\n' "${mounts}" | grep -v '^$' | sort | uniq -d || true)"
  [ -n "${dupm}" ] && bad "${label}: duplicate mountPaths: $(printf '%s' "${dupm}" | tr '\n' ' ')"
  if printf '%s\n' "${mounts}" | grep -qx '/var/run/secrets/eks.amazonaws.com/serviceaccount'; then
    bad "${label}: WIF token mounted on the IRSA reserved path"
  fi

  # --- envFrom must reflect exactly the sources that are enabled
  local envfrom has_cm has_sec
  envfrom="$(yq -r -N "select(.kind == \"${wkind}\") | ${pp}.containers[0].envFrom // [] | .[] | (.configMapRef.name // \"\") + \"|\" + (.secretRef.name // \"\")" <<<"${out}" 2>/dev/null || true)"
  has_cm=0; has_sec=0
  printf '%s\n' "${envfrom}" | grep -q '^t-config|$' && has_cm=1
  printf '%s\n' "${envfrom}" | grep -q '^|t-secret$' && has_sec=1
  [ "${cfg}" = "1" ] && [ "${has_cm}" = "0" ] && bad "${label}: config enabled but no configMapRef in envFrom"
  [ "${cfg}" = "0" ] && [ "${has_cm}" = "1" ] && bad "${label}: configMapRef present with config disabled"
  [ "${eso}" = "1" ] && [ "${has_sec}" = "0" ] && bad "${label}: externalSecret enabled but no secretRef in envFrom"
  [ "${eso}" = "0" ] && [ "${has_sec}" = "1" ] && bad "${label}: secretRef present with externalSecret disabled"

  # --- checksum annotations must track their source, so a change rolls pods
  local ann
  ann="$(yq -r -N "select(.kind == \"${wkind}\") | ${mp}.annotations // {} | keys | .[]" <<<"${out}" 2>/dev/null || true)"
  local has_ck_cfg=0 has_ck_wif=0
  printf '%s\n' "${ann}" | grep -qx 'checksum/config' && has_ck_cfg=1
  printf '%s\n' "${ann}" | grep -qx 'checksum/wif' && has_ck_wif=1
  [ "${cfg}" != "${has_ck_cfg}" ] && bad "${label}: checksum/config presence (${has_ck_cfg}) does not match config (${cfg})"
  [ "${wif}" != "${has_ck_wif}" ] && bad "${label}: checksum/wif presence (${has_ck_wif}) does not match workloadIdentity (${wif})"

  # --- WIF env + its ConfigMap appear together or not at all
  local has_gac cm_count
  has_gac=0
  yq -r -N "select(.kind == \"${wkind}\") | ${pp}.containers[0].env // [] | .[].name" <<<"${out}" 2>/dev/null \
    | grep -qx 'GOOGLE_APPLICATION_CREDENTIALS' && has_gac=1
  [ "${wif}" != "${has_gac}" ] && bad "${label}: GOOGLE_APPLICATION_CREDENTIALS presence (${has_gac}) does not match workloadIdentity (${wif})"
  cm_count="$(grep -c '^  name: t-wif-credentials$' <<<"${out}" || true)"
  [ "${wif}" = "1" ] && [ "${cm_count}" = "0" ] && bad "${label}: WIF enabled but wif-credentials ConfigMap missing"
  [ "${wif}" = "0" ] && [ "${cm_count}" != "0" ] && bad "${label}: wif-credentials ConfigMap present with WIF disabled"

  # --- ExternalSecret object tracks the toggle
  local es_count
  es_count="$(grep -c '^kind: ExternalSecret$' <<<"${out}" || true)"
  [ "${eso}" = "1" ] && [ "${es_count}" != "1" ] && bad "${label}: externalSecret enabled but ${es_count} ExternalSecret rendered"
  [ "${eso}" = "0" ] && [ "${es_count}" != "0" ] && bad "${label}: ${es_count} ExternalSecret rendered with externalSecret disabled"

  # --- persistence implies the data volume and Recreate; absence implies neither
  if [ "${wkind}" = "Deployment" ]; then
    local strat
    strat="$(yq -r -N 'select(.kind == "Deployment") | .spec.strategy.type' <<<"${out}" 2>/dev/null || true)"
    if [ "${persist}" = "1" ]; then
      printf '%s\n' "${vols}" | grep -qx data || bad "${label}: persistence enabled but no data volume"
      [ "${strat}" = "Recreate" ] || bad "${label}: persistence must force Recreate (got ${strat})"
    else
      printf '%s\n' "${vols}" | grep -qx data && bad "${label}: data volume present without persistence"
      [ "${strat}" = "RollingUpdate" ] || bad "${label}: expected RollingUpdate (got ${strat})"
    fi
  fi

  # --- every label value must satisfy the Kubernetes label syntax
  local badlabel
  badlabel="$(yq -r -N 'select(.metadata.labels != null) | .metadata.labels | to_entries | .[] | .key + "=" + (.value // "")' <<<"${out}" 2>/dev/null \
    | while IFS= read -r kv; do
        v="${kv#*=}"
        if [ -n "${v}" ] && ! printf '%s' "${v}" | grep -qE '^[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$'; then
          printf '%s\n' "${kv}"
        fi
      done)"
  [ -n "${badlabel//[[:space:]]/}" ] && bad "${label}: invalid label value(s): $(printf '%s' "${badlabel}" | tr '\n' ' ')"

  return 0
}

conform_combo() {
  local label="$1"
  shift
  [ "${HAVE_CONFORM}" = "1" ] || return 0
  CONFORMED=$((CONFORMED + 1))
  local out
  out="$("$@" 2>/dev/null)" || return 0
  if ! kubeconform -strict -kubernetes-version 1.27.0 \
    -schema-location default \
    -schema-location "${SCHEMA_DIR}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
    <<<"${out}" >/dev/null 2>&1; then
    bad "${label}: kubeconform rejected the rendered manifest"
  fi
}

app() {
  helm template t "${APP_CHART}" \
    --set-string image.repository=example.invalid/app \
    --set-string image.tag=v1 "$@"
}
job() {
  helm template t "${JOB_CHART}" \
    --set-string image.repository=example.invalid/job \
    --set-string image.tag=v1 \
    --set-string 'schedule.expression=0 2 * * *' \
    --set-string schedule.timeZone=America/Sao_Paulo \
    --set execution.timeoutSeconds=60 "$@"
}

echo "== interaction matrix: Application =="
for TYPE in web grpc worker; do
  for ENV in develop production; do
    for PERSIST in 0 1; do
      for WIF in 0 1; do
        for ESO in 0 1; do
          for CFG in 0 1; do
            ARGS="--set-string workload.type=${TYPE} --set-string runtime.environment=${ENV}"
            case "${TYPE}" in
              web)  PROBE="--set-json probes={\"readiness\":{\"path\":\"/h\"}}" ;;
              grpc) PROBE="--set-json probes={\"readiness\":{\"enabled\":true}}" ;;
              *)    PROBE="" ;;
            esac
            # RWO PVC cannot be shared, so persistence requires a single, non-autoscaled replica.
            PERS=""
            [ "${PERSIST}" = "1" ] && PERS="--set autoscaling=false --set replicaCount=1 --set-string persistence.mountPath=/data --set-string persistence.size=1Gi"
            W=""
            [ "${WIF}" = "1" ] && W="--set-string workloadIdentity.gcp.audience=${WIF_AUD} --set-string workloadIdentity.gcp.serviceAccountEmail=a@b.iam.gserviceaccount.com"
            S=""
            [ "${ESO}" = "1" ] && S="--set-string externalSecret.secretStoreRef.name=store --set-json externalSecret.data=[{\"secretKey\":\"K\",\"remoteRef\":{\"key\":\"r\"}}]"
            C=""
            [ "${CFG}" = "1" ] && C="--set-string config.FOO=bar"
            LBL="app/${TYPE}/${ENV}/pvc=${PERSIST}/wif=${WIF}/eso=${ESO}/cfg=${CFG}"
            # shellcheck disable=SC2086
            check_combo "${LBL}" Deployment "${WIF}" "${ESO}" "${CFG}" "${PERSIST}" -- app ${ARGS} ${PROBE} ${PERS} ${W} ${S} ${C}
          done
        done
      done
    done
  done
done

echo "== interaction matrix: ScheduledJob =="
for ENTRY in args command; do
  for WIF in 0 1; do
    for ESO in 0 1; do
      for CFG in 0 1; do
        case "${ENTRY}" in
          args)    E="--set-string execution.args[0]=--mode=job" ;;
          command) E="--set-string execution.command[0]=/app/start.sh" ;;
        esac
        W=""
        [ "${WIF}" = "1" ] && W="--set-string workloadIdentity.gcp.audience=${WIF_AUD} --set-string workloadIdentity.gcp.serviceAccountEmail=a@b.iam.gserviceaccount.com"
        S=""
        [ "${ESO}" = "1" ] && S="--set-string externalSecret.secretStoreRef.name=store --set-json externalSecret.data=[{\"secretKey\":\"K\",\"remoteRef\":{\"key\":\"r\"}}]"
        C=""
        [ "${CFG}" = "1" ] && C="--set-string config.FOO=bar"
        LBL="job/${ENTRY}/wif=${WIF}/eso=${ESO}/cfg=${CFG}"
        # shellcheck disable=SC2086
        check_combo "${LBL}" CronJob "${WIF}" "${ESO}" "${CFG}" 0 -- job ${E} ${W} ${S} ${C}
      done
    done
  done
done

# Structural validation over the corners most likely to produce malformed YAML: everything
# on at once, and each chart's richest shape.
echo "== kubeconform over matrix corners =="
ALL_ON="--set-string workloadIdentity.gcp.audience=${WIF_AUD} --set-string workloadIdentity.gcp.serviceAccountEmail=a@b.iam.gserviceaccount.com --set-string externalSecret.secretStoreRef.name=store --set-json externalSecret.data=[{\"secretKey\":\"K\",\"remoteRef\":{\"key\":\"r\"}}] --set-string config.FOO=bar"
for TYPE in web grpc worker; do
  case "${TYPE}" in
    web)  PROBE="--set-json probes={\"readiness\":{\"path\":\"/h\"}}" ;;
    grpc) PROBE="--set-json probes={\"readiness\":{\"enabled\":true}}" ;;
    *)    PROBE="" ;;
  esac
  # shellcheck disable=SC2086
  conform_combo "app/${TYPE}/all-on/production" app --set-string workload.type=${TYPE} \
    --set-string runtime.environment=production ${PROBE} ${ALL_ON}
done
# shellcheck disable=SC2086
conform_combo "app/web/all-on+persistence" app --set-string workload.type=web \
  --set-json 'probes={"readiness":{"path":"/h"}}' --set autoscaling=false --set replicaCount=1 \
  --set-string persistence.mountPath=/data --set-string persistence.size=1Gi ${ALL_ON}
# shellcheck disable=SC2086
conform_combo "job/all-on" job --set-string 'execution.args[0]=--mode=job' ${ALL_ON}

echo
if [ "${FAILED}" -ne 0 ]; then
  echo "Interaction matrix failed (${COMBOS} combinations, ${CONFORMED} conformance checks)"
  exit 1
fi
echo "Interaction matrix clean: ${COMBOS} combinations, ${CONFORMED} conformance checks"
