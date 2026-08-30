#!/usr/bin/env python3
"""OAuth behaviour assertions for the api-gateway chart.

Driven by tests/smoke/run.sh, which renders the chart and starts Dex plus the
well-known server. This module only talks HTTP, so every assertion is about
observable OAuth behaviour rather than rendered YAML.

Endpoints (set by run.sh):
  WK_URL   well-known server — serves the discovery documents and /auth scope injection
  DEX_URL  Dex — token endpoint; must equal Dex's configured issuer
"""

import base64
import hashlib
import http.cookiejar
import json
import os
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request

WK_URL = os.environ.get("WK_URL", "http://127.0.0.1:8080")
DEX_URL = os.environ.get("DEX_URL", "http://127.0.0.1:5556")
REDIRECT_URI = os.environ.get("SMOKE_REDIRECT_URI", "http://127.0.0.1:9999/cb")
CLIENT_ID = os.environ.get("SMOKE_CLIENT_ID", "claude-mcp")
# Empty when the chart declares a public client — then PKCE is the only credential.
CLIENT_SECRET = os.environ.get("SMOKE_CLIENT_SECRET", "")


def client_auth():
    return {"client_secret": CLIENT_SECRET} if CLIENT_SECRET else {}

_results = []


def check(name, condition, detail=""):
    _results.append((name, bool(condition), detail))
    print("  [%s] %s%s" % ("PASS" if condition else "FAIL", name, "  -- " + detail if detail else ""))


def _opener():
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None

    return urllib.request.build_opener(NoRedirect, urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))


def get_json(url):
    return json.loads(urllib.request.urlopen(url, timeout=15).read())


def post_json(url, body=b"{}"):
    req = urllib.request.Request(url, data=body, method="POST")
    return json.loads(urllib.request.urlopen(req, timeout=15).read())


def authorize(scope):
    """Run authorization-code + PKCE through the well-known server's /auth injector.

    scope=None omits the scope parameter entirely, which is what a spec-compliant
    MCP client does when the resource metadata advertises no scopes_supported.
    Returns (code, code_verifier) or (None, error_dict).
    """
    op = _opener()
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    params = {
        "client_id": CLIENT_ID,
        "redirect_uri": REDIRECT_URI,
        "response_type": "code",
        "state": "smoke",
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    }
    if scope is not None:
        params["scope"] = scope
    url = WK_URL + "/auth?" + urllib.parse.urlencode(params)

    for _ in range(12):
        try:
            resp = op.open(urllib.request.Request(url, method="GET"), timeout=15)
            location = resp.headers.get("Location")
        except urllib.error.HTTPError as exc:
            location = exc.headers.get("Location")
        if not location:
            return None, {"error": "no redirect from %s" % url}
        nxt = urllib.parse.urljoin(url, location)
        if nxt.startswith(REDIRECT_URI):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(nxt).query)
            if "code" in query:
                return query["code"][0], verifier
            return None, {k: v[0] for k, v in query.items()}
        url = nxt
    return None, {"error": "redirect loop"}


def token(**form):
    body = urllib.parse.urlencode(form).encode()
    req = urllib.request.Request(
        DEX_URL + "/token", data=body, method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        return 200, json.loads(urllib.request.urlopen(req, timeout=15).read())
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            return exc.code, json.loads(raw)
        except ValueError:
            return exc.code, {"raw": raw}


def main():
    print("Discovery documents")
    prm = get_json(WK_URL + "/.well-known/oauth-protected-resource")
    check("protected resource metadata uses RFC 9728 scopes_supported",
          "scopes_supported" in prm and "scopes_provided" not in prm, json.dumps(prm))
    check("protected resource metadata advertises offline_access",
          "offline_access" in prm.get("scopes_supported", []))

    print("\nAuthorization flow")
    # A client that finds no scopes_supported omits the scope parameter entirely.
    # The injector has to supply openid, or Dex rejects with invalid_scope.
    code, verifier = authorize(None)
    check("authorization succeeds when the client sends no scope", code is not None,
          "" if code else json.dumps(verifier))

    if code is None:
        return report()

    status, tok = token(grant_type="authorization_code", code=code,
                        redirect_uri=REDIRECT_URI, client_id=CLIENT_ID,
                        code_verifier=verifier, **client_auth())
    check("token endpoint returns 200", status == 200, json.dumps(tok) if status != 200 else "")
    check("token response contains a refresh_token", "refresh_token" in tok,
          "keys: %s" % sorted(tok.keys()))

    print("\nRefresh grant")
    if "refresh_token" in tok:
        status, refreshed = token(grant_type="refresh_token",
                                  refresh_token=tok["refresh_token"],
                                  client_id=CLIENT_ID, **client_auth())
        check("refresh grant succeeds", status == 200, json.dumps(refreshed) if status != 200 else "")
        check("refresh grant returns a new access token", "access_token" in refreshed)
        check("refresh grant rotates the refresh token",
              refreshed.get("refresh_token") not in (None, tok["refresh_token"]))

    return report()


def report():
    failed = [name for name, ok, _ in _results if not ok]
    print("\n%d/%d checks passed" % (len(_results) - len(failed), len(_results)))
    if failed:
        print("FAILED: " + ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
