{{/*
Presence-based toggles: non-empty map/list ⇒ on. No separate enabled flags for manifesto clarity.
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

{{- define "chart.autoscalingEnabled" -}}
{{- $a := .Values.autoscaling -}}
{{- if kindIs "bool" $a -}}
{{- if $a -}}true{{- else -}}false{{- end -}}
{{- else if and $a (kindIs "map" $a) (gt (len $a) 0) -}}
true
{{- else -}}
false
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
