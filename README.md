# Pipeline Templates

Templates YAML reutilizáveis para Azure DevOps (GitHub → `extends`).

## Conteúdo

| Caminho | Escopo |
|---------|--------|
| [`templates/dotnet/ci.yml`](templates/dotnet/ci.yml) | CI → ECR → Helm (opcional) |
| [`charts/app`](charts/app) | Chart mínimo (Deployment + Service) |

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
      ref: refs/heads/main

extends:
  template: templates/dotnet/ci.yml@templates
  parameters:
    solution: '**/*.sln'
    applicationName: sample-api
    buildImage: true
    deployEnabled: true
```

`applicationName` é a identidade única da aplicação. A plataforma deriva:

| Derivado | Regra |
|----------|--------|
| ECR repository | `applicationName` |
| Helm release | `applicationName` |
| Namespace | `asa-<applicationName>` (cria/usa idempotente) |
| Conta AWS / registry ECR | `aws sts get-caller-identity` no agent |
| Helm chart | fixo: `charts/app` (sem `helmChartPath` público) |

Obrigatório quando `buildImage` ou `deployEnabled` é `true`.

Pool `PG-AWS-EKS`: BuildKit (`buildctl`/`crane`) + AWS/ECR + `helm`/`kubectl`. Credenciais AWS são as do agent (ambient).

## Parâmetros principais

| Parâmetro | Default | Descrição |
|-----------|---------|-----------|
| `applicationName` | `''` | Identidade da app (ECR + release + namespace) |
| `buildImage` | `false` | Build/push ECR |
| `deployEnabled` | `false` | Helm deploy com chart `charts/app` (requer `buildImage`) |
| `containerPool` | `PG-AWS-EKS` | Agent self-hosted |
