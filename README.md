# Pipeline Templates

Templates YAML reutilizáveis para Azure DevOps (GitHub → `extends`).

## Conteúdo

| Caminho | Escopo |
|---------|--------|
| [`templates/dotnet/ci.yml`](templates/dotnet/ci.yml) | CI → ECR → Helm (promução) |
| [`templates/dotnet/helm-deploy.yml`](templates/dotnet/helm-deploy.yml) | Stage Helm por Environment |
| [`docker/dotnet/Dockerfile`](docker/dotnet/Dockerfile) | Dockerfile plataforma (.NET web/API) |
| [`charts/app`](charts/app) | Chart da plataforma (Deployment, Service, HPA, PDB, SA, HTTPRoute) |
| [`tests/chart-invariants.sh`](tests/chart-invariants.sh) | Testes mínimos do chart |

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
    dotnetProject: src/Sample.Api/Sample.Api.csproj
    deployEnvironments:
      - name: develop
        variableGroups: []
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
| Helm release / Service / HTTPRoute | `applicationName` |
| Namespace | `asa-<applicationName>` (mesmo nome em cada cluster; sem sufixo) |
| Conta AWS / registry ECR | `aws sts get-caller-identity` no agent |
| Helm chart | fixo: `charts/app` |
| Dockerfile | fixo: `docker/dotnet/Dockerfile` (runtime-only) |
| Imagem base | `mcr.microsoft.com/dotnet/aspnet:<tag>` — TFM avaliado via MSBuild (`net8.0` → `8.0`) |
| Conteúdo da imagem | `dotnet publish` no CI → artifact `app` → Container empacota |

### Chart baseline

| Item | Valor |
|------|--------|
| Resources | request CPU `150m`, memory `256Mi`; limit memory `512Mi`; **sem** CPU limit |
| Probes | contrato obrigatório `GET /health-check` (startup/liveness/readiness) |
| HPA | CPU 70%; `minReplicas`/`maxReplicas` = política de disponibilidade (default lab 1/3) |
| PDB | **off** por default (inútil com 1 réplica + maxUnavailable 1) |
| Pull ECR | sem `imagePullSecret` — EKS via node/IRSA |
| HTTPRoute | hostnames + Gateway derivados do Environment |
| Security | non-root, seccomp, drop caps, read-only root + `/tmp` |

Build `linux/amd64`. Helm `--reset-values --atomic --wait`.

### HTTPRoute / Gateway / DNS

| Environment ADO | Hostname corp | Gateway | Hostname legado (`exposeAsaComBr`) |
|-----------------|---------------|---------|-------------------------------------|
| `develop` | `<app>.dev.asa.corp` | `d-asa-com-br-internal-gateway` | `<app>.d.asa.com.br` |
| `homolog` | `<app>.hml.asa.corp` | `h-asa-com-br-internal-gateway` | `<app>.h.asa.com.br` |
| `production` | `<app>.prd.asa.corp` | `p-asa-com-br-internal-gateway` | `<app>.p.asa.com.br` |

Gateway namespace: `asa-infra-nginx-gateway`. DNS: ExternalDNS observa `HTTPRoute.spec.hostnames` (sem annotation duplicada).

### Environments vs target AWS/Kubernetes

Hoje o Environment ADO controla: **ordem de promoção**, **approvals**, **hostnames**, **Gateway**.

O agent (`containerPool`) e o kube context / conta AWS ainda são os **ambientais do pool** (lab: mesmo Rancher + mesmas credenciais para develop/hml/prd). Não há engine de target: quando HML/PRD tiverem pools ou contexts distintos, isso entra via pool/credencial do Environment — não via parâmetros novos no template.

### Variable Groups

`deployEnvironments[].variableGroups` anexa Variable Groups ao stage Deploy. Uso concreto: secrets/config **do ambiente** quando existirem. Lista vazia é válida. Não há sistema genérico de ConfigMap/Secret no chart.

### Lab (Rancher) — ECR pull

O baseline **não** cria `ecr-pull`. Em cluster sem IAM de node para ECR (ex. Rancher), provisione o secret fora da plataforma e defina a variável de pipeline `ECR_PULL_SECRET` com o nome do secret.

## Parâmetros principais

| Parâmetro | Default | Descrição |
|-----------|---------|-----------|
| `applicationName` | `''` | Identidade; obrigatório se houver deploy |
| `dotnetProject` | `''` | `.csproj` a publicar; TFM → tag aspnet |
| `dotnetVersion` | `10.x` | SDK do agent CI |
| `deployEnvironments` | `[]` | Ambientes + VGs; vazio = só CI |
| `exposeAsaComBr` | `false` | Hostname legado `.asa.com.br` em `spec.hostnames` |
| `containerPool` | `PG-AWS-EKS` | Agent self-hosted |

## Testes

```bash
./tests/chart-invariants.sh
```
