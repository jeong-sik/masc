#!/usr/bin/env python3
"""Run actual Standing/Quota/Backpressure source under explicit identity ports.

Does not exercise SDK classification, account-home resolution, provider hint
validation, product path-rest calculation, runtime registry or adapter dispatch.
This is a bounded algorithm check, not a native integration test or full build.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import tempfile

MODULES = (
    "runtime_candidate_backpressure_state",
    "runtime_candidate_backpressure",
    "runtime_quota_window",
    "runtime_candidate_standing",
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--tempdir", type=Path)
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    assets = Path(__file__).resolve().parent
    work = Path(tempfile.mkdtemp(prefix="masc-standing-check-", dir=args.tempdir))
    sources: dict[str, str] = {}
    combined = "module Artifact_boundary = struct\n" + (assets / "boundary_ports.ml").read_text()
    for name in MODULES:
        pair = []
        for extension in (".mli", ".ml"):
            relative = "lib/runtime/" + name + extension
            data = (root / relative).read_bytes()
            sources[relative] = digest(data)
            pair.append(data.decode())
        combined += "\nmodule " + name[0].upper() + name[1:] + " : sig\n"
        combined += pair[0] + "\nend = struct\n" + pair[1] + "\nend\n"
    combined += "end\n" + (assets / "cases.ml").read_text()
    (work / "check.ml").write_text(combined)
    commands = [
        ["opam", "exec", "--", "ocamlopt", "-I", "+unix", "-w", "+4+32+69",
         "-warn-error", "+a", "unix.cmxa", "check.ml", "-o", "check.exe"],
        [str(work / "check.exe")],
    ]
    records = []
    for label, command in zip(("compile", "run"), commands):
        result = subprocess.run(command, cwd=work, text=True, capture_output=True)
        records.append({"argv": command, "exit": result.returncode})
        (work / (label + ".log")).write_text(shlex.join(command) + "\n" + result.stdout
                                             + result.stderr + "\nexit=" + str(result.returncode) + "\n")
        print(label + ": exit=" + str(result.returncode), flush=True)
        print(result.stdout, end="", flush=True)
        result.check_returncode()
    unchanged = {path: digest((root / path).read_bytes()) == sha for path, sha in sources.items()}
    manifest = {
        "scope": __doc__, "actual_source_sha256": sources,
        "source_unchanged_during_execution": unchanged,
        "harness_sha256": {name: digest((assets / name).read_bytes())
                           for name in ("boundary_ports.ml", "cases.ml", "reproduce.py")},
        "commands": records, "cases_passed": 9,
    }
    (work / "source-identity.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("artifacts: " + str(work), flush=True)
    if not all(unchanged.values()):
        raise RuntimeError("source changed during execution")


if __name__ == "__main__":
    main()
