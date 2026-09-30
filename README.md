# Pipeline Templates

Templates YAML reutilizáveis para Azure DevOps (GitHub → `extends`).

## Conteúdo

| Caminho | Escopo |
|---------|--------|
| [`templates/dotnet/ci.yml`](templates/dotnet/ci.yml) | CI → DeployContract → ECR → Helm |
| [`templates/dotnet/helm-deploy.yml`](templates/dotnet/helm-deploy.yml) | Stage Helm por Environment (`kind` → chart) |
| [`config/platform-environments.json`](config/platform-environments.json) | Mapping autoritativo env → pool / gateway / `expectedKubeContext` |
| [`docker/dotnet/Dockerfile`](docker/dotnet/Dockerfile) | Dockerfile plataforma (.NET; listen 8080) |
| [`charts/asa-application`](charts/asa-application) | `kind: Application` — web \| grpc \| worker |
| [`charts/asa-scheduled-job`](charts/asa-scheduled-job) | `kind: ScheduledJob` — CronJob |
| [`schemas/`](schemas/) | Schema **público** (`additionalProperties: false`) |
| [`scripts/`](scripts/) | `jsonschema`, identidade cross-env, paridade de schemas, descoberta de valores de plataforma |
| [`tests/`](tests/) | Render invariants + drift de chart/schema + consistência de gateway + kubeconform |
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | CI obrigatório do repositório |

## Consumo

```yaml
resources:
  repositories:
    - repository: templates
      type: github
      name: diegofernandes-dev/pipeline-templates
      endpoint: github-diegofernandes-dev
      ref: refs/tags/v3.2.0   # após release; até lá use commit SHA

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

`applicationName` = **um deployable** = **uma imagem ECR** = **uma Helm release** = namespace `asa-<name>` = hostname. A implementação atual **não** compartilha imagem entre API e worker/job — use `applicationName` distintos.

### Fluxo

```text
CI (build/test) ──┐
                  ├→ Container (ECR IMMUTABLE)
DeployContract ───┘
                  ↓
               Deploy (Helm, sem --atomic)
```

Manifesto inválido falha **antes** do push de imagem. `DeployContract` aplica **duas** camadas:
o schema público (rejeita chave desconhecida/typo) e `helm template` por ambiente (roda as
invariantes do próprio chart — chaves reservadas em `config`, forma de probe por `workload.type`,
`persistence` vs autoscaling, WIF/ExternalSecret parcial, ScheduledJob sem `command`/`args`). Sem a
segunda camada essas regras só apareceriam no Deploy, e para `production` só depois de develop e
homolog já implantados.

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

Contexto kubectl: match **exato** quando mapeado (sem substring). O stage de Deploy lê
`expectedKubeContext` **desse arquivo** — preencher o mapping ativa a guarda de identidade de
cluster, sem mexer em pipeline. Enquanto estiver `null`, o deploy emite warning e **não** valida
em qual cluster está aplicando.

### Testes locais / CI do repo

```bash
helm lint charts/asa-application \
  --set-string image.repository=example.dkr.ecr.us-east-1.amazonaws.com/sample-api
helm lint charts/asa-scheduled-job --set-string image.repository=example.dkr.ecr.us-east-1.amazonaws.com/sample-job \
  --set-string schedule.expression='0 2 * * *' \
  --set-string schedule.timeZone=UTC --set execution.timeoutSeconds=60 \
  --set-string 'execution.args[0]=x'
