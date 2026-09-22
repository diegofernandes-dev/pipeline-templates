{{/*
app.envFrom — configMapRef / secretRef when enabled via manifesto.
*/}}
{{- define "app.envFrom" -}}
{{- $configEnabled := .Values.config.enabled | default false -}}
{{- $esEnabled := .Values.externalSecret.enabled | default false -}}
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
