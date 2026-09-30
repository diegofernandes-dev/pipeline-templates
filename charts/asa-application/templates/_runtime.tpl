{{/*
Presence-based toggles: non-empty map/list ⇒ on.

chart.toggleState classifies a values key that may be bool | map | nil:
  empty      — omitted / null / empty map
  off        — explicit false
  bare-true  — explicit true (usually invalid — prefer a map)
  on         — non-empty map
  bad-type   — anything else
*/}}
{{- define "chart.toggleState" -}}
{{- $v := index . 0 -}}
{{- if kindIs "invalid" $v -}}empty
{{- else if kindIs "bool" $v -}}
{{- if $v -}}bare-true{{- else -}}off{{- end -}}
{{- else if kindIs "map" $v -}}
{{- if eq (len $v) 0 -}}empty{{- else -}}on{{- end -}}
{{- else -}}bad-type
{{- end -}}
{{- end }}

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
{{- $state := include "chart.toggleState" (list $es) -}}
{{- if eq $state "bare-true" -}}
{{- fail "externalSecret: true is invalid — set externalSecret.data and externalSecret.secretStoreRef.name (or omit / externalSecret: false)" -}}
{{- else if or (eq $state "off") (eq $state "empty") -}}
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
{{- $state := include "chart.toggleState" (list $a) -}}
{{- if eq $state "bare-true" -}}
true
{{- else if eq $state "off" -}}
false
{{- else if eq $state "on" -}}
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
{{- required "platform.defaultMinReplicas is required (pipeline must inject via resolve-platform-values.sh)" .Values.platform.defaultMinReplicas -}}
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

{{- define "chart.validateAutoscaling" -}}
{{- if (include "chart.autoscalingEnabled" .) | eq "true" -}}
{{- $min := include "chart.hpaMinReplicas" . | int -}}
{{- $max := include "chart.hpaMaxReplicas" . | int -}}
{{- if gt $min $max -}}
{{- fail (printf "autoscaling.minReplicas (%d) must be <= autoscaling.maxReplicas (%d)" $min $max) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Effective floor on running replicas: the HPA minimum when autoscaling is on, otherwise
replicaCount. Used to decide whether a PDB is meaningful at all.
*/}}
{{- define "chart.effectiveMinReplicas" -}}
{{- if (include "chart.autoscalingEnabled" .) | eq "true" -}}
{{- include "chart.hpaMinReplicas" . -}}
{{- else -}}
{{- .Values.replicaCount | default 1 -}}
{{- end -}}
{{- end }}

{{- define "chart.pdbEnabled" -}}
{{- /* A PDB over a single replica cannot protect anything: the lone pod is still evictable,
       so the object is pure noise. Render only from 2 effective replicas up. */ -}}
{{- if not (.Values.pdb | default dict).enabled -}}
false
{{- else if ge ((include "chart.effectiveMinReplicas" .) | int) 2 -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{- define "chart.persistenceEnabled" -}}
{{- $p := .Values.persistence -}}
{{- $state := include "chart.toggleState" (list $p) -}}
{{- if eq $state "bare-true" -}}
true
{{- else if eq $state "off" -}}
false
{{- else if and (eq $state "on") ($p.mountPath | default "") -}}
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
{{- $state := include "chart.toggleState" (list $p) -}}
{{- if eq $state "bare-true" -}}
{{- fail "persistence: true is invalid — set persistence.mountPath and persistence.size (or persistence: false)" -}}
{{- else -}}
{{- $_ := required "persistence.mountPath is required when persistence is set" ($p.mountPath | default "") -}}
{{- $_ := required "persistence.size is required when persistence.mountPath is set" ($p.size | default "") -}}
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
Reject consumer config keys that collide with the platform↔image contract or WIF.
Runtime-specific keys (ASPNETCORE_*, Kestrel__*, …) are guarded by the runtime
profile / pipeline — not by this chart.
*/}}
{{- define "chart.validateConfig" -}}
{{- $c := .Values.config | default dict -}}
{{- if and (kindIs "map" $c) (gt (len $c) 0) -}}
{{- $reservedExact := list
  "PORT"
  "APP_PROTOCOL"
  "SHUTDOWN_TIMEOUT_SECONDS"
  "CPU_REQUEST_MILLICORES"
  "GOOGLE_APPLICATION_CREDENTIALS"
-}}
{{- range $k, $_ := $c -}}
{{- if has $k $reservedExact -}}
{{- fail (printf "config.%s is platform-owned and cannot be set in the manifesto" $k) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
App shutdown window must fit strictly inside the pod grace period so SIGKILL
does not race the runtime's own drain.
*/}}
{{- define "chart.validateShutdown" -}}
{{- $grace := .Values.terminationGracePeriodSeconds | default 0 | int -}}
{{- $shut := .Values.shutdownTimeoutSeconds | default 0 | int -}}
{{- if le $shut 0 -}}
{{- fail "shutdownTimeoutSeconds must be > 0" -}}
{{- end -}}
{{- if ge $shut $grace -}}
{{- fail (printf "shutdownTimeoutSeconds (%d) must be < terminationGracePeriodSeconds (%d)" $shut $grace) -}}
{{- end -}}
{{- end }}