./tests/chart-drift.sh            # primitivas compartilhadas + paridade dos schemas
./tests/gateway-consistency.sh    # chart × platform-environments.json
./tests/chart-conform.sh          # kubeconform -strict nos manifests renderizados
./tests/chart-invariants.sh       # suíte completa (chama as três acima)
```

**TDD / guardrail para agentes:** antes de mudar `charts/**/templates/**` ou `values.schema.json`, escreva ou ajuste o assert em [`tests/chart-invariants.sh`](tests/chart-invariants.sh) que prova a propriedade; só então edite o chart. A suíte deve ficar vermelha se a propriedade sumir. Alguns negativos de “dupla trava” usam bypass temporário do `values.schema.json` para exercitar o `fail` do template (além do schema) — assim remover o `fail` “duplicado” no `.tpl` também quebra o CI.

**Helm version:** o CI pina **Helm v3.16.2**. O validador de `values.schema.json` mudou de prosa entre Helm 3 e 4 para a mesma violação — não assertar o texto literal do validador. Use `expect_schema_fail` (path + preâmbulo compartilhado), que funciona em 3.x e 4.x. A suíte recusa Helm &lt; 3.16 no início.

### Premissas / docs

- **Baseline de pod (platform-owned, fora do manifesto público):** `runAsNonRoot` + `runAsUser`/`runAsGroup`/`fsGroup` **1654** (= `APP_UID` de `mcr.microsoft.com/dotnet/aspnet`, verificado em 8.0/9.0/10.0 e **asseverado em build time** por [`docker/dotnet/Dockerfile`](docker/dotnet/Dockerfile) — imagem e chart não divergem em silêncio), `readOnlyRootFilesystem`, `seccompProfile: RuntimeDefault`, `drop: [ALL]`, `automountServiceAccountToken: false`, `enableServiceLinks: false`, `terminationMessagePolicy: FallbackToLogsOnError`, `/tmp` como `emptyDir` com `sizeLimit: 128Mi`.
- **Labels:** `app.kubernetes.io/{name,instance,version,managed-by}` + `helm.sh/chart` no metadata dos recursos. `helm.sh/chart` **não** vai no pod template (bump de chart não força rollout). `spec.selector.matchLabels` permanece só `app: <release>` (campo imutável).
- **Rollout:** `revisionHistoryLimit: 3`; `progressDeadlineSeconds: 240` — mantenha **abaixo** do `helmTimeout` (default `5m`) para que rollout travado apareça como `ProgressDeadlineExceeded` em vez de timeout opaco do `helm --wait`. `maxUnavailable: 0` preserva capacidade; com PVC RWO a strategy vira `Recreate`.
- **Data Protection:** `readOnlyRootFilesystem` + múltiplas réplicas pode exigir key ring externo na aplicação — não resolvido pelo chart.
- **Alta disponibilidade (derivado, não descoberto):**
  - `kubeVersion: ">=1.27.0-0"` — piso derivado do que os charts **aplicam**, não do que algum cluster roda. Manda o `CronJob.spec.timeZone`, estável na [v1.27](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/). Gateway API `v1` e `external-secrets.io/v1` são CRDs, não versão de Kubernetes, então não cabem aqui — o preflight do deploy asseta esses group/versions por cluster.
  - **PDB** renderizado só a partir de 2 réplicas efetivas (abaixo disso não protege nada). `maxUnavailable: 1` em vez do `minAvailable: 90%` sugerido pelo [upstream para frontends stateless](https://kubernetes.io/docs/tasks/run-application/configure-pdb/): percentuais de `minAvailable` arredondam **para cima**, então 90% de 2 réplicas resolve para 2 e bloquearia **toda** disrupção voluntária, inclusive drain de nó. `unhealthyPodEvictionPolicy: AlwaysAllow` segue a recomendação explícita do upstream.
  - **TopologySpread** com `whenUnsatisfiable: ScheduleAnyway` de propósito: o upstream [alerta](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/) que `DoNotSchedule` em cluster com poucos domínios atrasa ou bloqueia agendamento. Soft é no-op em cluster de uma zona e ainda enviesa o scheduler em multi-zona — mesmo chart correto para os três ambientes, sem descoberta por cluster.
  - **PSA** por ambiente em [`config/platform-environments.json`](config/platform-environments.json) (`podSecurity.enforce` + `enforceVersion`). `null` ⇒ namespace **não** é rotulado. Os charts satisfazem o perfil [`restricted`](https://kubernetes.io/docs/concepts/security/pod-security-standards/) (`runAsNonRoot` + `runAsUser`, `allowPrivilegeEscalation: false`, `drop: [ALL]`, `seccompProfile: RuntimeDefault`), então `enforce=restricted` deve passar — mas *enforçar* é decisão de política da plataforma, não default de chart. Se `enforce` é setado sem `enforceVersion`, o deploy falha: versão não pinada faz um upgrade de cluster mudar silenciosamente o que é enforçado.
- **Proving ground (não inventar):** label `Gateway.allowedRoutes` por cluster / drain do gateway para `preStop` / prova gRPC e2e no cluster. Ver [`scripts/discover-platform-values.sh`](scripts/discover-platform-values.sh) — rode **uma vez por ambiente**; o que varia por cluster vai para `config/platform-environments.json`, não para o chart.

### Versões

| Tag | Notas |
|-----|-------|
| `v3.1.0` | imutável |
| `v3.1.1` | **RETIRADA — não usar.** Duas sintaxes jq inválidas no mikefarah/yq: `yq -e --arg` no preflight de Gateway faz **todo deploy web/grpc falhar**, e `\| last \|` quebra o rollback. `gatewayNamespace` também estava errado (`asa-infra`). |
| `v3.1.2` | correção da `v3.1.1` + hardening: `expectedKubeContext` ligado ao mapping autoritativo, invariantes de chart validadas **antes** do push de imagem, preflight por apiVersion exata, baseline de pod endurecido (`runAsUser` 1654, `enableServiceLinks: false`, `revisionHistoryLimit`, `progressDeadlineSeconds`), guardas de drift de gateway e de schema |
| `v3.2.0` | kubeconform nos manifests renderizados; `expect_fail` com asserção de mensagem; `validateAutoscaling` (min≤max); `remoteRef.key` required; `image.repository` minLength; `/tmp` `emptyDir.sizeLimit`; labels padrão (`version`/`managed-by`/`helm.sh/chart`); gate de bump de versão no CI |
