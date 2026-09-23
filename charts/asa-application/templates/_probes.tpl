{{/*
Probes — opt-in, no presumed endpoint.
web: HTTP path (global probes.path or probes.<type>.path)
grpc: probes.<type>.enabled → grpc probe on platform port 50051
worker: probes map with content → fail
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
{{- $global := $p.path | default "" -}}
{{- $specific := ((index $p $name) | default dict).path | default "" -}}
{{- if $global -}}http{{- else if $specific -}}http{{- end -}}
{{- else if eq $t "grpc" -}}
{{- $block := (index $p $name) | default dict -}}
{{- if and (kindIs "map" $block) ($block.enabled | default false) -}}grpc{{- end -}}
{{- end -}}
{{- end }}

{{- define "chart.probeHttpPath" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- $p := $root.Values.probes | default dict -}}
{{- $global := $p.path | default "" -}}
{{- if $global -}}
{{- $global -}}
{{- else -}}
{{- ((index $p $name) | default dict).path | default "" -}}
{{- end -}}
{{- end }}

{{- define "chart.validateProbes" -}}
{{- $t := include "chart.workloadType" . -}}
{{- $p := .Values.probes | default false -}}
{{- if kindIs "bool" $p -}}
{{- if $p -}}
{{- fail "probes: true is invalid — configure probes explicitly or omit / probes: false" -}}
{{- end -}}
{{- else if and (kindIs "map" $p) (gt (len $p) 0) -}}
{{- if eq $t "worker" -}}
{{- fail "probes are not supported for workload.type: worker" -}}
{{- end -}}
{{- if eq $t "web" -}}
{{- range $name, $block := $p -}}
{{- if and (ne $name "path") (kindIs "map" $block) -}}
{{- if hasKey $block "enabled" -}}
{{- fail "probes.<type>.enabled is for grpc only — web uses path" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $global := $p.path | default "" -}}
{{- $startup := (($p.startup | default dict).path | default "") -}}
{{- $readiness := (($p.readiness | default dict).path | default "") -}}
{{- $liveness := (($p.liveness | default dict).path | default "") -}}
{{- $hasGlobal := ne $global "" -}}
{{- $hasSpecific := or (ne $startup "") (ne $readiness "") (ne $liveness "") -}}
{{- if and $hasGlobal $hasSpecific -}}
{{- fail "probes.path cannot coexist with probes.<startup|readiness|liveness>.path" -}}
{{- end -}}
{{- if and (not $hasGlobal) (not $hasSpecific) -}}
{{- fail "probes for web requires probes.path or probes.<type>.path" -}}
{{- end -}}
{{- include "chart.validateProbePath" (list $global "probes.path") -}}
{{- include "chart.validateProbePath" (list $startup "probes.startup.path") -}}
{{- include "chart.validateProbePath" (list $readiness "probes.readiness.path") -}}
{{- include "chart.validateProbePath" (list $liveness "probes.liveness.path") -}}
{{- else if eq $t "grpc" -}}
{{- if $p.path | default "" -}}
{{- fail "probes.path is for web only — grpc uses probes.<type>.enabled" -}}
{{- end -}}
{{- $st := (($p.startup | default dict).enabled | default false) -}}
{{- $rd := (($p.readiness | default dict).enabled | default false) -}}
{{- $lv := (($p.liveness | default dict).enabled | default false) -}}
{{- if (($p.startup | default dict).path | default "") -}}
{{- fail "probes.startup.path is invalid for grpc — use enabled: true (platform port 50051)" -}}
{{- end -}}
{{- if (($p.readiness | default dict).path | default "") -}}
{{- fail "probes.readiness.path is invalid for grpc — use enabled: true (platform port 50051)" -}}
{{- end -}}
{{- if (($p.liveness | default dict).path | default "") -}}
{{- fail "probes.liveness.path is invalid for grpc — use enabled: true (platform port 50051)" -}}
{{- end -}}
{{- if not (or $st $rd $lv) -}}
{{- fail "probes for grpc requires at least one of probes.startup|readiness|liveness.enabled: true" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}
