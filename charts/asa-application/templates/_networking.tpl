{{/*
Platform-injected networking facts. The chart never maps area/tier → topology;
scripts/resolve-platform-values.sh reads platform/areas/<area>.yml and
passes platform.* (required, fail-closed — no silent defaults).
*/}}

{{- define "chart.hostname" -}}
{{- printf "%s.%s" .Release.Name (required "platform.dnsZone is required (pipeline must inject via resolve-platform-values.sh)" .Values.platform.dnsZone) -}}
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

{{/*
The composed hostname list both route kinds consume.

It joins two inputs of different origin: legacyDns is consumer intent (public manifest) while
legacyDnsZone is a platform fact (area profile), so the pipeline cannot compose it — the
resolver reads the area profile and never parses the app manifest. Composing it here keeps the
route templates purely structural and gives the rule one home: the identical block used to live
in httproute.yaml and grpcroute.yaml, so the same policy error surfaced from a different file
depending on workload.type.

Deduplicated on purpose: an area whose legacy zone equals its corp zone would otherwise emit
the same hostname twice, and the API server accepts that silently.
*/}}
{{- define "chart.hostnames" -}}
{{- $names := list (include "chart.hostname" .) -}}
{{- if .Values.legacyDns -}}
{{- $names = append $names (include "chart.legacyHostname" .) -}}
{{- end -}}
{{- $lines := list -}}
{{- range ($names | uniq) -}}
{{- $lines = append $lines (printf "- %s" (. | quote)) -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end }}
