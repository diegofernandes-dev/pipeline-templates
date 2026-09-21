{{/*
common.envFrom — bloco envFrom completo para o container spec.
Renderiza configMapRef e/ou secretRef quando habilitados.
Retorna string vazia quando nenhum está habilitado (seguro para uso com `with`).
Usar com nindent no nível do container (ex: nindent 10 para containers padrão).
*/}}
{{- define "common.envFrom" -}}
{{- $configEnabled := (include "chart.configEffectiveEnabled" .) | eq "true" -}}
{{- $secretEnabled := get (.Values.secret | default dict) "enabled" | default false -}}
{{- if or $configEnabled $secretEnabled }}
envFrom:
  {{- if $configEnabled }}
  - configMapRef:
      name: {{ .Release.Name }}-cm
  {{- end }}
  {{- if $secretEnabled }}
  - secretRef:
      name: {{ .Release.Name }}-secret
  {{- end }}
{{- end }}
{{- end }}
