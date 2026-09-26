# Pipeline Templates

Templates YAML reutilizáveis para Azure DevOps (GitHub → `extends`).

## Conteúdo

| Caminho | Escopo |
|---------|--------|
| [`templates/dotnet/ci.yml`](templates/dotnet/ci.yml) | CI → ECR → entrega (`deliveryMode: helm` \| `gitops`) |
| [`templates/dotnet/container-build.yml`](templates/dotnet/container-build.yml) | Stage `Container` (build único + digest + provenance) |
| [`templates/dotnet/helm-deploy.yml`](templates/dotnet/helm-deploy.yml) | Stage Helm por Environment (`kind` → chart) — caminho atual |
| [`config/platform-environments.json`](config/platform-environments.json) | Mapping autoritativo env → pool / gateway |
| [`docker/dotnet/Dockerfile`](docker/dotnet/Dockerfile) | Dockerfile plataforma (.NET; listen 8080) |
| [`charts/asa-application`](charts/asa-application) | `kind: Application` — web \| grpc \| worker |
| [`charts/asa-scheduled-job`](charts/asa-scheduled-job) | `kind: ScheduledJob` — CronJob |
| [`schemas/`](schemas/) | Schema **público** (`additionalProperties: false`) |
| [`scripts/`](scripts/) | `jsonschema` + identidade cross-env (`yq`) |
| [`tests/`](tests/) | Render invariants + drift |
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | CI obrigatório do repositório |

## Consumo

Exemplos prontos:

| Arquivo | Uso |
|---------|-----|
| [`examples/azure-pipelines.yml`](examples/azure-pipelines.yml) | `kind: Application` (web/grpc/worker) |
| [`examples/azure-pipelines.scheduled-job.yml`](examples/azure-pipelines.scheduled-job.yml) | `kind: ScheduledJob` |
| [`examples/azure-pipelines.gitops.yml`](examples/azure-pipelines.gitops.yml) | `deliveryMode: gitops` (Kargo + Argo CD) |
| [`examples/deploy/config/`](examples/deploy/config/) | Manifestos mínimos |

```yaml
variables:
  # Lab sem IAM no node: secret docker-registry renovado no deploy. Omitir com node IAM.
  ECR_PULL_SECRET: ecr-pull

resources:
  repositories:
    - repository: templates
      type: github
      name: diegofernandes-dev/pipeline-templates
      endpoint: github-diegofernandes-dev
      # Após release, pin em refs/tags/vX.Y.Z. Até lá: main ou commit SHA.
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
        variableGroups: []
```

Pós-deploy (evidência cluster): [`scripts/proving-ground-evidence.sh`](scripts/proving-ground-evidence.sh).

`applicationName` = **um deployable** = **uma imagem ECR** = **uma Helm release** = namespace `asa-<name>` = hostname. A implementação atual **não** compartilha imagem entre API e worker/job — use `applicationName` distintos.

### Fluxo

`deliveryMode: helm` (default, caminho atual):

```text
CI (build/test) ──┐
                  ├→ Container (ECR IMMUTABLE)
DeployContract ───┘
                  ↓
               Deploy (Helm, sem --atomic)
```

Manifesto inválido falha **antes** do push de imagem.

`deliveryMode: gitops` (pivot Kargo/Argo — proving ground):

```text
CI (build/test) ──┐
                  ├→ Container (ECR IMMUTABLE + digest + provenance)
GitOpsContract ───┘
                  ↓
        (fim do Azure DevOps)
                  ↓
Kargo Warehouse → Freight → develop → homolog → Argo CD → EKS
```

Em gitops mode o consumidor **não** escolhe infraestrutura: `deployEnvironments` e
`expectedKubeContext` são rejeitados, não ignorados. Ver
[`docs/gitops-kargo-argo.md`](docs/gitops-kargo-argo.md).

### Imagem: tag ou digest

| Caminho | Pin |
|---------|-----|
| `deliveryMode: helm` | `image.tag` = `Build.SourceVersion` (ECR IMMUTABLE) |
| `deliveryMode: gitops` | `image.digest` = `sha256:…` escrito pelo Kargo (**vence** o tag) |

Digest malformado ou imagem sem digest **e** sem tag falha o render — desired state
não pinado nunca é aplicado.

### Contrato público

