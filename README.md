# Pipeline Templates

Templates YAML reutilizáveis para Azure DevOps (GitHub → `extends`).

## Conteúdo

| Caminho | Escopo |
|---------|--------|
| [`templates/dotnet/ci.yml`](templates/dotnet/ci.yml) | CI → area profile → DeployContract → ECR → Helm |
| [`templates/dotnet/delivery.yml`](templates/dotnet/delivery.yml) | Stages de delivery (interno; incluído via area profile) |
| [`templates/dotnet/helm-deploy.yml`](templates/dotnet/helm-deploy.yml) | Stage Helm por tier (`kind` → chart) |
| [`platform/areas/`](platform/areas/) | Fonte única área × tier → pool / ADO Environment / gateway / contas |
| [`platform/areas.schema.json`](platform/areas.schema.json) | Schema do objeto `platform` em cada area profile |
| [`platform/runtimes/`](platform/runtimes/) | Defaults Kubernetes por runtime (probes/resources/tmp/grace) |
| [`docker/dotnet/`](docker/dotnet/) | Imagem + entrypoint .NET (traduz o contrato da plataforma) |
| [`charts/asa-application`](charts/asa-application) | `kind: Application` — web \| grpc \| worker |
| [`charts/asa-scheduled-job`](charts/asa-scheduled-job) | `kind: ScheduledJob` — CronJob |
| [`schemas/`](schemas/) | Schema **público** (`additionalProperties: false`) |
| [`scripts/`](scripts/) | Resolver de plataforma/runtime, `jsonschema`, identidade cross-env |
| [`tests/`](tests/) | Render invariants + drift + platform/runtime-contract + kubeconform + golden |
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | CI obrigatório do repositório |

## Consumo

