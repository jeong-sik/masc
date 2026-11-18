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
- Keeper names come from the layout the code declares for `keepers/`
  (lib/core/common.ml keeper_runtime_store_dirname): every directory there
  except the shared ones, the stems of the files there
  (`<keeper>.json`, `<keeper>.decisions.jsonl`), the `<keeper>.json` files in
  `tool_usage/`, and the `_<keeper>` directories in `.shutdown-operations/`
  and `.configuration-removals/`
- below the top level, a segment that is such a name is `<keeper>`, a
  `_`-prefixed one is `_<keeper>`, and a file named `<keeper>.<suffix>` keeps
  only its suffix: `keepers/<keeper>.decisions.jsonl`. The shared directories
  keep their names. Top-level store names stay
- uuids, long hex, dates, day numbers and long digit runs get typed placeholders

Outputs, both sorted by total bytes:
- --out: one row per family
- --stores-out: one row per store, the top-level name, or
  `keepers/<keeper>/<name>` under keepers/
No output names a file: a path would carry Keeper names and trace ids. Before
writing, every row is checked again; a row that still names a Keeper stops
the run with exit 1 and nothing is written.
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
KEEPERS_DIR = "keepers"
TOOL_USAGE_DIR = "tool_usage"
TOOL_USAGE_SUFFIX = ".json"
OWNER_PREFIXED_DIRS = frozenset({".shutdown-operations", ".configuration-removals"})
OWNER_DIR_PREFIX = "_"
SHARED_KEEPER_DIRS = OWNER_PREFIXED_DIRS | {TOOL_USAGE_DIR}
KEEPER = "<keeper>"

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


@dataclass(frozen=True, slots=True)
class FamilyStats:
    files: int
    total_bytes: int
    max_bytes: int
    changed_files: int
    changed_bytes: int
    newest_mtime: float


EMPTY_STATS = FamilyStats(0, 0, 0, 0, 0, 0.0)


def normalize_segment(segment: str) -> str:
    out = segment
    for pattern, placeholder in SEGMENT_RULES:
        out = pattern.sub(placeholder, out)
    return out


def masked_name(name: str, keeper_names: frozenset[str]) -> str | None:
    """The masked form of a segment that names a Keeper, or None."""
    if name in keeper_names:
        return KEEPER
    owner = name.removeprefix(OWNER_DIR_PREFIX)
    if owner != name and owner in keeper_names:
        return OWNER_DIR_PREFIX + KEEPER
    stem, dot, rest = name.partition(".")
    if dot and stem in keeper_names:
        return KEEPER + dot + normalize_segment(rest)
    return None


def dir_segment(name: str, *, family: str, wide: bool, keeper_names: frozenset[str]) -> str:
    if family == KEEPERS_DIR and name in SHARED_KEEPER_DIRS:
        return name
    if family:
        masked = masked_name(name, keeper_names)
        if masked is not None:
            return masked
    if wide:
        return "<*>"
    return normalize_segment(name)


def file_segment(name: str, *, family: str, keeper_names: frozenset[str]) -> str:
    if family:
        masked = masked_name(name, keeper_names)
        if masked is not None:
            return masked
    return normalize_segment(name)


def keeper_names_under(keepers_dir: Path) -> frozenset[str]:
    names: set[str] = set()
    for entry in os.scandir(keepers_dir):
        if entry.name == TOOL_USAGE_DIR:
            names.update(
                child.name.removesuffix(TOOL_USAGE_SUFFIX)
                for child in os.scandir(entry.path)
                if child.name.endswith(TOOL_USAGE_SUFFIX)
            )
        elif entry.name in OWNER_PREFIXED_DIRS:
            names.update(
                child.name.removeprefix(OWNER_DIR_PREFIX)
                for child in os.scandir(entry.path)
                if child.name.startswith(OWNER_DIR_PREFIX)
            )
        elif entry.is_dir(follow_symlinks=False):
            names.add(entry.name)
        else:
            names.add(entry.name.partition(".")[0])
    names.discard("")
    return frozenset(names)


