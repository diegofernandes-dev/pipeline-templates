{{/*
Application workload helpers — web | grpc | worker.
Platform ports: web=8080, grpc=50051 (not configurable in manifesto).
*/}}

{{- define "chart.workloadType" -}}
{{- $w := .Values.workload | default dict -}}
{{- $w.type | default "" -}}
{{- end }}

{{- define "chart.hasEndpoint" -}}
{{- $t := include "chart.workloadType" . -}}
{{- if or (eq $t "web") (eq $t "grpc") -}}true{{- else -}}false{{- end -}}
{{- end }}

{{- define "chart.isWeb" -}}
{{- if eq (include "chart.workloadType" .) "web" -}}true{{- else -}}false{{- end -}}
{{- end }}

{{- define "chart.isGrpc" -}}
{{- if eq (include "chart.workloadType" .) "grpc" -}}true{{- else -}}false{{- end -}}
{{- end }}

{{- define "chart.isWorker" -}}
{{- if eq (include "chart.workloadType" .) "worker" -}}true{{- else -}}false{{- end -}}
{{- end }}

{{- define "chart.containerPort" -}}
{{- $t := include "chart.workloadType" . -}}
{{- if eq $t "grpc" -}}50051{{- else if eq $t "web" -}}8080{{- else -}}0{{- end -}}
{{- end }}

{{- define "chart.validateApplication" -}}
{{- $kind := .Values.kind | default "" -}}
{{- if ne $kind "Application" -}}
{{- fail (printf "asa-application requires kind: Application (got %q)" $kind) -}}
{{- end -}}
{{- if hasKey (.Values.workload | default dict) "port" -}}
{{- fail "workload.port is not supported — platform owns ports (web=8080, grpc=50051)" -}}
{{- end -}}
{{- if or (hasKey .Values "schedule") (hasKey .Values "execution") (hasKey .Values "history") -}}
{{- fail "schedule/execution/history belong to kind: ScheduledJob (asa-scheduled-job), not Application" -}}
{{- end -}}
{{- if hasKey .Values "cronJob" -}}
{{- fail "cronJob is removed — use a separate deployable with kind: ScheduledJob" -}}
{{- end -}}
{{- $t := include "chart.workloadType" . -}}
{{- if not (or (eq $t "web") (eq $t "grpc") (eq $t "worker")) -}}
{{- fail (printf "workload.type must be web, grpc, or worker (got %q)" $t) -}}
{{- end -}}
{{- $legacy := .Values.legacyDns | default false -}}
{{- if and $legacy (eq $t "worker") -}}
{{- fail "legacyDns is invalid for workload.type: worker (no endpoint/DNS)" -}}
{{- end -}}
{{- end }}
