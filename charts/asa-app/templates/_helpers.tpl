{{- define "chart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "chart.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "chart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}

{{/*
chart.envSuffix — single source of truth for the environment letter used in gateway
host/parentRef names. Fails fast on an unrecognized environmentName instead of silently
falling back to a stray suffix, so deploys are forced onto the standard environment set
(no `qa`, no `dev` alias — use `develop`). Add a new environment here intentionally.
*/}}
{{- define "chart.envSuffix" -}}
{{- $env := lower (default "develop" .Values.environmentName) -}}
{{- $m := dict "production" "p" "homolog" "h" "develop" "d" "staging" "s" -}}
{{- if not (hasKey $m $env) -}}
{{- fail (printf "Unknown environmentName %q; must be one of: develop, homolog, staging, production" $env) -}}
{{- end -}}
{{- get $m $env -}}
{{- end }}

{{/*
chart.awsDnsEnvLabel — short environment label used in AWS-native .corp hostnames.
Separate from chart.envSuffix (single-letter, asa.com.br) to keep each mapping explicit.
*/}}
{{- define "chart.awsDnsEnvLabel" -}}
{{- $env := lower (default "develop" .Values.environmentName) -}}
{{- $m := dict "production" "prd" "homolog" "hml" "develop" "dev" "staging" "stg" -}}
{{- get $m $env | default $env -}}
{{- end }}

{{/*
chart.awsNativeGatewayHost — hostname for the aws-native DNS model.
Format when includeClusterInHost=true:  {release}.{cluster}.{envLabel}.asa.{domain}
Format when includeClusterInHost=false: {release}.{envLabel}.asa.{domain}
*/}}
{{- define "chart.awsNativeGatewayHost" -}}
{{- $dns := ((.Values.cloud | default dict).dns | default dict) -}}
{{- $cluster := $dns.cluster | default "" -}}
{{- $domain  := $dns.domain  | default "corp" -}}
{{- $envLabel := include "chart.awsDnsEnvLabel" . -}}
{{- if and ($dns.includeClusterInHost | default false) $cluster -}}
{{- printf "%s.%s.%s.asa.%s" .Release.Name $cluster $envLabel $domain -}}
{{- else -}}
{{- printf "%s.%s.asa.%s" .Release.Name $envLabel $domain -}}
{{- end -}}
{{- end }}

{{/*
chart.validateAwsNativeDns — fails at render time when includeClusterInHost=true
but no cluster is provided, preventing a malformed hostname from reaching the cluster.
*/}}
{{- define "chart.validateAwsNativeDns" -}}
{{- $dns := ((.Values.cloud | default dict).dns | default dict) -}}
{{- if and ($dns.includeClusterInHost | default false) (not ($dns.cluster | default "")) -}}
{{- fail "cloud.dns.includeClusterInHost=true requires cloud.dns.cluster to be set" -}}
{{- end -}}
{{- end }}

{{/*
chart.gcpLegacyGatewayDomain — returns the full domain suffix for GCP-legacy hostnames.
All environments use a single-letter subdomain, matching the GCP Cloud DNS zone and
Gateway listener for each environment (restored from v1.0.0 behaviour):
  production → p.asa.com.br  → full host: {namespace}.p.asa.com.br
  homolog    → h.asa.com.br  → full host: {namespace}.h.asa.com.br
  develop    → d.asa.com.br  → full host: {namespace}.d.asa.com.br
  staging    → s.asa.com.br  → full host: {namespace}.s.asa.com.br
*/}}
{{- define "chart.gcpLegacyGatewayDomain" -}}
{{- $env := lower (default "develop" .Values.environmentName) -}}
{{- $m := dict "production" "p.asa.com.br" "homolog" "h.asa.com.br" "develop" "d.asa.com.br" "staging" "s.asa.com.br" -}}
{{- get $m $env | default "d.asa.com.br" -}}
{{- end }}

{{/*
chart.gcpLegacyGatewayHost — canonical hostname for the GCP-legacy DNS format.
Format: {namespace}.{gcpLegacyGatewayDomain} (e.g. payments.h.asa.com.br)
Used by chart.gatewayHost (gcp-legacy path) and as the .com.br secondary hostname
in aws-native HTTPRoute/GRPCRoute for transitional dual-access.
*/}}
{{- define "chart.gcpLegacyGatewayHost" -}}
{{- printf "%s.%s" .Release.Namespace (include "chart.gcpLegacyGatewayDomain" .) -}}
{{- end }}

{{/*
chart.isAwsNative — "true" when cloud.provider==aws AND cloud.dns.mode==aws-native.
Single predicate to avoid repeating the two-field guard in template files.
*/}}
{{- define "chart.isAwsNative" -}}
{{- $cloud := .Values.cloud | default dict -}}
{{- if and (eq ($cloud.provider | default "") "aws") (eq (($cloud.dns | default dict).mode | default "gcp-legacy") "aws-native") -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/*
chart.gatewayHost — dispatches between gcp-legacy and aws-native hostname formats.
Double-guards on cloud.provider == "aws" so GCP is never affected even if cloud.dns.mode
is accidentally set in a GCP values file.
*/}}
{{- define "chart.gatewayHost" -}}
{{- if (include "chart.isAwsNative" .) | eq "true" -}}
{{- include "chart.validateAwsNativeDns" . -}}
{{- include "chart.awsNativeGatewayHost" . -}}
{{- else -}}
{{- include "chart.gcpLegacyGatewayHost" . -}}
{{- end -}}
{{- end }}

{{- define "chart.gatewayParentRefsName" -}}
{{- printf "%s-asa-com-br-internal-gateway" (include "chart.envSuffix" .) -}}
{{- end }}

{{/*
chart.ingressHost — hostname for the Ingress resource, parallel to chart.gatewayHost.
GCP-legacy: replaces the first dot separator with a dash so the env-suffix becomes
  part of a single subdomain label under asa.com.br rather than a nested subdomain.
  develop    → {namespace}-d.asa.com.br
  homolog    → {namespace}-h.asa.com.br
  staging    → {namespace}-s.asa.com.br
  production → {namespace}-p.asa.com.br
AWS-native: same "dash-join" rule applied to the .corp prefix segments.
  with cluster    → {release}-{cluster}-{envLabel}.asa.{domain}
  without cluster → {release}-{envLabel}.asa.{domain}
*/}}
{{- define "chart.ingressHost" -}}
{{- $cloud := .Values.cloud | default dict -}}
{{- $mode  := ($cloud.dns | default dict).mode | default "gcp-legacy" -}}
{{- if and (eq ($cloud.provider | default "") "aws") (eq $mode "aws-native") -}}
{{- include "chart.validateAwsNativeDns" . -}}
{{- $dns      := ($cloud.dns | default dict) -}}
{{- $cluster  := $dns.cluster | default "" -}}
{{- $domain   := $dns.domain  | default "corp" -}}
{{- $envLabel := include "chart.awsDnsEnvLabel" . -}}
{{- if and ($dns.includeClusterInHost | default false) $cluster -}}
{{- printf "%s-%s-%s.asa.%s" .Release.Name $cluster $envLabel $domain -}}
{{- else -}}
{{- printf "%s-%s.asa.%s" .Release.Name $envLabel $domain -}}
{{- end -}}
{{- else -}}
{{- $suffix := include "chart.envSuffix" . -}}
{{- printf "%s-%s.asa.com.br" .Release.Namespace $suffix -}}
{{- end -}}
{{- end }}

{{/*
Container image reference: immutable digest takes precedence over tag (Cosign / GAR promotion).
*/}}
{{- define "chart.image" -}}
{{- $repo := required "image.repository is required" .Values.image.repository -}}
{{- $digest := .Values.image.digest | default "" -}}
{{- $tag := .Values.image.tag | default "latest" -}}
{{- if ne $digest "" -}}
{{- printf "%s@%s" $repo $digest -}}
{{- else -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}
{{- end }}

{{/*
chart.workloadMode — validates and returns the effective workload.profile.
Allowed values: web | worker | grpc | cronjob.
Fails at render time if an unknown profile is supplied so the error is
caught before reaching the cluster.
*/}}
{{- define "chart.workloadMode" -}}
{{- $profile := (.Values.workload | default dict).profile | default "web" -}}
{{- $valid := list "web" "worker" "grpc" "cronjob" -}}
{{- if not (has $profile $valid) -}}
{{-   fail (printf "Invalid workload.profile %q; must be one of: web, worker, grpc, cronjob" $profile) -}}
{{- end -}}
{{- $profile -}}
{{- end }}

{{/*
chart.isDeployment — true when the chart should render Deployment-style
workload resources. Templates such as deployment.yaml, hpa.yaml, pdb.yaml,
service.yaml and httproute.yaml rely on this; they must NOT render when the
chart is deployed in CronJob mode (cronjob.enabled=true).
*/}}
{{- define "chart.isDeployment" -}}
{{- $cron := false -}}
{{- if hasKey .Values "cronjob" -}}
{{-   $cron = (get .Values.cronjob "enabled") | default false -}}
{{- end -}}
{{- not $cron -}}
{{- end }}

{{/*
chart.workloadIdentityLegacyEnabled — compatibility switch for the deprecated
`gcpWorkloadIdentity` block. Existing EKS -> GCP consumers keep their current
projected-token contract while they migrate to `workloadIdentity`.
*/}}
{{- define "chart.workloadIdentityLegacyEnabled" -}}
{{- $legacy := .Values.gcpWorkloadIdentity | default dict -}}
{{- if ($legacy.enabled | default false) -}}true{{- else -}}false{{- end -}}
{{- end }}

{{/*
chart.workloadIdentityEnabled — true when either the canonical block or the
legacy GCP block is enabled. The two blocks are mutually exclusive.
*/}}
{{- define "chart.workloadIdentityEnabled" -}}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $legacyEnabled := (include "chart.workloadIdentityLegacyEnabled" .) | eq "true" -}}
{{- if or ($wi.enabled | default false) $legacyEnabled -}}true{{- else -}}false{{- end -}}
{{- end }}

{{/*
chart.workloadIdentityTarget — returns the destination cloud (`aws` or `gcp`).
The legacy gcpWorkloadIdentity block always resolves to gcp.
*/}}
{{- define "chart.workloadIdentityTarget" -}}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $legacyEnabled := (include "chart.workloadIdentityLegacyEnabled" .) | eq "true" -}}
{{- if $legacyEnabled -}}
gcp
{{- else -}}
{{- $target := lower ($wi.target | default "") -}}
{{- if not (has $target (list "aws" "gcp")) -}}
{{- fail (printf "workloadIdentity.target inválido %q; valores permitidos: aws, gcp" $target) -}}
{{- end -}}
{{- $target -}}
{{- end -}}
{{- end }}

