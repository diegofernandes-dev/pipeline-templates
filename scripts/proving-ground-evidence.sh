#!/usr/bin/env bash
# Collect post-deploy evidence for an Application/web proving ground.
# Requires: kubectl, helm, curl, python3. Optional: aws, dig, yq.
#
# Usage:
#   ./scripts/proving-ground-evidence.sh <applicationName> [environment]
#
# Env overrides:
#   PLATFORM_ENVS   path to config/platform-environments.json (default: repo config/)
#   AWS_REGION      default us-east-1
#   HTTP_URL        full URL to curl (optional; skips auto Gateway discovery)
#   SKIP_HTTP=1     skip HTTP probe
#   SKIP_DNS=1      skip DNS lookup
#   SKIP_ECR=1      skip ECR describe
#
# Example:
#   ./scripts/proving-ground-evidence.sh pt-v3-web develop
#   HTTP_URL=http://127.0.0.1:18080/ ./scripts/proving-ground-evidence.sh pt-v3-web develop
set -Eeuo pipefail

APP="${1:-}"
ENV_NAME="${2:-develop}"
if [[ -z "${APP}" ]]; then
  echo "usage: $0 <applicationName> [environment]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM_ENVS="${PLATFORM_ENVS:-${ROOT}/config/platform-environments.json}"
NS="asa-${APP}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "FAIL missing tool: $1" >&2; exit 1; }
}
need kubectl
need helm
need curl
need python3

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; }
info() { printf 'INFO  %s\n' "$*"; }
section() { printf '\n======== %s ========\n' "$*"; }

json_get() {
  # json_get '<json-or-->' 'python expr using d'
  local src="$1" expr="$2"
  if [[ "${src}" == "-" ]]; then
    python3 -c "import json,sys; d=json.load(sys.stdin); print(${expr})"
  else
    python3 -c "import json; d=json.load(open(sys.argv[1])); print(${expr})" "${src}"
  fi
}

platform_field() {
  local key="$1"
  python3 - "${PLATFORM_ENVS}" "${ENV_NAME}" "${key}" <<'PY'
import json, sys
path, env, key = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    import yaml  # type: ignore
    data = yaml.safe_load(open(path, encoding="utf-8"))
except Exception:
    data = json.load(open(path, encoding="utf-8"))
val = (data or {}).get(env) or {}
v = val.get(key)
print("" if v is None else v)
PY
}

EXPECTED_POOL=""
EXPECTED_CTX=""
GATEWAY_NAME=""
GATEWAY_NS=""
if [[ -f "${PLATFORM_ENVS}" ]]; then
  EXPECTED_POOL="$(platform_field containerPool)"
  EXPECTED_CTX="$(platform_field expectedKubeContext)"
  GATEWAY_NAME="$(platform_field gatewayName)"
  GATEWAY_NS="$(platform_field gatewayNamespace)"
fi

# Hostname zones mirror charts/asa-application/templates/_networking.tpl (corp)
case "${ENV_NAME}" in
  develop) ZONE="dev.asa.corp" ;;
  homolog) ZONE="hml.asa.corp" ;;
  production) ZONE="prd.asa.corp" ;;
  *) ZONE="dev.asa.corp" ;;
esac
HOSTNAME="${APP}.${ZONE}"

PF_PID=""
cleanup() {
  if [[ -n "${PF_PID}" ]]; then
    kill "${PF_PID}" 2>/dev/null || true
  fi
  rm -f /tmp/pg-http-body.$$ /tmp/pg-pf.$$.log 2>/dev/null || true
}
trap cleanup EXIT

section "identity"
CTX="$(kubectl config current-context 2>/dev/null || true)"
info "kubectl context: ${CTX:-<none>}"
info "expectedKubeContext (${ENV_NAME}): ${EXPECTED_CTX:-null}"
if [[ -n "${EXPECTED_CTX}" && "${EXPECTED_CTX}" != "null" ]]; then
  if [[ "${CTX}" == "${EXPECTED_CTX}" ]]; then
    pass "cluster identity matches expectedKubeContext"
  else
    fail "cluster identity mismatch (got '${CTX}', expected '${EXPECTED_CTX}')"
  fi
else
  info "expectedKubeContext unset — record this context as authoritative for ${ENV_NAME}"
