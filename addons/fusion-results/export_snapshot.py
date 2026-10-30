"""Wrap an already-acquired Fusion detail response for snapshot_file input."""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path

from server import parse_detail


def snapshot(detail: dict, source_id: str) -> dict:
    run, _, _, _ = parse_detail(detail)
    if not source_id.strip():
        raise ValueError("source_id must be nonempty")
    timestamp = datetime.datetime.fromisoformat(detail["generated_at"].replace("Z", "+00:00"))
    if timestamp.tzinfo is None:
        raise ValueError("generated_at requires a timezone")
    canonical = json.dumps(detail, sort_keys=True, separators=(",", ":"), allow_nan=False)
    digest = hashlib.sha256(canonical.encode()).hexdigest()
    return {"source_id": source_id, "incarnation": run["run_id"], "cursor": digest,
            "complete": True, "detail": "One captured Fusion detail; not live or a complete run history",
            "observations": [{
                "id": digest, "kind": "fusion_run", "observed_at": timestamp.timestamp(),
                "actor": None, "evidence": [], "detail": detail}]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("detail", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--source-id", required=True)
    args = parser.parse_args()
    value = snapshot(json.loads(args.detail.read_text()), args.source_id)
    encoded = (json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2) + "\n").encode("utf-8")
    # Refuse replacing an existing capture; publish by explicitly choosing a new path.
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(encoded)
