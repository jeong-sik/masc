"""The reviewed release behavior selection shared by local runs and RC receipts."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import TypedDict


class Profile(TypedDict):
    profile: str
    suites: list[str]
    manifest_sha256: str


MANIFEST = Path(__file__).resolve().parents[2] / "config/release-behavior.json"


def load_profile(path: Path = MANIFEST) -> Profile:
    raw = path.read_bytes()
    value = json.loads(raw)
    if not isinstance(value, dict) or set(value) != {"profile", "suites"}:
        raise ValueError("Release behavior requires a profile and explicit suites")
    if value["profile"] != "release-essential-v1":
        raise ValueError("Unknown release behavior profile")
    suites = value["suites"]
    if not isinstance(suites, list) or not suites or any(
        not isinstance(suite, str) or not suite or "," in suite
        or any(char.isspace() for char in suite) for suite in suites
    ):
        raise ValueError("Release behavior suites must be nonempty explicit names")
    if len(set(suites)) != len(suites):
        raise ValueError("Release behavior suites must be unique")
    return {"profile": value["profile"], "suites": suites,
            "manifest_sha256": hashlib.sha256(raw).hexdigest()}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suites", action="store_true")
    args = parser.parse_args()
    profile = load_profile()
    print(",".join(profile["suites"]) if args.suites else json.dumps(profile))
