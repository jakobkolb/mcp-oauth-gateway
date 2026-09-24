{{/*
Auth server host: auth.mcp.<baseDomain>
*/}}
{{- define "api-gateway.authHost" -}}
{{- printf "auth.mcp.%s" .Values.global.baseDomain -}}
{{- end -}}

{{/*
With perEndpointConnectors enabled, /auth sends every MCP endpoint to its own
Dex connector.  A connector missing from dex.config.connectors would only
surface as a failed login, so refuse to render instead.
*/}}
{{- define "api-gateway.validatePerEndpointConnectors" -}}
{{- if .Values.perEndpointConnectors.enabled }}
{{- $ids := list }}
{{- range .Values.dex.config.connectors }}{{ $ids = append $ids .id }}{{ end }}
{{- range .Values.mcpEndpoints }}
{{- $want := printf "%s%s" $.Values.perEndpointConnectors.prefix .subdomain }}
{{- if not (has $want $ids) }}
{{- fail (printf "perEndpointConnectors: mcpEndpoints[%s] needs a Dex connector with id %q in dex.config.connectors" .subdomain $want) }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}