{{- define "chart.workloadIdentityTargetsAWS" -}}
{{- if ((include "chart.workloadIdentityEnabled" .) | eq "true") -}}
{{- if ((include "chart.workloadIdentityTarget" .) | eq "aws") -}}true{{- else -}}false{{- end -}}
{{- else -}}false{{- end -}}
{{- end }}

{{- define "chart.workloadIdentityTargetsGCP" -}}
{{- if ((include "chart.workloadIdentityEnabled" .) | eq "true") -}}
{{- if ((include "chart.workloadIdentityTarget" .) | eq "gcp") -}}true{{- else -}}false{{- end -}}
{{- else -}}false{{- end -}}
{{- end }}

{{/* Effective projected-token settings. */}}
{{- define "chart.workloadIdentityTokenAudience" -}}
{{- $legacy := .Values.gcpWorkloadIdentity | default dict -}}
{{- if ((include "chart.workloadIdentityLegacyEnabled" .) | eq "true") -}}
{{- $legacy.audience | default "sts.amazonaws.com" -}}
{{- else -}}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $token := $wi.token | default dict -}}
{{- $token.audience | default "sts.amazonaws.com" -}}
{{- end -}}
{{- end }}

{{- define "chart.workloadIdentityTokenExpirationSeconds" -}}
{{- $legacy := .Values.gcpWorkloadIdentity | default dict -}}
{{- if ((include "chart.workloadIdentityLegacyEnabled" .) | eq "true") -}}
{{- $legacy.expirationSeconds | default 3600 -}}
{{- else -}}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $token := $wi.token | default dict -}}
{{- $token.expirationSeconds | default 3600 -}}
{{- end -}}
{{- end }}

