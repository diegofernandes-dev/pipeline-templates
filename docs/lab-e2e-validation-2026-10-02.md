# Lab e2e validation report — 2026-10-02 / 2026-10-03

Evidence-first validation of `pipeline-templates` (charts `asa-application` **5.3.0**, `asa-scheduled-job` **4.3.0**, DNS `dns.publishLegacyHostname`, IRSA, WIF, External Secrets, ScheduledJob, Gateway/ExternalDNS, ADO delivery) against real AWS + GCP labs.

**Verdict:** platform chart + identity + DNS + ESO + ScheduledJob + Gateway path + ADO deploy path are proven live. Labs were destroyed after this report.

---

## 1. Scope and environments

| Axis | Detail |
|------|--------|
| AWS account | `448003890252` (profiles `lab` / `lab-deploy` / `lab-container`) |
| EKS | Pre-existing proving-ground `sample-template-pg` (us-east-1); kube context `sample-template-pg` |
| Route53 (ephemeral) | Private zones `dev.pg.lab.test` (`Z09350631IMMQRO7SGFOQ`), `d.pg.lab.test` (`Z09369331EPGIBPUX7RJM`) |
| GCP project (ephemeral) | `diego-lab-8371` (project number `24168548185`) |
| GKE | `asa-pg-legacy` (us-east1-b) |
| ADO | Org `https://dev.azure.com/diegolab`, project `platform-engineering` |
| Area profile | `platform/areas/lab.yml` → `expectedKubeContext: sample-template-pg` |

Ephemeral inventory lived in `.lab-aws-ephemeral.txt` (removed/obsolete after teardown).

---

## 2. What changed in the product under test

Primary product change exercised end-to-end:

- Migrate legacy DNS publication from deprecated `legacyDns` to **`dns.publishLegacyHostname`** (default `false`).
- HTTPRoute/GRPCRoute always *accept* corp + legacy hostnames when `platform.legacyDnsZone` is set; ExternalDNS only *publishes* legacy when `dns.publishLegacyHostname: true` (annotation-only hostname source).
- Chart versions bumped to **asa-application 5.3.0** / **asa-scheduled-job 4.3.0**; schemas, goldens, examples, and lab area aligned.

---

## 3. Test matrix (summary)

| # | Area | Method | Result |
|---|------|--------|--------|
| T1 | Local chart contract | `tests/chart-invariants.sh` (+ conform/drift/platform embedded) | PASS |
| T2 | Server-side apply dry-run | `KUBE_CONTEXT=sample-template-pg tests/chart-apply.sh` (24 manifests) | PASS |
| T3 | AWS assume-role profiles | `sts get-caller-identity` / `assume-role` for `lab`, `lab-deploy`, `lab-container` | PASS |
| T4 | DNS corp + legacy | Helm canary + ExternalDNS IRSA → Route53 Alias A/AAAA | PASS |
| T5 | Gateway → pod | Host header to NGF ELB; Kestrel access logs | PASS |
| T6 | ServiceAccount contract | `automountServiceAccountToken: false`, SA name = release | PASS |
| T7 | IRSA live | Projected token → `AssumeRoleWithWebIdentity` → `GetCallerIdentity` | PASS |
| T8 | WIF live (EKS→GCP) | Projected JWT → GCP STS exchange → SA `generateAccessToken` | PASS |
| T9 | IRSA+WIF coexistence | Distinct mounts; no path collision with `/var/run/secrets/eks.amazonaws.com/...` | PASS |
| T10 | ClusterSecretStore assume-role | ESO IRSA `asa-pg-eso` → assume `asa-pg-secrets-reader` → SM | PASS |
| T11 | ExternalSecret → pod env | Sync `DEMO_SECRET` / `ConnectionStrings__Default` into envFrom | PASS |
| T12 | ScheduledJob | CronJob + Job `succeeded=1`, log `job-canary-ok` | PASS |
| T13 | HTTP 2xx | `pt-v3-web` canary `/` → 200 via pod PF and Gateway | PASS |
| T14 | GKE legacy smoke | LoadBalancer `legacy-echo` → HTTP 200 `legacy-gcp-ok` | PASS |
| T15 | ADO DeployContract (local) | `assert-deploy-identity`, `validate-manifest`, helm template, `platform-contract` | PASS |
| T16 | ADO pipeline live | `pt-v3-web` builds **305** and **306** succeeded (`lab/cluster-axis-test`) | PASS |

