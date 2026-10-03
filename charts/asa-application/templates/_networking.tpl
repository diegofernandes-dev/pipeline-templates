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
{{- fail "dns.publishLegacyHostname=true requires platform.legacyDnsZone (cluster has no legacy DNS zone — unset dns.publishLegacyHostname or add the zone to the area profile)" -}}
{{- end -}}
{{- printf "%s.%s" .Release.Name $zone -}}
{{- end }}

{{- define "chart.gatewayName" -}}
{{- required "platform.gatewayName is required (pipeline must inject via resolve-platform-values.sh)" .Values.platform.gatewayName -}}
{{- end }}

{{- define "chart.gatewayNamespace" -}}
{{- required "platform.gatewayNamespace is required (pipeline must inject via resolve-platform-values.sh)" .Values.platform.gatewayNamespace -}}
{{- end }}

{{- define "chart.publishLegacyHostname" -}}
{{- $dns := .Values.dns | default dict -}}
{{- if and (hasKey $dns "publishLegacyHostname") $dns.publishLegacyHostname -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/*
Route acceptance hostnames — Gateway/TLS validation surface.

When platform.legacyDnsZone is set, BOTH corp and legacy hostnames are accepted on the
Route so cutover can be validated (TLS, Gateway, backend) before DNS is transferred.
dns.publishLegacyHostname does NOT gate this list — it only controls ExternalDNS publication.

Deduplicated on purpose: an area whose legacy zone equals its corp zone would otherwise
emit the same hostname twice, and the API server accepts that silently.
*/}}
{{- define "chart.hostnames" -}}
{{- $names := list (include "chart.hostname" .) -}}
{{- $zone := .Values.platform.legacyDnsZone | default "" -}}
{{- if $zone -}}
{{- $names = append $names (printf "%s.%s" .Release.Name $zone) -}}
{{- end -}}
{{- $lines := list -}}
{{- range ($names | uniq) -}}
{{- $lines = append $lines (printf "- %s" (. | quote)) -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end }}

{{/*
ExternalDNS publication annotations.

gateway-hostname-source: annotation-only keeps Route acceptance ≠ DNS ownership.
Hostnames in the annotation are the only ones ExternalDNS may publish.

Requires an ExternalDNS Gateway API source that honours
external-dns.kubernetes.io/gateway-hostname-source and
external-dns.kubernetes.io/hostname. See docs/lab-e2e-validation-2026-10-02.md
for the version and flags proven in lab.
*/}}
{{- define "chart.externalDnsAnnotations" -}}
{{- $names := list (include "chart.hostname" .) -}}
{{- if eq (include "chart.publishLegacyHostname" .) "true" -}}
{{- $names = append $names (include "chart.legacyHostname" .) -}}
{{- end -}}
external-dns.kubernetes.io/gateway-hostname-source: annotation-only
external-dns.kubernetes.io/hostname: {{ $names | uniq | join "," | quote }}
{{- end }}
