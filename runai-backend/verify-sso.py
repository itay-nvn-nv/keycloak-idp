#!/usr/bin/env python3
"""Verify that a user can really log in to Run:AI through the brokered IDP.

Drives the same authorization-code flow a browser performs: request a code from
the runai realm with kc_idp_hint, authenticate against the mock-idp realm,
follow the broker callback, exchange the code, then check the mapped claims and
the project the access rule is supposed to grant.

Exit codes:
  0  login succeeded and every expectation held
  1  a check failed (the IDP wiring is wrong)
  2  the control plane could not be reached (nothing proven either way)
"""

import argparse
import base64
import hashlib
import html
import http.cookiejar
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

FORM_RE = re.compile(r'<form[^>]*action="([^"]+)"[^>]*>(.*?)</form>', re.S | re.I)
INPUT_RE = re.compile(r'<input[^>]*name="([^"]+)"[^>]*value="([^"]*)"', re.S | re.I)
LOGIN_FORM_RE = re.compile(r'<form[^>]*id="kc-form-login"[^>]*action="([^"]+)"', re.I)

RETRY_ATTEMPTS = 5
RETRY_DELAY = 5


class Unreachable(Exception):
    """The control plane did not answer; the IDP configuration is not implicated."""


class CheckFailed(Exception):
    """The flow completed but did not behave as the setup intends."""


class Session:
    def __init__(self, insecure):
        context = None
        if insecure:
            context = ssl.create_default_context()
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
        self._opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
            urllib.request.HTTPSHandler(context=context),
        )
        self._opener.addheaders = [("User-Agent", "runai-keycloak-idp-verify")]

    def open(self, url, data=None, headers=None, allow_status=(), json_body=None):
        """Fetch a URL, retrying transport failures and 5xx responses."""
        if json_body is not None:
            body = json.dumps(json_body).encode()
            headers = dict(headers or {}, **{"Content-Type": "application/json"})
        else:
            body = urllib.parse.urlencode(data).encode() if data else None
        request = urllib.request.Request(url, data=body, headers=headers or {})

        for attempt in range(1, RETRY_ATTEMPTS + 1):
            try:
                with self._opener.open(request, timeout=60) as response:
                    return response.geturl(), response.status, response.read().decode("utf-8", "replace")
            except urllib.error.HTTPError as exc:
                if exc.code in allow_status:
                    return url, exc.code, exc.read().decode("utf-8", "replace")
                if exc.code < 500 or attempt == RETRY_ATTEMPTS:
                    raise Unreachable(f"{url} returned HTTP {exc.code}") from exc
            except (urllib.error.URLError, ConnectionError, TimeoutError, ssl.SSLError) as exc:
                if attempt == RETRY_ATTEMPTS:
                    raise Unreachable(f"{url} unreachable: {exc}") from exc
            time.sleep(RETRY_DELAY)

        raise Unreachable(url)


def submit_bridge_form(session, page):
    """POST a SAML auto-submit bridge page, the step a browser does silently."""
    for action, inner in FORM_RE.findall(page):
        if "SAMLRequest" in inner or "SAMLResponse" in inner:
            fields = {html.unescape(n): html.unescape(v) for n, v in INPUT_RE.findall(inner)}
            return session.open(html.unescape(action), fields)
    return None


def page_message(page):
    """Pull something human-readable out of a Keycloak error page."""
    text = re.sub(r"<script.*?</script>", " ", page, flags=re.S | re.I)
    text = re.sub(r"<[^>]+>", " ", text)
    return " ".join(text.split())[:300]


def admin_token(session, control_plane, admin_user, admin_password):
    _, _, body = session.open(f"{control_plane}/api/v1/token", json_body={
        "grantType": "password", "clientID": "cli",
        "username": admin_user, "password": admin_password})
    token = json.loads(body).get("accessToken")
    if not token:
        raise Unreachable(f"the control plane did not issue a token for {admin_user}")
    return token


def find_alias(session, control_plane, token, idp_type):
    _, _, body = session.open(
        f"{control_plane}/api/v1/idps", headers={"authorization": f"Bearer {token}"})
    idps = json.loads(body)
    if not idps:
        raise CheckFailed("the control plane has no IDP configured")

    wanted = idp_type.lower()
    for idp in idps:
        if idp.get("type", "").lower() == wanted:
            return idp["alias"]
    raise CheckFailed(
        f"no {idp_type} IDP found (control plane has: "
        f"{', '.join(i.get('alias', '?') for i in idps)})")


