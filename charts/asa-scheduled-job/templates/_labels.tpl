{{/*
Standard resource labels. helm.sh/chart is ONLY for resource metadata — never on
pod templates (a chart version bump must not force a rollout by itself).
spec.selector.matchLabels must stay {app: Release.Name} forever (immutable field).
*/}}
{{- define "chart.chartLabel" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" -}}
{{- end }}

{{/*
image.tag reaches a LABEL VALUE, which Kubernetes restricts to <=63 chars of
[A-Za-z0-9._-] starting and ending alphanumeric. A raw tag breaks that for real,
common forms — a digest (sha256:...) and semver build metadata (1.2.3+build.5) are
both rejected by the API server with "metadata.labels: Invalid value", which fails
the whole apply. kubeconform does NOT catch it: label value syntax is not in the
OpenAPI schema. Same reason chartLabel above replaces "+".
Sanitise, then truncate, then trim — truncating first can expose a trailing "." or "-".
*/}}
{{- define "chart.versionLabel" -}}
{{- $v := .Values.image.tag | default .Chart.AppVersion | toString -}}
{{- $v = regexReplaceAll "[^A-Za-z0-9._-]" $v "_" -}}
{{- $v = trunc 63 $v -}}
{{- $v = regexReplaceAll "^[^A-Za-z0-9]+" $v "" -}}
{{- $v = regexReplaceAll "[^A-Za-z0-9]+$" $v "" -}}
{{- $v -}}
{{- end }}

{{- define "chart.labels" -}}
app: {{ .Release.Name }}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ include "chart.versionLabel" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ include "chart.chartLabel" . }}
{{- end }}

{{- define "chart.podLabels" -}}
app: {{ .Release.Name }}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ include "chart.versionLabel" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
