#!/usr/bin/env python3
"""Turn rendered chart output into runnable configs for the smoke stack.

Everything the smoke test exercises is derived from the chart here — the
well-known nginx config and the MCP ingress's configuration-snippet come from
the rendered manifests, and the Dex client comes from values.yaml — so the
harness tests the chart's own artifacts rather than a copy of them.

Usage: render.py <rendered.yaml> <values.yaml> <out_dir> <release> <dex_port>
"""

import sys

import yaml

INGRESS_TEMPLATE = """resolver 127.0.0.11 ipv6=off;
server {
    listen 80;
    location = /_external_auth {
        internal;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header X-Original-URI    $request_uri;
        proxy_set_header Authorization     $http_authorization;
        proxy_pass http://host.docker.internal:4180/oauth2/auth;
    }
    location ~* "^/mcp(/|$)(.*)" {
%(snippet)s        auth_request /_external_auth;
        proxy_pass http://%(release)s-upstream:80/mcp/$2;
    }
}
"""

UPSTREAM_CONF = (
    'server { listen 80; location / { default_type application/json; '
    "return 200 '{\"mcp\":\"ok\"}'; } }\n"
)


def main():
    rendered, values_path, out_dir, release, dex_port = sys.argv[1:6]
    docs = [d for d in yaml.safe_load_all(open(rendered)) if d]

    # well-known nginx config, verbatim from the rendered ConfigMap
    cm = next(d for d in docs if d.get("kind") == "ConfigMap")
    conf = cm["data"]["default.conf"]
    open("%s/default.conf" % out_dir, "w").write(conf)
    print("    well-known config: %s (%d bytes)" % (cm["metadata"]["name"], len(conf)))

    # MCP ingress: take the configuration-snippet verbatim and wrap it in the
    # auth_request wiring ingress-nginx generates for the auth-url annotation.
    # Only that surrounding scaffolding is an approximation of the controller.
    ingress = next(
        d for d in docs
        if d.get("kind") == "Ingress"
        and "nginx.ingress.kubernetes.io/auth-url" in (d["metadata"].get("annotations") or {})
    )
    snippet = (ingress["metadata"]["annotations"]
               .get("nginx.ingress.kubernetes.io/configuration-snippet", ""))
    indented = "".join("        %s\n" % line for line in snippet.splitlines() if line.strip())
    open("%s/ingress.conf" % out_dir, "w").write(
        INGRESS_TEMPLATE % {"snippet": indented, "release": release}
    )
    print("    ingress snippet:   %s" % ("present" if snippet else "ABSENT"))
    open("%s/upstream.conf" % out_dir, "w").write(UPSTREAM_CONF)

    # Dex config: staticClients and expiry come from the chart. Test-only
    # deviations are in-memory storage and the mockCallback connector; both it
    # and github implement connector.RefreshConnector, which is the property
    # refresh-token issuance depends on.
    values = yaml.safe_load(open(values_path))
    dex_values = (values.get("dex") or {}).get("config") or {}

    clients = []
    for client in dex_values.get("staticClients") or []:
        client = dict(client)
        # secretEnv points at a Kubernetes Secret that does not exist here; a
        # public client carries no secret at all, so nothing needs substituting.
        if "secretEnv" in client:
            client.pop("secretEnv")
            client["secret"] = "smoke-client-secret"
        client.setdefault("redirectURIs", []).append("http://127.0.0.1:9999/cb")
        clients.append(client)

    config = {
        "issuer": "http://127.0.0.1:%s" % dex_port,
        "storage": {"type": "memory"},
        "web": {"http": "0.0.0.0:%s" % dex_port},
        "connectors": [{"type": "mockCallback", "id": "mock", "name": "Mock"}],
        "oauth2": dex_values.get("oauth2", {"skipApprovalScreen": True}),
        "staticClients": clients,
    }
    if "expiry" in dex_values:
        config["expiry"] = dex_values["expiry"]
    yaml.safe_dump(config, open("%s/dex.yaml" % out_dir, "w"), sort_keys=False)

    # The smoke client authenticates exactly the way the chart's client
    # definition says it should: a secret if confidential, PKCE alone if public.
    open("%s/client_secret" % out_dir, "w").write(
        clients[0].get("secret", "") if clients else ""
    )
    print("    dex staticClients: %s (%s)" % (
        [c.get("id") for c in clients],
        "public" if clients and clients[0].get("public") else "confidential",
    ))


if __name__ == "__main__":
    main()
