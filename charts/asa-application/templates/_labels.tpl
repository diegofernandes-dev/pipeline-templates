{{/*
Standard resource labels. helm.sh/chart is ONLY for resource metadata — never on
pod templates (a chart version bump must not force a rollout by itself).
spec.selector.matchLabels must stay {app: Release.Name} forever (immutable field).
*/}}
{{- define "chart.chartLabel" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" -}}
{{- end }}

{{- define "chart.labels" -}}
app: {{ .Release.Name }}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ include "chart.chartLabel" . }}
{{- end }}

{{- define "chart.podLabels" -}}
app: {{ .Release.Name }}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
