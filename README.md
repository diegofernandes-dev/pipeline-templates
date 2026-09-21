# Pipeline Templates

Templates YAML reutilizáveis para Azure DevOps (GitHub → `extends`).

## Conteúdo

| Caminho | Escopo |
|---------|--------|
| [`templates/dotnet/ci.yml`](templates/dotnet/ci.yml) | CI → ECR → Helm (opcional) |
| [`charts/app`](charts/app) | Chart da plataforma (Deployment + Service + HPA) |

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
| Namespace | `asa-<applicationName>` (mesmo nome em cada cluster; sem sufixo de ambiente) |
| Conta AWS / registry ECR | `aws sts get-caller-identity` no agent |
| Helm chart | fixo: `charts/app` (sem `helmChartPath` público) |

Chart `charts/app`: resources explícitos, porta `http`, probes em `/health-check`, HPA dono das réplicas.

Build de imagem fixa `linux/amd64`. Helm deploy usa `--atomic --wait`.

Obrigatório quando `buildImage` ou `deployEnabled` é `true`.

### Ambientes ADO

| Environment | No template hoje |
|-------------|------------------|
| `develop` | Stage `DeployDevelop` (ativo quando `deployEnabled`) |
| `homolog` | Próximo incremento |
| `production` | Próximo incremento |

Namespace **não** muda por ambiente: o mesmo `asa-<applicationName>` em clusters diferentes. A imagem promovida é a mesma (tag = commit SHA).

Pré-requisito: Environment `develop` criado no projeto Azure DevOps.

Pool `PG-AWS-EKS`: BuildKit (`buildctl`/`crane`) + AWS/ECR + `helm`/`kubectl`. Credenciais AWS são as do agent (ambient).

## Parâmetros principais

| Parâmetro | Default | Descrição |
|-----------|---------|-----------|
| `applicationName` | `''` | Identidade da app (ECR + release + namespace) |
| `buildImage` | `false` | Build/push ECR |
| `deployEnabled` | `false` | Helm deploy em `develop` com chart `charts/app` (requer `buildImage`) |
| `containerPool` | `PG-AWS-EKS` | Agent self-hosted |
