#!/usr/bin/env python3
"""Group every file under a MASC state directory into path families and size them.

Only metadata is read (lstat). No file is opened. A family is the relative
path with its variable segments replaced by placeholders, so
`keepers/alice/provider-inputs/2026-11/17.jsonl` and
`keepers/bob/provider-inputs/2026-10/03.jsonl` land in one row.

Variable segments:
- below the top level, a directory with more than WIDE_DIR_CHILDREN
  subdirectories has `<*>` children (top-level store names stay)
- a path deeper than MAX_FAMILY_SEGMENTS keeps its first segments and its file name
- a segment equal to a directory name under `keepers/` is `<keeper>`
- uuids, long hex, dates, day numbers and long digit runs get typed placeholders

Outputs, both sorted by total bytes:
- --out: one row per family
- --stores-out: one row per store, the top-level name, or
  `keepers/<keeper>/<name>` under keepers/
"""

from __future__ import annotations

import argparse
import dataclasses
import os
import re
import sys
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

WIDE_DIR_CHILDREN = 40
MAX_FAMILY_SEGMENTS = 7
SECONDS_PER_DAY = 86_400
BYTES_PER_MB = 1024 * 1024

SEGMENT_RULES: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"), "<uuid>"),
    (re.compile(r"[0-9a-f]{16,}"), "<hex>"),
    (re.compile(r"\d{4}-\d{2}-\d{2}"), "<date>"),
    (re.compile(r"\d{4}-\d{2}"), "<ym>"),
    (re.compile(r"\d{3,}"), "<n>"),
    (re.compile(r"^\d{1,2}(?=\.|$)"), "<dd>"),
)


@dataclass(frozen=True, slots=True)
class FileMeta:
    store: str
    rel_dir_family: str
    name: str
    size: int
    mtime: float
    rel_path: str


@dataclass(frozen=True, slots=True)
class FamilyStats:
    files: int
    total_bytes: int
    max_bytes: int
    max_path: str
    changed_files: int
    changed_bytes: int
    newest_mtime: float


EMPTY_STATS = FamilyStats(0, 0, 0, "", 0, 0, 0.0)


def normalize_segment(segment: str, keeper_names: frozenset[str]) -> str:
    if segment in keeper_names:
        return "<keeper>"
    out = segment
    for pattern, placeholder in SEGMENT_RULES:
        out = pattern.sub(placeholder, out)
    return out


def dir_segment(name: str, wide: bool, keeper_names: frozenset[str]) -> str:
    if name in keeper_names:
        return "<keeper>"
    if wide:
        return "<*>"
    return normalize_segment(name, keeper_names)


def store_of(family: str) -> str:
    parts = family.split("/")
    if parts[0] == "keepers" and len(parts) >= 3:
        return "/".join(parts[:3])
    return parts[0] if parts[0] != "keepers" else family


def walk(root: Path, keeper_names: frozenset[str]) -> Iterator[FileMeta]:
    stack: list[tuple[Path, str, str]] = [(root, "", "")]
    while stack:
        directory, family, store = stack.pop()
        try:
            entries = list(os.scandir(directory))
        except OSError as error:
            print(f"skip {directory}: {error}", file=sys.stderr)
            continue
        subdirs = [e for e in entries if e.is_dir(follow_symlinks=False)]
        wide = bool(family) and len(subdirs) > WIDE_DIR_CHILDREN
        for entry in subdirs:
            segment = dir_segment(entry.name, wide, keeper_names)
            child_family = f"{family}/{segment}" if family else segment
            stack.append((Path(entry.path), child_family, store_of(child_family)))
        for entry in entries:
            if not entry.is_file(follow_symlinks=False):
                continue
            try:
                st = entry.stat(follow_symlinks=False)
            except OSError:
                continue
            yield FileMeta(
                store=store or normalize_segment(entry.name, keeper_names),
                rel_dir_family=family,
                name=entry.name,
                size=st.st_size,
                mtime=st.st_mtime,
                rel_path=os.path.relpath(entry.path, root),
            )


def add(stats: FamilyStats, meta: FileMeta, changed_since: float) -> FamilyStats:
    changed = meta.mtime >= changed_since
    bigger = meta.size > stats.max_bytes
    return dataclasses.replace(
        stats,
        files=stats.files + 1,
        total_bytes=stats.total_bytes + meta.size,
        max_bytes=meta.size if bigger else stats.max_bytes,
        max_path=meta.rel_path if bigger else stats.max_path,
        changed_files=stats.changed_files + (1 if changed else 0),
        changed_bytes=stats.changed_bytes + (meta.size if changed else 0),
        newest_mtime=max(stats.newest_mtime, meta.mtime),
    )


def family_key(meta: FileMeta, keeper_names: frozenset[str]) -> str:
    name = normalize_segment(meta.name, keeper_names)
    parts = meta.rel_dir_family.split("/") if meta.rel_dir_family else []
    if len(parts) >= MAX_FAMILY_SEGMENTS:
        parts = [*parts[: MAX_FAMILY_SEGMENTS - 1], "..."]
    return "/".join([*parts, name])


def write_table(path: Path, rows: dict[str, FamilyStats], key_name: str) -> None:
    ordered = sorted(rows.items(), key=lambda kv: kv[1].total_bytes, reverse=True)
    with path.open("w", encoding="utf-8") as handle:
        handle.write(
            f"{key_name}\tfiles\ttotal_mb\tmax_mb\tchanged24h_files\tchanged24h_mb\tnewest_utc\tmax_path\n"
        )
        for key, s in ordered:
            newest = datetime.fromtimestamp(s.newest_mtime, tz=timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
            handle.write(
                f"{key}\t{s.files}\t{s.total_bytes / BYTES_PER_MB:.2f}\t{s.max_bytes / BYTES_PER_MB:.2f}"
                f"\t{s.changed_files}\t{s.changed_bytes / BYTES_PER_MB:.2f}\t{newest}\t{s.max_path}\n"
            )


def main(argv: list[str], now: datetime) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--stores-out", type=Path, required=True)
    args = parser.parse_args(argv)
    root: Path = args.root
    out: Path = args.out
    stores_out: Path = args.stores_out
    keepers_dir = root / "keepers"
    keeper_names = frozenset(
        e.name for e in os.scandir(keepers_dir) if e.is_dir(follow_symlinks=False)
    ) if keepers_dir.is_dir() else frozenset[str]()
    changed_since = now.timestamp() - SECONDS_PER_DAY
    families: dict[str, FamilyStats] = {}
    stores: dict[str, FamilyStats] = {}
    for meta in walk(root, keeper_names):
        key = family_key(meta, keeper_names)
        families[key] = add(families.get(key, EMPTY_STATS), meta, changed_since)
        stores[meta.store] = add(stores.get(meta.store, EMPTY_STATS), meta, changed_since)
    write_table(out, families, "family")
    write_table(stores_out, stores, "store")
    total_files = sum(s.files for s in families.values())
    total_bytes = sum(s.total_bytes for s in families.values())
    print(
        f"root={root} families={len(families)} files={total_files} "
        f"total_mb={total_bytes / BYTES_PER_MB:.1f} keepers_dirs={len(keeper_names)} "
        f"measured_at={now.isoformat(timespec='seconds')}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:], datetime.now(tz=timezone.utc)))
