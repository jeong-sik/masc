#!/usr/bin/env python3
"""Check the running installed binary and its actual public dashboard bytes."""
import argparse
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import urllib.request
import urllib.error
import os
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", type=Path, required=True)
parser.add_argument("--base-url", required=True)
parser.add_argument("--expected-source", help="Require the installed and running source commit")
parser.add_argument("--exercise-corruption", action="store_true",
                    help="Corrupt and restore files; use only on an isolated install-smoke fixture")
args = parser.parse_args()
binary = args.binary.resolve(strict=True)
receipt = json.loads((binary.parent / "release.json").read_text())
if args.expected_source is not None and receipt["source_commit"] != args.expected_source:
    raise SystemExit("installed receipt differs from expected source")
files = {entry["path"]: entry for entry in receipt["files"]}


def get(route):
    with urllib.request.urlopen(args.base_url + route, timeout=10) as response:
        return response.read()


def get_dashboard():
    with urllib.request.urlopen(args.base_url + "/dashboard", timeout=10) as response:
        return response.read(), response.status, dict(response.headers.items())


readiness = json.loads(get("/health/ready"))
if not isinstance(readiness, dict) or readiness.get("ready") is not True:
    raise SystemExit("installed server is not ready for dashboard verification")
health = json.loads(get("/health?full=1"))
if health["build"]["binary_commit"] != receipt["source_commit"]:
    raise SystemExit("running binary commit differs from installed receipt")
if Path(health["build"]["executable_path"]).resolve() != binary:
    raise SystemExit("smoke is not running the installed binary")
if hashlib.sha256(binary.read_bytes()).hexdigest() != receipt["binary_sha256"]:
    raise SystemExit("installed binary digest differs")
installed = health["dashboard_surface"]["installed_release"]
if installed["kind"] != "installed_release" or installed["status"] != "verified":
    raise SystemExit("runtime did not select a verified installed release")
if Path(installed["release_root"]) != binary.parent:
    raise SystemExit("runtime selected another installed release root")
if installed["receipt_sha256"] != hashlib.sha256((binary.parent / "release.json").read_bytes()).hexdigest():
    raise SystemExit("runtime receipt differs from installed receipt")
index, dashboard_status, dashboard_headers = get_dashboard()
if hashlib.sha256(index).hexdigest() != files["index.html"]["sha256"]:
    print("installed dashboard mismatch diagnostics:", file=sys.stderr)
    print(f"HTTP status: {dashboard_status}", file=sys.stderr)
    print(f"HTTP headers: {json.dumps(dashboard_headers, sort_keys=True)}", file=sys.stderr)
    print(f"served body: length={len(index)} sha256={hashlib.sha256(index).hexdigest()}", file=sys.stderr)
    print(f"expected body: length={files['index.html']['size']} sha256={files['index.html']['sha256']}", file=sys.stderr)
    print(f"served body first 200 bytes: {index[:200]!r}", file=sys.stderr)
    raise SystemExit("served dashboard index differs from installed bundle")


class References(HTMLParser):
    def __init__(self):
        super().__init__()
        self.paths = set()

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        value = attrs.get("src") if tag == "script" else attrs.get("href") if tag == "link" else None
        if value and value.startswith("/dashboard/assets/"):
            self.paths.add(value.removeprefix("/dashboard/"))


references = References()
references.feed(index.decode())
if not references.paths:
    raise SystemExit("dashboard references no packaged assets")
for relative in references.paths:
    if relative not in files or hashlib.sha256(get("/dashboard/" + relative)).hexdigest() != files[relative]["sha256"]:
        raise SystemExit("served dashboard resource differs from installed bundle")
if health["dashboard_surface"]["status"] != "ok":
    raise SystemExit("installed dashboard health is not ok; do not fabricate freshness")
if not args.exercise_corruption:
    print(json.dumps({
        "scope": "Read-only installed binary, readiness and served dashboard binding; no Item behavior check",
        "source_commit": receipt["source_commit"],
        "binary_sha256": receipt["binary_sha256"],
        "receipt_sha256": installed["receipt_sha256"],
        "dashboard_index_sha256": hashlib.sha256(index).hexdigest(),
        "referenced_assets_checked": len(references.paths),
        "passed": True,
    }, sort_keys=True))
    raise SystemExit(0)
# Deliberately corrupt only the isolated installed fixture. Every response must
# fail closed even if a same-named unbound fallback is available in cwd.
fixture = Path.cwd() / "assets/dashboard"
fixture.mkdir(parents=True)
(fixture / "index.html").write_bytes(b"wrong cwd fallback")
index_path = binary.parent / "assets/dashboard/index.html"
original_index = index_path.read_bytes()
original_stat = index_path.stat()
receipt_path = binary.parent / "release.json"
original_receipt = receipt_path.read_bytes()


def unavailable():
    try:
        get("/dashboard")
    except urllib.error.HTTPError as error:
        if error.code != 503:
            raise SystemExit("invalid installed binding did not return 503")
    else:
        raise SystemExit("invalid installed binding served dashboard bytes")
    surface = json.loads(get("/health?full=1"))["dashboard_surface"]
    if surface["status"] != "unavailable" or surface["installed_release"]["status"] != "unavailable":
        raise SystemExit("invalid installed binding lacks unavailable evidence")


try:
    index_path.write_bytes(b"corrupt installed index")
    unavailable()
finally:
    index_path.write_bytes(original_index)
    os.utime(index_path, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
try:
    receipt_path.unlink()
    unavailable()
finally:
    receipt_path.write_bytes(original_receipt)
if get("/dashboard") != original_index:
    raise SystemExit("restored exact installed artifact did not recover")
print(f"install-smoke: actual installed commit/index and {len(references.paths)} assets match; corruption and missing receipt fail closed")
