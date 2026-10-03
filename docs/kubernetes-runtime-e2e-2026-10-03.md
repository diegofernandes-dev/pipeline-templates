# Kubernetes runtime E2E — 2026-10-03

Focused runtime proof of the platform Kubernetes core on EKS proving-ground `sample-template-pg`.

| Field | Value |
|-------|-------|
| tested repository SHA (initial) | `4a9deca9653391797ef796711974c49922f5d910` |
| tested repository SHA (HPA/PVC retest) | `0a3c77a94780f30d43c4c2fdab1a28be26e4c4a6` (docs-only delta since `4a9deca`; no chart/template/script changes) |
| tested templates ref (ADO recovery) | `refs/tags/v5.3.1` (product unchanged; infra agent bootstrap only) |
| asa-application | `5.3.1` |
| asa-scheduled-job | `4.3.0` |
| cluster | `sample-template-pg` (us-east-1, account `448003890252`) |
| Kubernetes | server `v1.36.3-eks-cb19647` / nodes `v1.36.4-eks-3b4a6ca` |
| date (UTC) | `2026-10-03` |
| platform-ci | contracts **PASS** + apply-dryrun **PASS** on retest SHA ([run 37094118354](https://github.com/diegofernandes-dev/pipeline-templates/actions/runs/37094118354)) |
| Product changes | **NONE** |
| Final verdict | **ALL GREEN** (algorithm + ADO helm-deploy recovery path) |

Namespaces used: `asa-runtime-e2e`, `asa-psa-e2e` (initial); `asa-hpa-pvc-e2e` (HPA/PVC retest); `asa-helm-rec-ado-e2e` (ADO recovery). Temporary NGINX Gateway Fabric release `ngf-e2e` in `asa-infra-nginx-gateway` (gRPC only; removed). ADO canary pipeline `helm-rec-ado-e2e` (id 20) on `pt-v3-scenarios` branch `e2e/helm-recovery-ado`.

### Test inventory

| # | Capability | Method | Result |
|---|------------|--------|--------|
| R1 | HPA scale-up / scale-down | Chart canary `hpa-e2e` + live CPU burn after metrics-server addon | GREEN |
| R2 | PVC persist across pod replace | Chart canary `pvc-e2e` + gp2 / aws-ebs-csi-driver IRSA | GREEN |
| R3 | CronJob controller schedule | Chart `asa-scheduled-job` `cron-e2e`; controller-created Jobs | GREEN |
| R4 | gRPC via Service + Gateway | Chart `workload.type=grpc` + ephemeral h2c image + grpcurl | GREEN |
| R5 | PDB eviction | Eviction API against `web-e2e` (maxUnavailable=1) | GREEN |
| R6 | TopologySpread zones | Two pods across `us-east-1a` / `us-east-1b` | GREEN |
| R7 | PSA restricted admit | Namespace enforce=restricted; Application + ScheduledJob | GREEN |
| R8 | Helm recovery algorithm | Local script mirroring `helm-deploy.yml` rollback | GREEN |
| R9 | Helm recovery pipeline | ADO builds [310](https://dev.azure.com/diegolab/platform-engineering/_build/results?buildId=310) → [311](https://dev.azure.com/diegolab/platform-engineering/_build/results?buildId=311) via real `helm-deploy.yml` | GREEN |

---

## Environment

### Initial (morning)

```text
Repository SHA: 4a9deca9653391797ef796711974c49922f5d910
asa-application: 5.3.1
asa-scheduled-job: 4.3.0
EKS: sample-template-pg (us-east-1)
Kubernetes: v1.36.3-eks-cb19647
Nodes: 2
Zones: us-east-1a, us-east-1b
Metrics API: NOT AVAILABLE (/apis/metrics.k8s.io/v1beta1 → NotFound; kubectl top fails)
StorageClass: gp2 (provisioner kubernetes.io/aws-ebs, WaitForFirstConsumer; CSIMigration targets ebs.csi.aws.com)
CSI: efs.csi.aws.com present; aws-ebs-csi-driver ABSENT (EKS addon missing)
Gateway implementation: NGINX Gateway Fabric 1.6.2 (temporary install for this round) + Gateway API CRDs v1.1.0
```

### Remediation (afternoon retest) — infrastructure only

```text
metrics-server:
  mechanism: EKS managed addon
  version: v0.9.0-eksbuild.11
  namespace: kube-system
  source: aws eks create-addon (compatible version from describe-addon-versions for k8s 1.36)
  insecure TLS flags: NONE

aws-ebs-csi-driver:
  mechanism: EKS managed addon
  version: v1.66.0-eksbuild.1
  identity: IRSA
  IAM role: arn:aws:iam::448003890252:role/AmazonEKS_EBS_CSI_DriverRole_sample-template-pg
  IAM policy: arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
  SA annotation: kube-system/ebs-csi-controller-sa → role above

StorageClass: gp2 marked default (annotation storageclass.kubernetes.io/is-default-class=true)
CSIDriver: ebs.csi.aws.com + efs.csi.aws.com
Metrics API: /apis/metrics.k8s.io/v1beta1 OK; kubectl top nodes/pods OK
```

Addons **left installed** on proving-ground (legitimate platform prerequisites).

---

## Final matrix

```text
HPA                     GREEN
PVC                     GREEN
CronJob                 GREEN
gRPC                    GREEN
PDB                     GREEN
TopologySpread          GREEN
PSA restricted          GREEN
Helm recovery algorithm GREEN
Helm recovery pipeline  GREEN
```

---

## HPA

### Initial result

```text
Status: ENVIRONMENT BLOCKER
metrics.k8s.io unavailable; HPA cpu <unknown>
```

### HPA retest (after metrics-server)

```text
metrics-server:
version: v0.9.0-eksbuild.11

metrics API: GREEN
  kubectl get --raw /apis/metrics.k8s.io/v1beta1 → APIResourceList
  kubectl top nodes → data
  kubectl top pods → data
  no --kubelet-insecure-tls

Chart canary: asa-application release hpa-e2e in asa-hpa-pvc-e2e
  workload.type=web
  autoscaling minReplicas=1 maxReplicas=3 cpu.target=50
  CPU request (pod): 150m

Before load:
CPU: 0% (1m) / 50%
currentReplicas: 1
desiredReplicas: 1
AbleToScale: True (ReadyForNewScale)
ScalingActive: True (ValidMetricFound)
ScalingLimited: True (TooFewReplicas — below-min recommendation clamped)

Under load (in-pod busy loops via live kubectl exec session):
CPU: 433% (650m) / 50%
currentReplicas: 3
desiredReplicas: 3
Deployment ready: 3/3
Event: SuccessfulRescale New size: 3; reason: cpu resource utilization above target

After load removed (~331s including HPA scale-down stabilization window):
CPU: 0% (1m) / 50%
currentReplicas: 1
desiredReplicas: 1
Events: New size: 2 → New size: 1; reason: All metrics below target

Scale-up: PASS (1 → 3)
Scale-down: PASS (3 → 1)

Final status: GREEN
```

---

## PVC

### Initial result

```text
Status: ENVIRONMENT BLOCKER
aws-ebs-csi-driver absent; PVC Pending waiting for ebs.csi.aws.com
```

### PVC retest (after EBS CSI)

```text
aws-ebs-csi-driver:
version: v1.66.0-eksbuild.1
identity: IRSA (AmazonEKS_EBS_CSI_DriverRole_sample-template-pg + AmazonEBSCSIDriverPolicy)

Chart canary: asa-application release pvc-e2e
  persistence.mountPath=/data size=1Gi storageClassName=gp2
  autoscaling: false
  replicaCount: 1
Confirmed: strategy Recreate; HPA absent; RWO

PVC: pvc-e2e-data
PV: pvc-d3bd9005-6f82-4ac0-8428-947ae132b45c
StorageClass: gp2
capacity: 1Gi
accessMode: ReadWriteOnce
zone: us-east-1a

Bound: PASS
Mounted: PASS (/dev/nvme1n1 on /data)
Write marker: PASS (asa-pvc-e2e-20261003041040-0a3c77a)
Pod replacement: PASS
  old: pvc-e2e-84b8694889-p27pc uid=229711e9-2751-4c6b-8fa9-838d222a9137
  new: pvc-e2e-84b8694889-qj9jh uid=8b33c0a6-dbee-4a56-9043-c0e59335488c
Read persisted marker: PASS (exact match)
Recreate rollout (annotation patch): PASS; no Multi-Attach / FailedAttachVolume errors; marker survived
resource-policy keep: PASS (helm uninstall retained PVC; then manual PVC delete removed PV/EBS — no orphan volumes)

Final status: GREEN
```

---

## CronJob

```text
Status: GREEN

Schedule: */2 * * * *
TimeZone: America/Sao_Paulo
lastScheduleTime: 2026-10-03T03:38:00Z (and prior ticks 29849968/70/72/…)

Job: cron-e2e-29849978 (example)
ownerReference: kind=CronJob name=cron-e2e controller=true
Pod: completed
exit / logs: job-canary-ok (succeeded=1)

Proof: CronJob controller scheduled Jobs automatically (not kubectl create job --from).
Chart: asa-scheduled-job with execution.command ["sh","-c","echo job-canary-ok && exit 0"].
```

---

## gRPC

```text
Status: GREEN

Gateway: d-asa-com-br-internal-gateway (asa-infra-nginx-gateway)
  address: a55c1882f86f44e41ba397041627303a-1583331399.us-east-1.elb.amazonaws.com
GRPCRoute: grpc-e2e
Accepted: True
ResolvedRefs: True

Service: grpc-e2e:8080 (appProtocol kubernetes.io/h2c)
Endpoint: ready pod on chart Deployment

Client: grpcurl (in-cluster + external via Gateway Host authority)
Method: grpc.health.v1.Health/Check
Response: {"status":"SERVING"} via Service AND via Gateway

Notes:
- Lab image pt-v3-grpc:* speaks HTTP/1.1 JSON only (not gRPC) — unsuitable for this proof.
- Ephemeral linux/amd64 image runtime-e2e-grpc (UID 1654, distroless) used as test workload only; not a product change.
- Chart path: kind=Application workload.type=grpc + probes readiness/startup enabled.
```

---

## PDB

```text
Status: GREEN

Replicas: 2 (web-e2e, autoscaling.minReplicas=2)
PDB: web-e2e
maxUnavailable: 1
unhealthyPodEvictionPolicy: AlwaysAllow (chart)

Before eviction:
currentHealthy: 2
desiredHealthy: 1
disruptionsAllowed: 1
expectedPods: 2

Eviction:
POST /api/v1/namespaces/asa-runtime-e2e/pods/<pod>/eviction → HTTP 201 Success
(not kubectl delete pod)

After:
Deployment replaced evicted pod; currentHealthy returned to 2; capacity preserved under maxUnavailable=1
```

---

## TopologySpread

```text
Status: GREEN

Node → AZ inventory:
ip-172-31-5-233.ec2.internal → us-east-1a
ip-172-31-87-81.ec2.internal → us-east-1b

Pod web-e2e-645989d4b8-zx7r4:
node: ip-172-31-5-233.ec2.internal
zone: us-east-1a

Pod web-e2e-645989d4b8-vlfjm (representative after PDB churn; always one pod per zone observed):
node: ip-172-31-87-81.ec2.internal
zone: us-east-1b

Constraint:
maxSkew: 1
topologyKey: topology.kubernetes.io/zone
whenUnsatisfiable: ScheduleAnyway
```

---

## PSA restricted

```text
Status: GREEN

Namespace: asa-psa-e2e
enforce: restricted
enforce-version: v1.33

Application admitted: YES (psa-web-e2e Deployment/Pod Running)
ScheduledJob admitted: YES (CronJob psa-job-e2e; Jobs/Pods Completed including controller-scheduled and manual --from)

Admission errors: none (no FailedCreate / PSA deny events)
```

---

## Helm recovery

### Algorithm (initial round — still valid)

```text
Status: GREEN (algorithm)

Healthy revision: 1 (deployed, image …:86cc2ec7f0cbd8a44650ca15204f36abd4be1c5e)
Failed revision: 2 (failed — nonexistent tag does-not-exist-e2e-recovery; ImagePullBackOff)

Failure injected: bad image tag on helm upgrade --wait (canary-only)
Observed Helm status after failure: release status failed; rev1 still deployed

Recovery action: helm_rollback_to_last_deployed() — same logic as templates/dotnet/helm-deploy.yml
  (select last history entry with status==deployed via mikefarah yq .[-1]; helm rollback --wait)
Rollback target: 1

Final Helm revision: 3 (Rollback to 1 → deployed)
Final workload health: readyReplicas=1, image restored to healthy tag

Operation exit: failure (script/pipeline semantics exit 1 after recovery)
Uninstall executed: NO
```

### Helm recovery integration retest (ADO / real helm-deploy)

```text
Execution path:
  ADO pipeline helm-rec-ado-e2e (definition id 20)
  → extends templates/dotnet/ci.yml@templates ref refs/tags/v5.3.1
  → Deploy develop → templates/dotnet/helm-deploy.yml
  consumer: pt-v3-scenarios branch e2e/helm-recovery-ado
  applicationName: helm-rec-ado-e2e (worker; isolated namespace asa-helm-rec-ado-e2e)

Infra precondition (resolved before retest):
  PG-AWS-EKS agent tenv3-local-agent bootstrap ConfigMap tenv3-agent-bootstrap
  reconfigured to aws eks update-kubeconfig → context sample-template-pg
  (agent still runs on Rancher Desktop; targets EKS proving-ground API with ambient AWS creds)
  Source: infra-agents/k8s/proving-ground-agent-bootstrap.yaml (applied live)

Build 309 (20261003.1) — pre-fix:
  kubectl context: tenv3-local → fail-closed (expectedKubeContext mismatch). ENVIRONMENT BLOCKER.

Build 310 (20261003.2) — healthy deploy:
  source: 124addf95203265e27cb0a55a806779707b3d20a
  kubectl context: sample-template-pg (exact match)
  sts account matches 448003890252
  shared ECR image present
  Helm revision 1 deployed; readyReplicas=1
  image: …/helm-rec-ado-e2e:124addf95203265e27cb0a55a806779707b3d20a
  Pipeline result: Succeeded

Build 311 (20261003.3) — failed upgrade + recovery:
  source: 612812890cfc2b2db26a11f61e19203440198529
  Failure injected: consumer Program.cs Environment.Exit(1) before host start
    (real build→ECR→helm-deploy path; not a product bypass / not skipping ECR preflight)
  Failed upgrade observed: YES — helm upgrade --wait → CrashLoopBackOff → context deadline exceeded
  Failed revision: 2 (status failed)
  Automatic rollback observed: YES — "Attempting rollback… Rolling back to deployed revision 1"
  Final Helm revision: 3 (Rollback to 1 → deployed)
  Workload restored: readyReplicas=1; image restored to …:124addf95203265e27cb0a55a806779707b3d20a
  Pipeline result: FAILED (required semantics after recovery)
  Uninstall executed: NO

Algorithm: GREEN
Pipeline integration: GREEN
```

---

## Findings

### Finding 1 — metrics-server missing — RESOLVED

```text
Remediation: EKS addon metrics-server v0.9.0-eksbuild.11 installed
Retest: HPA scale-up + scale-down GREEN
```

### Finding 2 — EBS CSI missing — RESOLVED

```text
Remediation: EKS addon aws-ebs-csi-driver v1.66.0-eksbuild.1 + IRSA
Retest: PVC Bound→persist GREEN; EBS volume cleaned after PVC delete
```

### Finding 3 — pt-v3-grpc image is not gRPC

```text
Finding: ECR image pt-v3-grpc responds HTTP/1.1 JSON; fails HTTP/2/gRPC clients
Component: Test workload (not chart)
Severity: low for platform (workaround used)
Expected: h2c gRPC on 8080
Observed: curl HTTP/1.1 200; curl --http2-prior-knowledge fails; grpcurl timeout
Evidence: netprobe/h2probe against grpc-e2e Service before image swap
Root cause: consumer/lab image mismatch vs workload.type=grpc contract
Product / Infrastructure / Test workload: Test workload
Fix required: none in pipeline-templates; fix consumer image separately if still used
Retest required: none for platform (GREEN achieved with ephemeral runtime-e2e-grpc)
```

### Finding 4 — ADO agent kube context mismatch — RESOLVED

```text
Finding: PG-AWS-EKS agent could not satisfy expectedKubeContext for lab/develop
Component: Helm recovery pipeline integration (environment / agent)
Severity: was blocking ADO path against sample-template-pg with v5.3.1/main
Expected: agent kubectl context == sample-template-pg
Observed (before): tenv3-local (in-cluster Rancher kubeconfig)
Observed (after): sample-template-pg via agent bootstrap aws eks update-kubeconfig
Evidence: ADO builds 310 (healthy Succeeded) + 311 (failed upgrade → rollback → Failed)
Root cause: proving-ground agent bootstrap ConfigMap pointed at local Rancher API (10.43), not EKS
Product / Infrastructure / Test workload: Infrastructure (agent) — Product changes NONE
Fix applied: ConfigMap tenv3-agent-bootstrap → EKS sample-template-pg; persisted under
  infra-agents/k8s/proving-ground-agent-bootstrap.yaml; agent rollout restarted
Retest: GREEN (see Helm recovery integration retest)
```

---

## Teardown

Performed after evidence capture:

**Initial round:** Helm uninstall `web-e2e`, `grpc-e2e`, `cron-e2e`, `helm-rec-e2e`, `psa-web-e2e`, `psa-job-e2e`, `ngf-e2e`; delete namespaces `asa-runtime-e2e`, `asa-psa-e2e`, Gateway + `asa-infra-nginx-gateway`.

**Retest round:** Helm uninstall `hpa-e2e`, `pvc-e2e`; delete PVC `pvc-e2e-data` (PV/EBS removed); delete namespace `asa-hpa-pvc-e2e`. No orphan EBS volumes remaining.

**Helm recovery ADO round:** Helm uninstall `helm-rec-ado-e2e`; delete namespace `asa-helm-rec-ado-e2e`. Consumer branch restored to healthy `Program.cs` after crash canary (commit history retains crash + restore).

**Preserved on proving-ground:** EKS cluster; metrics-server addon; aws-ebs-csi-driver addon + IRSA role; gp2 StorageClass (now default); EFS CSI; Gateway API CRDs; PG-AWS-EKS agent bootstrap targeting `sample-template-pg`.

---

## Addendum — target identity fail-closed + capability preflight

```text
Date: post lab teardown (EKS sample-template-pg destroyed)
Product: scripts/preflight-deploy-target.sh + helm-deploy/delivery wiring
Chart semantics: unchanged

Target identity:
  missing expectedKubeContext → FAIL (DeployContract + deploy)
  missing awsAccountId → FAIL
  mismatch → FAIL
  exact match → PASS
  Regression: null warn-and-continue removed

Capability preflight (render-driven):
  HPA rendered + metrics.k8s.io absent → FAIL before helm upgrade
  PVC rendered + SC/CSI missing → FAIL before helm upgrade
  No HPA/PVC in render → checks skipped
  AWS EBS migration: kubernetes.io/aws-ebs → require CSIDriver ebs.csi.aws.com

Harness: tests/deploy-target-preflight.sh (fake kubectl) GREEN
ADO canary: EXTERNAL BLOCKER — proving-ground EKS no longer present
Prior ADO evidence (builds 310/311) remains valid for mismatch fail-closed + recovery
```

---

## Release

```text
release required: YES
candidate: v5.3.2
tag created: NO
```

Includes: target identity fail-closed, render-driven capability preflight, default StorageClass ambiguity fail-closed, CSI NotFound vs RBAC diagnostics. Chart versions unchanged (template/script release only).