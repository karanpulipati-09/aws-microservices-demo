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

{{/* DB connection env vars, sourced from the Secret that External Secrets creates */}}
{{- define "api.dbEnv" -}}
{{- range $pair := list (list "DB_HOST" "host") (list "DB_PORT" "port") (list "DB_USER" "username") (list "DB_PASSWORD" "password") (list "DB_NAME" "dbname") }}
- name: {{ index $pair 0 }}
  valueFrom:
    secretKeyRef:
      name: {{ $.Values.externalSecret.targetSecret }}
      key: {{ index $pair 1 }}
{{- end }}
{{- end }}
