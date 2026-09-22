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
