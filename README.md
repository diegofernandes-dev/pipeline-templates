# Pipeline Templates

Templates YAML reutilizáveis para Azure DevOps (GitHub → `extends`).

## Conteúdo

| Caminho | Escopo |
|---------|--------|
| [`templates/dotnet/ci.yml`](templates/dotnet/ci.yml) | CI → ECR → Helm (promução) |
| [`templates/dotnet/helm-deploy.yml`](templates/dotnet/helm-deploy.yml) | Stage Helm por Environment |
| [`docker/dotnet/Dockerfile`](docker/dotnet/Dockerfile) | Dockerfile plataforma (.NET web/API) |
| [`charts/app`](charts/app) | Chart da plataforma (API + opt-ins: WIF, config/ESO, PVC, CronJob) |
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
        containerPool: PG-AWS-EKS
        variableGroups: []
      - name: homolog
        containerPool: PG-AWS-EKS-HML
        variableGroups:
          - sample-api-homolog
      - name: production
        containerPool: PG-AWS-EKS
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
| Probes | contrato `GET /health-check` (startup + liveness + readiness) |
| HPA | CPU 70%; `minReplicas`/`maxReplicas` = política de disponibilidade (default lab 1/3) |
| PDB | **off** por default (inútil com 1 réplica + maxUnavailable 1); toggle `pdb.enabled` |
| Pull ECR | pipeline não cria `imagePullSecret`; cluster/node runtime deve ter acesso ao ECR |
| HTTPRoute | hostnames + Gateway derivados do Environment (pipeline); `httpRoute.enabled` |
| Security | non-root, seccomp, drop caps, read-only root + `/tmp` |
| Opt-ins (manifesto) | IRSA, WIF, config, ExternalSecret, PVC, CronJob |

Build `linux/amd64`. Helm `--reset-values --atomic --wait`.

### HTTPRoute / Gateway / DNS

| Environment ADO | Hostname corp | Gateway | Hostname legado (`exposeAsaComBr`) |
|-----------------|---------------|---------|-------------------------------------|
| `develop` | `<app>.dev.asa.corp` | `d-asa-com-br-internal-gateway` | `<app>.d.asa.com.br` |
| `homolog` | `<app>.hml.asa.corp` | `h-asa-com-br-internal-gateway` | `<app>.h.asa.com.br` |
| `production` | `<app>.prd.asa.corp` | `p-asa-com-br-internal-gateway` | `<app>.p.asa.com.br` |

Gateway namespace: `asa-infra-nginx-gateway`. DNS: ExternalDNS observa `HTTPRoute.spec.hostnames` (sem annotation duplicada).

### Environments vs target AWS/Kubernetes

O Environment ADO controla: **ordem de promoção**, **approvals**, **hostnames**, **Gateway**.

O **target físico** (cluster / kube context / conta AWS ambient) é o do **agent pool** do Deploy:

| Campo | Papel |
|-------|--------|
| `containerPool` (raiz) | Pool do stage Container (build/push ECR) |
| `deployEnvironments[].containerPool` | Pool do Deploy daquele ambiente (opcional; default = `containerPool` raiz) |

O agent de cada pool já carrega o kubeconfig do cluster em que roda. Não há parâmetro de kubeContext/awsAccount no template.

### Variable Groups

`deployEnvironments[].variableGroups` ainda pode anexar VGs ao stage Deploy (lab / legado). **Não** use VG para config de app, IRSA ou WIF — isso vai no manifesto por ambiente.

### Manifesto por ambiente (overlay da app)

No repo da aplicação:

```text
deploy/config/develop.yaml
deploy/config/homolog.yaml
deploy/config/production.yaml
```

O Deploy faz `helm upgrade -f deploy/config/<Environment>.yaml` quando o ficheiro existe. Path configurável: parâmetro `runtimeConfigPath` (default `deploy/config`).

