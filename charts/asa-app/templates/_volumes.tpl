{{/*
common.volumes — lista de volumes para o pod spec.
Renderiza emptyDir /tmp, PVC e o token OIDC projetado quando habilitados.
Usar com nindent dentro de `volumes:`.
*/}}
{{- define "common.volumes" -}}
{{- if and .Values.securityContext .Values.securityContext.readOnlyRootFilesystem }}
- name: tmp
  emptyDir: {}
{{- end }}
{{- if (include "chart.persistenceEnabled" .) | eq "true" }}
- name: data
  persistentVolumeClaim:
    claimName: {{ include "chart.pvcName" . }}
{{- end }}
{{- if (include "chart.workloadIdentityEnabled" .) | eq "true" }}
- name: {{ include "chart.workloadIdentityTokenVolumeName" . }}
  projected:
    # 420 decimal = 0644. The projected file is root-owned; 0644 keeps it
    # readable by the chart's default non-root application user.
    defaultMode: {{ include "chart.workloadIdentityTokenDefaultMode" . }}
    sources:
      - serviceAccountToken:
          audience: {{ include "chart.workloadIdentityTokenAudience" . | quote }}
          expirationSeconds: {{ include "chart.workloadIdentityTokenExpirationSeconds" . }}
          path: {{ include "chart.workloadIdentityTokenFileName" . | quote }}
{{- end }}
{{- if (include "chart.workloadIdentityTargetsGCP" .) | eq "true" }}
{{- $wi := .Values.workloadIdentity | default dict }}
{{- $gcp := $wi.gcp | default dict }}
{{- if $gcp.credentialsConfigMapName | default "" }}
- name: gcp-credentials
  configMap:
    name: {{ $gcp.credentialsConfigMapName | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
common.volumeMounts — lista de volumeMounts para o container spec.
Renderiza mount de /tmp, PVC e token OIDC projetado quando habilitados.
Usar com nindent dentro de `volumeMounts:`.
*/}}
{{- define "common.volumeMounts" -}}
{{- if and .Values.securityContext .Values.securityContext.readOnlyRootFilesystem }}
- name: tmp
  mountPath: /tmp
{{- end }}
{{- if (include "chart.persistenceEnabled" .) | eq "true" }}
{{- $p := .Values.persistence | default dict }}
- name: data
  mountPath: {{ $p.mountPath | default "/data" | quote }}
  {{- if $p.subPath }}
  subPath: {{ $p.subPath | quote }}
  {{- end }}
{{- end }}
{{- if (include "chart.workloadIdentityEnabled" .) | eq "true" }}
- name: {{ include "chart.workloadIdentityTokenVolumeName" . }}
  mountPath: {{ include "chart.workloadIdentityTokenMountPath" . | quote }}
  readOnly: true
{{- end }}
{{- if (include "chart.workloadIdentityTargetsGCP" .) | eq "true" }}
{{- $wi := .Values.workloadIdentity | default dict }}
{{- $gcp := $wi.gcp | default dict }}
{{- if $gcp.credentialsConfigMapName | default "" }}
- name: gcp-credentials
  mountPath: /var/run/secrets/google
  readOnly: true
{{- end }}
{{- end }}
{{- end }}
