{{/* Standart isim formatı */}}
{{- define "web-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Standart nesne etiketi */}}
{{- define "web-api.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "web-api.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/* Ortak Kubernetes etiketleri */}}
{{- define "web-api.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "web-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
tier: {{ .Values.tier }}
{{- end }}

{{/* Pod seçici etiketleri */}}
{{- define "web-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "web-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}