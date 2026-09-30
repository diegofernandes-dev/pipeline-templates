{{/*
Platform-injected networking facts. The chart never maps area/tier → topology;
scripts/resolve-platform-values.sh reads platform/areas/<area>.yml and
passes platform.* (required, fail-closed — no silent defaults).
*/}}

{{- define "chart.corpHostname" -}}
{{- printf "%s.%s" .Release.Name (required "platform.corpDnsZone is required (pipeline must inject via resolve-platform-values.sh)" .Values.platform.corpDnsZone) -}}
{{- end }}

{{- define "chart.legacyHostname" -}}
{{- $zone := .Values.platform.legacyDnsZone | default "" -}}
{{- if not $zone -}}
{{- fail "legacyDns=true requires platform.legacyDnsZone (cluster has no legacy DNS zone — unset legacyDns or add the zone to the area profile)" -}}
{{- end -}}
{{- printf "%s.%s" .Release.Name $zone -}}
{{- end }}

{{- define "chart.gatewayName" -}}
{{- required "platform.gatewayName is required (pipeline must inject via resolve-platform-values.sh)" .Values.platform.gatewayName -}}
{{- end }}

{{- define "chart.gatewayNamespace" -}}
{{- required "platform.gatewayNamespace is required (pipeline must inject via resolve-platform-values.sh)" .Values.platform.gatewayNamespace -}}
{{- end }}
