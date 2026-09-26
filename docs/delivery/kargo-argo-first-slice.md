# Kargo + Argo CD first slice — proving-ground results

**Question under test:** do Kargo + Argo CD solve our promotion lifecycle while keeping a
single build, independent environments and the current ASA chart, without forcing us to
build our own promotion engine?

**Answer so far: CONDITIONAL PASS — architecture accepted, execution incomplete.**
Everything up to the ECR handoff and everything downstream of a pinned digest is proven.
The middle link (Warehouse → Freight → promotion) is implemented and live but has not yet
observed a real image, because the slice's CI is blocked on a lab agent and on one
unreviewed pull request.

Date: 2026-09-26. Scope: `develop → homolog` only. No production, no release Stage,
no Backstage, no SemVer, no hotfix flow.

---

## 1. Baseline found (code, not documentation)

| Aspect | Finding |
|---|---|
| Templates | `templates/dotnet/ci.yml` (`CI → DeployContract → Container → Deploy_*`) + `helm-deploy.yml`, unrolled three times by index over `deployEnvironments[0..2]` |
| Image build | `buildctl` (BuildKit sidecar) + `crane` on self-hosted pool; ECR repository forced `IMMUTABLE`; build skipped when the commit-SHA tag already exists |
| Digest capture | **None.** `crane digest` was used only as an existence probe and never exported |
| Digest → Helm | **Never.** Outputs were `imageRepository` + `imageTag` (`Build.SourceVersion`); the chart rendered `repository:tag`. No `image.digest` existed in either chart |
| `helm upgrade` | inside an ADO `deployment` job bound to an ADO Environment, pool per environment |
| Public infra surface | `deployEnvironments[]` (+ `containerPool`, `variableGroups`, `helmTimeout`, `expectedKubeContext`, `smokeScheduledJob` per entry), `containerPool`, `awsRegion`, `runtimeConfigPath`, `expectedKubeContext`, consumer variable `ECR_PULL_SECRET` |
| Web API path | `kind: Application` + `workload.type: web` → `charts/asa-application` → Deployment / Service:8080 / HTTPRoute / HPA / SA / ConfigMap, namespace `asa-<applicationName>`, hostname and gateway derived from `runtime.environment` |
| Existing tests | `helm lint` ×2, `tests/chart-drift.sh`, `tests/chart-invariants.sh` (433 lines), GitHub Actions `platform-ci` |
| GitOps/Argo/Kargo docs | **none in the repository** before this branch |

Lab discovered (it made real execution possible): Argo CD v3.5.2, Kargo v1.11.4 and Argo
Rollouts already installed; an existing GitOps repository `d0-gitops-sandbox` already read
by Argo CD and written by Kargo through **two different Entra service principals**;
`pipeline-templates` public on GitHub, so Argo CD can read the chart with no credential.

## 2. Architecture implemented

```text
pt-v3-scenarios      feat/* → PR → main                (trunk based, no env branches)
      │
      │  Azure DevOps CI, deliveryMode: gitops — builds ONCE, then stops
      ▼
ECR 448003890252.dkr.ecr.us-east-1.amazonaws.com/pt-kargo-web@sha256:…   (identity)
      │
      ▼
Kargo Warehouse pt-kargo-web ──► Freight (identity = digest)
      │
      ├─► Stage develop   auto-promoted from the Warehouse
      │        writes asa-kargo-web/stages/develop/values.yaml → image.digest
      │
      └─► Stage homolog   manual, downstream of develop
               writes asa-kargo-web/stages/homolog/values.yaml → image.digest
      │
      ▼
d0-gitops-sandbox @ asa/desired-state                   (desired state)
      │
      ▼
Argo CD Applications pt-kargo-web-develop / pt-kargo-web-homolog
      │   multi-source: chart from pipeline-templates + values from the GitOps repo
      ▼
charts/asa-application (unmodified) ──► cluster
```

Azure DevOps has no authority after the ECR push. Kargo owns the artifact lifecycle;
Argo CD owns convergence; Helm keeps owning the Kubernetes shape.

## 3. Files changed

`pipeline-templates`, branch `poc/kargo-argo-first-slice` (no tag, `v3.1.2` not created):

