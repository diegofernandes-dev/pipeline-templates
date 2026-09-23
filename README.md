# Pipeline Templates

Templates YAML reutilizáveis para Azure DevOps (GitHub → `extends`).

## Conteúdo

| Caminho | Escopo |
|---------|--------|
| [`templates/dotnet/ci.yml`](templates/dotnet/ci.yml) | CI → ECR → Helm (promoção) |
| [`templates/dotnet/helm-deploy.yml`](templates/dotnet/helm-deploy.yml) | Stage Helm por Environment (`kind` → chart) |
| [`docker/dotnet/Dockerfile`](docker/dotnet/Dockerfile) | Dockerfile plataforma (.NET web/API) |
| [`charts/asa-application`](charts/asa-application) | `kind: Application` — web \| grpc \| worker |
| [`charts/asa-scheduled-job`](charts/asa-scheduled-job) | `kind: ScheduledJob` — CronJob |
| [`tests/chart-invariants.sh`](tests/chart-invariants.sh) | Testes de contrato |

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
      ref: refs/tags/v3.0.0

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
```

`applicationName` é a identidade do **deployable** (ECR repo, Helm release, namespace `asa-<name>`).

Um manifesto = um deployable = uma Helm release. API e worker são releases distintas (mesmo que compartilhem imagem/solução).

### kind → chart

O manifesto **obrigatório** `deploy/config/<env>.yaml` declara `kind`. A plataforma escolhe o chart (o consumidor **não** informa `chartPath`):

| kind | Chart |
|------|-------|
| `Application` | `charts/asa-application` |
| `ScheduledJob` | `charts/asa-scheduled-job` |

### Application (`workload.type`)

| type | Recursos |
|------|----------|
| `web` | Deployment + Service + HTTPRoute (+ HPA) — porta **8080** |
| `grpc` | Deployment + Service + GRPCRoute (+ HPA) — porta **50051** |
| `worker` | Deployment (+ HPA) — sem Service/Route/DNS |

Portas são contrato da plataforma (imagem .NET). **`workload.port` não existe** no manifesto.

```yaml
kind: Application
workload:
  type: web
legacyDns: false          # hostname .asa.com.br (só web/grpc)
probes:
  path: /health-check     # opt-in; sem path = sem probe
autoscaling:
  minReplicas: 2
  maxReplicas: 5
  cpu:
    target: 70
```

gRPC probes: `probes.readiness.enabled: true` (sem path HTTP).

### ScheduledJob

```yaml
kind: ScheduledJob
schedule:
  expression: "0 2 * * *"
  timeZone: America/Sao_Paulo
execution:
  retries: 2
  args: ["--mode=job"]   # command ou args obrigatório
```

Gera só CronJob (`restartPolicy: Never`). Sem Deployment/Service/probes/HPA.

### Opt-ins comuns (Application)

| Manifesto | Efeito |
|-----------|--------|
| `config` | ConfigMap → envFrom |
| `externalSecret` | ExternalSecret → Secret (requer ESO) |
| `serviceAccount.annotations` | IRSA |
| `workloadIdentity.gcp` | WIF EKS→GCP |
| `persistence.mountPath` + `size` | PVC RWO (exige `autoscaling: false`, `replicaCount: 1`) |
| `legacyDns: true` | hostname legado `.asa.com.br` (web/grpc) |
| `probes` | HTTP (web) ou gRPC (grpc) — sem fallback de path |

Pipeline injeta: `image.*`, `runtime.environment` (Application).

### HTTPRoute / Gateway / DNS (web e grpc)

| Environment | Hostname corp | Gateway | Legado (`legacyDns`) |
|-------------|---------------|---------|----------------------|
| `develop` | `<app>.dev.asa.corp` | `d-asa-com-br-internal-gateway` | `<app>.d.asa.com.br` |
| `homolog` | `<app>.hml.asa.corp` | `h-asa-com-br-internal-gateway` | `<app>.h.asa.com.br` |
| `production` | `<app>.prd.asa.corp` | `p-asa-com-br-internal-gateway` | `<app>.p.asa.com.br` |

### Testes

```bash
helm lint charts/asa-application
helm lint charts/asa-scheduled-job
./tests/chart-invariants.sh
```

### Versões

| Tag | Notas |
|-----|-------|
| `v1.0.0` | Chart `app`; probes sempre `/health-check`; CronJob addon |
| `v2.0.0` | Chart `app`; probes opt-in |
| `v3.0.0` | `asa-application` + `asa-scheduled-job`; `kind` obrigatório; CronJob = deployable separado |

**Migração v2 → v3:** mover `cronJob:` para um segundo pipeline/`applicationName` com `kind: ScheduledJob`. Trocar `exposeAsaComBr` por `legacyDns`. Declarar `kind` + `workload.type`.

Novas capabilities: só com consumidor real + bump de versão.
