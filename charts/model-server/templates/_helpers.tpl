{{- define "model-server.fullname" -}}
{{- default .Release.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "model-server.labels" -}}
app.kubernetes.io/name: model-server
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
model: {{ include "model-server.fullname" . }}
{{- end -}}

{{- define "model-server.selectorLabels" -}}
app.kubernetes.io/name: model-server
model: {{ include "model-server.fullname" . }}
{{- end -}}
