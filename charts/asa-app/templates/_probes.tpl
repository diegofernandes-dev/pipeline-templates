{{/*
common.probes.web — probes de startup/readiness/liveness para workload HTTP (web).
Suporta dois modos via probes.mode (ou probes.enabled para compat. retroativa):
  - "tcp"  → tcpSocket no port "http"
  - "http" → httpGet em probes.path no port "http"
  - "off"  → sem probes
No modo http, cada probe pode sobrescrever o path individualmente via
probes.{startup,readiness,liveness}.path; quando ausente, cai em probes.path
(e, por fim, em "/health-check"), preservando o comportamento de path único.
Usar com nindent 10 no nível do container.
*/}}
{{- define "common.probes.web" -}}
{{- $probes := default dict .Values.probes -}}
{{- $probesMode := include "common.probes.mode" . -}}
{{- if ne $probesMode "off" -}}
{{- if eq $probesMode "tcp" }}
startupProbe:
  tcpSocket:
    port: http
  failureThreshold: {{ (default dict $probes.startup).failureThreshold | default 30 }}
  periodSeconds: {{ (default dict $probes.startup).periodSeconds | default 5 }}
readinessProbe:
  tcpSocket:
    port: http
  initialDelaySeconds: {{ (default dict $probes.readiness).initialDelaySeconds | default 5 }}
  periodSeconds: {{ (default dict $probes.readiness).periodSeconds | default 10 }}
  timeoutSeconds: {{ (default dict $probes.readiness).timeoutSeconds | default 3 }}
  failureThreshold: {{ (default dict $probes.readiness).failureThreshold | default 3 }}
livenessProbe:
  tcpSocket:
    port: http
  initialDelaySeconds: {{ (default dict $probes.liveness).initialDelaySeconds | default 15 }}
  periodSeconds: {{ (default dict $probes.liveness).periodSeconds | default 20 }}
  timeoutSeconds: {{ (default dict $probes.liveness).timeoutSeconds | default 3 }}
  failureThreshold: {{ (default dict $probes.liveness).failureThreshold | default 3 }}
{{- else }}
startupProbe:
  httpGet:
    path: {{ (default dict $probes.startup).path | default $probes.path | default "/health-check" }}
    port: http
  failureThreshold: {{ (default dict $probes.startup).failureThreshold | default 30 }}
  periodSeconds: {{ (default dict $probes.startup).periodSeconds | default 5 }}
readinessProbe:
  httpGet:
    path: {{ (default dict $probes.readiness).path | default $probes.path | default "/health-check" }}
    port: http
  initialDelaySeconds: {{ (default dict $probes.readiness).initialDelaySeconds | default 5 }}
  periodSeconds: {{ (default dict $probes.readiness).periodSeconds | default 10 }}
  timeoutSeconds: {{ (default dict $probes.readiness).timeoutSeconds | default 3 }}
  failureThreshold: {{ (default dict $probes.readiness).failureThreshold | default 3 }}
livenessProbe:
  httpGet:
    path: {{ (default dict $probes.liveness).path | default $probes.path | default "/health-check" }}
    port: http
  initialDelaySeconds: {{ (default dict $probes.liveness).initialDelaySeconds | default 15 }}
  periodSeconds: {{ (default dict $probes.liveness).periodSeconds | default 20 }}
  timeoutSeconds: {{ (default dict $probes.liveness).timeoutSeconds | default 3 }}
  failureThreshold: {{ (default dict $probes.liveness).failureThreshold | default 3 }}
{{- end }}
{{- end }}
{{- end }}

