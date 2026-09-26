#!/usr/bin/env bash
# Read-only evidence for the Kargo/Argo delivery path.
#
# Answers, in one run, the questions an operator actually asks:
#   Which Git SHA produced this Freight?   Which digest is it?
#   Which Stage is it in?                  Which digest does each Stage run?
#   Which Promotion moved it?              Is the Argo Application Healthy?
#
# Usage: ./scripts/kargo-argo-evidence.sh [kargo-project] [freight-name-or-alias]
#   ./scripts/kargo-argo-evidence.sh                       # defaults below
#   ./scripts/kargo-argo-evidence.sh pt-kargo-web 4cc69dc  # trace one Freight
set -Eeuo pipefail

PROJECT="${1:-pt-kargo-web}"
FREIGHT="${2:-}"
APP_PREFIX="${APP_PREFIX:-${PROJECT}}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"

for c in kubectl jq; do
  command -v "$c" >/dev/null 2>&1 || { echo "missing required tool: $c" >&2; exit 1; }
done

hr() { printf '\n== %s ==\n' "$1"; }

hr "warehouses (${PROJECT})"
kubectl -n "${PROJECT}" get warehouses -o json | jq -r '
  .items[] |
  "warehouse: \(.metadata.name)\n  ready: \((.status.conditions // [] | map(select(.type=="Ready")) | .[0].status) // "?") (\((.status.conditions // [] | map(select(.type=="Ready")) | .[0].reason) // "?"))\n  subscriptions: \([.spec.subscriptions[]?.image.repoURL] | join(", "))\n  discovered: \((.status.discoveredArtifacts.images // []) | length) image stream(s)"'

hr "freight (digest ← git SHA ← warehouse)"
# The image tag is the ADO CI tag = Build.SourceVersion = the Git SHA that produced it.
kubectl -n "${PROJECT}" get freight -o json | jq -r '
  .items
  | sort_by(.metadata.creationTimestamp)
  | .[]
  | "freight: \(.metadata.name)\n  alias: \(.alias // "-")\n  created: \(.metadata.creationTimestamp)\n  origin: \(.origin.kind)/\(.origin.name)\n"
    + ( [ .images[]? | "  image: \(.repoURL)\n    digest: \(.digest)\n    gitSha(tag): \(.tag)" ] | join("\n") )'

