#!/usr/bin/env python3
"""Hash only the explicitly packaged public probe inputs, never runtime config."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def write_manifest(directory: Path, source_sha: str) -> None:
    if re.fullmatch(r"[0-9a-f]{40}", source_sha) is None:
        raise ValueError("source SHA must be a full Git commit")
    names = ["stagehand_model_probe.exe", "llm-generate-params.json", "README.md",
             "native-dependencies.txt", "offline-validator-controls.txt"]
    files = {name: hashlib.sha256((directory / name).read_bytes()).hexdigest()
             for name in names}
    manifest = {"schema_version": 1, "source_commit": source_sha,
                "platform": "macos-arm64", "provider_execution": "not_run_in_ci",
                "offline_validator_controls_file": "offline-validator-controls.txt", "sha256": files}
    path = directory / "manifest.json"
    path.write_text(json.dumps(manifest, indent=2) + "\n")
    files[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    (directory / "SHA256SUMS").write_text(
        "".join(f"{digest}  {name}\n" for name, digest in files.items()))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    args = parser.parse_args()
    write_manifest(args.directory, args.source_sha)