fi
info "expected pool (${ENV_NAME}): ${EXPECTED_POOL:-null}"
kubectl version -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("client="+d.get("clientVersion",{}).get("gitVersion","?")
      +" server="+d.get("serverVersion",{}).get("gitVersion","?"))
' 2>/dev/null || kubectl version 2>&1 | head -8

if command -v aws >/dev/null 2>&1 && [[ "${SKIP_ECR:-0}" != "1" ]]; then
  section "aws / ecr"
  if aws sts get-caller-identity; then
    pass "AWS identity"
  else
    fail "AWS identity"
  fi
  if aws ecr describe-repositories --repository-names "${APP}" --region "${AWS_REGION}" \
    --query 'repositories[0].{uri:repositoryUri,mutability:imageTagMutability}' --output table; then
    TAG="$(helm -n "${NS}" get values "${APP}" -a -o json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("image",{}).get("tag") or "")' || true)"
    if [[ -n "${TAG}" ]]; then
      if aws ecr describe-images --repository-name "${APP}" --region "${AWS_REGION}" \
        --image-ids "imageTag=${TAG}" \
        --query 'imageDetails[0].{digest:imageDigest,tags:imageTags,pushed:imagePushedAt}' --output table; then
        pass "ECR image tag ${TAG}"
      else
        fail "ECR image tag ${TAG} missing"
      fi
    else
      info "helm image.tag unavailable — skip digest check"
    fi
  else
    fail "ECR repository ${APP}"
  fi
else
  info "skipping AWS/ECR (aws missing or SKIP_ECR=1)"
fi

section "namespace ${NS}"
if kubectl get ns "${NS}" >/dev/null 2>&1; then
  kubectl get ns "${NS}" -o jsonpath='name={.metadata.name} phase={.status.phase}{"\n"}labels={.metadata.labels}{"\n"}'
  pass "namespace"
else
  fail "namespace ${NS} missing"
fi

section "helm release"
if helm -n "${NS}" status "${APP}"; then
  helm -n "${NS}" get values "${APP}" -a -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(json.dumps({
  "kind": d.get("kind"),
  "runtime_environment": (d.get("runtime") or {}).get("environment"),
  "image_repository": (d.get("image") or {}).get("repository"),
  "image_tag": (d.get("image") or {}).get("tag"),
  "imagePullSecrets": d.get("imagePullSecrets"),
  "probes": d.get("probes"),
  "autoscaling": d.get("autoscaling"),
}, indent=2))
'
  CHART="$(helm -n "${NS}" list -o json \
    | python3 -c 'import json,sys; n=sys.argv[1];
items=json.load(sys.stdin);
print(next((i.get("chart") or "" for i in items if i.get("name")==n), ""))' "${APP}")"
  info "chart: ${CHART}"
  if [[ "${CHART}" == asa-application-* ]]; then
    pass "Helm release (asa-application)"
  else
    fail "unexpected chart '${CHART}' for Application"
  fi
else
  fail "helm release ${APP}"
fi

section "deployment / runtime"
if kubectl -n "${NS}" get deploy "${APP}" >/dev/null 2>&1; then
  kubectl -n "${NS}" get deploy,pods,sa -l "app=${APP}" -o wide
  READY="$(kubectl -n "${NS}" get deploy "${APP}" -o jsonpath='{.status.readyReplicas}')"
  DESIRED="$(kubectl -n "${NS}" get deploy "${APP}" -o jsonpath='{.spec.replicas}')"
  IMAGE="$(kubectl -n "${NS}" get deploy "${APP}" -o jsonpath='{.spec.template.spec.containers[0].image}')"
  PORT="$(kubectl -n "${NS}" get deploy "${APP}" -o jsonpath='{.spec.template.spec.containers[0].ports[0].containerPort}')"
  SA="$(kubectl -n "${NS}" get deploy "${APP}" -o jsonpath='{.spec.template.spec.serviceAccountName}')"
  info "image=${IMAGE}"
  info "sa=${SA} containerPort=${PORT} ready=${READY}/${DESIRED}"
  [[ "${PORT}" == "8080" ]] && pass "platform port 8080" || fail "containerPort=${PORT} (expected 8080)"
  if [[ -n "${READY}" && "${READY}" != "0" && "${READY}" == "${DESIRED}" ]]; then
    pass "Deployment Ready"
  else
    fail "Deployment not Ready"
  fi
  POD="$(kubectl -n "${NS}" get pods -l "app=${APP}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${POD}" ]]; then
    kubectl -n "${NS}" logs "${POD}" --tail=8 2>/dev/null | grep -E 'listening|8080' || true
  fi
