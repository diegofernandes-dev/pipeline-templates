{{/*
Presence-based toggles: non-empty map/list ⇒ on.
*/}}

{{- define "chart.configEnabled" -}}
{{- $c := .Values.config | default dict -}}
{{- if and (kindIs "map" $c) (gt (len $c) 0) -}}true{{- else -}}false{{- end -}}
{{- end }}

{{- define "chart.externalSecretEnabled" -}}
{{- $es := .Values.externalSecret | default dict -}}
{{- $data := $es.data | default list -}}
{{- if and (gt (len $data) 0) ($es.secretStoreRef.name | default "") -}}true{{- else -}}false{{- end -}}
{{- end }}

{{- define "chart.validateExternalSecret" -}}
{{- $es := .Values.externalSecret | default dict -}}
{{- if kindIs "bool" $es -}}
{{- if $es -}}
{{- fail "externalSecret: true is invalid — set externalSecret.data and externalSecret.secretStoreRef.name (or omit / externalSecret: false)" -}}
{{- end -}}
{{- else -}}
{{- $data := $es.data | default list -}}
{{- $store := ($es.secretStoreRef | default dict).name | default "" -}}
{{- $hasData := gt (len $data) 0 -}}
{{- $hasStore := ne $store "" -}}
{{- if and $hasData (not $hasStore) -}}
{{- fail "externalSecret.data requires externalSecret.secretStoreRef.name (partial ExternalSecret config is not allowed)" -}}
{{- end -}}
{{- if and $hasStore (not $hasData) -}}
{{- fail "externalSecret.secretStoreRef.name requires externalSecret.data (partial ExternalSecret config is not allowed)" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Autoscaling:
- web/grpc: ON by default (empty map / omitted → platform HPA defaults).
- worker: OFF by default (workers are not assumed idempotent). Explicit non-empty
  autoscaling map in the consumer manifesto opts in.
- autoscaling: false disables for any workload type.
*/}}
{{- define "chart.autoscalingEnabled" -}}
{{- $t := include "chart.workloadType" . -}}
{{- $a := .Values.autoscaling -}}
{{- if kindIs "bool" $a -}}
{{- if $a -}}true{{- else -}}false{{- end -}}
{{- else if and $a (kindIs "map" $a) (gt (len $a) 0) -}}
true
{{- else if or (eq $t "web") (eq $t "grpc") -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{- define "chart.hpaMinReplicas" -}}
{{- $a := .Values.autoscaling | default dict -}}
{{- if and (kindIs "map" $a) (hasKey $a "minReplicas") -}}
{{- $a.minReplicas -}}
{{- else -}}
{{- $env := (.Values.runtime | default dict).environment | default "develop" -}}
{{- if eq $env "production" -}}2{{- else -}}1{{- end -}}
{{- end -}}
{{- end }}

{{- define "chart.hpaMaxReplicas" -}}
{{- $a := .Values.autoscaling | default dict -}}
{{- if and (kindIs "map" $a) (hasKey $a "maxReplicas") -}}
{{- $a.maxReplicas -}}
{{- else -}}
3
{{- end -}}
{{- end }}

{{- define "chart.hpaCpuTarget" -}}
{{- $a := .Values.autoscaling | default dict -}}
{{- if kindIs "map" $a -}}
{{- $cpu := $a.cpu | default dict -}}
{{- $cpu.target | default 70 -}}
{{- else -}}
70
{{- end -}}
{{- end }}

{{- define "chart.persistenceEnabled" -}}
{{- $p := .Values.persistence -}}
{{- if kindIs "bool" $p -}}
{{- if $p -}}true{{- else -}}false{{- end -}}
{{- else if and (kindIs "map" $p) ($p.mountPath | default "") -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{- define "chart.persistencePvcName" -}}
{{- printf "%s-data" .Release.Name -}}
{{- end }}

{{- define "chart.validatePersistence" -}}
{{- if (include "chart.persistenceEnabled" .) | eq "true" -}}
{{- $p := .Values.persistence | default dict -}}
{{- if not (kindIs "bool" $p) -}}
{{- $_ := required "persistence.mountPath is required when persistence is set" ($p.mountPath | default "") -}}
{{- $_ := required "persistence.size is required when persistence.mountPath is set" ($p.size | default "") -}}
{{- else -}}
{{- fail "persistence: true is invalid — set persistence.mountPath and persistence.size (or persistence: false)" -}}
{{- end -}}
{{- if (include "chart.autoscalingEnabled" .) | eq "true" -}}
{{- fail "persistence requires autoscaling: false (RWO PVC cannot be shared across HPA replicas)" -}}
{{- end -}}
{{- $replicas := .Values.replicaCount | int -}}
{{- if gt $replicas 1 -}}
{{- fail "persistence requires replicaCount: 1 (RWO PVC cannot be shared across pods)" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "app.envFrom" -}}
{{- $configEnabled := (include "chart.configEnabled" .) | eq "true" -}}
{{- $esEnabled := (include "chart.externalSecretEnabled" .) | eq "true" -}}
{{- if or $configEnabled $esEnabled }}
envFrom:
  {{- if $configEnabled }}
  - configMapRef:
      name: {{ .Release.Name }}-config
  {{- end }}
  {{- if $esEnabled }}
  - secretRef:
      name: {{ .Release.Name }}-secret
  {{- end }}
{{- end }}
{{- end }}

{{/*
Reject consumer config keys that would override platform-owned runtime settings.
config → ConfigMap → envFrom is overridden by explicit env, but reserved keys must still fail-fast.
*/}}
{{- define "chart.validateConfig" -}}
{{- $c := .Values.config | default dict -}}
{{- if and (kindIs "map" $c) (gt (len $c) 0) -}}
{{- $reservedExact := list
  "ASPNETCORE_URLS"
  "ASPNETCORE_HTTP_PORTS"
  "ASPNETCORE_HTTPS_PORTS"
  "GOOGLE_APPLICATION_CREDENTIALS"
-}}
{{- range $k, $_ := $c -}}
{{- if has $k $reservedExact -}}
{{- fail (printf "config.%s is platform-owned and cannot be set in the manifesto" $k) -}}
{{- end -}}
{{- if hasPrefix "Kestrel__" $k -}}
{{- fail (printf "config.%s is platform-owned (Kestrel__*) and cannot be set in the manifesto" $k) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Image reference. Digest wins over tag: GitOps/Kargo pins by immutable digest,
the Azure DevOps Helm path still pins by the (IMMUTABLE) commit-SHA tag.
Keep byte-identical with charts/asa-scheduled-job (tests/chart-invariants.sh asserts parity).
*/}}
{{- define "chart.validateImage" -}}
{{- $img := .Values.image | default dict -}}
{{- $digest := $img.digest | default "" -}}
{{- $tag := $img.tag | default "" -}}
{{- if not ($img.repository | default "") -}}
{{- fail "image.repository is required (injected by the platform, never by the manifesto)" -}}
{{- end -}}
{{- if $digest -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" $digest) -}}
{{- fail (printf "image.digest must match ^sha256:[0-9a-f]{64}$ (got %q)" $digest) -}}
{{- end -}}
{{- else if not $tag -}}
{{- fail "image requires digest (preferred) or tag" -}}
{{- end -}}
{{- end }}

{{- define "chart.imageRef" -}}
{{- $img := .Values.image | default dict -}}
{{- $digest := $img.digest | default "" -}}
{{- if $digest -}}
{{- printf "%s@%s" $img.repository $digest -}}
{{- else -}}
{{- printf "%s:%s" $img.repository ($img.tag | default "") -}}
{{- end -}}
{{- end }}
