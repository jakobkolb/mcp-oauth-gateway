{{/*
nginx config served by the well-known server.

Kept in a named template so the Deployment can checksum it. A mounted
ConfigMap updates on disk but OpenResty only reads its config at startup,
so without a checksum annotation forcing a rolling restart the pod keeps
serving stale discovery metadata after every config change.
*/}}
{{- define "api-gateway.wellKnownConfig" -}}
server {
    listen 80;
    # RFC 9728: protected resource metadata
    location = /.well-known/oauth-protected-resource {
        default_type application/json;
        return 200 '{"resource":"https://$host","authorization_servers":["{{ .Values.global.authServerUrl }}"],"scopes_supported":["openid","profile","email","offline_access"]}';
    }
    # RFC 8414: auth server metadata for claude.ai MCP discovery
    # token_endpoint_auth_methods_supported=["none"] tells clients not to send a
    # client_secret (PKCE is sufficient).  registration_endpoint enables RFC 7591
    # Dynamic Client Registration, which the MCP spec requires.
    location = /.well-known/oauth-authorization-server {
        default_type application/json;
        return 200 '{"issuer":"{{ .Values.global.authServerUrl }}","authorization_endpoint":"{{ .Values.global.authServerUrl }}/auth","token_endpoint":"{{ .Values.global.authServerUrl }}/token","registration_endpoint":"{{ .Values.global.authServerUrl }}/register","jwks_uri":"{{ .Values.global.authServerUrl }}/keys","scopes_supported":["openid","profile","email","offline_access"],"response_types_supported":["code"],"grant_types_supported":["authorization_code","refresh_token"],"token_endpoint_auth_methods_supported":["none"],"code_challenge_methods_supported":["S256"]}';
    }
    # RFC 7591: Dynamic Client Registration — MCP spec requires this.
    # Returns a fixed public-client registration so claude.ai learns to use
    # token_endpoint_auth_method=none (PKCE only, no client_secret).
    location = /register {
        content_by_lua_block {
            ngx.req.read_body()
            ngx.header["Content-Type"] = "application/json"
            ngx.status = 201
            ngx.say('{"client_id":"claude-mcp","client_id_issued_at":' .. ngx.time() .. ',"redirect_uris":["https://claude.ai/api/mcp/auth_callback"],"grant_types":["authorization_code","refresh_token"],"response_types":["code"],"token_endpoint_auth_method":"none","code_challenge_methods_supported":["S256"]}')
            return ngx.exit(201)
        }
    }
    # Proxy Dex OIDC discovery — the /.well-known prefix ingress intercepts
    # this before the Dex ingress's /, so we must forward it internally.
    location = /.well-known/openid-configuration {
        proxy_pass http://{{ .Release.Name }}-dex:5556;
    }
    # Scope injection: claude.ai under-specifies the scopes it asks for.
    # Dex rejects a request without "openid", and only mints a refresh token
    # when the request carries "offline_access" — without it every token
    # expires with no way to renew it.  Add both before forwarding to Dex.
    # Uses OpenResty Lua (rewrite_by_lua_block) to modify the scope arg.
    location /auth {
        rewrite_by_lua_block {
            local args = ngx.req.get_uri_args()
            local scope = args.scope or ""
            -- match whole space-delimited scope tokens, so a scope such as
            -- "openid-foo" is not mistaken for "openid"
            local function has(s, want)
                return (" " .. s .. " "):find(" " .. want .. " ", 1, true) ~= nil
            end
            for _, want in ipairs({"openid", "offline_access"}) do
                if not has(scope, want) then
                    if scope == "" then scope = want else scope = scope .. " " .. want end
                end
            end
            args.scope = scope
            ngx.req.set_uri_args(args)
        }
        proxy_pass http://{{ .Release.Name }}-dex:5556;
    }
    location / { return 404; }
}
{{- end -}}
