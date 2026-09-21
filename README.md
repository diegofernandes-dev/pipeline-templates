# Pipeline Templates

Templates YAML reutilizáveis para Azure DevOps. Este repositório fica no GitHub e é referenciado por pipelines em outros repositórios via `resources.repositories` + `extends`.

## O que existe hoje

| Template | Caminho | Escopo |
|----------|---------|--------|
| CI .NET 10 | [`templates/dotnet/ci.yml`](templates/dotnet/ci.yml) | Restore, build, test; opcional ECR (BuildKit) e deploy Helm no Rancher |
| Chart | [`charts/asa-app`](charts/asa-app) | Chart Helm genérico (`asa-app`) usado no stage Deploy |

**Ainda não inclui:** cache NuGet, quality gates (Sonar etc.), assinatura Cosign.

## Pré-requisito

No Azure DevOps, crie uma **service connection** do tipo GitHub com acesso a este repositório. No exemplo usamos o nome `github-diegofernandes-dev` — ajuste se o seu for diferente.

Para `buildImage` / `deployEnabled`, o agent pool (default `PG-AWS-EKS`) precisa de:

- BuildKit (`buildctl` + `crane`) e credenciais AWS (ECR)
- `helm` + `kubectl` com RBAC no namespace de destino (ex. `proving-ground-app`)

## Como consumir

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
    buildConfiguration: 'Release'
    buildImage: true
    ecrRepository: 'my-api'
    deployEnabled: true
    helmReleaseName: 'proving-ground-app'
    helmNamespace: 'proving-ground-app'
```

Triggers (`trigger` / `pr`) ficam no pipeline consumidor, não no template.

## Parâmetros — `templates/dotnet/ci.yml`

| Parâmetro | Default | Descrição |
|-----------|---------|-----------|
| `solution` | `'**/*.sln'` | Caminho do `.sln` ou `.csproj` |
| `buildConfiguration` | `'Release'` | Configuração MSBuild |
| `vmImage` | `'ubuntu-latest'` | Imagem do agent Microsoft-hosted (stage CI) |
| `dotnetVersion` | `'10.x'` | Versão do SDK .NET |
| `additionalSdkVersions` | `[]` | SDKs extras (ex. `['8.x']`) se o TFM for mais antigo |
| `buildImage` | `false` | Stage Container (build + push ECR) |
| `containerPool` | `'PG-AWS-EKS'` | Pool self-hosted (BuildKit + Helm) |
| `awsAccountId` | `'448003890252'` | Conta AWS do registry ECR |
| `awsRegion` | `'us-east-1'` | Região do ECR |
| `ecrRepository` | `''` | Nome do repositório ECR |
| `dockerfile` | `'Dockerfile'` | Caminho do Dockerfile |
| `dockerContext` | `'.'` | Contexto do build |
| `deployEnabled` | `false` | Stage Deploy (Helm); requer `buildImage: true` |
| `helmReleaseName` | `'proving-ground-app'` | Release Helm |
| `helmNamespace` | `'proving-ground-app'` | Namespace no Rancher |
| `helmChartPath` | `'charts/asa-app'` | Chart no repo de templates |
| `helmTimeout` | `'5m'` | Timeout do `--wait` |
| `helmCreateNamespace` | `true` | Passa `--create-namespace` |

Fluxo: CI (hosted) → Container (ECR) → Deploy (`helm upgrade --install` com `image.repository` + `image.digest`).

## Evolução futura

Versionamento por tags (`refs/tags/v1`), quality gates e assinatura de imagem.
