#!/usr/bin/env python3
"""Parse the committed blobs of the PR's changed OCaml files.

Each file is read from a commit with `git show <rev>:<path>`, hashed, written
under a temporary directory at its repository path, and parsed there with
`ocamlc -stop-after parsing`. Nothing is typechecked. The result is written to
syntax.json next to this script.

Usage: python3 check-syntax.py [rev]   (rev defaults to HEAD)
"""
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

OUT = Path(__file__).resolve().parent
ROOT = Path(subprocess.check_output(
    ["git", "-C", str(OUT), "rev-parse", "--show-toplevel"], text=True).strip())
SOURCES = [
    "lib/lane_addon/lane_addon_application.mli",
    "lib/lane_addon/lane_addon_application.ml",
    "lib/lane_addon/lane_addon_config.mli",
    "lib/lane_addon/lane_addon_config.ml",
    "lib/lane_addon/lane_addon_runtime.mli",
    "lib/lane_addon/lane_addon_runtime.ml",
    "lib/lane_addon/lane_addon_store.mli",
    "lib/lane_addon/lane_addon_store.ml",
    "test/test_lane_addon_application.ml",
    "test/test_lane_addon_config.ml",
    "test/test_lane_addon_reconcile.ml",
]


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


rev = sys.argv[1] if len(sys.argv) > 1 else "HEAD"
commit = git("rev-parse", "--verify", rev + "^{commit}").decode().strip()
version = subprocess.check_output(["ocamlc", "-version"], text=True).strip()
checks = []
with tempfile.TemporaryDirectory(prefix="masc-lane-application-syntax-") as work:
    for source in SOURCES:
        blob = git("show", commit + ":" + source)
        target = Path(work) / source
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(blob)
        argv = ["ocamlc", "-stop-after", "parsing", "-c",
                "-intf" if source.endswith(".mli") else "-impl", source]
        process = subprocess.run(argv, cwd=work, text=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        checks.append({"file": source,
                       "sha256": hashlib.sha256(blob).hexdigest(),
                       "argv": argv,
                       "exit_code": process.returncode,
                       "output": process.stdout})
(OUT / "syntax.json").write_text(json.dumps(
    {"compiler": version, "source_commit": commit, "checks": checks},
    indent=2) + "\n")
failed = [check["file"] for check in checks if check["exit_code"]]
if failed:
    raise SystemExit("Syntax check failed: " + ", ".join(failed))
print("OCaml %s: %d/%d committed sources parsed at %s"
      % (version, len(checks), len(SOURCES), commit))
