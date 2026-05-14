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

## Prerequisites

- Kubernetes cluster with **nginx-ingress** and **cert-manager** installed.
- A GitHub OAuth App whose callback URL is `https://auth.<baseDomain>/callback`.

## Installation

### From OCI registry

```bash
helm install api-gateway oci://ghcr.io/jakobkolb/charts/api-gateway \
  --version 0.2.0 \
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
    version: "0.2.0"
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
| `mcpEndpoints` | List of MCP servers to expose. Each entry needs `subdomain` and `service`. | `[]` |
| `global.baseDomain` | Base domain. Endpoints land at `<subdomain>.<baseDomain>`, auth at `auth.<baseDomain>`. | required |
| `global.authServerUrl` | Public URL of the Dex issuer, e.g. `https://auth.example.com`. | required |
| `global.clusterIssuer` | cert-manager ClusterIssuer name. | `letsencrypt-prod` |
| `global.createSecrets` | Create Kubernetes Secrets from `global.secrets.*`. Disable when using ArgoCD / external secrets. | `false` |
| `global.secrets.githubClientId` | GitHub OAuth App client ID. | `""` |
| `global.secrets.githubClientSecret` | GitHub OAuth App client secret. | `""` |
| `global.secrets.dexClientSecret` | Shared secret between Dex and oauth2-proxy. | `""` |
| `global.secrets.cookieSecret` | 32-byte base64 cookie signing secret for oauth2-proxy. | `""` |
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
| `dex-static-client` | `DEX_CLIENT_SECRET` |
| `oauth2-proxy` | `client-id`, `client-secret`, `cookie-secret` |

## CI/Publishing Pipeline

### Release process

This repository uses GitHub Actions to automate chart releases. The release workflow is triggered when a git tag matching `v*` is pushed.

**To publish a new version:**

1. Update the `version` field in [Chart.yaml](Chart.yaml)
2. Commit the changes
3. Create and push a git tag:
   ```bash
   git tag v0.2.0
   git push origin v0.2.0
   ```

### Release workflow

The GitHub Actions workflow ([.github/workflows/release.yaml](.github/workflows/release.yaml)) performs the following steps:

1. **Checkout** - Retrieves the repository code for the tagged version
2. **Setup Helm** - Installs Helm 3.17.0
3. **Authenticate** - Logs in to GitHub Container Registry (GHCR) using the repository token
4. **Fetch dependencies** - Runs `helm dependency update` to download Dex and oauth2-proxy charts
5. **Package chart** - Creates a `.tgz` package in the `./dist` directory
6. **Push to registry** - Publishes the packaged chart to the OCI registry at `oci://ghcr.io/<owner>/charts`

The chart is then available for installation with:
```bash
helm install api-gateway oci://ghcr.io/<owner>/charts/api-gateway --version <version>
```

### Registry access

Published charts are hosted on GitHub Container Registry (GHCR) and publicly accessible. Authentication is required only when pushing new versions (handled automatically by GitHub Actions).
