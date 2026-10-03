# Kubernetes runtime E2E — 2026-10-03

Focused runtime proof of the platform Kubernetes core on EKS proving-ground `sample-template-pg`.

| Field | Value |
|-------|-------|
| tested repository SHA | `4a9deca9653391797ef796711974c49922f5d910` |
| asa-application | `5.3.1` |
| asa-scheduled-job | `4.3.0` |
| cluster | `sample-template-pg` (us-east-1, account `448003890252`) |
| Kubernetes | server `v1.36.3-eks-cb19647` / nodes `v1.36.4-eks-3b4a6ca` |
| date (UTC) | `2026-10-03` |
| platform-ci | contracts **PASS** + apply-dryrun **PASS** on SHA ([run 37091256700](https://github.com/diegofernandes-dev/pipeline-templates/actions/runs/37091256700)) |
| Product changes | **NONE** |

Namespaces used: `asa-runtime-e2e`, `asa-psa-e2e`. Temporary NGINX Gateway Fabric release `ngf-e2e` in `asa-infra-nginx-gateway` (installed only for gRPC; removed at teardown).

---

## Environment

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

---

## Final matrix

```text
HPA             ENVIRONMENT BLOCKER
PVC             ENVIRONMENT BLOCKER
CronJob         GREEN
gRPC            GREEN
PDB             GREEN
TopologySpread  GREEN
PSA restricted  GREEN
Helm recovery   GREEN
```

---

## HPA

```text
Status: ENVIRONMENT BLOCKER

CPU request: 150m (from chart resources.requests.cpu on web-e2e pods)
min: 2
max: 3
target: 50

Before: HPA object rendered and applied (AbleToScale/SucceededGetScale True) but cpu metric <unknown>
Peak / After / Scale-up / Scale-down: NOT OBSERVED — metrics.k8s.io unavailable

Evidence:
- kubectl get --raw /apis/metrics.k8s.io/v1beta1 → NotFound
- kubectl top nodes → Metrics API not available
- metrics-server EKS addon absent
- HPA web-e2e exists with target CPU 50% but cannot scale without metrics
```

---

## PVC

```text
Status: ENVIRONMENT BLOCKER

StorageClass: gp2
Provisioner: kubernetes.io/aws-ebs (events show external provisioner ebs.csi.aws.com via CSIMigration)
Binding mode: WaitForFirstConsumer

PVC probe (pvc-probe-e2e + consumer pod):
- selected-node assigned
- ExternalProvisioning: Waiting for volume from ebs.csi.aws.com
- CSIDriver ebs.csi.aws.com: missing (only efs.csi.aws.com installed)
- STATUS remained Pending — no Bound, no mount/write/recreate proof possible

Recreate strategy / resource-policy keep: chart contract unchanged (not exercised live)
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

```text
Status: GREEN

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

---

## Findings

### Finding 1 — metrics-server missing

```text
Finding: metrics.k8s.io unavailable on proving-ground
Component: HPA (environment)
Severity: blocks scale proof only
Expected: metrics API for CPU HPA
Observed: NotFound; HPA cpu <unknown>
Evidence: kubectl get --raw /apis/metrics.k8s.io/v1beta1; missing metrics-server addon
Root cause: cluster addon not installed after prior lab teardown
Product / Infrastructure / Test workload: Infrastructure
Fix required: install metrics-server (EKS addon) on sample-template-pg
Retest required: HPA scale-up + scale-down only
```

### Finding 2 — EBS CSI missing

```text
Finding: gp2 volumes cannot provision (ebs.csi.aws.com absent)
Component: PVC (environment)
Severity: blocks persistence proof
Expected: PVC Bound via gp2
Observed: Pending / ExternalProvisioning waiting for ebs.csi.aws.com
Evidence: PVC events; CSIDriver list shows only efs.csi.aws.com; aws-ebs-csi-driver addon missing
Root cause: EBS CSI driver not installed
Product / Infrastructure / Test workload: Infrastructure
Fix required: install aws-ebs-csi-driver (+ node IAM for EC2 volumes)
Retest required: PVC Bound→write→recreate→read only
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

---

## Teardown

Performed after evidence capture:

- Helm uninstall: `web-e2e`, `grpc-e2e`, `cron-e2e`, `helm-rec-e2e`, `psa-web-e2e`, `psa-job-e2e`, `ngf-e2e`
- Delete namespaces `asa-runtime-e2e`, `asa-psa-e2e`
- Delete Gateway `d-asa-com-br-internal-gateway` and namespace `asa-infra-nginx-gateway` contents from this round
- Preserved: EKS cluster, nodes, StorageClasses, EFS CSI, Gateway API CRDs already on cluster

---

## Release

```text
release required: NO
new tag created: NO
v5.3.1 unchanged
```
