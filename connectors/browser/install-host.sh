#!/usr/bin/env bash
# Install a built OCaml native host into the runtime, independently of its checkout.
set -euo pipefail

exec python3 - "$@" <<'PY'
import argparse
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import sys
import tempfile

parser = argparse.ArgumentParser(description="Install the Firefox OCaml browser lane host")
parser.add_argument("--base-path", default=os.environ.get("MASC_BASE_PATH"))
parser.add_argument("--binary", default=shutil.which("masc-browser-host"))
parser.add_argument("--server", default=os.environ.get("MASC_HTTP_BASE_URL"))
parser.add_argument("--token-file")
parser.add_argument("--manifest-dir", help="Override Firefox's native messaging manifest directory")
args = parser.parse_args()
if not args.base_path:
    parser.error("--base-path or MASC_BASE_PATH is required")
if not args.binary:
    parser.error("--binary must name a built masc-browser-host executable, or install it on PATH")
source = Path(args.binary).expanduser().resolve()
if not source.is_file() or not os.access(source, os.X_OK):
    parser.error("--binary must be an executable file")
base = Path(args.base_path).expanduser().resolve()
lane = base / ".masc" / "browser-lane"
host_dir = lane / "host"
if args.manifest_dir:
    manifest_dir = Path(args.manifest_dir).expanduser().resolve()
elif sys.platform == "darwin":
    manifest_dir = Path.home() / "Library/Application Support/Mozilla/NativeMessagingHosts"
elif sys.platform.startswith("linux"):
    manifest_dir = Path.home() / ".mozilla/native-messaging-hosts"
else:
    parser.error("this installer supports macOS and Linux")
token_file = Path(args.token_file).expanduser() if args.token_file else lane / "token"
if not token_file.is_absolute():
    token_file = base / token_file
canonical_token = lane / "token"
if args.token_file and (not token_file.is_file() or token_file.stat().st_size == 0):
    parser.error("--token-file must name an existing provisioned lane token")
if canonical_token.exists() and args.token_file:
    if canonical_token.read_bytes().strip() != token_file.read_bytes().strip():
        parser.error("--token-file does not match the server's canonical lane token")
canonical_token.parent.mkdir(parents=True, exist_ok=True)
if not canonical_token.exists():
    try:
        fd = os.open(canonical_token, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        pass
    else:
        with os.fdopen(fd, "w") as stream:
            value = token_file.read_text().strip() if args.token_file else secrets.token_hex(24)
            stream.write(value + "\n")
if not token_file.is_file() or token_file.stat().st_size == 0:
    parser.error("token file must be a nonempty regular file")
os.chmod(token_file, 0o600)
os.chmod(canonical_token, 0o600)
host_dir.mkdir(parents=True, exist_ok=True)
manifest_dir.mkdir(parents=True, exist_ok=True)

def atomic_file(path, data, mode):
    fd, temporary = tempfile.mkstemp(prefix=".install-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

binary = host_dir / "masc-browser-host"
atomic_file(binary, source.read_bytes(), 0o755)
launcher = host_dir / "launch"
command = [str(binary), "--base-path", str(base), "--token-file", str(token_file)]
if args.server:
    command.extend(["--server", args.server])
# Firefox supplies its manifest path and extension id. Forward these after
# the explicit configuration; no token value is written into this launcher.
atomic_file(launcher, ("#!/bin/sh\nexec " + shlex.join(command) + ' "$@"\n').encode(), 0o755)
manifest = manifest_dir / "masc_browser_host.json"
atomic_file(manifest, (json.dumps({
    "name": "masc_browser_host",
    "description": "MASC OCaml Firefox browser lane host",
    "path": str(launcher),
    "type": "stdio",
    "allowed_extensions": ["browser-lane@masc.local"],
}, indent=2) + "\n").encode(), 0o644)
print(f"installed native host: {binary}")
print(f"registered manifest: {manifest}")
print("Load connectors/browser/extension/manifest.json in Firefox about:debugging.")
PY
