{{- define "frontend.name" -}}
{{- .Chart.Name }}
{{- end }}

{{- define "frontend.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name }}
{{- end }}

{{- define "frontend.labels" -}}
app: {{ include "frontend.name" . }}
release: {{ .Release.Name }}
{{- end }}
