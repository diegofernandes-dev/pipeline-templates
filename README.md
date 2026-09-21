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
    buildImage: true
    ecrRepository: 'my-api'
    deployEnabled: true
    helmReleaseName: 'sample-api'
    helmNamespace: 'proving-ground-app'
```

Pool `PG-AWS-EKS`: BuildKit (`buildctl`/`crane`) + AWS/ECR + `helm`/`kubectl`.

## Parâmetros principais

| Parâmetro | Default | Descrição |
|-----------|---------|-----------|
| `buildImage` | `false` | Build/push ECR |
| `deployEnabled` | `false` | Helm deploy (requer `buildImage`) |
| `ecrRepository` | `''` | Repo ECR |
| `containerPool` | `PG-AWS-EKS` | Agent self-hosted |
| `helmReleaseName` | `sample-api` | Release |
| `helmNamespace` | `proving-ground-app` | Namespace |
| `helmChartPath` | `charts/app` | Chart no repo de templates |