| File | Change |
|---|---|
| `charts/asa-application/templates/_runtime.tpl` | `chart.validateImage` + `chart.imageRef` (digest wins over tag) |
| `charts/asa-application/templates/deployment.yaml` | image rendered through `chart.imageRef`; `validateImage` wired in |
| `charts/asa-application/values.yaml`, `values.schema.json` | optional `image.digest` (`^(sha256:[0-9a-f]{64})?$`) |
| `charts/asa-scheduled-job/…` | the same four changes, kept byte-identical |
| `templates/dotnet/container-build.yml` | **new** — the `Container` stage extracted verbatim, plus digest resolution and `image-provenance.json` |
| `templates/dotnet/ci.yml` | `deliveryMode: helm \| gitops` (default `helm`); `GitOpsContract` stage; both modes call the one build template |
| `tests/chart-invariants.sh` | +9 invariants for digest pinning, tag fallback, malformed digests, cross-chart helper parity |
| `examples/azure-pipelines.gitops.yml` | **new** — consumer example with no infrastructure choices |
| `docs/gitops-kargo-argo.md` | **new** — architecture, branch model, identities, consumer-API removal strategy |
| `docs/delivery/kargo-argo-first-slice.md` | **new** — this report |
| `scripts/kargo-argo-evidence.sh` | **new** — read-only correlation tool |
| `README.md` | both delivery modes, digest-or-tag pinning, pointers |

Nothing was removed. `helm-deploy.yml`, `deployEnvironments`, the ADO Environments and
`config/platform-environments.json` are untouched and still the default path.

`pt-v3-scenarios` (application source): `azure-pipelines.kargo-web.yml` added through
PR #90 (merged, auto-triggered CI) and PR #91 (build-pool fix, **open**).

`d0-gitops-sandbox`, branch `asa/desired-state`: `asa-kargo-web/` (14 files).

## 4. GitOps structure used

The existing `d0-gitops-sandbox` repository was reused — no new repository was invented,
and `pipeline-templates` was not turned into a GitOps monorepo.

```text
asa-kargo-web/
├── README.md
├── stages/develop/values.yaml          ← Argo CD reads; Kargo writes image.digest
├── stages/homolog/values.yaml          ← independent file, independent digest
└── control-plane/
    ├── namespaces.yaml                 ← platform-owned, created out of band
    ├── argocd/{appproject,application-develop,application-homolog}.yaml
    ├── kargo/{project,projectconfig,warehouse,stage-develop,stage-homolog,
    │          analysistemplate-develop,analysistemplate-homolog}.yaml
    └── lab-fixtures/gateway-homolog.yaml   ← lab only, stands in for real infra
```

**Application source branches ≠ GitOps stage branches.** The application repository has
only `feat/*`, `fix/*` and `main`; no `develop`, `homolog`, `production` or `release/*`
branch was created there. Environments live in the GitOps repository as the paths
`stages/develop` and `stages/homolog` on `asa/desired-state`. If a future design prefers
branch-per-stage, those branches belong to the GitOps repository.

## 5. Argo CD Applications created

| Application | Namespace | Authorized Kargo Stage | Sources |
|---|---|---|---|
| `pt-kargo-web-develop` | `asa-pt-kargo-web-dev` | `pt-kargo-web:develop` | chart `pipeline-templates@poc/kargo-argo-first-slice:charts/asa-application` + values `d0-gitops-sandbox@asa/desired-state` (`ref: values`) |
| `pt-kargo-web-homolog` | `asa-pt-kargo-web-hml` | `pt-kargo-web:homolog` | same chart source, `stages/homolog/values.yaml` |

`AppProject pt-kargo-web`: two destinations, `clusterResourceWhitelist: []`, and a
`namespaceResourceWhitelist` of exactly the six kinds the chart renders
(Deployment, Service, ServiceAccount, ConfigMap, HorizontalPodAutoscaler, HTTPRoute).
No `ApplicationSet`. One explicit Application per environment, as allowed for this slice.

## 6. Kargo resources created

| Resource | Configuration |
|---|---|
| `Project pt-kargo-web` | Ready |
| `ProjectConfig` | `develop` `autoPromotionEnabled: true`; `homolog` `false` |
| `Warehouse pt-kargo-web` | image subscription on the ECR repo, `imageSelectionStrategy: NewestBuild`, `allowTagsRegexes: ^[0-9a-f]{40}$`, `discoveryLimit: 10`, interval 1m |
| `Stage develop` | `requestedFreight.sources.direct: true`; steps `git-clone → yaml-update(image.digest,image.tag) → git-commit → git-push → argocd-update`; verification `http-smoke-develop` |
| `Stage homolog` | `requestedFreight.sources.stages: [develop]`; same five steps against `stages/homolog`; verification `http-smoke-homolog` |
| `AnalysisTemplate` ×2 | one `curl -sf /health-check` through the chart's Service |

