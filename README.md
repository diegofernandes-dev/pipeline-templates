# Pipeline Templates

Templates YAML reutilizáveis para Azure DevOps (GitHub → `extends`).

## Conteúdo

| Caminho | Escopo |
|---------|--------|
| [`templates/dotnet/ci.yml`](templates/dotnet/ci.yml) | CI → ECR → Helm (promução) |
| [`templates/dotnet/helm-deploy.yml`](templates/dotnet/helm-deploy.yml) | Stage Helm por Environment |
| [`charts/app`](charts/app) | Chart da plataforma (Deployment, Service, HPA, PDB, SA, HTTPRoute) |

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

Chart `charts/app`: resources, porta `http`, startup/liveness/readiness em `/health-check`, HPA, PDB (`maxUnavailable: 1`), ServiceAccount dedicado, securityContext (non-root, read-only root + `/tmp`), HTTPRoute. Build `linux/amd64`. Helm `--atomic --wait`.

NetworkPolicy **não** entra no baseline lab: Rancher Desktop sem CNI com enforcement de NetworkPolicy evidenciado.

### HTTPRoute / DNS por Environment

| Environment ADO | Hostname corp | Hostname legado (`exposeAsaComBr`) |
|-----------------|---------------|-------------------------------------|
| `develop` | `<app>.dev.asa.corp` | `<app>.d.asa.com.br` |
| `homolog` | `<app>.hml.asa.corp` | `<app>.h.asa.com.br` |
| `production` | `<app>.prd.asa.corp` | `<app>.p.asa.com.br` |

parentRefs: Gateway `d-asa-com-br-internal-gateway` em `asa-infra-nginx-gateway`.

No lab Rancher, sem Gateway/ExternalDNS, o HTTPRoute sobe; parent pode ficar não-Accepted e o DNS não é registrado de fato.

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
| `exposeAsaComBr` | `false` | Hostname legado `.d.asa.com.br` + annotation ExternalDNS |
| `containerPool` | `PG-AWS-EKS` | Agent self-hosted |