| No manifesto | Efeito |
|--------------|--------|
| `config` (map não vazio) | ConfigMap `{app}-config` → `envFrom` |
| `externalSecret.data` + `secretStoreRef.name` | CR ExternalSecret → Secret `{app}-secret` → `envFrom` (requer ESO) |
| `serviceAccount.annotations` | IRSA (`eks.amazonaws.com/role-arn`) |
| `workloadIdentity.gcp.audience` (+ `serviceAccountEmail`) | WIF EKS→GCP; chart cria `{app}-wif-credentials` (`external_account`) |
| `persistence.mountPath` (+ `size`) | PVC `{app}-data` (RWO, `resource-policy: keep`); exige `autoscaling: false` e `replicaCount: 1` |
| `cronJob.schedule` | CronJob `{app}-cron` (adicional à API; reusa image/SA/config/WIF; sem probes/PVC; labels sem `app=` do Service) |
| `autoscaling` (map) | HPA; para desligar no env: `autoscaling: false` |
| `resources` / `pdb` | Overrides por env (`pdb` ainda usa `enabled`) |

Regra do manifesto: **preencheu o bloco ⇒ aplica**. Sem flags `enabled` / nesting `data` em `config`. Omitir o bloco mantém o default do chart.

**Fica fora do manifesto:** `image.*` (CI), `httpRoute.environment` / Gateway (pipeline), probes/security (contrato do chart), valores secretos.

Exemplo: [`examples/deploy/config/develop.yaml`](examples/deploy/config/develop.yaml).

### Identidade do workload (opt-in via manifesto)

Runtime é sempre **EKS**. Sem manifesto de identidade ⇒ SA sem IRSA, sem WIF.

**EKS → AWS (IRSA):** annotation no manifesto; Role IAM fora do chart.

**EKS → GCP:** `workloadIdentity.gcp` no manifesto (`audience` = provider GCP no `external_account`, `serviceAccountEmail`, opcional `projectId`). O projected SA token usa `token.audience` (default `sts.amazonaws.com`, contrato corporativo EKS→GCP). Chart gera o ConfigMap — sem CM pré-provisionado. Opt-out: `workloadIdentity: false`. `automountServiceAccountToken` permanece `false`.

IRSA e GCP WIF podem coexistir no mesmo ServiceAccount/pod.

### Lab (Rancher) — ECR pull

Baseline AWS/EKS: o pipeline **não** cria `imagePullSecret`; o cluster/node runtime deve ter acesso apropriado ao ECR.

Em lab sem esse acesso (ex. Rancher), provisione o secret fora da plataforma e defina a variável de pipeline `ECR_PULL_SECRET` com o nome do secret. Variável ausente ⇒ nenhum `imagePullSecret`.

## Parâmetros principais

| Parâmetro | Default | Descrição |
|-----------|---------|-----------|
| `applicationName` | `''` | Identidade; obrigatório se houver deploy |
| `dotnetProject` | `''` | `.csproj` a publicar; TFM → tag aspnet |
| `dotnetVersion` | `10.x` | SDK do agent CI |
| `deployEnvironments` | `[]` | Ambientes + `containerPool` por env; vazio = só CI |
| `runtimeConfigPath` | `deploy/config` | Pasta dos manifestos `<env>.yaml` no repo da app |
| `exposeAsaComBr` | `false` | Hostname legado `.asa.com.br` em `spec.hostnames` |
| `containerPool` | `PG-AWS-EKS` | Pool do Container (+ default dos Deploys sem override) |

## Testes

```bash
./tests/chart-invariants.sh
```

## Freeze (Helm)

**Status: FROZEN** at chart `app` **v1.0.0** (API .NET → EKS).

Escopo **dentro** do freeze:

```text
CI → ECR → Helm
Deployment + Service + SA + probes + security + resources
HPA / PDB (opt)
HTTPRoute + Gateway por Environment
Manifesto: config, ExternalSecret, IRSA, WIF, PVC, CronJob
```

**Não** entra sem consumidor real + decisão explícita:

- StatefulSet / vários PVCs / RWX
- cronjob-only / múltiplos CronJobs / workers genéricos
- NetworkPolicy, ServiceMonitor/PodMonitor
- SealedSecrets / secrets no Git ou VG→Secret de app
- GKE / multicloud de deploy
- Image signing, Sonar, cache de build como contrato do template
- `workloadType` / framework genérico de workloads

Novas capabilities: só com necessidade comprovada e incremento aprovado (bump de chart version).
