# Pipeline Templates

Templates YAML reutilizáveis para Azure DevOps. Este repositório fica no GitHub e é referenciado por pipelines em outros repositórios via `resources.repositories` + `extends`.

## O que existe hoje

| Template | Caminho | Escopo |
|----------|---------|--------|
| CI .NET 10 | [`templates/dotnet/ci.yml`](templates/dotnet/ci.yml) | Restore, build e test |

**Ainda não inclui:** publish de artefatos, deploy, cache NuGet, quality gates (Sonar etc.).

## Pré-requisito

No Azure DevOps, crie uma **service connection** do tipo GitHub com acesso a este repositório. No exemplo usamos o nome `GitHub` — ajuste se o seu for diferente.

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
      endpoint: GitHub
      ref: refs/heads/main

extends:
  template: templates/dotnet/ci.yml@templates
  parameters:
    solution: '**/*.sln'
    buildConfiguration: 'Release'
```

Triggers (`trigger` / `pr`) ficam no pipeline consumidor, não no template.

## Parâmetros — `templates/dotnet/ci.yml`

| Parâmetro | Default | Descrição |
|-----------|---------|-----------|
| `solution` | `'**/*.sln'` | Caminho do `.sln` ou `.csproj` |
| `buildConfiguration` | `'Release'` | Configuração MSBuild |
| `vmImage` | `'ubuntu-latest'` | Imagem do agent Microsoft-hosted |
| `dotnetVersion` | `'10.x'` | Versão do SDK .NET |

## Evolução futura

Próximas iterações previstas: publish de artefatos/containers, deploy, templates por steps/jobs, versionamento por tags (`refs/tags/v1`) e quality gates.
