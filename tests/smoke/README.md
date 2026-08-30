# OAuth smoke tests

`helm unittest` asserts on rendered YAML. These tests assert on **behaviour**:
they start Dex and the well-known server from this chart's own rendered output
and drive a real authorization-code + PKCE flow against them.

```bash
tests/smoke/run.sh
```

Requires `docker`, `helm` and `python3` with PyYAML. Everything is torn down on
exit.

## What it covers

- the protected-resource document uses the RFC 9728 `scopes_supported` field
  and advertises `offline_access`
- authorization succeeds even when the client sends no `scope` parameter
- the token response carries a `refresh_token`
- the refresh grant succeeds and rotates the refresh token
- the authorization-server document offers the auth method `/register` hands out
- the chart's Dex client is public, so PKCE alone is enough to authenticate
- a public client rejects a stale `client_secret` — the property that requires
  existing connectors to drop the secret they were configured with

## Fidelity

The nginx config is extracted from the rendered `well-known` ConfigMap, and the
Dex `staticClients` and `expiry` blocks are read from `values.yaml`, so the
client definition under test is the chart's own. The smoke client authenticates
the way that definition says it should — with a secret if the client is
confidential, with PKCE alone if it is public.

Two test-only deviations from a real deployment:

| | production | smoke |
|---|---|---|
| Dex storage | `kubernetes` | `memory` |
| Dex connector | `github` | `mockCallback` |

Both connectors implement `connector.RefreshConnector`, which is the property
refresh-token issuance depends on, so the substitution does not affect what is
being tested.
