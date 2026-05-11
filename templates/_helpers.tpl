{{/*
Auth server host: auth.mcp.<baseDomain>
*/}}
{{- define "api-gateway.authHost" -}}
{{- printf "auth.mcp.%s" .Values.global.baseDomain -}}
{{- end -}}
