# Pipeline Templates

Templates YAML reutilizáveis para Azure DevOps. Este repositório fica no GitHub e é referenciado por pipelines em outros repositórios via `resources.repositories` + `extends`.

## O que existe hoje

| Template | Caminho | Escopo |
|----------|---------|--------|
| CI .NET 10 | [`templates/dotnet/ci.yml`](templates/dotnet/ci.yml) | Restore, build, test; opcionalmente build/push de imagem no ECR |

**Ainda não inclui:** deploy, cache NuGet, quality gates (Sonar etc.), assinatura Cosign.

## Pré-requisito

No Azure DevOps, crie uma **service connection** do tipo GitHub com acesso a este repositório. No exemplo usamos o nome `github-diegofernandes-dev` — ajuste se o seu for diferente.

Para `buildImage: true`, o agent pool (default `PG-AWS-EKS`) precisa de Docker e credenciais AWS com acesso ao ECR.

## Como consumir

1. No repositório da aplicação, crie um `azure-pipelines.yml` (ou use o exemplo em [`examples/azure-pipelines.yml`](examples/azure-pipelines.yml)).
2. Declare o resource apontando para este repo.
3. Use `extends` no template desejado.

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
```

Triggers (`trigger` / `pr`) ficam no pipeline consumidor, não no template.

## Parâmetros — `templates/dotnet/ci.yml`

| Parâmetro | Default | Descrição |
|-----------|---------|-----------|
| `solution` | `'**/*.sln'` | Caminho do `.sln` ou `.csproj` |
| `buildConfiguration` | `'Release'` | Configuração MSBuild |
| `vmImage` | `'ubuntu-latest'` | Imagem do agent Microsoft-hosted (stage CI) |
| `dotnetVersion` | `'10.x'` | Versão do SDK .NET |
| `additionalSdkVersions` | `[]` | SDKs extras (ex. `['8.x']`) se o TFM for mais antigo (inclui AspNetCore) |
| `buildImage` | `false` | Se `true`, executa stage Container (build + push ECR) |
| `containerPool` | `'PG-AWS-EKS'` | Pool self-hosted com Docker + ECR |
| `awsAccountId` | `'448003890252'` | Conta AWS do registry ECR |
| `awsRegion` | `'us-east-1'` | Região do ECR |
| `ecrRepository` | `''` | Nome do repositório ECR (obrigatório se `buildImage`) |
| `dockerfile` | `'Dockerfile'` | Caminho do Dockerfile |
| `dockerContext` | `'.'` | Contexto do `docker build` |

Tag da imagem: `$(Build.SourceVersion)` (SHA do commit).  
Referência: `{awsAccountId}.dkr.ecr.{awsRegion}.amazonaws.com/{ecrRepository}:{sha}`

## Evolução futura

Próximas iterações previstas: deploy, versionamento por tags (`refs/tags/v1`), quality gates e assinatura de imagem.
