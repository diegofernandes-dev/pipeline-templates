{{/*
ScheduledJob — CronJob-only chart.
*/}}

{{- define "chart.configEnabled" -}}
{{- $c := .Values.config | default dict -}}
{{- if and (kindIs "map" $c) (gt (len $c) 0) -}}true{{- else -}}false{{- end -}}
{{- end }}

{{- define "chart.externalSecretEnabled" -}}
{{- $es := .Values.externalSecret | default dict -}}
{{- $data := $es.data | default list -}}
{{- if and (gt (len $data) 0) ($es.secretStoreRef.name | default "") -}}true{{- else -}}false{{- end -}}
{{- end }}

{{- define "chart.validateExternalSecret" -}}
{{- $es := .Values.externalSecret | default dict -}}
{{- if kindIs "bool" $es -}}
{{- if $es -}}
{{- fail "externalSecret: true is invalid — set externalSecret.data and externalSecret.secretStoreRef.name (or omit / externalSecret: false)" -}}
{{- end -}}
{{- else -}}
{{- $data := $es.data | default list -}}
{{- $store := ($es.secretStoreRef | default dict).name | default "" -}}
{{- $hasData := gt (len $data) 0 -}}
{{- $hasStore := ne $store "" -}}
{{- if and $hasData (not $hasStore) -}}
{{- fail "externalSecret.data requires externalSecret.secretStoreRef.name (partial ExternalSecret config is not allowed)" -}}
{{- end -}}
{{- if and $hasStore (not $hasData) -}}
{{- fail "externalSecret.secretStoreRef.name requires externalSecret.data (partial ExternalSecret config is not allowed)" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "chart.validateScheduledJob" -}}
{{- $kind := .Values.kind | default "" -}}
{{- if ne $kind "ScheduledJob" -}}
{{- fail (printf "asa-scheduled-job requires kind: ScheduledJob (got %q)" $kind) -}}
{{- end -}}
{{- if hasKey .Values "workload" -}}
{{- fail "workload belongs to kind: Application — not ScheduledJob" -}}
{{- end -}}
{{- if hasKey .Values "legacyDns" -}}
{{- fail "legacyDns belongs to kind: Application — not ScheduledJob" -}}
{{- end -}}
{{- if hasKey .Values "probes" -}}
{{- fail "probes are not supported on ScheduledJob" -}}
{{- end -}}
{{- if hasKey .Values "autoscaling" -}}
{{- fail "autoscaling is not supported on ScheduledJob" -}}
{{- end -}}
{{- if hasKey .Values "persistence" -}}
{{- fail "persistence is not supported on ScheduledJob" -}}
{{- end -}}
{{- $sched := .Values.schedule | default dict -}}
{{- $_ := required "schedule.expression is required" ($sched.expression | default "") -}}
{{- $tz := $sched.timeZone | default "" -}}
{{- if eq $tz "" -}}
{{- fail "schedule.timeZone is required (default America/Sao_Paulo — set explicitly to avoid control-plane TZ)" -}}
{{- end -}}
{{- $policy := $sched.concurrencyPolicy | default "Forbid" -}}
{{- if not (or (eq $policy "Allow") (eq $policy "Forbid") (eq $policy "Replace")) -}}
{{- fail (printf "schedule.concurrencyPolicy must be Allow, Forbid, or Replace (got %q)" $policy) -}}
{{- end -}}
{{- if and (hasKey $sched "startingDeadlineSeconds") (not (kindIs "invalid" $sched.startingDeadlineSeconds)) (ne ($sched.startingDeadlineSeconds | toString) "<nil>") (ne ($sched.startingDeadlineSeconds | toString) "") -}}
{{- if lt ($sched.startingDeadlineSeconds | int) 0 -}}
{{- fail "schedule.startingDeadlineSeconds must be >= 0" -}}
{{- end -}}
{{- end -}}
{{- $ex := .Values.execution | default dict -}}
{{- $cmd := $ex.command | default list -}}
{{- $args := $ex.args | default list -}}
{{- if and (eq (len $cmd) 0) (eq (len $args) 0) -}}
{{- fail "execution.command or execution.args is required (API entrypoint must not run as a ScheduledJob)" -}}
{{- end -}}
{{- if and (hasKey $ex "retries") (lt ($ex.retries | int) 0) -}}
{{- fail "execution.retries must be >= 0" -}}
{{- end -}}
{{- if and (hasKey $ex "timeoutSeconds") $ex.timeoutSeconds (le ($ex.timeoutSeconds | int) 0) -}}
{{- fail "execution.timeoutSeconds must be > 0 when set" -}}
{{- end -}}
{{- $hist := .Values.history | default dict -}}
{{- if and (hasKey $hist "successful") (lt ($hist.successful | int) 0) -}}
{{- fail "history.successful must be >= 0" -}}
{{- end -}}
{{- if and (hasKey $hist "failed") (lt ($hist.failed | int) 0) -}}
{{- fail "history.failed must be >= 0" -}}
{{- end -}}
{{- end }}

{{- define "app.envFrom" -}}
{{- $configEnabled := (include "chart.configEnabled" .) | eq "true" -}}
{{- $esEnabled := (include "chart.externalSecretEnabled" .) | eq "true" -}}
{{- if or $configEnabled $esEnabled }}
envFrom:
  {{- if $configEnabled }}
  - configMapRef:
      name: {{ .Release.Name }}-config
  {{- end }}
  {{- if $esEnabled }}
  - secretRef:
      name: {{ .Release.Name }}-secret
  {{- end }}
{{- end }}
{{- end }}