```yaml
resources:
  repositories:
    - repository: templates
      type: github
      name: diegofernandes-dev/pipeline-templates
      endpoint: github-diegofernandes-dev
      # Prefer an immutable tag only after platform-ci is green on that SHA.
      # v5.3.0 is RETIRADA — do not use. Until v5.3.1 is tagged, pin a green commit SHA
      # (or temporarily track main after the hygiene fix).
      ref: refs/heads/main

extends:
  template: templates/dotnet/ci.yml@templates
  parameters:
    solution: '**/*.sln'
    applicationName: sample-api
    dotnetProject: src/Sample.Api/Sample.Api.csproj
    platformArea: lab
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

**config:** mapa livre de strings (`ConnectionStrings__Default`). Reservados do chart: `PORT`, `APP_PROTOCOL`, `SHUTDOWN_TIMEOUT_SECONDS`, `CPU_REQUEST_MILLICORES`, `GOOGLE_APPLICATION_CREDENTIALS`. Chaves de runtime (ex.: `ASPNETCORE_*`, `Kestrel__*`) são rejeitadas pelo profile em [`platform/runtimes/`](platform/runtimes/) no DeployContract.

### Contrato de runtime (charts agnósticos)

Os charts **não** conhecem .NET nem Java. Há dois canais:

1. **Env (chart → imagem)** — vocabulário de mercado:
   - `PORT` — porta de listen (8080; só web/grpc)
   - `APP_PROTOCOL` — `http` \| `h2c` (espelha `Service.appProtocol`)
   - `SHUTDOWN_TIMEOUT_SECONDS` — orçamento de drain do app (`< terminationGracePeriodSeconds`)
   - `CPU_REQUEST_MILLICORES` — downward API do request de CPU (exposto; adapter .NET ainda não consome)
2. **Perfil** [`platform/runtimes/<runtime>.yml`](platform/runtimes/) — defaults Kubernetes que dependem do runtime, injetados pelo pipeline **antes** do manifesto. Shape:

   ```yaml
   chart:
     defaults: { resources, tmp, probeDefaults, grace, shutdown, … }
     workloads:
       web: {}          # merge sobre defaults
       grpc: {}
       worker: {}
       scheduledJob: {}
   reservedConfig: …   # guard no DeployContract
   ```

   Merge: `defaults ← workloads.<tipo>`. O tipo vem do manifesto (`Application` + `workload.type` → `web|grpc|worker`; `ScheduledJob` → `scheduledJob`). O consumer declara só `runtime: dotnet`. O manifesto ainda pode sobrescrever `resources`/probes; os fatos de área vencem por último.

Cada `docker/<runtime>/entrypoint.sh` traduz as env para o runtime (ex.: .NET → `ASPNETCORE_URLS`, `Kestrel__EndpointDefaults__Protocols`, `HostOptions__ShutdownTimeout`) e faz `exec` do processo como PID 1.

**Atenção:** `execution.command` no ScheduledJob **substitui** o ENTRYPOINT da imagem — o adapter (e o mapeamento) é pulado. Prefira `execution.args` para jobs .NET.

**.NET 10 / SIGTERM:** o runtime deixou de instalar handler default de SIGTERM para apps console sem generic host. Apps ASP.NET com generic host continuam cobertas; entrypoints de console precisam registrar o handler — isso é responsabilidade da aplicação, não do chart.

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

### Platform area × tier mapping

Fonte única: [`platform/areas/<area>.yml`](platform/areas/) (ex.: [`lab.yml`](platform/areas/lab.yml)).
O ADO lê o profile em tempo de compilação (pool / Environment); o resolvedor lê o mesmo arquivo
em runtime (gateway, DNS, `defaultMinReplicas`, guards).

| Área | Tier | Deploy pool | ADO Environment | expectedKubeContext | awsAccountId |
|------|------|-------------|-----------------|---------------------|--------------|
| lab | develop | `PG-AWS-EKS` | `develop` | **EXTERNAL BLOCKER** | **EXTERNAL BLOCKER** |
| lab | homolog | `PG-AWS-EKS-HML` | `homolog` | **EXTERNAL BLOCKER** | **EXTERNAL BLOCKER** |
| lab | production | **EXTERNAL BLOCKER** (`null`) | `production` | **EXTERNAL BLOCKER** | **EXTERNAL BLOCKER** |

- Contexto kubectl e conta STS: match **exato** quando mapeados. Enquanto `null`, o deploy emite warning e não valida identidade.
- Registry ECR compartilhado: `platform.registry` no profile (conta/região). A **repository policy** de pull cross-account é pré-provisionada pela infra; o pipeline só cria o repositório com `--registry-id`.
- Manifestos da app continuam em `deploy/config/<tier>.yaml`. O stage chama-se `Deploy_<tier>`; o Environment ADO pode diferir (`environmentName` no profile).

#### Ownership (delivery vs infra)

| Recurso | Owner | Quem provisiona |
|---------|-------|-----------------|
| Repositório ECR | delivery | Pipeline (`create-repository --registry-id`) |
| Repository policy / Org pull | infra | Conta compartilhada (ex.: `aws:PrincipalOrgID`) |
| Namespace K8s | delivery | `kubectl apply` quando ausente |
| Agent pools / ADO Environments | infra | Pré-requisito por cluster |
| `ClusterSecretStore` / node ECR pull | infra | Pré-requisito por cluster |
| DNS | ExternalDNS | Pipeline **não** cria registros. Chart emite `external-dns.kubernetes.io/gateway-hostname-source: annotation-only` + `hostname` nos Routes. `dns.publishLegacyHostname` (default `false`) autoriza publicar o hostname legado `.asa.com.br`; a Route **sempre** aceita corp + legacy quando `platform.legacyDnsZone` existe (cutover ≠ publicação). |

#### Pré-requisitos de infra por cluster

- Pool de deploy com o nome em `deployPool` e identidade (Pod Identity / IRSA) limitada ao cluster.
- Pool de build (`buildPool`) com push no ECR compartilhado.
- ADO Environment com o nome em `environmentName`, com exclusividade/lock e (recomendado) Required template check.
- Role dos nodes com `ecr:BatchGetImage` / `ecr:GetDownloadUrlForLayer` no registry compartilhado.
- `ClusterSecretStore` com assume-role na conta do Secrets Manager compartilhado.

### Testes locais / CI do repo

Relatório de validação e2e em lab (AWS/GCP/ADO, 2026-10-02): [`docs/lab-e2e-validation-2026-10-02.md`](docs/lab-e2e-validation-2026-10-02.md).

```bash
helm lint charts/asa-application \
  -f <(./scripts/resolve-platform-values.sh lab develop) \
  --set-string image.repository=example.dkr.ecr.us-east-1.amazonaws.com/sample-api