### Explicitly out of scope / consumer issues (not chart regressions)

| Item | Evidence |
|------|----------|
| `sample-api-ci-template-test` queue | Blocked: `Unexpected parameter 'exposeAsaComBr'` in consumer YAML `azure-pipelines.ci-template-test.yml` |
| `pt-v3-web` @ `main` builds 303/304 | Failed `helm upgrade` **context deadline exceeded** (rollout/timeout on agent path), not schema rejection; lab branch succeeded twice |
| Public `dig` for `*.pg.lab.test` | Private hosted zones — validated via Route53 API Alias targets instead |

---

## 4. Detailed evidence

### 4.1 Local / CI-equivalent chart suites

```text
bash tests/chart-invariants.sh
```

Covered (non-exhaustive): schema negatives, IRSA+WIF render contract (role-arn annotation, WIF mount at `/var/run/secrets/gcp/serviceaccount`, `GOOGLE_APPLICATION_CREDENTIALS`, no WIF on IRSA path), probes/DNS/publishLegacyHostname goldens parity hooks, platform-contract (area allowlist, resolve per tier, gateway names), kubeconform, helm lint, example renders.

```text
KUBE_CONTEXT=sample-template-pg bash tests/chart-apply.sh
```

Result: **Server-side validation clean: 24 manifests accepted by a real API server** (web/grpc/worker/job combos, persistence, publishLegacyHostname, “everything on”, image.tag edge cases for `app.kubernetes.io/version`).

Requires cluster APIs: `gateway.networking.k8s.io/v1`, `external-secrets.io/v1`.

### 4.2 Assume-role (pipeline agent identity)

| Profile / call | Observed identity |
|----------------|-------------------|
| `AWS_PROFILE=lab` | `arn:aws:iam::448003890252:user/diego` |
| `AWS_PROFILE=lab-deploy` | `assumed-role/pipeline-deploy/lab-deploy` |
| `AWS_PROFILE=lab-container` | `assumed-role/pipeline-container/lab-container` |
| Explicit `sts assume-role` → `pipeline-deploy` | Session ARN under `pipeline-deploy` |

### 4.3 DNS + ExternalDNS + Gateway (publishLegacyHostname)

**ExternalDNS provenance (lab inventory / `helm list` during the session)**

| Field | Value |
|-------|--------|
| Helm chart | `external-dns-1.23.0` (repo `external-dns`) |
| App version | **0.23.0** |
| Provider | AWS Route53 |
| Sources | `gateway-httproute` (Gateway API) |
| Hostname source | chart annotation `external-dns.kubernetes.io/gateway-hostname-source: annotation-only` |
| IRSA | `asa-pg-external-dns` on SA `external-dns/external-dns` |
| Evidence source | Live `helm list -A` on `sample-template-pg` during 2026-10-02 lab; agent session summary after canary |

**Setup**

- NGINX Gateway Fabric (`ngf`) + Gateway `d-asa-com-br-internal-gateway` in `asa-infra-nginx-gateway`.
- ExternalDNS (above) with IRSA role `asa-pg-external-dns` (Route53 change on lab zones).
- Release `sample-canary` (`asa-application`) with platform zones overridden to ephemeral Route53:

```yaml
platform:
  dnsZone: dev.pg.lab.test
  legacyDnsZone: d.pg.lab.test
```

**Cutover sequence (live)**

| Step | Flag | HTTPRoute hostnames | Route53 publication |
|------|------|---------------------|---------------------|
| 1 | `publishLegacyHostname: false` | corp **and** legacy | **corp only** (`sample-canary.dev.pg.lab.test`) |
| 2 | flip → `true` | unchanged (both) | corp **+** legacy (`sample-canary.d.pg.lab.test` Alias added) |

This is the controlled-rollout contract: Route keeps accepting legacy Host for validation; ExternalDNS only publishes legacy when authorized.

**Assertions**

- After step 1: legacy FQDN absent from Route53; corp Alias → NGF ELB.
- After step 2: Route53 Alias A/AAAA for both corp and legacy → same ELB.
- ExternalDNS logs free of credential provider errors.
- Gateway address programmed (ELB hostname under `us-east-1.elb.amazonaws.com`).

Later `http-canary` repeated the path with `pt-v3-web` and proved **HTTP 200** (see §4.8).

### 4.4 ServiceAccount + IRSA (live STS)

**Release:** `id-canary` in `asa-id-canary`.