else
  fail "deployment missing"
fi

section "HPA / metrics"
if kubectl get --raw /apis/metrics.k8s.io/v1beta1 >/dev/null 2>&1; then
  pass "metrics.k8s.io available"
else
  fail "metrics.k8s.io unavailable"
fi
if kubectl -n "${NS}" get hpa "${APP}" >/dev/null 2>&1; then
  kubectl -n "${NS}" get hpa "${APP}"
  MIN="$(kubectl -n "${NS}" get hpa "${APP}" -o jsonpath='{.spec.minReplicas}')"
  SCALING="$(kubectl -n "${NS}" get hpa "${APP}" -o jsonpath='{.status.conditions[?(@.type=="ScalingActive")].status}')"
  info "minReplicas=${MIN} ScalingActive=${SCALING}"
  if [[ "${ENV_NAME}" == "develop" && "${MIN}" == "1" ]]; then
    pass "HPA minReplicas=1 (develop)"
  else
    info "HPA minReplicas=${MIN}"
  fi
  [[ "${SCALING}" == "True" ]] && pass "HPA ScalingActive" || fail "HPA ScalingActive!=True"
else
  fail "HPA missing"
fi

section "Service"
if kubectl -n "${NS}" get svc "${APP}" >/dev/null 2>&1; then
  kubectl -n "${NS}" get svc "${APP}" -o wide
  kubectl -n "${NS}" get endpoints "${APP}" -o wide 2>/dev/null || true
  SVC_PORT="$(kubectl -n "${NS}" get svc "${APP}" -o jsonpath='{.spec.ports[0].port}')"
  EP="$(kubectl -n "${NS}" get endpoints "${APP}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
  [[ "${SVC_PORT}" == "8080" ]] && pass "Service port 8080" || fail "Service port=${SVC_PORT}"
  [[ -n "${EP}" ]] && pass "Service has endpoints (${EP})" || fail "Service has no endpoints"
else
  fail "Service missing"
fi

section "HTTPRoute / Gateway"
if kubectl -n "${NS}" get httproute "${APP}" >/dev/null 2>&1; then
  RH="$(kubectl -n "${NS}" get httproute "${APP}" -o jsonpath='{.spec.hostnames[0]}')"
  info "route hostname=${RH} (derived expect ${HOSTNAME})"
  kubectl -n "${NS}" get httproute "${APP}" -o jsonpath='{range .status.parents[*]}{.parentRef.namespace}/{.parentRef.name}{"\n"}{range .conditions[*]}  {.type}={.status} reason={.reason} msg={.message}{"\n"}{end}{end}'
  ACC="$(kubectl -n "${NS}" get httproute "${APP}" -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}')"
  REF="$(kubectl -n "${NS}" get httproute "${APP}" -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}')"
  [[ "${ACC}" == "True" ]] && pass "HTTPRoute Accepted" || fail "HTTPRoute Accepted=${ACC}"
  [[ "${REF}" == "True" ]] && pass "HTTPRoute ResolvedRefs" || fail "HTTPRoute ResolvedRefs=${REF}"
else
  fail "HTTPRoute missing"
fi

if [[ -n "${GATEWAY_NAME}" ]]; then
  if [[ -n "${GATEWAY_NS}" ]] && kubectl -n "${GATEWAY_NS}" get gateway "${GATEWAY_NAME}" >/dev/null 2>&1; then
    info "Gateway ${GATEWAY_NS}/${GATEWAY_NAME}"
    kubectl -n "${GATEWAY_NS}" get gateway "${GATEWAY_NAME}" \
      -o jsonpath='class={.spec.gatewayClassName} programmed={.status.conditions[?(@.type=="Programmed")].status}{"\n"}'
    kubectl -n "${GATEWAY_NS}" get gateway "${GATEWAY_NAME}" \
      -o jsonpath='{range .spec.listeners[*]}listener={.name} port={.port} allowedRoutes={.allowedRoutes.namespaces.from}{"\n"}{end}'
    pass "Gateway present"
  elif kubectl get gateway -A -o json 2>/dev/null | python3 -c "