{{/*
common.probes.grpc — probes de startup/readiness/liveness para workload gRPC.
Suporta dois modos via workload.grpc.useHttpProbes:
  - false (default) → probe tipo grpc nativo (Kubernetes 1.24+), port numérico
  - true            → httpGet em probes.path (compatível com todos os clusters)
Usa probes.mode para on/off (compat. retroativa via probes.enabled).
Usar com nindent 10 no nível do container.
*/}}
{{- define "common.probes.grpc" -}}
{{- $probes := default dict .Values.probes -}}
{{- $probesEnabled := eq (include "common.probes.enabled" .) "true" -}}
{{- $probesMode := include "common.probes.mode" . -}}
{{- $svcPort := .Values.service.port | default 8080 -}}
{{- $gp := (.Values.workload | default dict).grpc | default dict -}}
{{- $grpcUseHttp := $gp.useHttpProbes | default false -}}
{{- $grpcHealthSvc := $gp.healthService | default "" -}}
{{- if and $probesEnabled (ne $probesMode "off") -}}
{{- if $grpcUseHttp }}
startupProbe:
  httpGet:
    path: {{ (default dict $probes.startup).path | default $probes.path | default "/health-check" }}
    port: grpc
  failureThreshold: {{ (default dict $probes.startup).failureThreshold | default 30 }}
  periodSeconds: {{ (default dict $probes.startup).periodSeconds | default 5 }}
readinessProbe:
  httpGet:
    path: {{ (default dict $probes.readiness).path | default $probes.path | default "/health-check" }}
    port: grpc
  initialDelaySeconds: {{ (default dict $probes.readiness).initialDelaySeconds | default 5 }}
  periodSeconds: {{ (default dict $probes.readiness).periodSeconds | default 10 }}
  timeoutSeconds: {{ (default dict $probes.readiness).timeoutSeconds | default 3 }}
  failureThreshold: {{ (default dict $probes.readiness).failureThreshold | default 3 }}
livenessProbe:
  httpGet:
    path: {{ (default dict $probes.liveness).path | default $probes.path | default "/health-check" }}
    port: grpc
  initialDelaySeconds: {{ (default dict $probes.liveness).initialDelaySeconds | default 15 }}
  periodSeconds: {{ (default dict $probes.liveness).periodSeconds | default 20 }}
  timeoutSeconds: {{ (default dict $probes.liveness).timeoutSeconds | default 3 }}
  failureThreshold: {{ (default dict $probes.liveness).failureThreshold | default 3 }}
{{- else }}
startupProbe:
  grpc:
    port: {{ $svcPort }}
    {{- if ne $grpcHealthSvc "" }}
    service: {{ $grpcHealthSvc | quote }}
    {{- end }}
  failureThreshold: {{ (default dict $probes.startup).failureThreshold | default 30 }}
  periodSeconds: {{ (default dict $probes.startup).periodSeconds | default 5 }}
readinessProbe:
  grpc:
    port: {{ $svcPort }}
    {{- if ne $grpcHealthSvc "" }}
    service: {{ $grpcHealthSvc | quote }}
    {{- end }}
  initialDelaySeconds: {{ (default dict $probes.readiness).initialDelaySeconds | default 5 }}
  periodSeconds: {{ (default dict $probes.readiness).periodSeconds | default 10 }}
  timeoutSeconds: {{ (default dict $probes.readiness).timeoutSeconds | default 3 }}
  failureThreshold: {{ (default dict $probes.readiness).failureThreshold | default 3 }}
livenessProbe:
  grpc:
    port: {{ $svcPort }}
    {{- if ne $grpcHealthSvc "" }}
    service: {{ $grpcHealthSvc | quote }}
    {{- end }}
  initialDelaySeconds: {{ (default dict $probes.liveness).initialDelaySeconds | default 15 }}
  periodSeconds: {{ (default dict $probes.liveness).periodSeconds | default 20 }}
  timeoutSeconds: {{ (default dict $probes.liveness).timeoutSeconds | default 3 }}
  failureThreshold: {{ (default dict $probes.liveness).failureThreshold | default 3 }}
{{- end }}
{{- end }}
{{- end }}

