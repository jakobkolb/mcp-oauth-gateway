#!/usr/bin/env bash
# Integration smoke test for the api-gateway OAuth flow.
#
# Renders this chart, starts Dex and the well-known server from the rendered
# config, and drives a real authorization-code + PKCE flow against them.
# Unlike `helm unittest` (which asserts on rendered YAML) this checks that the
# OAuth interface actually behaves — tokens are issued, and can be renewed.
#
# Requires: docker, helm, python3 (with PyYAML). Run with: tests/smoke/run.sh
set -euo pipefail

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="$(mktemp -d)"
NETWORK="api-gateway-smoke"
RELEASE="smoke"
DEX_IMAGE="${DEX_IMAGE:-dexidp/dex:v2.41.1}"
OPENRESTY_IMAGE="${OPENRESTY_IMAGE:-openresty/openresty:alpine}"
DEX_PORT=5556
WK_PORT=8080

cleanup() {
  docker rm -f "$RELEASE-dex" "$RELEASE-well-known" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "==> Rendering chart"
# The subcharts (dex, oauth2-proxy) are not needed to render our own templates.
sed '/^dependencies:/,$d' "$CHART_DIR/Chart.yaml" > "$WORK_DIR/Chart.yaml.stripped"
cp -r "$CHART_DIR" "$WORK_DIR/chart"
cp "$WORK_DIR/Chart.yaml.stripped" "$WORK_DIR/chart/Chart.yaml"
rm -rf "$WORK_DIR/chart/charts"

helm template "$RELEASE" "$WORK_DIR/chart" \
  --set global.baseDomain=smoke.test \
  --set "global.authServerUrl=http://127.0.0.1:$DEX_PORT" \
  --set 'mcpEndpoints[0].subdomain=calendar' \
  --set 'mcpEndpoints[0].service=mcp-calendar' \
  > "$WORK_DIR/rendered.yaml"

# Pull the well-known nginx config out of the rendered ConfigMap so the smoke
# test exercises the chart's own artifact, not a copy of it.
python3 - "$WORK_DIR/rendered.yaml" "$WORK_DIR/default.conf" "$RELEASE" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
cm = next(d for d in docs if d.get("kind") == "ConfigMap")
conf = cm["data"]["default.conf"]
open(sys.argv[2], "w").write(conf)
print("    extracted %s (%d bytes)" % (cm["metadata"]["name"], len(conf)))
PY

echo "==> Building Dex config from chart values"
# staticClients come from the chart so the smoke test covers the real client
# definition. Test-only deviations: in-memory storage instead of kubernetes,
# and the mockCallback connector instead of github (both implement
# connector.RefreshConnector, which is what refresh-token issuance depends on).
python3 - "$CHART_DIR/values.yaml" "$WORK_DIR/dex.yaml" "$DEX_PORT" "$WORK_DIR" <<'PY'
import sys, yaml
values = yaml.safe_load(open(sys.argv[1]))
dex_values = (values.get("dex") or {}).get("config") or {}
port = sys.argv[3]

clients = []
for client in dex_values.get("staticClients") or []:
    client = dict(client)
    # secretEnv points at a Kubernetes Secret that does not exist here; a public
    # client carries no secret at all, so nothing needs substituting for it.
    if "secretEnv" in client:
        client.pop("secretEnv")
        client["secret"] = "smoke-client-secret"
    client.setdefault("redirectURIs", []).append("http://127.0.0.1:9999/cb")
    clients.append(client)

# The smoke client authenticates exactly the way the chart's client definition
# says it should: a secret if the client is confidential, PKCE alone if public.
open("%s/client_secret" % sys.argv[4], "w").write(
    "" if not clients else clients[0].get("secret", "")
)

config = {
    "issuer": "http://127.0.0.1:%s" % port,
    "storage": {"type": "memory"},
    "web": {"http": "0.0.0.0:%s" % port},
    "connectors": [{"type": "mockCallback", "id": "mock", "name": "Mock"}],
    "oauth2": dex_values.get("oauth2", {"skipApprovalScreen": True}),
    "staticClients": clients,
}
if "expiry" in dex_values:
    config["expiry"] = dex_values["expiry"]
yaml.safe_dump(config, open(sys.argv[2], "w"), sort_keys=False)
print("    staticClients: %s" % [c.get("id") for c in clients])
PY

echo "==> Starting containers"
docker network create "$NETWORK" >/dev/null 2>&1 || true
docker rm -f "$RELEASE-dex" "$RELEASE-well-known" >/dev/null 2>&1 || true
docker run -d --name "$RELEASE-dex" --network "$NETWORK" -p "$DEX_PORT:$DEX_PORT" \
  -v "$WORK_DIR/dex.yaml:/etc/dex/config.yaml:ro" \
  "$DEX_IMAGE" dex serve /etc/dex/config.yaml >/dev/null
docker run -d --name "$RELEASE-well-known" --network "$NETWORK" -p "$WK_PORT:80" \
  -v "$WORK_DIR/default.conf:/etc/nginx/conf.d/default.conf:ro" \
  "$OPENRESTY_IMAGE" >/dev/null

for _ in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$DEX_PORT/.well-known/openid-configuration" >/dev/null 2>&1 &&
     curl -sf "http://127.0.0.1:$WK_PORT/.well-known/oauth-protected-resource" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "==> Running OAuth smoke checks"
WK_URL="http://127.0.0.1:$WK_PORT" DEX_URL="http://127.0.0.1:$DEX_PORT" \
  SMOKE_CLIENT_SECRET="$(cat "$WORK_DIR/client_secret")" \
  python3 "$CHART_DIR/tests/smoke/oauth_smoke.py"
