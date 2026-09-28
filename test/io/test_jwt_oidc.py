"IO tests for verifying JWTs with the keys an issuer publishes through OpenID Connect discovery."

import http.server
import json
import signal
import threading
import time

import jwt
import pytest

from config import BASEDIR
from postgrest import run, sleep_until_postgrest_config_reload
from util import authheader

KEYS = json.loads((BASEDIR / "fixtures" / "oidc_keys.json").read_text())


class IdentityProvider:
    "Serves the discovery document and the key set of an issuer."

    def __init__(self, kids):
        self.kids = kids
        self.status = 200
        self.requests = []
        self.lock = threading.Lock()

        provider = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                with provider.lock:
                    provider.requests.append(self.path)
                if self.path == "/.well-known/openid-configuration":
                    body = {
                        "issuer": provider.issuer,
                        "jwks_uri": provider.issuer + "/jwks",
                    }
                else:
                    body = {"keys": [KEYS[kid]["public"] for kid in provider.kids]}
                payload = json.dumps(body).encode()
                self.send_response(provider.status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *_args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def issuer(self):
        return f"http://127.0.0.1:{self.server.server_address[1]}"

    def fetches(self):
        with self.lock:
            return len(self.requests)


@pytest.fixture
def identity_provider():
    provider = IdentityProvider(["k1"])
    provider.thread.start()
    yield provider
    provider.server.shutdown()


@pytest.fixture
def oidcenv(defaultenv, identity_provider):
    return {
        **defaultenv,
        "PGRST_JWT_ISS": identity_provider.issuer,
        "PGRST_JWT_OIDC_DISCOVERY": "true",
    }


def token(kid, issuer):
    "A JWT signed with a test key."
    key = jwt.algorithms.RSAAlgorithm.from_jwk(json.dumps(KEYS[kid]["private"]))
    claims = {"role": "postgrest_test_author", "iss": issuer}
    return authheader(jwt.encode(claims, key, algorithm="RS256", headers={"kid": kid}))


def logged(postgrest, text, max_seconds=2):
    "Whether a line with the text is logged within max_seconds, the startup lines included."
    deadline = time.monotonic() + max_seconds
    while time.monotonic() < deadline:
        if any(text in line for line in postgrest.read_stdout(nlines=10)):
            return True
    return False


def test_jwt_oidc_discovery(oidcenv, identity_provider):
    "JWTs signed with a key of the issuer are accepted, and the fetched keys are logged"

    with run(env=oidcenv, no_startup_stdout=False) as postgrest:
        response = postgrest.session.get(
            "/authors_only", headers=token("k1", identity_provider.issuer)
        )
        assert response.status_code == 200

        response = postgrest.session.get(
            "/authors_only", headers=token("k2", identity_provider.issuer)
        )
        assert response.status_code == 401

        assert logged(
            postgrest, f"Fetched 1 JWT keys of issuer {identity_provider.issuer}"
        )


def test_jwt_oidc_discovery_unavailable(oidcenv, identity_provider):
    "JWTs are answered with 503 while the keys of the issuer can't be fetched"

    identity_provider.status = 500

    with run(env=oidcenv, no_startup_stdout=False) as postgrest:
        response = postgrest.session.get(
            "/authors_only", headers=token("k1", identity_provider.issuer)
        )
        assert response.status_code == 503
        assert response.json()["code"] == "PGRST304"

        assert logged(
            postgrest,
            f"Failed fetching the JWT keys of issuer {identity_provider.issuer}",
        )


def test_jwt_oidc_discovery_keeps_keys_on_config_reload(oidcenv, identity_provider):
    "Reloading the config with the same issuer keeps the fetched keys"

    with run(env=oidcenv) as postgrest:
        response = postgrest.session.get(
            "/authors_only", headers=token("k1", identity_provider.issuer)
        )
        assert response.status_code == 200
        fetches = identity_provider.fetches()

        postgrest.process.send_signal(signal.SIGUSR2)
        sleep_until_postgrest_config_reload()

        response = postgrest.session.get(
            "/authors_only", headers=token("k1", identity_provider.issuer)
        )
        assert response.status_code == 200
        assert identity_provider.fetches() == fetches