helm lint charts/asa-scheduled-job \
  -f <(./scripts/resolve-platform-values.sh lab develop) \
  --set-string image.repository=example.dkr.ecr.us-east-1.amazonaws.com/sample-job \
  --set-string schedule.expression='0 2 * * *' \
  --set-string schedule.timeZone=UTC --set execution.timeoutSeconds=60 \
  --set-string 'execution.args[0]=x'
./tests/chart-drift.sh            # primitivas compartilhadas + paridade dos schemas
./tests/platform-contract.sh      # area profiles × chart (resolve + render + allowlist)
./tests/runtime-contract.sh       # runtime profiles × chart + reservedConfig
./tests/runtime-adapter-dotnet.sh # entrypoint.sh mapeia PORT/APP_PROTOCOL/SHUTDOWN
./tests/chart-golden.sh check     # snapshots de render (gate de refatoração)
./tests/chart-conform.sh          # kubeconform -strict nos manifests renderizados
./tests/chart-invariants.sh       # suíte completa (chama drift/contract/conform)
```

**TDD / guardrail para agentes:** antes de mudar `charts/**/templates/**` ou `values.schema.json`, escreva ou ajuste o assert em [`tests/chart-invariants.sh`](tests/chart-invariants.sh) que prova a propriedade; só então edite o chart. A suíte deve ficar vermelha se a propriedade sumir. Alguns negativos de “dupla trava” usam bypass temporário do `values.schema.json` para exercitar o `fail` do template (além do schema) — assim remover o `fail` “duplicado” no `.tpl` também quebra o CI.

**Helm version:** o CI pina **Helm v3.16.2**. O validador de `values.schema.json` mudou de prosa entre Helm 3 e 4 para a mesma violação — não assertar o texto literal do validador. Use `expect_schema_fail` (path + preâmbulo compartilhado), que funciona em 3.x e 4.x. A suíte recusa Helm &lt; 3.16 no início.

### Premissas / docs

- **Baseline de pod (platform-owned, fora do manifesto público):** `runAsNonRoot` + `runAsUser`/`runAsGroup`/`fsGroup` **1654** (UID da plataforma — todo `docker/<runtime>/` deve criar ou assegurar esse UID; o Dockerfile .NET falha no build se `APP_UID` divergir), `readOnlyRootFilesystem`, `seccompProfile: RuntimeDefault`, `drop: [ALL]`, `automountServiceAccountToken: false`, `enableServiceLinks: false`, `terminationMessagePolicy: FallbackToLogsOnError`, `/tmp` como `emptyDir` com `sizeLimit: 128Mi`, `minReadySeconds: 10`, `terminationGracePeriodSeconds: 30` + `shutdownTimeoutSeconds: 25` (este último vira `SHUTDOWN_TIMEOUT_SECONDS` no container).
- **Labels:** `app.kubernetes.io/{name,instance,version,managed-by}` + `helm.sh/chart` + `asa.platform/{area,tier}` no metadata dos recursos. `helm.sh/chart` e `asa.platform/*` **não** vão no pod template (bump de chart/área não força rollout). `spec.selector.matchLabels` permanece só `app: <release>` (campo imutável).
- **Rollout:** `revisionHistoryLimit: 3`; `progressDeadlineSeconds: 240` — mantenha **abaixo** do `helmTimeout` (default `5m`) para que rollout travado apareça como `ProgressDeadlineExceeded` em vez de timeout opaco do `helm --wait`. `maxUnavailable: 0` preserva capacidade; com PVC RWO a strategy vira `Recreate`.
- **Data Protection:** `readOnlyRootFilesystem` + múltiplas réplicas pode exigir key ring externo na aplicação — não resolvido pelo chart.
- **Alta disponibilidade (derivado, não descoberto):**
  - `kubeVersion: ">=1.27.0-0"` — piso derivado do que os charts **aplicam**, não do que algum cluster roda. Manda o `CronJob.spec.timeZone`, estável na [v1.27](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/). Gateway API `v1` e `external-secrets.io/v1` são CRDs, não versão de Kubernetes, então não cabem aqui — o preflight do deploy asseta esses group/versions por cluster.
  - **PDB** renderizado só a partir de 2 réplicas efetivas (abaixo disso não protege nada). `maxUnavailable: 1` em vez do `minAvailable: 90%` sugerido pelo [upstream para frontends stateless](https://kubernetes.io/docs/tasks/run-application/configure-pdb/): percentuais de `minAvailable` arredondam **para cima**, então 90% de 2 réplicas resolve para 2 e bloquearia **toda** disrupção voluntária, inclusive drain de nó. `unhealthyPodEvictionPolicy: AlwaysAllow` segue a recomendação explícita do upstream.
  - **TopologySpread** com `whenUnsatisfiable: ScheduleAnyway` de propósito: o upstream [alerta](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/) que `DoNotSchedule` em cluster com poucos domínios atrasa ou bloqueia agendamento. Soft é no-op em cluster de uma zona e ainda enviesa o scheduler em multi-zona — mesmo chart correto para os três ambientes, sem descoberta por cluster.
  - **PSA** por cluster em [`platform/areas/<area>.yml`](platform/areas/) (`podSecurity.enforce` + `enforceVersion`). `null` ⇒ namespace **não** é rotulado. Os charts satisfazem o perfil [`restricted`](https://kubernetes.io/docs/concepts/security/pod-security-standards/) (`runAsNonRoot` + `runAsUser`, `allowPrivilegeEscalation: false`, `drop: [ALL]`, `seccompProfile: RuntimeDefault`), então `enforce=restricted` deve passar — mas *enforçar* é decisão de política da plataforma, não default de chart. Se `enforce` é setado sem `enforceVersion`, o deploy falha: versão não pinada faz um upgrade de cluster mudar silenciosamente o que é enforçado.
- **Proving ground (não inventar):** label `Gateway.allowedRoutes` por cluster / drain do gateway para `preStop` / prova gRPC e2e no cluster. Ver [`scripts/discover-platform-values.sh`](scripts/discover-platform-values.sh) — rode **uma vez por cluster (área × tier)**; o que varia por cluster vai para `platform/areas/<area>.yml`, não para o chart.

### Versões

| Tag | Notas |
|-----|-------|
| `v3.1.0` | imutável |
| `v3.1.1` | **RETIRADA — não usar.** Duas sintaxes jq inválidas no mikefarah/yq: `yq -e --arg` no preflight de Gateway faz **todo deploy web/grpc falhar**, e `\| last \|` quebra o rollback. `gatewayNamespace` também estava errado (`asa-infra`). |
| `v3.1.2` | correção da `v3.1.1` + hardening: `expectedKubeContext` ligado ao mapping autoritativo, invariantes de chart validadas **antes** do push de imagem, preflight por apiVersion exata, baseline de pod endurecido (`runAsUser` 1654, `enableServiceLinks: false`, `revisionHistoryLimit`, `progressDeadlineSeconds`), guardas de drift de gateway e de schema |
| `v3.2.0` | kubeconform nos manifests renderizados; `expect_fail` com asserção de mensagem; `validateAutoscaling` (min≤max); `remoteRef.key` required; `image.repository` minLength; `/tmp` `emptyDir.sizeLimit`; labels padrão (`version`/`managed-by`/`helm.sh/chart`); gate de bump de versão no CI |
| `v4.0.0` | Desacoplamento env→topology via `resolve-platform-values.sh` + `platform.*` no chart; asa-application 4.x |
| `v5.0.0` | Cluster axis + runtime-agnostic charts: `platform/areas` + `platform/runtimes`; env `PORT`/`APP_PROTOCOL`/`SHUTDOWN_TIMEOUT_SECONDS`; asa-application 5.2.0 / asa-scheduled-job 4.2.0 |
| `v5.3.0` | **RETIRADA — não usar.** Tag criada em `fa1aa5d` antes dos gates completos do repositório (`contracts` falhava com exit 141 / SIGPIPE no harness). O comportamento DNS (`dns.publishLegacyHostname`) e a evidência E2E em [`docs/lab-e2e-validation-2026-10-02.md`](docs/lab-e2e-validation-2026-10-02.md) permanecem válidos; o problema é **qualificação de release**, não o runtime. Tag imutável — não mover. Próxima corretiva candidata: `v5.3.1` **somente** após `platform-ci` verde no SHA exato. |

**Release (fluxo alvo):** candidate SHA → `platform-ci` concluído com `conclusion=success` em **todos** os jobs obrigatórios (`contracts`, `apply-dryrun`) no **mesmo** SHA (execução cancelada por concurrency **não** qualifica) → evidência de integração já registada ou revalidada se houver mudança runtime → tag imutável → consumers passam a apontar para essa tag. Nunca: merge → tag → descobrir depois se o CI passou.
