#!/usr/bin/env bash
# Integration smoke test for the api-gateway OAuth flow.
#
# Renders this chart, starts Dex, the well-known server, oauth2-proxy and an
# ingress replica from the rendered config, and drives a real authorization-code
# + PKCE flow against them. Unlike `helm unittest` (which asserts on rendered
# YAML) this checks that the OAuth interface actually behaves: tokens are
# issued, can be renewed, and expired ones get a usable challenge back.
#
# Requires: docker, helm, python3 (with PyYAML). Run with: tests/smoke/run.sh
set -euo pipefail

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="$(mktemp -d)"
NETWORK="api-gateway-smoke"
RELEASE="smoke"
DEX_IMAGE="${DEX_IMAGE:-dexidp/dex:v2.41.1}"
OPENRESTY_IMAGE="${OPENRESTY_IMAGE:-openresty/openresty:alpine}"
OAUTH2_PROXY_IMAGE="${OAUTH2_PROXY_IMAGE:-quay.io/oauth2-proxy/oauth2-proxy:v7.7.1}"
DEX_PORT=5556
WK_PORT=8080
INGRESS_PORT=8081
SMOKE_CLIENT_ID="${SMOKE_CLIENT_ID:-claude-mcp}"

cleanup() {
  docker rm -f "$RELEASE-dex" "$RELEASE-well-known" "$RELEASE-oauth2-proxy" \
    "$RELEASE-upstream" "$RELEASE-ingress" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "==> Rendering chart"
# The subcharts (dex, oauth2-proxy) are not needed to render our own templates.
cp -r "$CHART_DIR" "$WORK_DIR/chart"
rm -rf "$WORK_DIR/chart/charts"
sed '/^dependencies:/,$d' "$CHART_DIR/Chart.yaml" > "$WORK_DIR/chart/Chart.yaml"

helm template "$RELEASE" "$WORK_DIR/chart" \
  --set global.baseDomain=smoke.test \
  --set "global.authServerUrl=http://127.0.0.1:$DEX_PORT" \
  --set 'mcpEndpoints[0].subdomain=calendar' \
  --set 'mcpEndpoints[0].service=mcp-calendar' \
  > "$WORK_DIR/rendered.yaml"

echo "==> Extracting chart artifacts"
python3 "$CHART_DIR/tests/smoke/render.py" \
  "$WORK_DIR/rendered.yaml" "$CHART_DIR/values.yaml" "$WORK_DIR" "$RELEASE" "$DEX_PORT"

echo "==> Starting containers"
docker network create "$NETWORK" >/dev/null 2>&1 || true
docker rm -f "$RELEASE-dex" "$RELEASE-well-known" "$RELEASE-oauth2-proxy" \
  "$RELEASE-upstream" "$RELEASE-ingress" >/dev/null 2>&1 || true

docker run -d --name "$RELEASE-dex" --network "$NETWORK" -p "$DEX_PORT:$DEX_PORT" \
  -v "$WORK_DIR/dex.yaml:/etc/dex/config.yaml:ro" \
  "$DEX_IMAGE" dex serve /etc/dex/config.yaml >/dev/null
docker run -d --name "$RELEASE-well-known" --network "$NETWORK" -p "$WK_PORT:80" \
  -v "$WORK_DIR/default.conf:/etc/nginx/conf.d/default.conf:ro" \
  "$OPENRESTY_IMAGE" >/dev/null
docker run -d --name "$RELEASE-upstream" --network "$NETWORK" \
  -v "$WORK_DIR/upstream.conf:/etc/nginx/conf.d/default.conf:ro" \
  "$OPENRESTY_IMAGE" >/dev/null
# Host networking so oauth2-proxy reaches Dex at the same issuer URL the tokens
# carry; the ingress replica reaches it back via host.docker.internal.
docker run -d --name "$RELEASE-oauth2-proxy" --network host "$OAUTH2_PROXY_IMAGE" \
  --provider=oidc "--oidc-issuer-url=http://127.0.0.1:$DEX_PORT" \
  --upstream=file:///dev/null --email-domain=* --skip-jwt-bearer-tokens=true \
  --skip-provider-button=true --http-address=0.0.0.0:4180 \
  --client-id="$SMOKE_CLIENT_ID" --client-secret=unused-in-bearer-only-mode \
  --cookie-secret="$(head -c 32 /dev/urandom | base64 | head -c 32)" >/dev/null
docker run -d --name "$RELEASE-ingress" --network "$NETWORK" -p "$INGRESS_PORT:80" \
  --add-host=host.docker.internal:host-gateway \
  -v "$WORK_DIR/ingress.conf:/etc/nginx/conf.d/default.conf:ro" \
  "$OPENRESTY_IMAGE" >/dev/null

for _ in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$DEX_PORT/.well-known/openid-configuration" >/dev/null 2>&1 &&
     curl -sf "http://127.0.0.1:$WK_PORT/.well-known/oauth-protected-resource" >/dev/null 2>&1 &&
     curl -so /dev/null "http://127.0.0.1:$INGRESS_PORT/mcp" &&
     curl -so /dev/null "http://127.0.0.1:4180/oauth2/auth"; then
    break
  fi
  sleep 1
done

echo "==> Running OAuth smoke checks"
WK_URL="http://127.0.0.1:$WK_PORT" \
  DEX_URL="http://127.0.0.1:$DEX_PORT" \
  MCP_URL="http://127.0.0.1:$INGRESS_PORT/mcp" \
  SMOKE_CLIENT_ID="$SMOKE_CLIENT_ID" \
  SMOKE_CLIENT_SECRET="$(cat "$WORK_DIR/client_secret")" \
  python3 "$CHART_DIR/tests/smoke/oauth_smoke.py"
