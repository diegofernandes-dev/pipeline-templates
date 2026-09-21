{{/*
common.workloadIdentityEnv — bloco `env:` específico do provedor de destino.

AWS: configura o provider de credenciais Web Identity dos SDKs AWS.
GCP: mantém o fluxo existente de token projetado; GOOGLE_APPLICATION_CREDENTIALS
     e GOOGLE_CLOUD_PROJECT são opcionais porque o external_account JSON pode ser
     injetado por outro mecanismo já existente no consumidor.
*/}}
{{- define "common.workloadIdentityEnv" -}}
{{- if (include "chart.workloadIdentityTargetsAWS" .) | eq "true" }}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $aws := $wi.aws | default dict -}}
env:
  - name: AWS_ROLE_ARN
    value: {{ required "workloadIdentity.aws.roleArn é obrigatório quando target=aws" ($aws.roleArn | default "") | quote }}
  - name: AWS_WEB_IDENTITY_TOKEN_FILE
    value: {{ include "chart.workloadIdentityTokenPath" . | quote }}
  - name: AWS_REGION
    value: {{ required "workloadIdentity.aws.region é obrigatório quando target=aws" ($aws.region | default "") | quote }}
  - name: AWS_DEFAULT_REGION
    value: {{ required "workloadIdentity.aws.region é obrigatório quando target=aws" ($aws.region | default "") | quote }}
  {{- with $aws.roleSessionName }}
  - name: AWS_ROLE_SESSION_NAME
    value: {{ . | quote }}
  {{- end }}
{{- else if and ((include "chart.workloadIdentityTargetsGCP" .) | eq "true") (not ((include "chart.workloadIdentityLegacyEnabled" .) | eq "true")) }}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $gcp := $wi.gcp | default dict -}}
{{- if or ($gcp.credentialsConfigMapName | default "") ($gcp.projectId | default "") }}
env:
  {{- if $gcp.credentialsConfigMapName | default "" }}
  - name: GOOGLE_APPLICATION_CREDENTIALS
    value: {{ include "chart.workloadIdentityGCPCredentialsPath" . | quote }}
  {{- end }}
  {{- with $gcp.projectId }}
  - name: GOOGLE_CLOUD_PROJECT
    value: {{ . | quote }}
  {{- end }}
{{- end }}
{{- end }}
{{- end }}