No candidate object, no promotion database, no run-tag scheme, no custom CRD, no
abstraction over Kargo or Argo was introduced.

## 7. Evidence

### 7.1 ECR → Freight

**NOT PROVEN.** The Warehouse is live and authenticated against ECR — it reaches the
registry and fails only with `RepositoryNotFoundException`, because the slice's ECR
repository is created by the `Container` stage, which has not run yet:

```text
Ready: DiscoveryFailure — error listing tags for repo URL
448003890252.dkr.ecr.us-east-1.amazonaws.com/pt-kargo-web:
NAME_UNKNOWN: The repository with name 'pt-kargo-web' does not exist
```

That message is itself the proof that the ECR credential and the subscription are correct.

### 7.2 CI builds once

**PARTIAL.** PR #90 merged to `main` at SHA `fd58eda9` and **auto-triggered** build
`20260926.1` (id 293) — `reason: individualCI`, `ci.sourceSha: fd58eda9…`. The `CI` and
`GitOpsContract` stages passed; `GitOpsContract` printed:

```text
applicationName : pt-kargo-web
ECR repository  : pt-kargo-web
image tag       : fd58eda931e0065566e0e13f0d013ec17777f873 (git SHA, ECR IMMUTABLE)
handoff         : ECR digest → Kargo Warehouse → Freight → Stage develop → Stage homolog
this pipeline   : does NOT deploy, does NOT promote, does NOT rebuild
```

The `Container` stage then queued on pool `PG-AWS-EKS`, whose only agent is
`CrashLoopBackOff` (1304 restarts, fails a kubectl RBAC check at startup) and has no
BuildKit sidecar. The stage was cancelled. PR #91 moves the slice's **build** pool to
`PG-AWS-EKS-HML`, the pool whose agent exposes BuildKit + crane. That PR is open.

Structurally, a rebuild between stages is now impossible in gitops mode: exactly one
stage in the pipeline can build (`container-build.yml`), and there is no stage after it.

### 7.3 Freight X → develop, same Freight X → homolog, identical digest, `develop=Y` while `homolog=X`, specific old Freight, verification failure

**NOT PROVEN — pending 7.1/7.2.** All five scenarios are configured and the control plane
is live; none has executed. The mechanisms they depend on are in place and inspectable:

- same digest across stages: both Stages write the **same** `imageFrom(...).Digest` into
  their own values file; nothing recomputes or rebuilds anything.
- independence: `homolog` has `autoPromotionEnabled: false` and only advances through an
  explicit `Promotion`. A new Freight reaching `develop` cannot move `homolog`.
- specific/old Freight: a `Promotion` names a Freight explicitly; `NewestBuild` affects
  only which Freight is *created*, never which one may be promoted.
- verification: each Stage carries an `AnalysisTemplate`, and `homolog` accepts only
  Freight that `develop` has verified (`sources.stages: [develop]`).

### 7.4 Argo CD renders and deploys the existing chart

**PROVEN.** A temporary hand-pinned digest (commit `e2202a9`, reverted by `5f0993e`) was
used to exercise the rendering path before any promotion existed:

```text
application pt-kargo-web-develop
  sync: Synced      health: Healthy
  revisions: 6b7a366 (pipeline-templates, chart)   e2202a9 (d0-gitops-sandbox, values)
  resources: ConfigMap, Service, ServiceAccount, Deployment,
             HorizontalPodAutoscaler, HTTPRoute — all Synced
  pod image: …/pt-v3-web@sha256:3c4e97bdb4eb642403dd15c49aeff4bbe2c63703af9254f84f4da842cac2dc23
```

The chart was read as-is from GitHub. No template was duplicated, no Kustomize
conversion, no CRD or operator was introduced. The workload was then removed and the
desired state returned to unpinned so that Kargo owns the file.

Also proven, as a side effect: an unpinned desired state **fails to render**
(`image requires digest (preferred) or tag`), so a half-written promotion cannot deploy.