{{- define "chart.workloadIdentityTokenFileName" -}}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $token := $wi.token | default dict -}}
{{- if ((include "chart.workloadIdentityLegacyEnabled" .) | eq "true") -}}token{{- else -}}{{- $token.fileName | default "token" -}}{{- end -}}
{{- end }}

{{- define "chart.workloadIdentityTokenVolumeName" -}}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $token := $wi.token | default dict -}}
{{- if $token.volumeName -}}
{{- $token.volumeName -}}
{{- else if and ((include "chart.workloadIdentityLegacyEnabled" .) | ne "true") (eq ($wi.target | default "") "aws") -}}
{{- "aws-iam-token" -}}
{{- else if and ((include "chart.workloadIdentityLegacyEnabled" .) | ne "true") (eq ($wi.target | default "") "gcp") -}}
{{- "aws-token" -}}
{{- else -}}
{{- "workload-identity-token" -}}
{{- end -}}
{{- end }}

{{- define "chart.workloadIdentityTokenMountPath" -}}
{{- $legacy := .Values.gcpWorkloadIdentity | default dict -}}
{{- if ((include "chart.workloadIdentityLegacyEnabled" .) | eq "true") -}}
{{- $legacy.mountPath | default "/var/run/secrets/eks.amazonaws.com/serviceaccount" -}}
{{- else -}}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $token := $wi.token | default dict -}}
{{- if $token.mountPath -}}
{{- $token.mountPath -}}
{{- else if eq ($wi.target | default "") "aws" -}}
{{- "/var/run/secrets/aws-iam-token/serviceaccount" -}}
{{- else if eq ($wi.target | default "") "gcp" -}}
{{- "/var/run/secrets/eks.amazonaws.com/serviceaccount" -}}
{{- else -}}
{{- "/var/run/secrets/workload-identity" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "chart.workloadIdentityTokenPath" -}}
{{- printf "%s/%s" (include "chart.workloadIdentityTokenMountPath" .) (include "chart.workloadIdentityTokenFileName" .) -}}
{{- end }}