| type | Recursos |
|------|----------|
| `web` | Deploy + Service **8080** + HTTPRoute + HPA (min 1/1/2 por env) |
| `grpc` | Deploy + Service **8080** h2c + GRPCRoute + HTTP/2 + HPA |
| `worker` | Deploy; **sem** HPA default; sem Service/Route |
| `ScheduledJob` | CronJob; `timeZone` + `timeoutSeconds` obrigatórios |

Porta networked = **8080**. `workload.port` não existe.

**Probes (web/grpc):** obrigatório escolher `probes: false` **ou** objeto com pelo menos uma probe explícita. Sem `probes.path` global. Sem `/health-check` implícito.

**ServiceAccount público:** só `annotations` (IRSA). Plataforma cria SA = release name, `automountServiceAccountToken: false`.

**config:** mapa livre de strings; use `ConnectionStrings__Default` (hierarquia .NET). Reservados rejeitados: `ASPNETCORE_URLS`, `ASPNETCORE_HTTP_PORTS`, `ASPNETCORE_HTTPS_PORTS`, `GOOGLE_APPLICATION_CREDENTIALS`, `Kestrel__*`.

**WIF + IRSA:** token GCP em `/var/run/secrets/gcp/serviceaccount` (não colide com IRSA).

### ScheduledJob

```yaml
schedule:
  expression: "0 2 * * *"
  timeZone: America/Sao_Paulo          # obrigatório
  startingDeadlineSeconds: 600         # opcional — “ainda vale a pena rodar atrasado?”
execution:
  timeoutSeconds: 1800                 # obrigatório → activeDeadlineSeconds
  args: ["--mode=job"]
```

### Helm recovery (baixo blast radius)

| Situação | Ação |
|----------|------|
| Falha de first install | diagnostics → **FAIL** (sem uninstall automático) |
| Falha de upgrade com revisão `deployed` | diagnostics → rollback → **FAIL** |
| Rollback falha | **FAIL** — **nunca** uninstall |
| `pending-install` sem revisão deployed | diagnostics → uninstall limpeza |
| `pending-upgrade` / `failed` | diagnostics → rollback para última `deployed` |

ADO Environments de deploy devem ter **exclusividade/lock** (requisito operacional; não há lock em Bash).

### Platform environment mapping

Ver [`config/platform-environments.json`](config/platform-environments.json).

| Env | Pool | expectedKubeContext |
|-----|------|---------------------|
| develop | `PG-AWS-EKS` | **EXTERNAL BLOCKER** (não mapeado) |
| homolog | `PG-AWS-EKS-HML` | **EXTERNAL BLOCKER** |
| production | **EXTERNAL BLOCKER** | **EXTERNAL BLOCKER** |

Contexto kubectl: match **exato** quando mapeado (sem substring).

### Proving ground Kargo/Argo

Evidência (read-only, responde SHA ↔ digest ↔ Freight ↔ Stage ↔ Argo ↔ pod):

```bash
./scripts/kargo-argo-evidence.sh pt-kargo-web
```

Arquitetura, modelo de branches e estratégia de remoção da API pública:
[`docs/gitops-kargo-argo.md`](docs/gitops-kargo-argo.md).

### Testes locais / CI do repo

```bash
helm lint charts/asa-application
helm lint charts/asa-scheduled-job --set-string schedule.expression='0 2 * * *' \
  --set-string schedule.timeZone=UTC --set execution.timeoutSeconds=60 \
  --set-string 'execution.args[0]=x'
./tests/chart-drift.sh
./tests/chart-invariants.sh
```

### Premissas / docs

- **Data Protection:** `readOnlyRootFilesystem` + múltiplas réplicas pode exigir key ring externo na aplicação — não resolvido pelo chart.
- **Proving ground (não inventar):** versão mínima EKS / `kubeVersion` / PSA enforce-version / label `Gateway.allowedRoutes` / PDB / TopologySpread / preStop / prova gRPC e2e no cluster.

### Versões

| Tag | Notas |
|-----|-------|
| `v3.1.0` | imutável |
| `v3.1.1` | hardening (porta 8080, probes explícitos, SA, recovery, contract-first, …) |
| `main` (pós-v3.1.1) | fixes do proving ground (Gateway preflight yq, ECR pull secret, …) — pin SHA/`main` até a próxima tag |