### 7.5 Observability

`scripts/kargo-argo-evidence.sh` answers, in one read-only run: which Git SHA produced a
Freight (the ECR tag is `Build.SourceVersion`), its digest, which Stage holds it, the
digest each Stage runs, which Promotion moved it, whether the Argo Application is Healthy,
and the image ID the kubelet actually pulled. The correlation chain needs no manual hunting:

```text
Git SHA ⇢ ECR tag ⇢ digest ⇢ Freight ⇢ Stage (Promotion) ⇢ values.yaml ⇢ Argo CD ⇢ kubelet
```

Gap: `image-provenance.json` is a pipeline artifact, so answering "which ADO run produced
this digest?" still means opening that run. Acceptable for the slice; a durable
provenance store is a later decision.

## 8. RBAC used

| Layer | What is in place | Verdict |
|---|---|---|
| Argo CD `AppProject` | 2 namespaces, `clusterResourceWhitelist: []`, 6 namespaced kinds | least privilege applied |
| Namespaces | pre-created out of band, not by the Applications, so no cluster-scoped write is needed | good |
| Kargo → Argo | per-Application `kargo.akuity.io/authorized-stage`; a Stage can act on its own Application only | explicit |
| Argo CD application **controller** | `ClusterRole argocd-application-controller` = `apiGroups:'*' resources:'*' verbs:'*'` (upstream default) | **RBAC BLOCKER** |

The controller-level privilege is not hidden and not normalized: it is the known
architectural risk. It must be reduced (namespaced Argo CD instances, or a restricted
controller role plus per-destination service accounts) before this path carries production.

## 9. Git identities used

| Role | Identity | Rights |
|---|---|---|
| promotion (Git write) | Entra SP `idp-d1-kargo-writer` → Secret `pt-kargo-web/gitops-writer` | write the GitOps repo |
| reconciliation (Git read) | Entra SP `idp-d1-argocd-reader` → Secret `argocd/d0-gitops-sandbox-repo` | read the GitOps repo |
| chart read | none (public repository) | read |
| ECR read (Warehouse) | lab ECR token Secret `pt-kargo-web/ecr-credentials` | **temporary, ~12 h** |

Write authority and read authority are different principals. No shared PAT was used and
none is required by the design. Two lab caveats: the ECR token is manual (production
answer is IRSA on the Kargo controller service account), and the Kargo writer Secret is a
manual copy of the Entra-refreshed one, because the existing refresh CronJob's RBAC covers
only two named Secrets.

## 10. External blockers

| ID | Blocker | Impact |
|---|---|---|
| EB-1 | Real EKS (`sample-template-pg`) unreachable from here | slice runs on the lab cluster; both stages share one cluster, so namespaces are suffixed. Real target is one cluster per environment |
| EB-2 | No IRSA for Kargo in the lab | ECR credential is a manual 12 h token |
| EB-3 | `argocd-application-controller` is cluster-admin (upstream default) | **RBAC BLOCKER** for production readiness |
| EB-4 | No node/kubelet ECR IAM in the lab | `imagePullSecrets: ecr-pull` fallback stays in the values file |
| EB-5 | Homolog gateway absent in the lab | added as a declared lab fixture |
| EB-6 | Kargo verification needs Argo Rollouts `AnalysisTemplate` CRDs | present; no Rollout, canary or blue/green is used |
| EB-7 | `expectedKubeContext` and the production pool still unmapped | pre-existing, affects the Helm path only |
| EB-8 | `ado-agents/ado-agent` (pool `PG-AWS-EKS`) CrashLoopBackOff, no BuildKit sidecar | blocks the slice's `Container` stage; PR #91 repoints the build pool |
| EB-9 | Kargo Git-writer Secret is a manual copy; refresh CronJob RBAC is scoped to two named Secrets | credential needs re-syncing roughly hourly during the proving ground |
| EB-10 | PR #91 awaits human review | **the remaining evidence cannot be produced until it merges** |

## 11. Results by area

