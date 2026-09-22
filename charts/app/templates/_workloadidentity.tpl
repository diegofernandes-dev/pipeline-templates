{{/*
EKS → GCP Workload Identity Federation.
Chart renders external_account ConfigMap from manifesto (no pre-provisioned CM).
IRSA (eks.amazonaws.com/role-arn) is configured separately via serviceAccount.annotations.
Presence: gcp.audience non-empty ⇒ on. Opt-out: workloadIdentity: false
*/}}

{{- define "chart.workloadIdentityEnabled" -}}
{{- $wi := .Values.workloadIdentity -}}
{{- if kindIs "bool" $wi -}}
{{- if $wi -}}true{{- else -}}false{{- end -}}
{{- else -}}
{{- $gcp := ($wi | default dict).gcp | default dict -}}
{{- if $gcp.audience | default "" -}}true{{- else -}}false{{- end -}}
{{- end -}}
{{- end }}

{{- define "chart.workloadIdentityConfigMapName" -}}
{{- printf "%s-wif-credentials" .Release.Name -}}
{{- end }}

{{- define "chart.workloadIdentityCredentialsKey" -}}
external-account.json
{{- end }}

{{- define "chart.workloadIdentityTokenAudience" -}}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $token := $wi.token | default dict -}}
{{- $gcp := $wi.gcp | default dict -}}
{{- $override := $token.audience | default "" -}}
{{- if $override -}}
{{- $override -}}
{{- else -}}
{{- $gcp.audience | default "" -}}
{{- end -}}
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

{{- define "chart.workloadIdentityTokenFilePath" -}}
{{- printf "%s/%s" (include "chart.workloadIdentityTokenMountPath" .) (include "chart.workloadIdentityTokenFileName" .) -}}
{{- end }}

{{- define "chart.workloadIdentityGCPCredentialsPath" -}}
{{- printf "/var/run/secrets/google/%s" (include "chart.workloadIdentityCredentialsKey" .) -}}
{{- end }}

{{- define "chart.workloadIdentityExternalAccount" -}}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $gcp := $wi.gcp | default dict -}}
{{- $cred := dict
  "type" "external_account"
  "audience" ($gcp.audience | required "workloadIdentity.gcp.audience is required")
  "subject_token_type" "urn:ietf:params:oauth:token-type:jwt"
  "token_url" "https://sts.googleapis.com/v1/token"
  "credential_source" (dict
    "file" (include "chart.workloadIdentityTokenFilePath" .)
    "format" (dict "type" "text")
  )
  "service_account_impersonation_url" (printf "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/%s:generateAccessToken" ($gcp.serviceAccountEmail | required "workloadIdentity.gcp.serviceAccountEmail is required"))
 -}}
{{- $cred | toPrettyJson -}}
{{- end }}

{{- define "chart.validateWorkloadIdentity" -}}
{{- if (include "chart.workloadIdentityEnabled" .) | eq "true" -}}
{{- if not .Values.serviceAccount.create -}}
{{- fail "workloadIdentity requires serviceAccount.create=true" -}}
{{- end -}}
{{- $wi := .Values.workloadIdentity | default dict -}}
{{- $gcp := $wi.gcp | default dict -}}
{{- $_ := required "workloadIdentity.gcp.audience is required when workloadIdentity is set" ($gcp.audience | default "") -}}
{{- $_ := required "workloadIdentity.gcp.serviceAccountEmail is required when workloadIdentity is set" ($gcp.serviceAccountEmail | default "") -}}
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
- name: gcp-credentials
  mountPath: /var/run/secrets/google
  readOnly: true
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
- name: gcp-credentials
  configMap:
    name: {{ include "chart.workloadIdentityConfigMapName" . | quote }}
{{- end }}
{{- end }}
