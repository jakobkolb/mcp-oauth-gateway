# api-gateway

Helm chart that provides an OAuth 2.1 authentication gateway for MCP (Model Context Protocol) server endpoints. Originally developed as a subchart of the [knowledge-base](https://github.com/jakobkolb/knowledge-base) umbrella chart and published here so it can be referenced as an OCI dependency.

## What it does

The chart wires together three components to protect any number of MCP server `Service`s behind OAuth Bearer JWT authentication:

| Component | Role |
|-----------|------|
| **Dex** | OAuth 2.1 / OIDC authorization server. Fronts GitHub as the identity provider and issues JWTs to clients. |
| **oauth2-proxy** | Internal Bearer JWT validator. nginx-ingress forwards each authenticated request to it; oauth2-proxy validates the JWT and lets the request through (or rejects it). |
| **well-known server** | OpenResty/Lua sidecar serving the RFC-required discovery documents and Dynamic Client Registration endpoint so that MCP clients (e.g. claude.ai) can self-configure. |

### Request flow

```
claude.ai  ──/mcp/...──►  nginx-ingress
                              │  auth subrequest
                              ▼
                        oauth2-proxy :4180   (Bearer JWT check)
                              │  200 OK
                              ▼
                        MCP service :8000
```

### Discovery / RFC compliance

| Endpoint | RFC | Served by |
|----------|-----|-----------|
| `/.well-known/oauth-protected-resource` | RFC 9728 | well-known server |
| `/.well-known/oauth-authorization-server` | RFC 8414 | well-known server |
| `/register` | RFC 7591 | well-known server |
| `/.well-known/openid-configuration` | OIDC Core | proxied to Dex |
| `/auth` | OAuth 2.1 | well-known server (scope injection) → Dex |

The scope-injection layer on `/auth` silently prepends `openid` to authorization requests that omit it, working around a quirk in the claude.ai MCP client.

### One refresh token per connector (`perEndpointConnectors`)

`/register` hands every client the same `client_id` (`claude-mcp`), and Dex keeps
only **one refresh token per user, Dex connector and client**. So when several MCP
connectors (calendar, obsidian, …) log in through the same Dex connector, each
login deletes the refresh token of every other connector (Dex
`server/handlers.go`, "Delete old refresh token from storage"). Those connectors
keep working until their access token expires, then fail to refresh and need a
manual reconnect.

With `perEndpointConnectors.enabled`, `/auth` reads the RFC 8707 `resource`
parameter that MCP clients send (`https://<subdomain>.<baseDomain>`) and adds
`connector_id=<prefix><subdomain>`. Each endpoint then logs in through its own Dex
connector, gets its own offline session and keeps its own refresh token. Every
endpoint needs a matching entry in `dex.config.connectors`, and the render fails
if one is missing. The connectors can all share one GitHub OAuth app and callback
URL:

```yaml
perEndpointConnectors:
  enabled: true
dex:
  config:
    connectors:
      - &github {type: github, id: github, name: GitHub, config: {clientID: $GITHUB_CLIENT_ID, clientSecret: $GITHUB_CLIENT_SECRET, redirectURI: https://auth.example.com/callback}}
      - {<<: *github, id: github-calendar}
      - {<<: *github, id: github-obsidian}
```

Existing connectors keep their old refresh token until they next log in, so
reconnect each one once after enabling this.

## Prerequisites

- Kubernetes cluster with **nginx-ingress** and **cert-manager** installed.
- A GitHub OAuth App whose callback URL is `https://auth.<baseDomain>/callback`.

## Installation

### From OCI registry

```bash
helm install api-gateway oci://ghcr.io/jakobkolb/charts/api-gateway \
  --version 0.5.0 \
  --set global.baseDomain=example.com \
  --set global.authServerUrl=https://auth.example.com \
  --set global.createSecrets=true \
  --set global.secrets.githubClientId=<id> \
  --set global.secrets.githubClientSecret=<secret> \
  --set global.secrets.dexClientSecret=<secret> \
  --set global.secrets.cookieSecret=<32-byte-base64>
```

### As an umbrella chart dependency

```yaml
# Chart.yaml
dependencies:
  - name: api-gateway
    version: "0.5.0"
    repository: "oci://ghcr.io/jakobkolb/charts"
```

```yaml
# values.yaml
api-gateway:
  mcpEndpoints:
    - subdomain: calendar
      service: mcp-calendar   # K8s Service name: <release>-mcp-calendar
    - subdomain: notes
      service: mcp-notes
    - subdomain: whisper
      service: mcp-whisper
      annotations:            # per-endpoint extras — this one accepts audio uploads
        nginx.ingress.kubernetes.io/proxy-body-size: "64m"

global:
  baseDomain: example.com
  authServerUrl: https://auth.example.com
  clusterIssuer: letsencrypt-prod   # optional, defaults to letsencrypt-prod
  createSecrets: true               # set false when using external secret management
  secrets:
    githubClientId: ""
    githubClientSecret: ""
    dexClientSecret: ""
    cookieSecret: ""
```

## Values reference

| Key | Description | Default |
|-----|-------------|---------|
| `mcpEndpoints` | List of MCP servers to expose. Each entry needs `subdomain` and `service`, and may set `port` (default `8000`) and `annotations`. | `[]` |
| `mcpEndpoints[].annotations` | Extra ingress annotations for that one endpoint, e.g. `nginx.ingress.kubernetes.io/proxy-body-size` for an endpoint that accepts uploads. The chart's own auth/TLS/rewrite annotations cannot be overridden — doing so fails the render. | `{}` |
| `global.baseDomain` | Base domain. Endpoints land at `<subdomain>.<baseDomain>`, auth at `auth.<baseDomain>`. | required |
| `global.authServerUrl` | Public URL of the Dex issuer, e.g. `https://auth.example.com`. | required |
| `global.clusterIssuer` | cert-manager ClusterIssuer name. | `letsencrypt-prod` |
| `global.createSecrets` | Create Kubernetes Secrets from `global.secrets.*`. Disable when using ArgoCD / external secrets. | `false` |
| `global.secrets.githubClientId` | GitHub OAuth App client ID. | `""` |
| `global.secrets.githubClientSecret` | GitHub OAuth App client secret. | `""` |
| `global.secrets.dexClientSecret` | Placeholder secret for oauth2-proxy. Despite the name it is **not** shared with Dex: `claude-mcp` is a public PKCE client with no secret, and oauth2-proxy runs bearer-only, so the value is never exchanged with anything — it only has to be set. Any random string works. | `""` |
| `global.secrets.cookieSecret` | 32-byte base64 cookie signing secret for oauth2-proxy. | `""` |
| `perEndpointConnectors.enabled` | Send each MCP endpoint's login through its own Dex connector so every connector keeps its own refresh token — see [One refresh token per connector](#one-refresh-token-per-connector-perendpointconnectors). | `false` |
| `perEndpointConnectors.prefix` | Dex connector id prefix; the connector for `<subdomain>` must be named `<prefix><subdomain>`. | `github-` |
| `dex.*` | Passed through to the [Dex chart](https://github.com/dex-idp/helm-charts). | see `values.yaml` |
| `oauth2-proxy.*` | Passed through to the [oauth2-proxy chart](https://github.com/oauth2-proxy/manifests). | see `values.yaml` |

## Chart dependencies

| Chart | Version | Repository |
|-------|---------|------------|
| **dex** | 0.24.0 | https://charts.dexidp.io |
| **oauth2-proxy** | 7.18.0 | https://oauth2-proxy.github.io/manifests |

Dependencies are automatically fetched during Helm package and install operations.

## Secret management without `createSecrets`

When `global.createSecrets=false` the chart expects the following Secrets to already exist in the release namespace (created e.g. by `secrets-bootstrap.sh` in the umbrella chart or by an external secrets operator):

| Secret name | Keys |
|-------------|------|
| `dex-github-client` | `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` |
| `dex-static-client` | `DEX_CLIENT_SECRET` — **unused**, see below |
| `oauth2-proxy` | `client-id`, `client-secret`, `cookie-secret` |

### About the client secret

There is no client secret in this setup. `claude-mcp` is declared `public: true`,
`/register` hands out `token_endpoint_auth_method: "none"`, and the
authorization-server metadata advertises `token_endpoint_auth_methods_supported:
["none"]` — clients authenticate with PKCE alone. Adding a secret to the Dex
static client would make Dex reject exactly the PKCE-only clients this gateway
exists for.

Two leftovers still carry the name:

- `dex-static-client` / `DEX_CLIENT_SECRET` is injected into Dex via `envFrom` but
  referenced nowhere in `dex.config`, so Dex ignores it. It is dead since the
  static client became public.
- `oauth2-proxy`'s `client-secret` is set from the same value. oauth2-proxy runs
  in bearer-only mode (`skip-jwt-bearer-tokens`, `upstream: file:///dev/null`) and
  never performs a code exchange, so the value is never presented to Dex — it just
  has to be present. `tests/smoke/run.sh` passes the literal
  `unused-in-bearer-only-mode` and the smoke test passes.

## CI/Publishing Pipeline

### Release process

This repository uses GitHub Actions to automate chart releases. The release workflow is triggered when a git tag matching `v*` is pushed.

**To publish a new version:** create and push a git tag.

```bash
git tag v0.5.0
git push origin v0.5.0
```

The workflow packages with `--version "${GITHUB_REF_NAME#v}"`, so the tag is the
source of truth. The `version` in [Chart.yaml](Chart.yaml) is a local dev default
and does not need to be bumped before tagging.

### Release workflow

The GitHub Actions workflow ([.github/workflows/release.yaml](.github/workflows/release.yaml)) performs the following steps:

1. **Checkout** - Retrieves the repository code for the tagged version
2. **Setup Helm** - Installs Helm 3.17.0
3. **Authenticate** - Logs in to GitHub Container Registry (GHCR) using the repository token
4. **Fetch dependencies** - Runs `helm dependency update` to download Dex and oauth2-proxy charts
5. **Package chart** - Creates a `.tgz` package in `./dist`, versioned from the tag
6. **Push to registry** - Publishes the packaged chart to the OCI registry at `oci://ghcr.io/<owner>/charts`

The chart is then available for installation with:
```bash
helm install api-gateway oci://ghcr.io/<owner>/charts/api-gateway --version <version>
```

### Registry access

Published charts are hosted on GitHub Container Registry (GHCR) and publicly accessible. Authentication is required only when pushing new versions (handled automatically by GitHub Actions).
