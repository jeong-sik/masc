#!/usr/bin/env python3
"""Describe tracked OCaml scope at one commit; never score or gate code."""

import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import subprocess


def category(path):
    parts = Path(path).parts
    if parts[0] == "test" or (parts[0] == "packages" and "test" in parts):
        return "test"
    if parts[0] in ("lib", "bin") or path.startswith("packages/agent_core/lib/"):
        return "production"
    if parts[0] in ("scripts", "tools", "ppx_tla", "benchmarks"):
        return "tooling"
    return "documentation_or_experiment"


def area(path):
    parts = Path(path).parts
    if parts[0] == "lib":
        return "lib/" + (parts[1] if len(parts) > 2 else "(root)")
    if parts[0] == "packages":
        return "/".join(parts[:4] if len(parts) > 4 else parts[:3])
    return parts[0]


def inventory(revision):
    root = Path(__file__).resolve().parents[3]

    def git(*args):
        return subprocess.check_output(["git", "-C", str(root), *args], text=True)

    baseline = git("rev-parse", "--verify", revision + "^{commit}").strip()
    entries = {}
    for row in git("ls-tree", "-r", "--full-tree", baseline).splitlines():
        meta, path = row.split("\t", 1)
        _, kind, oid = meta.split()
        if kind == "blob" and path.endswith((".ml", ".mli")):
            entries[path] = oid

    counts = defaultdict(Counter)
    groups = defaultdict(lambda: {"implementations": 0, "lines": 0, "with_interface": 0})
    manifest = hashlib.sha256()
    with subprocess.Popen(
        ["git", "-C", str(root), "cat-file", "--batch"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    ) as reader:
        for path, oid in sorted(entries.items()):
            kind = category(path)
            counts[kind][Path(path).suffix] += 1
            if kind != "production" or not path.endswith(".ml"):
                continue
            reader.stdin.write((oid + "\n").encode())
            reader.stdin.flush()
            header = reader.stdout.readline().split()
            size = int(header[2])
            data = reader.stdout.read(size)
            if len(data) != size or reader.stdout.read(1) != b"\n":
                raise RuntimeError("Incomplete Git blob response: " + path)
            manifest.update((path + "\t" + oid + "\n").encode())
            group = groups[area(path)]
            group["implementations"] += 1
            group["lines"] += len(data.splitlines())
            group["with_interface"] += path + "i" in entries
        reader.stdin.close()
        if reader.wait() != 0:
            raise RuntimeError("Git blob reader failed")

    return {
        "baseline": baseline,
        "scope": "All tracked .ml/.mli files; production: lib/, bin/, packages/agent_core/lib/.",
        "meaning": "Descriptive census only; no semantic inspection or defect follows from a count.",
        "production_manifest_sha256": manifest.hexdigest(),
        "counts": dict(counts),
        "production_areas": dict(sorted(groups.items())),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("revision", help="Commit or ref to inspect without changing the checkout")
    args = parser.parse_args()
    print(json.dumps(inventory(args.revision), ensure_ascii=False, indent=2))
