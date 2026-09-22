{{/*
EKS → GCP Workload Identity Federation (projected SA token + external_account ConfigMap).
IRSA (eks.amazonaws.com/role-arn) is configured separately via serviceAccount.annotations.
*/}}

{{- define "chart.workloadIdentityEnabled" -}}
{{- if .Values.workloadIdentity.enabled -}}true{{- else -}}false{{- end -}}
{{- end }}

{{- define "chart.workloadIdentityTokenAudience" -}}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $token := $wi.token | default dict -}}
{{- $token.audience | default "sts.amazonaws.com" -}}
{{- end }}

{{- define "chart.workloadIdentityTokenExpirationSeconds" -}}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $token := $wi.token | default dict -}}
{{- $token.expirationSeconds | default 3600 -}}
{{- end }}

{{- define "chart.workloadIdentityTokenFileName" -}}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $token := $wi.token | default dict -}}
{{- $token.fileName | default "token" -}}
{{- end }}

{{- define "chart.workloadIdentityTokenMountPath" -}}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $token := $wi.token | default dict -}}
{{- $token.mountPath | default "/var/run/secrets/eks.amazonaws.com/serviceaccount" -}}
{{- end }}

{{- define "chart.workloadIdentityTokenVolumeName" -}}
aws-token
{{- end }}

{{- define "chart.workloadIdentityTokenDefaultMode" -}}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $token := $wi.token | default dict -}}
{{- $token.defaultMode | default 420 -}}
{{- end }}

{{- define "chart.workloadIdentityGCPCredentialsPath" -}}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $gcp := $wi.gcp | default dict -}}
{{- $key := $gcp.credentialsConfigMapKey | default "external-account.json" -}}
{{- printf "/var/run/secrets/google/%s" $key -}}
{{- end }}

{{- define "chart.validateWorkloadIdentity" -}}
{{- if .Values.workloadIdentity.enabled -}}
{{- if not .Values.serviceAccount.create -}}
{{- fail "workloadIdentity requires serviceAccount.create=true" -}}
{{- end -}}
{{- $gcp := .Values.workloadIdentity.gcp | default dict -}}
{{- $_ := required "workloadIdentity.gcp.credentialsConfigMapName is required when workloadIdentity.enabled=true" ($gcp.credentialsConfigMapName | default "") -}}
{{- $expiration := include "chart.workloadIdentityTokenExpirationSeconds" . | int -}}
{{- if lt $expiration 600 -}}
{{- fail "workloadIdentity.token.expirationSeconds must be >= 600" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "app.workloadIdentityEnv" -}}
{{- if (include "chart.workloadIdentityEnabled" .) | eq "true" }}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $gcp := $wi.gcp | default dict -}}
env:
  - name: GOOGLE_APPLICATION_CREDENTIALS
    value: {{ include "chart.workloadIdentityGCPCredentialsPath" . | quote }}
  {{- with $gcp.projectId }}
  - name: GOOGLE_CLOUD_PROJECT
    value: {{ . | quote }}
  {{- end }}
{{- end }}
{{- end }}

{{- define "app.workloadIdentityVolumeMounts" -}}
{{- if (include "chart.workloadIdentityEnabled" .) | eq "true" }}
- name: {{ include "chart.workloadIdentityTokenVolumeName" . }}
  mountPath: {{ include "chart.workloadIdentityTokenMountPath" . | quote }}
  readOnly: true
{{- $gcp := .Values.workloadIdentity.gcp | default dict -}}
{{- if $gcp.credentialsConfigMapName | default "" }}
- name: gcp-credentials
  mountPath: /var/run/secrets/google
  readOnly: true
{{- end }}
{{- end }}
{{- end }}

{{- define "app.workloadIdentityVolumes" -}}
{{- if (include "chart.workloadIdentityEnabled" .) | eq "true" }}
- name: {{ include "chart.workloadIdentityTokenVolumeName" . }}
  projected:
    defaultMode: {{ include "chart.workloadIdentityTokenDefaultMode" . }}
    sources:
      - serviceAccountToken:
          audience: {{ include "chart.workloadIdentityTokenAudience" . | quote }}
          expirationSeconds: {{ include "chart.workloadIdentityTokenExpirationSeconds" . }}
          path: {{ include "chart.workloadIdentityTokenFileName" . | quote }}
{{- $gcp := .Values.workloadIdentity.gcp | default dict -}}
{{- if $gcp.credentialsConfigMapName | default "" }}
- name: gcp-credentials
  configMap:
    name: {{ $gcp.credentialsConfigMapName | quote }}
{{- end }}
{{- end }}
{{- end }}
