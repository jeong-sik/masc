#!/usr/bin/env python3
"""Mint GitHub App installation tokens into keeper secret projections.

Out-of-core companion to the retired RFC-0236 §10: masc core stays free of
GitHub-specific credential branches (#24332); this script does the minting
and hands the result to the existing ambient-env contract
(``<base>/.masc/secrets/<keeper>/env/GH_TOKEN``), which
``Keeper_secret_projection`` already carries into both sandbox profiles.

Installation tokens expire after one hour, so run this on a timer (default
loop interval 50 minutes) or one-shot with ``--once``.

Credentials come from the operator environment, never from the repo:
  MASC_GITHUB_APP_ID            numeric App ID
  MASC_GITHUB_APP_PRIVATE_KEY   path to the App's PEM private key
  MASC_GITHUB_APP_INSTALLATION  installation id (integer)

Signing uses the openssl CLI (RS256), so there is no Python dependency.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.error
import urllib.request

GITHUB_API = "https://api.github.com"
TOKEN_ENV_NAMES = ("GH_TOKEN", "GITHUB_TOKEN")
DEFAULT_INTERVAL_SECONDS = 50 * 60  # installation tokens live 60 minutes


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def mint_app_jwt(app_id: str, private_key_path: pathlib.Path) -> str:
    now = int(time.time())
    header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    # iat 60s in the past guards against clock skew, per GitHub's guidance.
    payload = b64url(
        json.dumps({"iat": now - 60, "exp": now + 540, "iss": app_id}).encode()
    )
    signing_input = f"{header}.{payload}".encode()
    signature = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(private_key_path)],
        input=signing_input,
        capture_output=True,
        check=True,
    ).stdout
    return f"{header}.{payload}.{b64url(signature)}"


def mint_installation_token(jwt: str, installation_id: str) -> dict:
    request = urllib.request.Request(
        f"{GITHUB_API}/app/installations/{installation_id}/access_tokens",
        method="POST",
        headers={
            "Authorization": f"Bearer {jwt}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        data=b"{}",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def write_keeper_secret(base_path: pathlib.Path, keeper: str, token: str) -> list[str]:
    env_dir = base_path / ".masc" / "secrets" / keeper / "env"
    env_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for name in TOKEN_ENV_NAMES:
        target = env_dir / name
        target.write_text(token + "\n", encoding="utf-8")
        target.chmod(0o600)
        written.append(str(target))
    return written


def sync_once(base_path: pathlib.Path, keepers: list[str]) -> str:
    app_id = os.environ.get("MASC_GITHUB_APP_ID", "").strip()
    key_path = os.environ.get("MASC_GITHUB_APP_PRIVATE_KEY", "").strip()
    installation = os.environ.get("MASC_GITHUB_APP_INSTALLATION", "").strip()
    missing = [
        name
        for name, value in (
            ("MASC_GITHUB_APP_ID", app_id),
            ("MASC_GITHUB_APP_PRIVATE_KEY", key_path),
            ("MASC_GITHUB_APP_INSTALLATION", installation),
        )
        if not value
    ]
    if missing:
        raise SystemExit(f"missing operator credentials in env: {', '.join(missing)}")
    pem = pathlib.Path(key_path).expanduser()
    if not pem.is_file():
        raise SystemExit(f"private key not found: {pem}")

    jwt = mint_app_jwt(app_id, pem)
    grant = mint_installation_token(jwt, installation)
    token = grant["token"]
    expires = grant.get("expires_at", "?")
    for keeper in keepers:
        paths = write_keeper_secret(base_path, keeper, token)
        print(f"[sync] {keeper}: wrote {len(paths)} env secrets, expires {expires}")
    return expires


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-path", required=True, type=pathlib.Path)
    parser.add_argument(
        "--keeper",
        action="append",
        required=True,
        help="keeper name to provision (repeatable)",
    )
    parser.add_argument("--once", action="store_true", help="single sync, no loop")
    parser.add_argument(
        "--interval-seconds", type=int, default=DEFAULT_INTERVAL_SECONDS
    )
    args = parser.parse_args()

    while True:
        try:
            sync_once(args.base_path, args.keeper)
        except (urllib.error.HTTPError, urllib.error.URLError) as error:
            print(f"[sync] GitHub API error: {error}", file=sys.stderr)
            if args.once:
                return 1
        if args.once:
            return 0
        time.sleep(args.interval_seconds)


if __name__ == "__main__":
    raise SystemExit(main())