import json,sys
name=sys.argv[1]
items=json.load(sys.stdin).get('items') or []
hits=[i['metadata']['namespace']+'/'+i['metadata']['name'] for i in items if i['metadata']['name']==name]
sys.exit(0 if hits else 1)
" "${GATEWAY_NAME}"; then
    pass "Gateway ${GATEWAY_NAME} present (cluster-wide)"
  else
    fail "Gateway ${GATEWAY_NAME} not found${GATEWAY_NS:+ in ${GATEWAY_NS}}"
  fi
fi

RESOLVED=""
section "DNS ${HOSTNAME}"
if [[ "${SKIP_DNS:-0}" == "1" ]]; then
  info "SKIP_DNS=1"
else
  if command -v dig >/dev/null 2>&1; then
    RESOLVED="$(dig +short "${HOSTNAME}" 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "${RESOLVED}" ]] && command -v getent >/dev/null 2>&1; then
    RESOLVED="$(getent hosts "${HOSTNAME}" 2>/dev/null | awk '{print $1; exit}' || true)"
  fi
  if [[ -n "${RESOLVED}" ]]; then
    pass "DNS ${HOSTNAME} → ${RESOLVED}"
  else
    fail "DNS ${HOSTNAME} does not resolve (ExternalDNS/LB may be missing)"
  fi
fi

section "HTTP"
if [[ "${SKIP_HTTP:-0}" == "1" ]]; then
  info "SKIP_HTTP=1"
else
  TARGET_URL="${HTTP_URL:-}"
  CURL_HOST=()

  if [[ -z "${TARGET_URL}" && -n "${RESOLVED}" ]]; then
    TARGET_URL="http://${HOSTNAME}/"
  fi

  if [[ -z "${TARGET_URL}" ]]; then
    FWD_NS=""
    FWD_SVC=""
    if [[ -n "${GATEWAY_NS}" ]]; then
      FWD_SVC="$(kubectl -n "${GATEWAY_NS}" get svc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
      [[ -n "${FWD_SVC}" ]] && FWD_NS="${GATEWAY_NS}"
    fi
    if [[ -z "${FWD_SVC}" ]]; then
      FWD_SVC="$(kubectl -n nginx-gateway get svc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
      [[ -n "${FWD_SVC}" ]] && FWD_NS="nginx-gateway"
    fi
    if [[ -n "${FWD_NS}" && -n "${FWD_SVC}" ]]; then
      kubectl -n "${FWD_NS}" port-forward "svc/${FWD_SVC}" 18080:80 >/tmp/pg-pf.$$.log 2>&1 &
      PF_PID=$!
      sleep 2
      TARGET_URL="http://127.0.0.1:18080/"
      CURL_HOST=(-H "Host: ${HOSTNAME}")
      info "no DNS — port-forward ${FWD_NS}/${FWD_SVC} → ${TARGET_URL} Host=${HOSTNAME}"
    else
      fail "HTTP skipped — set HTTP_URL=... or ensure a Gateway Service exists"
    fi
  fi

  if [[ -n "${TARGET_URL}" ]]; then
    BODY="/tmp/pg-http-body.$$"
    HTTP_CODE="$(curl -sS -o "${BODY}" -w '%{http_code}' --max-time 20 "${CURL_HOST[@]}" "${TARGET_URL}" || echo 000)"
    info "GET ${TARGET_URL} → HTTP ${HTTP_CODE}"
    head -c 400 "${BODY}" 2>/dev/null; echo
    if [[ "${HTTP_CODE}" =~ ^2 ]]; then
      pass "HTTP end-to-end (${HTTP_CODE})"
    else
      fail "HTTP end-to-end status=${HTTP_CODE}"
    fi
  fi
fi

section "ADO checks (manual)"
cat <<EOF
This script covers cluster-side gates after deploy.
Also verify in Azure DevOps:
  - compile / extends / convertToJson accepted
  - stage order: Validate deploy manifests → Docker → Deploy
  - DeployContract: kind, workload.type, schema OK, cross-env OK
  - agent pool for ${ENV_NAME}: expected ${EXPECTED_POOL:-<see platform-environments.json>}
  - same-commit rerun: ECR "already exists ... skipping build/push"
EOF
