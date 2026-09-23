{{/*
Shared env → hostname / gateway maps for HTTPRoute and GRPCRoute.
*/}}

{{- define "chart.corpHostname" -}}
{{- $env := .Values.runtime.environment | default "develop" -}}
{{- $zones := dict "develop" "dev.asa.corp" "homolog" "hml.asa.corp" "production" "prd.asa.corp" -}}
{{- printf "%s.%s" .Release.Name (index $zones $env | default "dev.asa.corp") -}}
{{- end }}

{{- define "chart.legacyHostname" -}}
{{- $env := .Values.runtime.environment | default "develop" -}}
{{- $zones := dict "develop" "d.asa.com.br" "homolog" "h.asa.com.br" "production" "p.asa.com.br" -}}
{{- printf "%s.%s" .Release.Name (index $zones $env | default "d.asa.com.br") -}}
{{- end }}

{{- define "chart.gatewayName" -}}
{{- $env := .Values.runtime.environment | default "develop" -}}
{{- $gws := dict "develop" "d-asa-com-br-internal-gateway" "homolog" "h-asa-com-br-internal-gateway" "production" "p-asa-com-br-internal-gateway" -}}
{{- index $gws $env | default "d-asa-com-br-internal-gateway" -}}
{{- end }}
