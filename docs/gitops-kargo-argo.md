# Delivery architecture — Azure DevOps CI + ECR + Kargo + Argo CD + Helm

Status: **proving ground**. The direct-Helm path (`deliveryMode: helm`) is still the
default and must stay until the slice below is accepted.

## Division of authority

```text
Azure DevOps   = CI (build and test, build the image once)
ECR            = artifact registry (IMMUTABLE tags, digest = identity)
Kargo          = artifact promotion (owns the lifecycle AFTER the build)
Argo CD        = Kubernetes deployment / reconciliation
Helm           = the existing Kubernetes contract (charts/asa-application, unchanged)
```

Azure DevOps stops at the ECR push. It does not promote, does not deploy, does not
decide what "the next environment" is. That authority is Kargo's.

## Two lifecycles, not one

### Git lifecycle (application source)

```text
feat/* ─┐
fix/*  ─┴─ PR ──► main
```

`main` is the only branch that produces artifacts. There is **no** `develop`,
`homolog`, `production` or `release/*` branch in an application repository.
A branch is never an environment.

### Artifact lifecycle (after the build)

```text
ADO CI (build once)
   │
   ▼
ECR image digest ──► Kargo Warehouse ──► Freight
                                           │
                                           ├─► develop
                                           │      │
                                           │      ▼
                                           │   homolog
                                           │      │
                                           │      ▼
                                           │   release      (not implemented yet)
                                           │      │
                                           │      ▼
                                           └─► production   (not implemented yet)
```

Freight identity is the **image digest**. The ADO build id and the Git SHA are
provenance recorded alongside it (`image-provenance.json`, and the ECR tag is the
Git SHA), never the identity.

### Deployment

```text
Kargo Promotion ──► writes image.digest into the GitOps repo ──► Argo CD ──► EKS
```

## Application source branches ≠ GitOps stage branches

| | Repository | Branches | What a branch means |
|---|---|---|---|
| Application source | the app repo (e.g. `pt-v3-scenarios`) | `feat/*`, `fix/*`, `main` | a change to the code |
| Desired state | the GitOps repo (e.g. `d0-gitops-sandbox`) | `asa/desired-state` (stages are paths) | the state a cluster should converge to |

If a future design prefers `stage/develop` and `stage/homolog` **branches**, those
branches belong to the **GitOps repository**. Creating them in an application
repository would put environments back into the source branch model, which is the
thing this pivot removes.

## Where each concern lives

| Concern | Owner | Location |
|---|---|---|
| build, test, image | Azure DevOps CI | `templates/dotnet/ci.yml` + `container-build.yml` |
| image identity | ECR | digest (tags are IMMUTABLE, tag = Git SHA) |
| "which artifact may advance" | Kargo | `Warehouse`, `Freight`, `Stage`, `PromotionTemplate`, `verification` |
| "what the cluster should run" | GitOps repo | `asa-kargo-web/stages/<env>/values.yaml` |
| "make the cluster match" | Argo CD | one `Application` per environment |
| Kubernetes shape | Helm | `charts/asa-application` (read as-is, never copied) |
| application secrets | ESO | `externalSecret` references only — never values in Git |

## Kargo → Argo CD authorization

Two-sided and explicit:

1. The Argo `Application` carries `kargo.akuity.io/authorized-stage: <project>:<stage>`.
   Only that one Stage may act on it.
2. The Kargo Stage names the Application in its `argocd-update` step.

An `AppProject` then limits each Application to its own namespace and to exactly the
resource kinds the chart renders. No Stage can reach another Stage's Application, and
no Application can create cluster-scoped objects.

## Git identities

| Role | Identity | Rights |
|---|---|---|
| promotion (Git **write**) | Kargo — Entra SP `idp-d1-kargo-writer` | write the GitOps repo |
| reconciliation (Git **read**) | Argo CD — Entra SP `idp-d1-argocd-reader` | read the GitOps repo |
| chart read | none (public repo) | read |
| ECR read (Warehouse) | lab ECR token Secret (**temporary**) | read the ECR repo |