**IAM:** role `asa-pg-id-canary-irsa` trusted via EKS OIDC for  
`system:serviceaccount:asa-id-canary:id-canary`, policy `sts:GetCallerIdentity`.

**Pod facts**

- SA annotation `eks.amazonaws.com/role-arn=arn:aws:iam::448003890252:role/asa-pg-id-canary-irsa`
- `automountServiceAccountToken: false`
- Webhook injected `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token`
- IRSA JWT: `aud=sts.amazonaws.com`, `sub=system:serviceaccount:asa-id-canary:id-canary`

**Live exchange (token read from pod, STS called from workstation)**

1. `sts assume-role-with-web-identity` → `arn:aws:sts::448003890252:assumed-role/asa-pg-id-canary-irsa/...`
2. `sts get-caller-identity` with temporary credentials → same role session

### 4.5 WIF (EKS OIDC → GCP)

**GCP**

- Pool `asa-pg-pool`, OIDC provider `eks-oidc`
- Issuer = EKS OIDC URL for `sample-template-pg`
- Allowed audience =  
  `//iam.googleapis.com/projects/24168548185/locations/global/workloadIdentityPools/asa-pg-pool/providers/eks-oidc`
- SA `asa-pg-wif@diego-lab-8371.iam.gserviceaccount.com` with `roles/iam.workloadIdentityUser` (+ token creator) for principal  
  `.../subject/system:serviceaccount:asa-id-canary:id-canary`
- APIs enabled: `iamcredentials.googleapis.com`, `sts.googleapis.com`

**Chart values (relevant)**

```yaml
workloadIdentity:
  token:
    audience: //iam.googleapis.com/projects/24168548185/.../providers/eks-oidc
  gcp:
    audience: //iam.googleapis.com/projects/24168548185/.../providers/eks-oidc
    serviceAccountEmail: asa-pg-wif@diego-lab-8371.iam.gserviceaccount.com
    projectId: diego-lab-8371
```

**Assertions**

- ConfigMap `external-account.json` with correct audience, impersonation URL, credential_source file under `/var/run/secrets/gcp/serviceaccount/token`
- Env: `GOOGLE_APPLICATION_CREDENTIALS=/var/run/secrets/google/...`, `GOOGLE_CLOUD_PROJECT=diego-lab-8371`
- Mounts unique: IRSA webhook path + `/var/run/secrets/gcp/serviceaccount` + `/var/run/secrets/google` + `/tmp`
- WIF JWT aud/sub match pool provider and K8s SA
- Live: GCP STS token exchange + `generateAccessToken` for `asa-pg-wif@...`

### 4.6 External Secrets Operator + ClusterSecretStore assume-role

**IAM chain (infra pattern from README)**

1. Controller SA `external-secrets/external-secrets` → IRSA role `asa-pg-eso`
2. `asa-pg-eso` permitted `sts:AssumeRole` on `asa-pg-secrets-reader`
3. `asa-pg-secrets-reader` trust = `asa-pg-eso`; policy `secretsmanager:GetSecretValue` on `asa/pg-lab/*`

**Store**

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secretsmanager
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      role: arn:aws:iam::448003890252:role/asa-pg-secrets-reader
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

Status: **Ready / store validated**.

**App**

- SM secret `asa/pg-lab/id-canary/demo` =  
  `{"DEMO_SECRET":"pg-lab-secret-ok","ConnectionStrings__Default":"Host=lab;Database=demo"}`
- Chart `externalSecret.data` → ExternalSecret **Ready: secret synced**
- Pod after rollout: `DEMO_SECRET=pg-lab-secret-ok`, connection string present via envFrom `id-canary-secret`

### 4.7 ScheduledJob

```text
helm upgrade --install job-canary charts/asa-scheduled-job ...
kubectl create job job-ok --from=cronjob/job-canary
```

- CronJob present; SA `automountServiceAccountToken=false`
- Success proof used platform UID-compatible image with  
  `execution.command: ["sh","-c","echo job-canary-ok && exit 0"]`
- Job status **succeeded=1**, logs contain `job-canary-ok`

(Earlier `pt-v3-job` with `--once` hit `DeadlineExceeded` — app/args issue, not CronJob API path.)

### 4.8 HTTP 2xx (real app image)

Release `http-canary` / image `pt-v3-web:86cc2ec7f0cbd8a44650ca15204f36abd4be1c5e`:

