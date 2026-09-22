{{/*
HTTP probes — opt-in (v2). No endpoint is presumed.
Presence: probes.path (all three) OR probes.<type>.path (partial).
Opt-out: probes: false / omit / {}.
*/}}

{{- define "chart.validateProbePath" -}}
{{- $path := index . 0 -}}
{{- $label := index . 1 -}}
{{- if and $path (not (hasPrefix "/" $path)) -}}
{{- fail (printf "%s must start with / (got %q)" $label $path) -}}
{{- end -}}
{{- end }}

{{- define "chart.validateProbes" -}}
{{- $p := .Values.probes | default false -}}
{{- if kindIs "bool" $p -}}
{{- if $p -}}
{{- fail "probes: true is invalid — set probes.path or probes.<startup|readiness|liveness>.path (or probes: false)" -}}
{{- end -}}
{{- else if and (kindIs "map" $p) (gt (len $p) 0) -}}
{{- $global := $p.path | default "" -}}
{{- $startup := (($p.startup | default dict).path | default "") -}}
{{- $readiness := (($p.readiness | default dict).path | default "") -}}
{{- $liveness := (($p.liveness | default dict).path | default "") -}}
{{- $hasGlobal := ne $global "" -}}
{{- $hasSpecific := or (ne $startup "") (ne $readiness "") (ne $liveness "") -}}
{{- if and $hasGlobal $hasSpecific -}}
{{- fail "probes.path cannot coexist with probes.<startup|readiness|liveness>.path — choose global or specific paths" -}}
{{- end -}}
{{- if and (not $hasGlobal) (not $hasSpecific) -}}
{{- fail "probes requires probes.path or at least one of probes.startup|readiness|liveness.path" -}}
{{- end -}}
{{- include "chart.validateProbePath" (list $global "probes.path") -}}
{{- include "chart.validateProbePath" (list $startup "probes.startup.path") -}}
{{- include "chart.validateProbePath" (list $readiness "probes.readiness.path") -}}
{{- include "chart.validateProbePath" (list $liveness "probes.liveness.path") -}}
{{- end -}}
{{- end }}

{{- define "chart.probeStartupPath" -}}
{{- $p := .Values.probes | default false -}}
{{- if kindIs "bool" $p -}}
{{- else if and (kindIs "map" $p) (gt (len $p) 0) -}}
{{- $global := $p.path | default "" -}}
{{- if $global -}}
{{- $global -}}
{{- else -}}
{{- ($p.startup | default dict).path | default "" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "chart.probeReadinessPath" -}}
{{- $p := .Values.probes | default false -}}
{{- if kindIs "bool" $p -}}
{{- else if and (kindIs "map" $p) (gt (len $p) 0) -}}
{{- $global := $p.path | default "" -}}
{{- if $global -}}
{{- $global -}}
{{- else -}}
{{- ($p.readiness | default dict).path | default "" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "chart.probeLivenessPath" -}}
{{- $p := .Values.probes | default false -}}
{{- if kindIs "bool" $p -}}
{{- else if and (kindIs "map" $p) (gt (len $p) 0) -}}
{{- $global := $p.path | default "" -}}
{{- if $global -}}
{{- $global -}}
{{- else -}}
{{- ($p.liveness | default dict).path | default "" -}}
{{- end -}}
{{- end -}}
{{- end }}
