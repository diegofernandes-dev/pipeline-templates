# Pipeline Templates

Templates YAML reutilizáveis para Azure DevOps (GitHub → `extends`).

## Conteúdo

| Caminho | Escopo |
|---------|--------|
| [`templates/dotnet/ci.yml`](templates/dotnet/ci.yml) | CI → ECR → Helm (promoção) |
| [`templates/dotnet/helm-deploy.yml`](templates/dotnet/helm-deploy.yml) | Stage Helm por Environment (`kind` → chart) |
| [`docker/dotnet/Dockerfile`](docker/dotnet/Dockerfile) | Dockerfile plataforma (.NET; listen web=8080) |
| [`charts/asa-application`](charts/asa-application) | `kind: Application` — web \| grpc \| worker |
| [`charts/asa-scheduled-job`](charts/asa-scheduled-job) | `kind: ScheduledJob` — CronJob |
| [`schemas/`](schemas/) | Schema **público** do manifesto (`additionalProperties: false`) |
| [`scripts/`](scripts/) | Validação de manifesto + identidade cross-env |
| [`tests/chart-invariants.sh`](tests/chart-invariants.sh) | Testes de **render** (não delivery) |
| [`tests/chart-drift.sh`](tests/chart-drift.sh) | Drift de templates compartilhados entre charts |

## Consumo

```yaml
trigger:
  - main

resources:
  repositories:
    - repository: templates
      type: github
      name: diegofernandes-dev/pipeline-templates
      endpoint: github-diegofernandes-dev
      ref: refs/tags/v3.1.0

extends:
  template: templates/dotnet/ci.yml@templates
  parameters:
    solution: '**/*.sln'
    applicationName: sample-api
    dotnetProject: src/Sample.Api/Sample.Api.csproj
    deployEnvironments:
      - name: develop
        containerPool: PG-AWS-EKS
        variableGroups: []
        # helmTimeout: 10m
        # expectedKubeContext: my-eks-dev
        # smokeScheduledJob: true   # only meaningful for ScheduledJob + develop
```

`applicationName` é a identidade do **deployable** (ECR repo, Helm release, namespace `asa-<name>`).

Um manifesto = um deployable = uma Helm release. API e worker são releases distintas (pipelines/`applicationName` distintos).

### Contrato público vs inputs da plataforma

```text
PUBLIC MANIFEST (deploy/config/<env>.yaml)
        +
PLATFORM RUNTIME INPUTS (image.*, runtime.environment, imagePullSecrets)
        ↓
HELM VALUES
```

O consumidor **não** declara `image` / `runtime` no manifesto. Typos (`legasyDns`) falham no schema público.

`kind` e `workload.type` (Application) devem ser **idênticos** em todos os `deployEnvironments` (preflight no stage DeployContract).

### kind → chart

| kind | Chart |
|------|-------|
| `Application` | `charts/asa-application` |
| `ScheduledJob` | `charts/asa-scheduled-job` |

### Application (`workload.type`)

| type | Recursos |
|------|----------|
| `web` | Deployment + Service + HTTPRoute (+ HPA CPU) — porta **8080** |
| `grpc` | Deployment + Service (`appProtocol: kubernetes.io/h2c`) + GRPCRoute (+ HPA) — porta **50051**, listen HTTP/2 injetado pela plataforma |
| `worker` | Deployment **sem** HPA por padrão — sem Service/Route/DNS |

Portas são contrato da plataforma. **`workload.port` não existe**. gRPC sobrescreve o `ASPNETCORE_URLS=8080` do Dockerfile via env do chart.

```yaml
kind: Application
workload:
  type: web
legacyDns: false
probes:
  path: /health-check     # opt-in
autoscaling:
  minReplicas: 2
  maxReplicas: 5
  cpu:
    target: 70
```

**Worker / HPA:** default **off** (worker não é assumido idempotente). Opt-in com `autoscaling:` explícito no manifesto. web/grpc: HPA on por omissão (`autoscaling: false` desliga).

gRPC probes: `probes.readiness.enabled: true` (sem path HTTP).

### ScheduledJob

```yaml
kind: ScheduledJob
schedule:
  expression: "0 2 * * *"
  timeZone: America/Sao_Paulo   # default do chart; obrigatório após merge
  concurrencyPolicy: Forbid       # Allow | Forbid | Replace
execution:
  retries: 2
  args: ["--mode=job"]            # command ou args obrigatório
```

### Opt-ins comuns (Application)

| Manifesto | Efeito |
|-----------|--------|
| `config` | ConfigMap → envFrom |
| `externalSecret` | ExternalSecret → Secret (requer ESO); rotação **não** reinicia pods |
| `serviceAccount.annotations` | IRSA |
| `workloadIdentity.gcp` | WIF EKS→GCP |
| `persistence.mountPath` + `size` | PVC RWO (`autoscaling: false`, `replicaCount: 1`) |
| `legacyDns: true` | hostname legado `.asa.com.br` (web/grpc) |
| `probes` | HTTP (web) ou gRPC (grpc) |

### ECR pull

Preferir **IAM do node / kubelet credential provider**. `ECR_PULL_SECRET` (variável de pipeline) é fallback de lab: secret `kubernetes.io/dockerconfigjson` pré-provisionado no namespace (tokens ECR expiram ~12h).

### HTTPRoute / Gateway / DNS (web e grpc)

| Environment | Hostname corp | Gateway | Legado (`legacyDns`) |
|-------------|---------------|---------|----------------------|
| `develop` | `<app>.dev.asa.corp` | `d-asa-com-br-internal-gateway` | `<app>.d.asa.com.br` |
| `homolog` | `<app>.hml.asa.corp` | `h-asa-com-br-internal-gateway` | `<app>.h.asa.com.br` |
| `production` | `<app>.prd.asa.corp` | `p-asa-com-br-internal-gateway` | `<app>.p.asa.com.br` |

### Dívida: duplicação entre charts

Templates idênticos hoje: `serviceaccount`, `externalsecret`, `configmap`, `wif-credentials`, `_workloadidentity`. Monitorados por [`tests/chart-drift.sh`](tests/chart-drift.sh).

**Gatilho para `asa-runtime-common`:** terceiro chart **ou** correção operacional repetida nos dois charts. Sem Library Chart genérica / workload engine.

### Testes

```bash
helm lint charts/asa-application
helm lint charts/asa-scheduled-job
./tests/chart-invariants.sh   # render + schema público + drift
./tests/chart-drift.sh
```

Invariants cobrem **render**, não delivery (`--atomic`, pull de imagem, Gateway real).

### Versões

| Tag | Notas |
|-----|-------|
| `v1.0.0` | Chart `app`; probes sempre `/health-check`; CronJob addon |
| `v2.0.0` | Chart `app`; probes opt-in |
| `v3.0.0` | `asa-application` + `asa-scheduled-job`; `kind` obrigatório |
| `v3.1.0` | gRPC e2e (listen+h2c); schema público; identidade cross-env; worker sem HPA default; ScheduledJob timeZone/enum; harden helm-deploy |

**Migração v2 → v3:** mover `cronJob:` para deployable `ScheduledJob`. `exposeAsaComBr` → `legacyDns`. Declarar `kind` + `workload.type`.

**Migração worker HPA:** se precisava de escala automática, declare `autoscaling:` no manifesto.