{{- define "chart.workloadIdentityTokenDefaultMode" -}}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $token := $wi.token | default dict -}}
{{- if ((include "chart.workloadIdentityLegacyEnabled" .) | eq "true") -}}420{{- else -}}{{- $token.defaultMode | default 420 -}}{{- end -}}
{{- end }}

{{/*
chart.workloadIdentityGCPCredentialsPath — path absoluto do external_account JSON dentro do pod.
Calculado a partir de credentialsConfigMapKey; nunca configurável pelo consumidor.
*/}}
{{- define "chart.workloadIdentityGCPCredentialsPath" -}}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $gcp := $wi.gcp | default dict -}}
{{- $key := $gcp.credentialsConfigMapKey | default "external-account.json" -}}
{{- printf "/var/run/secrets/google/%s" $key -}}
{{- end }}

{{/*
chart.validateWorkloadIdentity — validates only chart-owned settings. Cloud-side
OIDC providers, trust policies and IAM bindings remain infrastructure concerns.
*/}}
{{- define "chart.validateWorkloadIdentity" -}}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $legacyEnabled := (include "chart.workloadIdentityLegacyEnabled" .) | eq "true" -}}
{{- $canonicalEnabled := $wi.enabled | default false -}}
{{- if and $canonicalEnabled $legacyEnabled -}}
{{- fail "Não habilite workloadIdentity e gcpWorkloadIdentity simultaneamente" -}}
{{- end -}}
{{- if or $canonicalEnabled $legacyEnabled -}}
{{- $sa := .Values.serviceAccount | default dict -}}
{{- if not ($sa.enabled | default false) -}}
{{- fail "workloadIdentity requer serviceAccount.enabled=true para vincular o token projetado a uma Kubernetes ServiceAccount explícita" -}}
{{- end -}}
{{- $expiration := include "chart.workloadIdentityTokenExpirationSeconds" . | int -}}
{{- if lt $expiration 600 -}}
{{- fail "workloadIdentity.token.expirationSeconds deve ser >= 600" -}}
{{- end -}}
{{- $target := include "chart.workloadIdentityTarget" . -}}
{{- if eq $target "aws" -}}
{{- $aws := $wi.aws | default dict -}}
{{- $_ := required "workloadIdentity.aws.roleArn é obrigatório quando target=aws" ($aws.roleArn | default "") -}}
{{- $_ := required "workloadIdentity.aws.region é obrigatório quando target=aws" ($aws.region | default "") -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/* Backward-compatible alias retained for external includes. */}}
{{- define "chart.gcpWorkloadIdentityEnabled" -}}
{{- if ((include "chart.workloadIdentityTargetsGCP" .) | eq "true") -}}true{{- else -}}false{{- end -}}
{{- end }}