hr "stages (what each environment actually runs)"
kubectl -n "${PROJECT}" get stages -o json | jq -r '
  .items[] |
  "stage: \(.metadata.name)\n"
  + "  upstream: \(if (.spec.requestedFreight[0].sources.direct // false) then "Warehouse (direct)" else ((.spec.requestedFreight[0].sources.stages // []) | join(",")) end)\n"
  + "  current freight: \(.status.freightSummary // "-")\n"
  + "  digest: \([ (.status.freightHistory // [])[0].items[]?.images[]?.digest ] | first // "-")\n"
  + "  gitSha(tag): \([ (.status.freightHistory // [])[0].items[]?.images[]?.tag ] | first // "-")\n"
  + "  health: \(.status.health.status // "-")\n"
  + "  ready: \((.status.conditions // [] | map(select(.type=="Ready")) | .[0].status) // "?") (\((.status.conditions // [] | map(select(.type=="Ready")) | .[0].reason) // "?"))\n"
  + "  verified: \((.status.conditions // [] | map(select(.type=="Verified")) | .[0].status) // "?")\n"
  + "  last verification: \([ (.status.freightHistory // [])[0].verificationHistory[]? | "\(.phase) @ \(.finishTime // .startTime)" ] | last // "-")\n"
  + "  last promotion: \(.status.lastPromotion.name // "-") (\(.status.lastPromotion.status.phase // "-"))"'

hr "promotions (who moved what, newest first)"
kubectl -n "${PROJECT}" get promotions -o json | jq -r '
  .items
  | sort_by(.metadata.creationTimestamp) | reverse
  | .[]
  | "\(.metadata.creationTimestamp)  stage=\(.spec.stage)  freight=\(.spec.freight)  phase=\(.status.phase // "-")"'

hr "argo cd applications"
kubectl -n "${ARGOCD_NS}" get applications -o json | jq -r --arg p "${APP_PREFIX}" '
  .items[] | select(.metadata.name | startswith($p)) |
  "application: \(.metadata.name)\n"
  + "  authorized stage: \(.metadata.annotations["kargo.akuity.io/authorized-stage"] // "NONE — any stage could write this app")\n"
  + "  project: \(.spec.project)\n"
  + "  sync: \(.status.sync.status // "-")   health: \(.status.health.status // "-")\n"
  + "  revision: \(.status.sync.revision // "-")\n"
  + "  chart source: \([ .spec.sources[]? | select(.path != null) | "\(.repoURL)@\(.targetRevision) path=\(.path)" ] | join(", "))\n"
  + "  values source: \([ .spec.sources[]? | select(.ref != null) | "\(.repoURL)@\(.targetRevision) ref=\(.ref)" ] | join(", "))\n"
  + "  last sync: \(.status.operationState.finishedAt // "-") \(.status.operationState.phase // "")"'

hr "running workloads (digest actually pulled by the kubelet)"
for ns in $(kubectl -n "${ARGOCD_NS}" get applications -o json \
              | jq -r --arg p "${APP_PREFIX}" '.items[] | select(.metadata.name|startswith($p)) | .spec.destination.namespace' | sort -u); do
  kubectl -n "${ns}" get deploy -o json 2>/dev/null | jq -r --arg ns "${ns}" '
    .items[] |
    "namespace: \($ns)\n  deployment: \(.metadata.name)  ready=\(.status.readyReplicas // 0)/\(.status.replicas // 0)\n"
    + "  spec image: \(.spec.template.spec.containers[0].image)"'
  kubectl -n "${ns}" get pods -o json 2>/dev/null | jq -r '
    .items[] | "  pod \(.metadata.name): \([.status.containerStatuses[]?.imageID] | join(" "))"'
done

if [[ -n "${FREIGHT}" ]]; then
  hr "trace freight ${FREIGHT}"
  FULL="$(kubectl -n "${PROJECT}" get freight -o json \
    | jq -r --arg f "${FREIGHT}" '.items[] | select((.metadata.name|startswith($f)) or (.alias == $f)) | .metadata.name' | head -1)"
  if [[ -z "${FULL}" ]]; then
    echo "no freight matching '${FREIGHT}'"
  else
    kubectl -n "${PROJECT}" get freight "${FULL}" -o json | jq -r '
      "freight: \(.metadata.name) (\(.alias // "-"))\n"
      + ( [ .images[]? | "  \(.repoURL)@\(.digest)  gitSha(tag)=\(.tag)" ] | join("\n") )
      + "\n  verified in: \((.status.verifiedIn // {}) | keys | join(", ") // "none")"
      + "\n  approved for: \((.status.approvedFor // {}) | keys | join(", ") // "none")"'
    echo "  promotions carrying this freight:"
    kubectl -n "${PROJECT}" get promotions -o json | jq -r --arg f "${FULL}" '
      .items[] | select(.spec.freight == $f)
      | "    \(.metadata.name)  stage=\(.spec.stage)  phase=\(.status.phase // "-")"'
  fi
fi

hr "correlation summary"
echo "Git SHA  ⇢ ECR tag (ADO Container stage tags with Build.SourceVersion)"
echo "ECR tag  ⇢ digest (ECR IMMUTABLE; crane digest recorded in image-provenance.json)"
echo "digest   ⇢ Freight (Kargo Warehouse; digest IS the Freight identity)"
echo "Freight  ⇢ Stage (Promotion) ⇢ values.yaml image.digest (Git) ⇢ Argo CD ⇢ kubelet imageID"
