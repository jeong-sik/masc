#!/usr/bin/env python3
"""One-time offline preparation. Never writes the source or live pin tree."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import uuid

NAMES = ("memory-recall-current.json", "librarian-recall-current.json")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def artifact(value):
    if not isinstance(value, dict) or set(value) != {"_blob"}:
        raise ValueError("expected exact normalized _blob wrapper")
    row = value["_blob"]
    if not isinstance(row, dict) or set(row) != {"sha256", "bytes", "mime", "preview"}:
        raise ValueError("invalid normalized artifact fields")
    digest = row["sha256"]
    if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        raise ValueError("invalid lowercase SHA-256")
    if type(row["bytes"]) is not int or not 0 <= row["bytes"] <= (1 << 62) - 1:
        raise ValueError("invalid artifact byte count")
    if not isinstance(row["preview"], str) or not isinstance(row["mime"], str) or not row["mime"].strip() or any(c in row["mime"] for c in " \t\n\r"):
        raise ValueError("invalid artifact strings")
    return value


def publication(value):
    if value is None:
        return None
    if isinstance(value, dict) and set(value) == {"generation", "artifact"}:
        generation = uuid.UUID(value["generation"])
        if generation.version != 7 or str(generation) != value["generation"]:
            raise ValueError("invalid publication generation")
        artifact(value["artifact"])
        return value
    return {"generation": str(uuid.uuid7()), "artifact": artifact(value)}


def prepare(source, output):
    source = Path(source)
    output = Path(output)
    if not hasattr(uuid, "uuid7"):
        raise ValueError("Python 3.14 or newer is required")
    if source.is_symlink() or not source.is_dir() or output.exists():
        raise ValueError("source must be a snapshot directory; output must not exist")
    if source.resolve() == output.resolve() or source.resolve() in output.resolve().parents:
        raise ValueError("output must be outside the source snapshot")
    staged = []
    for keeper in sorted(source.iterdir()):
        if keeper.is_symlink():
            raise ValueError("symlinked keeper directory")
        if not keeper.is_dir():
            continue
        for name in NAMES:
            path = keeper / name
            if not path.exists() and not path.is_symlink():
                continue
            mode = path.lstat()
            if not stat.S_ISREG(mode.st_mode) or mode.st_uid != os.getuid() or mode.st_nlink != 1:
                raise ValueError(f"pin is not an owned regular single-link file: {path}")
            raw = path.read_bytes()
            value = json.loads(raw, object_pairs_hook=unique_object)
            next_value = publication(value)
            encoded = (json.dumps(next_value, ensure_ascii=False) + "\n").encode()
            staged.append((path.relative_to(source), raw, encoded))
    output.mkdir(mode=0o700)
    rows = []
    for relative, raw, encoded in staged:
        for group, content in (("original", raw), ("replacement", encoded)):
            target = output / group / relative
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with target.open("xb") as stream:
                os.chmod(target, 0o600)
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
        rows.append({"path": str(relative), "before_sha256": hashlib.sha256(raw).hexdigest(),
                     "after_sha256": hashlib.sha256(encoded).hexdigest()})
    (output / "manifest.json").write_text(json.dumps(rows, indent=2) + "\n")
    return rows


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot")
    parser.add_argument("output")
    args = parser.parse_args()
    print(json.dumps(prepare(args.snapshot, args.output), indent=2))