def rows_naming_a_keeper(keys: Iterator[str], keeper_names: frozenset[str]) -> int:
    return sum(
        1
        for key in keys
        if any(masked_name(segment, keeper_names) is not None for segment in key.split("/")[1:])
    )


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
            segment = dir_segment(entry.name, family=family, wide=wide, keeper_names=keeper_names)
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
                store=store or normalize_segment(entry.name),
                rel_dir_family=family,
                name=file_segment(entry.name, family=family, keeper_names=keeper_names),
                size=st.st_size,
                mtime=st.st_mtime,
            )


def add(stats: FamilyStats, meta: FileMeta, changed_since: float) -> FamilyStats:
    changed = meta.mtime >= changed_since
    bigger = meta.size > stats.max_bytes
    return dataclasses.replace(
        stats,
        files=stats.files + 1,
        total_bytes=stats.total_bytes + meta.size,
        max_bytes=meta.size if bigger else stats.max_bytes,
        changed_files=stats.changed_files + (1 if changed else 0),
        changed_bytes=stats.changed_bytes + (meta.size if changed else 0),
        newest_mtime=max(stats.newest_mtime, meta.mtime),
    )


def family_key(meta: FileMeta) -> str:
    name = meta.name
    parts = meta.rel_dir_family.split("/") if meta.rel_dir_family else []
    if len(parts) >= MAX_FAMILY_SEGMENTS:
        parts = [*parts[: MAX_FAMILY_SEGMENTS - 1], "..."]
    return "/".join([*parts, name])


def write_table(path: Path, rows: dict[str, FamilyStats], key_name: str) -> None:
    ordered = sorted(rows.items(), key=lambda kv: kv[1].total_bytes, reverse=True)
    with path.open("w", encoding="utf-8") as handle:
        handle.write(
            f"{key_name}\tfiles\ttotal_mb\tmax_mb\tchanged24h_files\tchanged24h_mb\tnewest_utc\n"
        )
        for key, s in ordered:
            newest = datetime.fromtimestamp(s.newest_mtime, tz=timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
            handle.write(
                f"{key}\t{s.files}\t{s.total_bytes / BYTES_PER_MB:.2f}\t{s.max_bytes / BYTES_PER_MB:.2f}"
                f"\t{s.changed_files}\t{s.changed_bytes / BYTES_PER_MB:.2f}\t{newest}\n"
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
    keepers_dir = root / KEEPERS_DIR
    keeper_names = keeper_names_under(keepers_dir) if keepers_dir.is_dir() else frozenset[str]()
    keeper_dirs = sum(
        1
        for e in os.scandir(keepers_dir)
        if e.is_dir(follow_symlinks=False) and e.name not in SHARED_KEEPER_DIRS
    ) if keepers_dir.is_dir() else 0
    changed_since = now.timestamp() - SECONDS_PER_DAY
    families: dict[str, FamilyStats] = {}
    stores: dict[str, FamilyStats] = {}
    for meta in walk(root, keeper_names):
        key = family_key(meta)
        families[key] = add(families.get(key, EMPTY_STATS), meta, changed_since)
        stores[meta.store] = add(stores.get(meta.store, EMPTY_STATS), meta, changed_since)
    named = rows_naming_a_keeper(iter([*families, *stores]), keeper_names)
    if named:
        print(f"{named} rows still name a Keeper; nothing written", file=sys.stderr)
        return 1
    write_table(out, families, "family")
    write_table(stores_out, stores, "store")
    total_files = sum(s.files for s in families.values())
    total_bytes = sum(s.total_bytes for s in families.values())
    print(
        f"root={root} families={len(families)} files={total_files} "
        f"total_mb={total_bytes / BYTES_PER_MB:.1f} keeper_dirs={keeper_dirs} keeper_names={len(keeper_names)} "
        f"measured_at={now.isoformat(timespec='seconds')}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:], datetime.now(tz=timezone.utc)))