{{/*
chart.persistenceEnabled — true quando persistence.enabled = true.
*/}}
{{- define "chart.persistenceEnabled" -}}
{{- $p := .Values.persistence | default dict -}}
{{- if $p.enabled -}}true{{- else -}}false{{- end -}}
{{- end }}

{{/*
chart.pvcName — devolve o nome efetivo da PVC.
Usa persistence.name quando definido, caso contrário "<release>-data".
*/}}
{{- define "chart.pvcName" -}}
{{- $p := .Values.persistence | default dict -}}
{{- $name := $p.name | default "" -}}
{{- if $name -}}
{{- $name -}}
{{- else -}}
{{- printf "%s-data" .Release.Name -}}
{{- end -}}
{{- end }}

{{/*
chart.validatePersistence — falha em render time quando persistence está habilitada
com ReadWriteOnce e replicaCount > 1. Um volume RWO só pode ser attached a um nó por
vez: múltiplas réplicas deixariam todos os pods exceto um presos em ContainerCreating.
Não retorna valor; é chamado apenas pelo efeito colateral do fail.
*/}}
{{- define "chart.validatePersistence" -}}
{{- $p := .Values.persistence | default dict -}}
{{- $modes := $p.accessModes | default (list "ReadWriteOnce") -}}
{{- $replicas := .Values.replicaCount | default 1 | int -}}
{{- if and $p.enabled (has "ReadWriteOnce" $modes) (gt $replicas 1) -}}
{{- fail (printf "persistence.accessModes=[ReadWriteOnce] é incompatível com replicaCount=%d: um volume RWO só pode ser attached a um nó por vez. Use replicaCount: 1 ou mude para accessModes: [ReadWriteMany]." $replicas) -}}
{{- end -}}
{{- end }}

{{/*
chart.persistenceForcesRecreate — "true" quando persistence está habilitada
e algum accessMode é ReadWriteOnce (situação onde RollingUpdate trava por
conflito de attach do volume; força strategy: Recreate no Deployment).
*/}}
{{- define "chart.persistenceForcesRecreate" -}}
{{- $p := .Values.persistence | default dict -}}
{{- $modes := $p.accessModes | default (list "ReadWriteOnce") -}}
{{- if and $p.enabled (has "ReadWriteOnce" $modes) -}}true{{- else -}}false{{- end -}}
{{- end }}

