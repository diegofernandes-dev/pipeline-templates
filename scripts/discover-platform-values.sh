#!/usr/bin/env bash
# Read-only discovery of the platform values that platform/areas/<area>.yml and the
# charts still need. NOTHING is created, modified or deleted.
#
#   ./scripts/discover-platform-values.sh <kube-context>
#
# Run it once per cluster (area × tier) with that cluster's context.
#
# Optionally set EKS_CLUSTER (+ AWS_REGION) to also read what the AWS API can answer WITHOUT
# cluster network access — control-plane version and Availability Zones. Useful when the EKS
# public endpoint is CIDR-restricted:
#
#   EKS_CLUSTER=my-cluster ./scripts/discover-platform-values.sh <kube-context>
#
# Requires kubectl only (plus aws for the optional Part A). No yq, no python.
set -uo pipefail

CTX="${1:-$(kubectl config current-context 2>/dev/null)}"
K="kubectl --context=${CTX} --request-timeout=20s"
GW_NS="${GATEWAY_NAMESPACE:-asa-infra-nginx-gateway}"

h() { printf '\n=== %s ===\n' "$*"; }
say_or() {
  local out="$1" empty_msg="$2"
  if [[ -n "${out//[[:space:]]/}" ]]; then sed 's/^/  /' <<<"${out}"; else echo "  ${empty_msg}"; fi
}

echo "context: ${CTX}"

# ───────── Part A: AWS API only — works even when the cluster endpoint is unreachable ─────────
if [[ -n "${EKS_CLUSTER:-}" ]]; then
  REGION="${AWS_REGION:-us-east-1}"

  h "A1) EKS control-plane version  ->  charts/*/Chart.yaml kubeVersion"
  say_or "$(aws eks describe-cluster --name "${EKS_CLUSTER}" --region "${REGION}" \
    --query 'cluster.{version:version,platformVersion:platformVersion,status:status}' --output text 2>/dev/null)" \
    "could not describe cluster ${EKS_CLUSTER} (check credentials / name / region)"

  h "A2) Availability Zones  ->  topologySpreadConstraints"
  AZS="$(aws eks describe-cluster --name "${EKS_CLUSTER}" --region "${REGION}" \
    --query 'cluster.resourcesVpcConfig.subnetIds[]' --output text 2>/dev/null | tr '\t' '\n' \
    | while read -r sn; do
        [[ -n "${sn}" ]] && aws ec2 describe-subnets --subnet-ids "${sn}" --region "${REGION}" \
          --query 'Subnets[0].AvailabilityZone' --output text 2>/dev/null
      done | sort -u)"
  say_or "${AZS}" "no AZ resolved"
  echo "  count: $(grep -c . <<<"${AZS}" || true)  -> 2+ makes zone spread meaningful"

  h "A3) Is the cluster endpoint reachable from here?"
  MYIP="$(curl -s --max-time 8 https://checkip.amazonaws.com 2>/dev/null || echo unknown)"
  CIDRS="$(aws eks describe-cluster --name "${EKS_CLUSTER}" --region "${REGION}" \
    --query 'cluster.resourcesVpcConfig.publicAccessCidrs[]' --output text 2>/dev/null || true)"
  echo "  your public IP    : ${MYIP}"
  echo "  publicAccessCidrs : ${CIDRS:-<none>}"
  if [[ -n "${CIDRS}" && "${MYIP}" != "unknown" ]]; then
    if grep -qF -- "${MYIP}/32" <<<"${CIDRS}"; then
      echo "  -> your IP IS allowlisted"
    else
      echo "  -> your IP is NOT allowlisted; Part B will time out. Run this on a deploy agent"
      echo "     from the environment's pool instead (that is also where section 6 lives)."
    fi
  fi
fi

# ───────── Part B: Kubernetes API — needs cluster reachability ─────────
# Gate on reachability FIRST. Without this, an unreachable cluster yields empty output for
# every section below, and "empty" is indistinguishable from "genuinely absent" — which is
# exactly how a wrong value ends up recorded as authoritative.
h "Part B preflight: can we reach the API server?"
if ! $K version -o json >/dev/null 2>&1; then
  cat <<MSG
  UNREACHABLE — cannot talk to the API server for context '${CTX}'.

  Every section below would print nothing, and nothing is NOT the same as "absent".
  Do NOT record any value from this run. Fix access first:
    - on VPN / correct network?
    - is your IP in the cluster's publicAccessCidrs? (re-run with EKS_CLUSTER=<name> for Part A)
    - does your identity have an EKS access entry / aws-auth mapping?
    - kubectl config use-context <name>, then retry
MSG
  echo ""
  echo "  contexts available here:"
  kubectl config get-contexts -o name 2>/dev/null | sed 's/^/    /'
  exit 1
fi
echo "  reachable"

h "1) kubeVersion  ->  charts/*/Chart.yaml"
say_or "$($K version 2>/dev/null | grep -i '^server version')" "UNREACHABLE (check VPN / kubeconfig / IP allowlist)"
echo "  -> use the LOWEST major.minor across area×tier clusters:"
echo "     kubeVersion: \">=<major>.<minor>.0-0\""

h "2) Pod Security Admission labels already in use"
say_or "$($K get ns --show-labels --no-headers 2>/dev/null | tr ',' '\n' \
  | grep -o 'pod-security\.kubernetes\.io/[a-z-]*=[a-z0-9.]*' | sort -u)" \
  "no PSA labels anywhere -> no existing convention to copy"