Write authority and read authority are different principals. A shared read/write PAT
is not acceptable, in the lab or in production.

## Image pinning in the chart

`charts/asa-application` and `charts/asa-scheduled-job` accept **either**:

```yaml
image:
  repository: <registry>/<repo>
  tag: <git-sha>        # Azure DevOps Helm path (ECR IMMUTABLE)
```

```yaml
image:
  repository: <registry>/<repo>
  digest: sha256:...    # GitOps path — wins over tag
  tag: <git-sha>        # kept for correlation only
```

A malformed digest fails rendering. An image with neither digest nor tag fails
rendering — an unpinned desired state is never deployed.

## Consumer API — removal strategy

The target is a consumer who declares **what** is built, never **where** it runs.

| Public surface today | Status in `deliveryMode: gitops` | Removal precondition |
|---|---|---|
| `deployEnvironments[]` | **rejected** (fail-fast) | none — environments are Kargo Stages |
| `expectedKubeContext` | **rejected** | none — Argo CD owns the cluster target |
| `deployEnvironments[].variableGroups` | gone with `deployEnvironments` | none |
| `deployEnvironments[].containerPool` | gone with `deployEnvironments` | none |
| `deployEnvironments[].helmTimeout` | gone with `deployEnvironments` | none |
| `deployEnvironments[].smokeScheduledJob` | gone with `deployEnvironments` | ScheduledJob slice (not in this round) |
| gateway / cluster / promotion order | never public; platform-derived | — |
| `ECR_PULL_SECRET` variable | still used (lab) | node/kubelet ECR IAM, or ESO-managed pull secret |
| `containerPool` (build pool) | **still required** | a platform-default build pool |
| `runtimeConfigPath` | unused in gitops mode | desired state moved to the GitOps repo |
| `awsRegion` | still public | platform default per account |

Removal order, once the proving ground is accepted:

1. Move the public manifesto schema validation to the GitOps repo CI. **Today the
   gitops path loses the "invalid manifesto fails before the image is pushed" guard
   that `DeployContract` gives the Helm path.** This is the one real regression of
   the slice and must be closed before the Helm path is deleted.
2. Default `containerPool` and `awsRegion` in the template so the consumer omits them.
3. Delete `helm-deploy.yml`, `deployEnvironments`, `expectedKubeContext`,
   `runtimeConfigPath` and the `config/platform-environments.json` pool/context
   mapping — only after (1) and after the same slice passes on real EKS.

No `useDevelop` / `skipDevelop` style flags. A consumer either builds artifacts
(`gitops`) or is still on the legacy path (`helm`).

## Designed to extend, not implemented yet

- **`release` Stage** downstream of `homolog`: collects/applies a version, creates the
  Git tag, retags in OCI, integrates change management, releases production. None of
  those actions may rebuild the image — the digest promoted into `release` must be
  byte-identical to the one built on `main`.
- **SemVer**: a `release` Stage concern, not a CI concern. Azure DevOps run-tag
  versioning is superseded by this design.
- **Hotfix lineage**: the design must support `PRD = Freight A / v1.0.0`,
  `HML = Freight F`, `DEV = Freight K` at the same time, and a hotfix based on
  release `A` producing artifact `A1` → new Freight → validation → patch release.
  Nothing in this slice assumes production equals the head of `main`, and nothing
  couples the Stages' current Freight to each other.
- **production**: not touched in this round.

## Deliberately not built

Backstage, Argo Rollouts deployment strategies (canary, blue/green), generic
`ApplicationSet`, change-management integration, automatic SemVer, a custom
candidate/promotion store, ADO run-tag versioning, environment branches in the app
repo, per-stage rebuilds, chart rewrites, custom CRDs/operators, a generic GitOps
abstraction layer.

Kargo's `AnalysisTemplate`-based verification does use Argo Rollouts CRDs, because
that is how Kargo expresses verification. No `Rollout` object and no progressive
delivery strategy is introduced.