| | Area | Verdict | Basis |
|---|---|---|---|
| A | Existing Helm contract preservation | **PASS** | chart changes are additive; every pre-existing lint / drift / invariant / public-schema test still passes; the tag path renders exactly as before |
| B | ADO CI → ECR | **CONDITIONAL PASS** | `CI` + `GitOpsContract` proven on a real auto-triggered run; the ECR push itself blocked by EB-8/EB-10 |
| C | Argo rendering / deployment | **PASS** | Synced + Healthy from the unmodified chart with GitOps values and a digest-pinned image |
| D | Kargo Warehouse / Freight | **NOT PROVEN** | Warehouse live and authenticated; no image to discover yet |
| E | develop promotion | **NOT PROVEN** | configured, not executed |
| F | homolog promotion | **NOT PROVEN** | configured, not executed |
| G | same-digest guarantee | **CONDITIONAL PASS** | by construction (both Stages write the same `imageFrom(...).Digest`; the chart pins by digest and refuses malformed or absent pins) — not yet observed end to end |
| H | environment independence | **CONDITIONAL PASS** | by construction (`homolog` auto-promotion off, separate values file, separate Application) — not yet observed |
| I | old / specific Freight selection | **CONDITIONAL PASS** | Kargo promotes a named Freight; nothing in the design is "latest only" — not yet observed |
| J | verification | **CONDITIONAL PASS** | templates in place, `homolog` restricted to Freight verified in `develop`; failure path not yet exercised |
| K | Git identity separation | **PASS** | two distinct Entra service principals, write and read; no shared PAT |
| L | Argo RBAC | **CONDITIONAL PASS** | least privilege at `AppProject` level; **controller is cluster-admin** and must be fixed before production |
| M | Consumer API simplification readiness | **PASS** | in gitops mode `deployEnvironments` and `expectedKubeContext` are rejected, not ignored; the removal order is written down, including the one regression it must close first |

No numeric average is implied.

## 12. Veto checks

| Veto condition | Observed |
|---|---|
| rebuild between Stages | No. One build stage exists and nothing follows it in gitops mode |
| source branch used as environment | No. Only `feat/*`, `fix/*`, `main` in the app repo |
| feature branch overwriting shared DEV | No. Only `main` triggers the slice pipeline |
| consumer choosing infrastructure | No. Rejected at the contract stage |
| non-deterministic Freight/digest | No. Digest is the identity; ECR tags are IMMUTABLE; malformed or missing pins fail rendering |
| homolog following develop without promotion | No. `autoPromotionEnabled: false`, separate desired-state file |
| permanent cluster-admin requirement | **Open** — the Argo CD controller default must be reduced (EB-3). Not a property of Kargo or of this design |
| permanent shared read/write PAT | No. Two separate identities already |
| substantial chart rewrite required | No. Four additive changes, no template duplication, no Kustomize |

No veto was triggered by the architecture. One veto item (cluster-admin) is a property of
the current Argo CD installation and is recorded rather than accepted.

## 13. Conclusion

**CONDITIONAL PASS.**

Kargo + Argo CD do answer the question the pivot was about: the artifact lifecycle after
the build is expressible in Kargo's own concepts — `Warehouse`, `Freight`, `Stage`,
`PromotionTemplate`, `verification` — with no candidate object, no promotion state machine,
no environment pinning table, no run tags and no promotion database of ours. The concepts
that were pushing us toward writing a promotion engine map onto stock Kargo resources, and
the current ASA chart survives the move with four additive lines of change.

What is not yet demonstrated is the live sequence: a real CI digest becoming Freight,
moving to `develop`, then the same Freight moving to `homolog`, then a newer image
advancing `develop` while `homolog` stays put, then an older Freight being promoted
explicitly, then a failing verification being treated as not eligible downstream. That
sequence is blocked on lab plumbing (EB-8) and one unreviewed pull request (EB-10), not on
anything architectural discovered so far.

The current CD path was not removed and is still the default.

## 14. Smallest recommended next step

Merge PR #91 in `pt-v3-scenarios` so the `Container` stage runs on the pool that has the
BuildKit toolchain. That single merge produces the first slice digest and unblocks
PG-KA-02 through PG-KA-08 in one pass, with no further code change:
Freight appears → `develop` auto-promotes → verify → promote the same Freight to
`homolog` → two more commits on `main` produce images Y and Z → promote Y to `develop`
only → promote the older Freight X to `homolog` explicitly → exercise one failing
verification.

Do not proceed to `release` or `production`, and do not remove the Helm path, until that
sequence is green and EB-3 (Argo CD controller privilege) has an owner.