{{/*
common.probes.worker — probes de startup/readiness/liveness para workloads de background (worker).
Suporta três tipos via workload.workerProbes.type:
  - "tcp"  → tcpSocket no port (workload.workerProbes.port ou service.port)
  - "exec" → exec command (workload.workerProbes.exec.command é obrigatório)
  - outros → fallback para tcpSocket (igual ao tcp, mas com thresholds maiores)
Só renderiza quando habilitado (probes.enabled=true) E probes.mode != "off". O master
switch continua sendo probes.enabled; probes.mode="off" suprime as probes de forma
consistente com os perfis web/grpc (probes.mode não liga probes no worker sozinho — o
tipo segue governado por workload.workerProbes.type).
Usar com nindent 10 no nível do container.
*/}}
{{- define "common.probes.worker" -}}
{{- $probes := default dict .Values.probes -}}
{{- $probesEnabled := eq (include "common.probes.enabled" .) "true" -}}
{{- $probesMode := include "common.probes.mode" . -}}
{{- $svcPort := .Values.service.port | default 8080 -}}
{{- $wp := (.Values.workload | default dict).workerProbes | default dict -}}
{{- $wtype := $wp.type | default "tcp" -}}
{{- $wexec := $wp.exec | default dict -}}
{{- $workerTcpPort := $wp.port | default $svcPort -}}
{{- if and $probesEnabled (ne $probesMode "off") -}}
{{- if eq $wtype "tcp" }}
startupProbe:
  tcpSocket:
    port: {{ $workerTcpPort }}
  failureThreshold: {{ (default dict $probes.startup).failureThreshold | default 30 }}
  periodSeconds: {{ (default dict $probes.startup).periodSeconds | default 5 }}
readinessProbe:
  tcpSocket:
    port: {{ $workerTcpPort }}
  initialDelaySeconds: {{ (default dict $probes.readiness).initialDelaySeconds | default 5 }}
  periodSeconds: {{ (default dict $probes.readiness).periodSeconds | default 10 }}
  timeoutSeconds: {{ (default dict $probes.readiness).timeoutSeconds | default 3 }}
  failureThreshold: {{ (default dict $probes.readiness).failureThreshold | default 3 }}
livenessProbe:
  tcpSocket:
    port: {{ $workerTcpPort }}
  initialDelaySeconds: {{ (default dict $probes.liveness).initialDelaySeconds | default 15 }}
  periodSeconds: {{ (default dict $probes.liveness).periodSeconds | default 20 }}
  timeoutSeconds: {{ (default dict $probes.liveness).timeoutSeconds | default 3 }}
  failureThreshold: {{ (default dict $probes.liveness).failureThreshold | default 3 }}
{{- else if eq $wtype "exec" }}
{{- $cmd := $wexec.command | default list }}
{{- if not $cmd }}{{ fail "workload.workerProbes.exec.command is required when workload.workerProbes.type is exec" }}{{ end }}
startupProbe:
  exec:
    command:
{{ toYaml $cmd | nindent 6 }}
  failureThreshold: {{ (default dict $probes.startup).failureThreshold | default 30 }}
  periodSeconds: {{ (default dict $probes.startup).periodSeconds | default 5 }}
readinessProbe:
  exec:
    command:
{{ toYaml $cmd | nindent 6 }}
  initialDelaySeconds: {{ (default dict $probes.readiness).initialDelaySeconds | default 5 }}
  periodSeconds: {{ (default dict $probes.readiness).periodSeconds | default 10 }}
  timeoutSeconds: {{ (default dict $probes.readiness).timeoutSeconds | default 3 }}
  failureThreshold: {{ (default dict $probes.readiness).failureThreshold | default 3 }}
livenessProbe:
  exec:
    command:
{{ toYaml $cmd | nindent 6 }}
  initialDelaySeconds: {{ (default dict $probes.liveness).initialDelaySeconds | default 15 }}
  periodSeconds: {{ (default dict $probes.liveness).periodSeconds | default 20 }}
  timeoutSeconds: {{ (default dict $probes.liveness).timeoutSeconds | default 3 }}
  failureThreshold: {{ (default dict $probes.liveness).failureThreshold | default 3 }}
{{- else }}
startupProbe:
  tcpSocket:
    port: {{ $workerTcpPort }}
  failureThreshold: {{ (default dict $probes.startup).failureThreshold | default 60 }}
  periodSeconds: {{ (default dict $probes.startup).periodSeconds | default 10 }}
{{- end }}
{{- end }}
{{- end }}
