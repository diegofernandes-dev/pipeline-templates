{{/*
Probes — explicit only. No global probes.path. No presumed /health-check.
web: each of startup|readiness|liveness may set path independently (optional per type).
grpc: each of startup|readiness|liveness may set enabled: true (platform port 8080).
worker: probes not supported.
Networked workloads (web/grpc) MUST choose probes: false OR configure at least one probe.
*/}}

{{- define "chart.validateProbePath" -}}
{{- $path := index . 0 -}}
{{- $label := index . 1 -}}
{{- if and $path (not (hasPrefix "/" $path)) -}}
{{- fail (printf "%s must start with / (got %q)" $label $path) -}}
{{- end -}}
{{- end }}

{{- define "chart.probeTypeEnabled" -}}
{{- /* args: root, typeName → "http" | "grpc" | "" */ -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- $t := include "chart.workloadType" $root -}}
{{- $p := $root.Values.probes | default dict -}}
{{- if kindIs "bool" $p -}}
{{- else if not (kindIs "map" $p) -}}
{{- else if eq (len $p) 0 -}}
{{- else if eq $t "worker" -}}
{{- else if eq $t "web" -}}
{{- $specific := ((index $p $name) | default dict).path | default "" -}}
{{- if $specific -}}http{{- end -}}
{{- else if eq $t "grpc" -}}
{{- $block := (index $p $name) | default dict -}}
{{- if and (kindIs "map" $block) ($block.enabled | default false) -}}grpc{{- end -}}
{{- end -}}
{{- end }}

{{- define "chart.probeHttpPath" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- $p := $root.Values.probes | default dict -}}
{{- ((index $p $name) | default dict).path | default "" -}}
{{- end }}

{{- define "chart.validateProbes" -}}
{{- $t := include "chart.workloadType" . -}}
{{- $p := .Values.probes -}}
{{- /* omitted / empty map → fail for networked; false → ok; object → validate */ -}}
{{- if eq $t "worker" -}}
{{- if and (kindIs "bool" $p) $p -}}
{{- fail "probes: true is invalid for worker — omit probes or set probes: false" -}}
{{- else if and (kindIs "map" $p) (gt (len $p) 0) -}}
{{- fail "probes are not supported for workload.type: worker" -}}
{{- end -}}
{{- else if or (eq $t "web") (eq $t "grpc") -}}
{{- if kindIs "invalid" $p -}}
{{- fail "probes is required for networked workloads — set probes: false or configure at least one probe explicitly" -}}
{{- else if kindIs "bool" $p -}}
{{- if $p -}}
{{- fail "probes: true is invalid — set probes: false or configure probes.<type> explicitly" -}}
{{- end -}}
{{- else if not (kindIs "map" $p) -}}
{{- fail "probes must be false or an object" -}}
{{- else if eq (len $p) 0 -}}
{{- fail "probes is required for networked workloads — set probes: false or configure at least one probe explicitly" -}}
{{- else -}}
{{- if hasKey $p "path" -}}
{{- fail "probes.path is not supported — set probes.startup|readiness|liveness.path (web) or .enabled (grpc) explicitly" -}}
{{- end -}}
{{- if eq $t "web" -}}
{{- range $name, $block := $p -}}
{{- if and (kindIs "map" $block) (hasKey $block "enabled") -}}
{{- fail "probes.<type>.enabled is for grpc only — web uses probes.<type>.path" -}}
{{- end -}}
{{- end -}}
{{- $startup := (($p.startup | default dict).path | default "") -}}
{{- $readiness := (($p.readiness | default dict).path | default "") -}}
{{- $liveness := (($p.liveness | default dict).path | default "") -}}
{{- if not (or (ne $startup "") (ne $readiness "") (ne $liveness "")) -}}
{{- fail "probes for web requires at least one of probes.startup|readiness|liveness.path" -}}
{{- end -}}
{{- include "chart.validateProbePath" (list $startup "probes.startup.path") -}}
{{- include "chart.validateProbePath" (list $readiness "probes.readiness.path") -}}
{{- include "chart.validateProbePath" (list $liveness "probes.liveness.path") -}}
{{- else if eq $t "grpc" -}}
{{- range $name, $block := $p -}}
{{- if and (kindIs "map" $block) (hasKey $block "path") -}}
{{- fail (printf "probes.%s.path is invalid for grpc — use enabled: true (platform port 8080)" $name) -}}
{{- end -}}
{{- end -}}
{{- $st := (($p.startup | default dict).enabled | default false) -}}
{{- $rd := (($p.readiness | default dict).enabled | default false) -}}
{{- $lv := (($p.liveness | default dict).enabled | default false) -}}
{{- if not (or $st $rd $lv) -}}
{{- fail "probes for grpc requires at least one of probes.startup|readiness|liveness.enabled: true" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}