{{/*
chart.needsVolumes — "true" quando volumes/volumeMounts devem ser renderizados
(readOnlyRootFilesystem, persistence ou Workload Identity habilitados).
*/}}
{{- define "chart.needsVolumes" -}}
{{- $sc := .Values.securityContext | default dict -}}
{{- $p := .Values.persistence | default dict -}}
{{- $wiEnabled := (include "chart.workloadIdentityEnabled" .) | eq "true" -}}
{{- if or ($sc.readOnlyRootFilesystem | default false) ($p.enabled | default false) $wiEnabled -}}true{{- else -}}false{{- end -}}
{{- end }}

{{/*
chart.configEffectiveEnabled — "true" quando um ConfigMap deve ser renderizado.
O chart NÃO injeta configuração própria (ex.: níveis de log): o ConfigMap existe apenas
quando o consumidor opta por ele via config.enabled (definido pelo overlay de deploy quando
há variáveis CM_* não-vazias, ou explicitamente nos values), OU implicitamente quando há
qualquer chave de configuração além de "enabled" (caso de um deploy/values*.yaml versionado
no repo da aplicação, que não passa pelo overlay e portanto nunca seta enabled=true). Centraliza
a decisão para que configmap.yaml e deployment.yaml (envFrom) usem o mesmo critério.
*/}}
{{- define "chart.configEffectiveEnabled" -}}
{{- $config := .Values.config | default (dict) -}}
{{- $hasKeys := false -}}
{{- range $key, $value := $config -}}
{{- if ne $key "enabled" -}}{{- $hasKeys = true -}}{{- end -}}
{{- end -}}
{{- if or (get $config "enabled" | default false) $hasKeys -}}true{{- else -}}false{{- end -}}
{{- end }}

{{/*
chart.serviceEnabled — "true" when a Service should be rendered for this workload.
Checks service.enabled explicitly first (set by workload profile YAML files).
Falls back to workload.profile derivation for backward compat with legacy consumers
that only pass --set-string workload.profile=web without a profile YAML file.
*/}}
{{- define "chart.serviceEnabled" -}}
{{- $svc := .Values.service | default dict -}}
{{- if hasKey $svc "enabled" -}}
{{- ternary "true" "false" $svc.enabled -}}
{{- else -}}
{{- $p := include "chart.workloadMode" . -}}
{{- if or (eq $p "web") (eq $p "grpc") -}}true{{- else -}}false{{- end -}}
{{- end -}}
{{- end }}

{{/*
chart.ingressEnabled — "true" when an Ingress should be rendered.
Checks ingress.enabled explicitly first (set by workload profile YAML files).
Falls back to workload.profile derivation for legacy consumers that pass only
--set workload.profile=web without a profile YAML file.

Fallback covers only "web". gRPC workloads use ingress.enabled set explicitly
by profiles/workloads/grpc.yaml — they never reach the fallback in normal use.
This is intentionally asymmetric with chart.gatewayEnabled, which does include
grpc in its fallback because gRPC is gateway-native; Nginx Ingress is opt-in
and must be explicitly enabled via the profile file.
*/}}
{{- define "chart.ingressEnabled" -}}
{{- $cloud := .Values.cloud | default dict -}}
{{- $mode  := ($cloud.dns | default dict).mode | default "gcp-legacy" -}}
{{- if and (eq ($cloud.provider | default "") "aws") (eq $mode "aws-native") -}}
false
{{- else -}}
{{- $ing := .Values.ingress | default dict -}}
{{- if hasKey $ing "enabled" -}}
{{- ternary "true" "false" $ing.enabled -}}
{{- else -}}
{{- $p := include "chart.workloadMode" . -}}
{{- if eq $p "web" -}}true{{- else -}}false{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
chart.gatewayEnabled — "true" when an HTTPRoute or GRPCRoute should be rendered.
Checks gateway.enabled explicitly first (set by workload profile YAML files).
Falls back to workload.profile derivation for backward compat.
*/}}
{{- define "chart.gatewayEnabled" -}}
{{- $gw := .Values.gateway | default dict -}}
{{- if hasKey $gw "enabled" -}}
{{- ternary "true" "false" $gw.enabled -}}
{{- else -}}
{{- $p := include "chart.workloadMode" . -}}
{{- if or (eq $p "web") (eq $p "grpc") -}}true{{- else -}}false{{- end -}}
{{- end -}}
{{- end }}

