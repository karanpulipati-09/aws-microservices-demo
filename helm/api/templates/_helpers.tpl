{{- define "api.name" -}}
{{- .Chart.Name }}
{{- end }}

{{- define "api.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name }}
{{- end }}

{{- define "api.labels" -}}
app: {{ include "api.name" . }}
release: {{ .Release.Name }}
{{- end }}