echo "  -> the charts' securityContext already satisfies 'restricted' (runAsNonRoot + runAsUser,"
echo "     seccomp RuntimeDefault, drop ALL, allowPrivilegeEscalation false)."

h "3) Gateway.allowedRoutes  ->  must the app namespace carry a label?"
say_or "$($K get gateway.gateway.networking.k8s.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{range .spec.listeners[*]}{"    listener "}{.name}{"  port="}{.port}{"  from="}{.allowedRoutes.namespaces.from}{"  selector="}{.allowedRoutes.namespaces.selector}{"\n"}{end}{end}' 2>/dev/null)" \
  "no Gateway visible (Gateway API absent, unreachable, or no RBAC to list)"
echo "  from empty/Same -> cross-namespace parentRef needs a ReferenceGrant"
echo "  from=All        -> nothing to label"
echo "  from=Selector   -> app namespace MUST carry the selector labels shown above"

h "4) Node topology  ->  topologySpreadConstraints"
say_or "$($K get nodes --no-headers \
  -o custom-columns='NODE:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone' 2>/dev/null)" \
  "UNREACHABLE"
ZONES="$($K get nodes -o jsonpath='{.items[*].metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null \
  | tr ' ' '\n' | grep -v '^$' | sort -u)"
echo "  distinct zones : $(tr '\n' ' ' <<<"${ZONES}")"
echo "  count          : $(grep -c . <<<"${ZONES}" || true)  -> 2+ makes zone spread meaningful (maxSkew: 1)"

h "5) Gateway drain window  ->  preStop sleep"
say_or "$($K -n "${GW_NS}" get deploy,daemonset --no-headers \
  -o custom-columns='KIND:.kind,NAME:.metadata.name,GRACE:.spec.template.spec.terminationGracePeriodSeconds' 2>/dev/null)" \
  "nothing in ${GW_NS} — set GATEWAY_NAMESPACE=<ns> and re-run, or find where the gateway runs"
echo "  -> preStop sleep must cover 'pod Terminating' until 'gateway stops sending traffic'."
echo "     With endpoint-based routing that is readiness periodSeconds x failureThreshold."

h "7) Scheduling / placement conventions  ->  nodeSelector, tolerations, priorityClassName"
echo "  -- node pools (are there distinct pools to select between?)"
say_or "$($K get nodes --no-headers -o custom-columns=\
'NODE:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,CAPACITY:.metadata.labels.eks\.amazonaws\.com/capacityType,POOL:.metadata.labels.eks\.amazonaws\.com/nodegroup' 2>/dev/null)" \
  "UNREACHABLE"
echo "  -- node taints (a taint means workloads MUST tolerate it to land there)"
say_or "$($K get nodes --no-headers -o custom-columns='NODE:.metadata.name,TAINTS:.spec.taints' 2>/dev/null \
  | grep -v '<none>')" "no taints on any node"
echo "  -- nodes per zone (>1 per zone means a hostname spread constraint adds something)"
say_or "$($K get nodes -o jsonpath='{.items[*].metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null \
  | tr ' ' '\n' | grep -v '^$' | sort | uniq -c)" "UNREACHABLE"
echo "  -- PriorityClasses defined on the cluster"
say_or "$($K get priorityclass --no-headers -o custom-columns='NAME:.metadata.name,VALUE:.value,DEFAULT:.globalDefault' 2>/dev/null)" \
  "none beyond the built-ins"
echo "  -- does anything scale the node pool? (Pending pods just stay Pending if not)"
say_or "$($K get deploy,daemonset -A --no-headers 2>/dev/null \
  | grep -iE 'cluster-autoscaler|karpenter' | awk '{print $1, $2}')" "no cluster-autoscaler or Karpenter found"
echo "  -- what OTHER teams' workloads already do (the platform's real convention)"
say_or "$($K get deploy -A -o jsonpath='{range .items[*]}{.metadata.namespace}{\"/\"}{.metadata.name}{\" nodeSelector=\"}{.spec.template.spec.nodeSelector}{\" tolerations=\"}{.spec.template.spec.tolerations}{\" priorityClass=\"}{.spec.template.spec.priorityClassName}{\"\n\"}{end}' 2>/dev/null \
  | grep -vE 'nodeSelector= tolerations= priorityClass=$' | head -25)" \
  "no Deployment uses nodeSelector/tolerations/priorityClassName"
echo "  -> If there is one homogeneous pool, no taints and nobody uses these fields, the charts"
echo "     should NOT expose them. If pools differ or other teams use them, they must."

h "8) Secret rotation  ->  does anything already reload pods on Secret change?"
say_or "$($K get deploy,daemonset -A --no-headers 2>/dev/null \
  | grep -iE 'reloader|stakater|wave' | awk '{print $1, $2}')" "no Reloader-style controller found"
echo "  -> ExternalSecret updates the Secret, but envFrom only injects at pod start, so a rotated"
echo "     credential does nothing until the next deploy unless something restarts the pods."

h "6) expectedKubeContext / awsAccountId  ->  NOT obtainable from any workstation"
echo "  '${CTX}' is THIS machine's kubeconfig alias; the deploy agent has its own name."
echo "  Take expectedKubeContext from a Deploy_<tier> pipeline log line: 'kubectl context: <name>'"
echo "  Take awsAccountId from the deploy pool's sts get-caller-identity (must match the cluster account)."

h "contexts available here"
say_or "$(kubectl config get-contexts -o name 2>/dev/null)" "none"

printf '\nRecord the findings in platform/areas/<area>.yml / charts, then re-run ./tests/chart-invariants.sh\n'
