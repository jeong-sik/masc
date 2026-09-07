#!/usr/bin/env python3
"""Check the running installed binary and its actual public dashboard bytes."""
import argparse
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", type=Path, required=True)
parser.add_argument("--base-url", required=True)
args = parser.parse_args()
binary = args.binary.resolve(strict=True)
receipt = json.loads((binary.parent / "release.json").read_text())
files = {entry["path"]: entry for entry in receipt["files"]}


def get(route):
    with urllib.request.urlopen(args.base_url + route, timeout=10) as response:
        return response.read()


health = json.loads(get("/health?full=1"))
if health["build"]["binary_commit"] != receipt["source_commit"]:
    raise SystemExit("running binary commit differs from installed receipt")
if Path(health["build"]["executable_path"]).resolve() != binary:
    raise SystemExit("smoke is not running the installed binary")
if hashlib.sha256(binary.read_bytes()).hexdigest() != receipt["binary_sha256"]:
    raise SystemExit("installed binary digest differs")
index = get("/dashboard")
if hashlib.sha256(index).hexdigest() != files["index.html"]["sha256"]:
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
print(f"install-smoke: installed commit/index and {len(references.paths)} referenced assets match")