{{/*
chart.gatewayProtocol — returns "grpc" or "http" for the gateway route type.
Checks gateway.protocol explicitly first (set by workload profile YAML files).
Falls back to workload.profile derivation for backward compat.
*/}}
{{- define "chart.gatewayProtocol" -}}
{{- $gw := .Values.gateway | default dict -}}
{{- if $gw.protocol -}}
{{- $gw.protocol -}}
{{- else -}}
{{- $p := include "chart.workloadMode" . -}}
{{- if eq $p "grpc" -}}grpc{{- else -}}http{{- end -}}
{{- end -}}
{{- end }}

{{/*
common.probes.enabled — effective on/off master switch (legacy `probes.enabled`).
Returns "true" when probes.enabled is true, OR when the key is absent (chart historically
defaults to enabled when the key is omitted). Single source of truth reused by all profiles.
*/}}
{{- define "common.probes.enabled" -}}
{{- $probes := default dict .Values.probes -}}
{{- ternary $probes.enabled true (hasKey $probes "enabled") -}}
{{- end }}

{{/*
common.probes.mode — canonical effective probe mode, consistent across all workload profiles.
Resolution: probes.mode when set; otherwise derived from probes.enabled (true → "http",
false → "off"). Returns one of: off | tcp | http. This is the single switch that turns probes
on/off everywhere; profile-specific TYPE selectors (workload.workerProbes.type,
workload.grpc.useHttpProbes) remain authoritative for HOW each probe is shaped.
*/}}
{{- define "common.probes.mode" -}}
{{- $probes := default dict .Values.probes -}}
{{- $enabled := ternary $probes.enabled true (hasKey $probes "enabled") -}}
{{- coalesce $probes.mode (ternary "http" "off" $enabled) -}}
{{- end }}

{{/*
chart.probes — dispatches to the correct common.probes.* partial based on workload type.
This is the single if-eq chain allowed by the architecture: it lives here in one helper
so that capability templates call `include "chart.probes" .` with no profile awareness.
*/}}
{{- define "chart.probes" -}}
{{- $p := include "chart.workloadMode" . -}}
{{- if eq $p "grpc" -}}{{- include "common.probes.grpc" . -}}
{{- else if eq $p "worker" -}}{{- include "common.probes.worker" . -}}
{{- else -}}{{- include "common.probes.web" . -}}{{- end -}}
{{- end }}

{{/*
chart.serviceAppProtocol — returns the appProtocol for the Service port, if applicable.
Checks service.appProtocol explicitly first (set by workload profile YAML files).
Falls back to workload.profile derivation: gRPC workloads use kubernetes.io/h2c.
Returns empty string when no appProtocol is required (safe to check with `if`).
*/}}
{{- define "chart.serviceAppProtocol" -}}
{{- $svc := .Values.service | default dict -}}
{{- if $svc.appProtocol -}}
{{- $svc.appProtocol -}}
{{- else -}}
{{- $p := include "chart.workloadMode" . -}}
{{- if eq $p "grpc" -}}kubernetes.io/h2c{{- end -}}
{{- end -}}
{{- end }}

{{/*
chart.portName — returns the named port for the container ports section.
  web    → "http"   (used by web probe tcpSocket/httpGet port references)
  grpc   → "grpc"   (used by grpc probe httpGet port reference)
  worker → "tcp"    (worker probes use numeric port, name is informational)
*/}}
{{- define "chart.portName" -}}
{{- $p := include "chart.workloadMode" . -}}
{{- if eq $p "grpc" -}}grpc{{- else if eq $p "worker" -}}tcp{{- else -}}http{{- end -}}
{{- end }}