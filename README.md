# Pipeline Templates

Templates YAML reutilizáveis para Azure DevOps (GitHub → `extends`).

## Conteúdo

| Caminho | Escopo |
|---------|--------|
| [`templates/dotnet/ci.yml`](templates/dotnet/ci.yml) | CI → ECR → Helm (promução) |
| [`templates/dotnet/helm-deploy.yml`](templates/dotnet/helm-deploy.yml) | Stage Helm por Environment |
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
    deployEnvironments:
      - name: develop
        variableGroups: []
      - name: homolog
        variableGroups:
          - sample-api-homolog
          - shared-platform-homolog
      - name: production
        variableGroups:
          - sample-api-production
```

Só HML → PRD:

```yaml
deployEnvironments:
  - name: homolog
    variableGroups:
      - sample-api-homolog
  - name: production
    variableGroups:
      - sample-api-production
```

Só CI (ex.: PR): `deployEnvironments: []` (default) — sem Container/Deploy.

`applicationName` é a identidade única. A plataforma deriva:

| Derivado | Regra |
|----------|--------|
| ECR repository | `applicationName` |
| Helm release | `applicationName` |
| Namespace | `asa-<applicationName>` (mesmo nome em cada cluster; sem sufixo) |
| Conta AWS / registry ECR | `aws sts get-caller-identity` no agent |
| Helm chart | fixo: `charts/app` |

Chart `charts/app`: resources, porta `http`, probes `/health-check`, HPA. Build `linux/amd64`. Helm `--atomic --wait`.

### Ambientes e Variable Groups

| Campo | Regra |
|-------|--------|
| `deployEnvironments[].name` | `develop` \| `homolog` \| `production` (Environment ADO) |
| `deployEnvironments[].variableGroups` | Lista 0..N de Variable Groups daquele stage |
| Ordem | Ordem da lista = ordem dos stages (mesma imagem/SHA) |

Pré-requisito: Environments ADO criados no projeto. Approvals ficam na Environment (portal).

Pool `PG-AWS-EKS`: BuildKit + AWS/ECR + `helm`/`kubectl`.

## Parâmetros principais

| Parâmetro | Default | Descrição |
|-----------|---------|-----------|
| `applicationName` | `''` | Identidade (ECR + release + namespace); obrigatório se houver deploy |
| `deployEnvironments` | `[]` | Ambientes + VGs; vazio = só CI |
| `containerPool` | `PG-AWS-EKS` | Agent self-hosted |