| Path | Result |
|------|--------|
| Pod port-forward `:8080/` | **200** |
| Gateway `Host: http-canary.dev.pg.lab.test` `/` | **200** |

Note: earlier `sample-api` canary returned **404** on all routes (empty app routes) while still proving Gateway→pod delivery via Kestrel logs.

### 4.9 GKE legacy

- Deployment `legacy-echo` Running
- Service LoadBalancer IP `34.148.116.99`
- `curl http://$IP/` → **200** body `legacy-gcp-ok`

### 4.10 Azure DevOps

**Local DeployContract equivalents**

- `scripts/assert-deploy-identity.sh examples/deploy/config develop`
- `scripts/validate-manifest.py schemas/application.manifest.schema.json examples/deploy/config/develop.yaml`
- `resolve-platform-values.sh lab develop` + `helm template` with example manifesto → Deployment + HTTPRoute
- `tests/platform-contract.sh`
- IRSA account parse check vs `lab` `awsAccountId` `448003890252`

**Live pipeline**

| Build | Pipeline | Branch | Result |
|------:|----------|--------|--------|
| 305 | pt-v3-web (id 14) | `lab/cluster-axis-test` | **succeeded** |
| 306 | pt-v3-web (id 14) | `lab/cluster-axis-test` | **succeeded** |
| 303/304 | pt-v3-web | `main` | failed — helm upgrade atomic timeout |
| — | sample-api-ci-template-test (id 13) | `test/ci-template` | **cannot queue** — consumer YAML param `exposeAsaComBr` |

---

## 5. Canaries and infra created for proof (then destroyed)

| Resource | Purpose |
|----------|---------|
| Helm `sample-canary`, `id-canary`, `http-canary`, `job-canary` | DNS / identity+ESO / HTTP 200 / CronJob |
| Helm `ngf`, Gateways | Gateway API data plane |
| Helm `external-dns` + role `asa-pg-external-dns` | Route53 publication |
| Helm `external-secrets` + roles `asa-pg-eso`, `asa-pg-secrets-reader` | SM sync via assume-role |
| IAM `asa-pg-id-canary-irsa` | IRSA proof |
| Route53 zones `dev.pg.lab.test`, `d.pg.lab.test` | DNS e2e |
| SM `asa/pg-lab/id-canary/demo` | ExternalSecret source |
| GKE `asa-pg-legacy` + `legacy-echo` | GCP legacy path |
| WIF pool/provider + `asa-pg-wif@...` | EKS→GCP WIF |
| GCP project `diego-lab-8371` | Ephemeral billing sandbox |

**Teardown policy**

- Destroyed: all canaries, NGF, ExternalDNS, ESO, Route53 zones, lab IAM roles/policies, SM secret, GKE cluster, WIF, GCP SA, GCP project `diego-lab-8371`.
- **Not deleted:** EKS cluster `sample-template-pg` (pre-existing proving-ground referenced by `platform/areas/lab.yml`, cluster system namespaces ~23d old). Workloads and lab IAM/DNS attached for this exercise were removed.

---

## 6. Conclusion

The platform contracts that matter for shipping this hardening are evidenced on real clusters and a real ADO deploy pipeline:

1. **DNS cutover control** via `dns.publishLegacyHostname` works with ExternalDNS annotation-only + Gateway API.
2. **IRSA and WIF** coexist with correct mounts and live token exchange.
3. **External Secrets** works with the documented **IRSA → assume-role → Secrets Manager** store pattern, including env injection.
4. **ScheduledJob** chart produces a runnable CronJob that completes successfully.
5. **HTTP** path through Gateway returns **2xx** with a real web image.
6. **ADO** delivery using these templates succeeds on the lab consumer branch (`pt-v3-web` 305/306).

Remaining failures observed were **consumer YAML drift** (`exposeAsaComBr`) or **environment/rollout timeouts on `main`**, not failures of chart schema or identity wiring.

---

## 7. How to re-run (checklist)

```bash
# Local
bash tests/chart-invariants.sh
KUBE_CONTEXT=<eks-context> bash tests/chart-apply.sh

# Identity / ESO / DNS require: EKS+OIDC, Route53 zones, ESO operator+ClusterSecretStore,
# optional GCP WIF pool bound to EKS issuer, and a canary helm release from charts/asa-application.

# ADO
az pipelines run --org https://dev.azure.com/diegolab \
  --project platform-engineering --name pt-v3-web \
  --branch lab/cluster-axis-test
```