def login(session, control_plane, alias, user, password):
    verifier = base64.urlsafe_b64encode(os.urandom(48)).decode().rstrip("=")
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    redirect_uri = f"{control_plane}/oauth-code"

    authorize = f"{control_plane}/auth/realms/runai/protocol/openid-connect/auth?" + urllib.parse.urlencode({
        "client_id": "runai", "redirect_uri": redirect_uri, "response_type": "code",
        "scope": "openid email profile", "state": "verify", "nonce": "verify",
        "code_challenge": challenge, "code_challenge_method": "S256",
        "kc_idp_hint": alias,
    })

    url, _, page = session.open(authorize)
    bridged = submit_bridge_form(session, page)
    if bridged:
        url, _, page = bridged

    if "mock-idp" not in url:
        raise CheckFailed(
            f"the broker did not hand off to the mock-idp realm (landed on {url}). "
            f"Page said: {page_message(page)}")

    match = LOGIN_FORM_RE.search(page) or FORM_RE.search(page)
    if not match:
        raise CheckFailed(f"no login form on the IDP page: {page_message(page)}")

    url, _, page = session.open(html.unescape(match.group(1)), {
        "username": user, "password": password, "credentialId": ""})

    for _ in range(4):
        bridged = submit_bridge_form(session, page)
        if not bridged:
            break
        url, _, page = bridged

    code = urllib.parse.parse_qs(urllib.parse.urlparse(url).query).get("code", [None])[0]
    if not code:
        parsed = urllib.parse.urlparse(url)
        raise CheckFailed(
            f"login did not produce an authorization code. "
            f"Page said: {page_message(page)} "
            f"(stopped at {parsed.scheme}://{parsed.netloc}{parsed.path})")

    _, _, body = session.open(
        f"{control_plane}/auth/realms/runai/protocol/openid-connect/token", {
            "grant_type": "authorization_code", "client_id": "runai", "code": code,
            "redirect_uri": redirect_uri, "code_verifier": verifier})
    token = json.loads(body).get("access_token")
    if not token:
        raise CheckFailed(f"the control plane refused to exchange the code: {body[:300]}")
    return token


def claims_of(token):
    payload = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--control-plane", required=True)
    parser.add_argument("--idp-type", required=True, choices=["OIDC", "SAML"])
    parser.add_argument("--admin-user", required=True)
    parser.add_argument("--user", required=True, help="IDP username to log in as")
    parser.add_argument("--password", required=True)
    parser.add_argument("--expect-group")
    parser.add_argument("--expect-project")
    parser.add_argument("--insecure", action="store_true",
                        help="skip TLS verification (self-signed control plane)")
    args = parser.parse_args()

    admin_password = os.environ.get("RUNAI_ADMIN_PASSWORD")
    if not admin_password:
        print("RUNAI_ADMIN_PASSWORD is not set", file=sys.stderr)
        return 2

    control_plane = args.control_plane.rstrip("/")
    session = Session(args.insecure)

    try:
        token = admin_token(session, control_plane, args.admin_user, admin_password)
        alias = find_alias(session, control_plane, token, args.idp_type)
        print(f"  IDP alias: {alias}")

        user_token = login(session, control_plane, alias, args.user, args.password)
        claims = claims_of(user_token)
        groups = claims.get("groups") or []
        print(f"  Logged in as {claims.get('email', args.user)} "
              f"(groups={groups}, uid={claims.get('uid')}, gid={claims.get('gid')})")

        if args.expect_group and args.expect_group not in groups:
            raise CheckFailed(
                f"expected group '{args.expect_group}' in the token, got {groups}. "
                "The IDP group mapper is not delivering group membership.")

        if args.expect_project:
            _, status, body = session.open(
                f"{control_plane}/api/v1/org-unit/projects",
                headers={"authorization": f"Bearer {user_token}"},
                allow_status=(401, 403))
            if status != 200:
                raise CheckFailed(
                    f"listing projects returned HTTP {status}; the access rule for "
                    f"'{args.expect_group}' is not granting access")
            names = [p["name"] for p in json.loads(body).get("projects", [])]
            if args.expect_project not in names:
                raise CheckFailed(
                    f"expected project '{args.expect_project}' to be visible, got {names}")
            print(f"  Projects visible: {names}")

    except Unreachable as exc:
        print(f"  Could not reach the control plane: {exc}", file=sys.stderr)
        return 2
    except CheckFailed as exc:
        print(f"  {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
