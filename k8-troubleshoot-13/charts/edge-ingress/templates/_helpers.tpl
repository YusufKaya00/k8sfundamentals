{{/*
Expand the name of the chart.
*/}}
{{- define "edge-ingress.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "edge-ingress.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "edge-ingress.labels" -}}
helm.sh/chart: {{ include "edge-ingress.name" . }}-{{ .Chart.Version | replace "+" "_" }}
{{ include "edge-ingress.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: novaedge
{{- end }}

{{/*
Selector labels
*/}}
{{- define "edge-ingress.selectorLabels" -}}
app.kubernetes.io/name: {{ include "edge-ingress.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
