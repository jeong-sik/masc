#!/usr/bin/env python3
# pyright: strict
"""migrate-lane-addon-bindings.py — classify (and optionally move) lane add-on
binding records written by v0.48.0 or earlier.

The v0.55.0 upgrade notes say: "Lane add-on bindings written by v0.48.0 or
earlier are no longer read." A record from before v0.49.0 carries neither
`visibility` nor `source_access`, so the container reads it as a retained
fault and holds back reconciliation work until the record is repaired or
moved away. This tool follows the container's own rules, checked on this
tree:

- A record is detached iff its top-level `phase` is exactly
  {"kind": "detached"} (lib/lane_addon/lane_addon_runtime.ml,
  record_is_detached). A detached record holds no worker and no container,
  so it can be moved away freely.
- A record that is not detached holds its worker back, and the container
  reads it only through a readable record: repairing means adding
  `visibility` and `source_access` at the TOP LEVEL of the record
  (read_authority). The container never reads those fields inside the
  `binding` object.
- The store reads only files ending in ".json" in bindings/
  (lib/lane_addon/lane_addon_store.ml, read_bindings); renaming a record to
  any other suffix takes it out of every read without deleting data.

Modes:
  (default)          Classify only. Prints counts and one line per record.
                     Changes nothing.
  --write-out DIR    Additionally handles the records that are safe to move
                     without any operator decision (run with the server
                     stopped): every detached legacy record is copied to
                     DIR/<name>.json.legacy (byte identical, verified by hash)
                     and its source file is renamed to <name>.json.migrated so
                     the container stops reading it. Nothing else is copied,
                     rewritten or moved.

A "legacy" record has neither authority field. A record with one or two
authority fields was written by a newer version; the tool only reports it
(newer-broken when the fields do not parse, newer-readable when they do).

Exit status: 0 on a completed run (classification is not a failure), 2 on a
usage or I/O error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import sys
from typing import Any, NamedTuple

BINDINGS_DIR = "bindings"
MIGRATED_SUFFIX = ".migrated"
LEGACY_SUFFIX = ".legacy"


class ClassifiedRecord(NamedTuple):
    name: str
    raw_bytes: bytes
    raw_sha256: str
    record_class: str
    fields: dict[str, Any] | None


def object_fields(value: Any) -> dict[str, Any] | None:
    """Mirror the container's `object_`: an association is a JSON object."""
    return value if isinstance(value, dict) else None


def text_field(fields: dict[str, Any], key: str) -> str | None:
    value = fields.get(key)
    return value if isinstance(value, str) else None


def is_detached(fields: dict[str, Any]) -> bool:
    """Exactly the container's record_is_detached: phase_of_json must parse
    to Detached, and that parser rejects extra keys and other kinds."""
    phase = object_fields(fields.get("phase") if "phase" in fields else None)
    return phase is not None and set(phase) == {"kind"} and phase["kind"] == "detached"


def visibility_is_valid(fields: dict[str, Any]) -> bool:
    if "visibility" not in fields:
        return False
    value = object_fields(fields["visibility"])
    if value is None:
        return False
    keys = sorted(value)
    keeper = value.get("keeper") if "keeper" in value else None
    keeper_ok = isinstance(keeper, str) and keeper.strip() != ""
    return (
        keys == ["kind"] and value["kind"] == "shared"
        or keys == ["kind"] and value["kind"] == "operator"
        or keys == sorted(["kind", "keeper"]) and value.get("kind") == "keeper" and keeper_ok
    )


def source_access_is_valid(fields: dict[str, Any]) -> bool:
    if "source_access" not in fields:
        return False
    value = object_fields(fields["source_access"])
    if value is None:
        return False
    keys = sorted(value)
    keeper = value.get("keeper") if "keeper" in value else None
    keeper_ok = isinstance(keeper, str) and keeper.strip() != ""
    return (
        keys == ["kind"] and value.get("kind") == "operator_configuration"
        or keys == sorted(["kind", "keeper"]) and value.get("kind") == "keeper" and keeper_ok
        or keys == ["kind"] and value.get("kind") == "unauthenticated"
    )


def owner_of(fields: dict[str, Any]) -> str:
    """Classify `configuration` the way the container attributes a worker.
    Absent or null names no declaration; a configuration that cannot be
    parsed could name any; a parsed one names its installation id."""
    if "configuration" not in fields or fields["configuration"] is None:
        return "unowned"
    value = object_fields(fields["configuration"])
    if value is None:
        return "unreadable"
    identifier = text_field(value, "id")
    if (
        identifier is not None
        and text_field(value, "source_path") is not None
        and text_field(value, "revision") is not None
    ):
        return identifier
    return "unreadable"


DETACHED_LEGACY = "detached-legacy"
NON_DETACHED_LEGACY = "non-detached-legacy"
NEWER_READABLE = "newer-readable"
NEWER_BROKEN = "newer-broken"
UNREADABLE = "unreadable"

CLASSES = (DETACHED_LEGACY, NON_DETACHED_LEGACY, NEWER_READABLE, NEWER_BROKEN, UNREADABLE)


def classify(value: Any) -> str:
    fields = object_fields(value)
    if fields is None:
        return UNREADABLE
    has_any = "visibility" in fields or "source_access" in fields
    if not has_any:
        return DETACHED_LEGACY if is_detached(fields) else NON_DETACHED_LEGACY
    has_visibility = visibility_is_valid(fields)
    has_source_access = source_access_is_valid(fields)
    return NEWER_READABLE if has_visibility and has_source_access else NEWER_BROKEN


def identity_of(fields: dict[str, Any]) -> tuple[str, str]:
    """(instance id, observation sequence) for the report, '-' when absent.
    The store already refuses bindings without a usable identity; this only
    describes the record."""
    fields_map = object_fields(fields)
    if fields_map is None:
        return "-", "-"
    identifier = text_field(fields_map, "instance_id") or "-"
    sequence = fields_map.get("observation_seq")
    sequence_text = str(sequence) if isinstance(sequence, int) and not isinstance(sequence, bool) and sequence >= 0 else "-"
    return identifier, sequence_text


def holding_of(record_class: str, fields: dict[str, Any] | None) -> str:
    """Who waits on this record, in the container's own words."""
    if record_class != NON_DETACHED_LEGACY or fields is None:
        return "nothing"
    owner = owner_of(fields)
    if owner == "unowned":
        return "nothing (manual attach)"
    if owner == "unreadable":
        return "every enabled installation (owner unreadable)"
    return f"installation {owner}"


class Report:
    def __init__(self) -> None:
        self.counts = {name: 0 for name in CLASSES}
        self.lines: list[str] = []

    def add(self, name: str, line: str) -> None:
        self.counts[name] += 1
        self.lines.append(line)

    def total(self) -> int:
        return sum(self.counts.values())


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_of(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(65536), b""):
            digest.update(block)
    return digest.hexdigest()


def read_and_classify(path: pathlib.Path) -> ClassifiedRecord:
    try:
        raw_bytes = path.read_bytes()
    except OSError:
        raw_bytes = b""
        value = None
    else:
        try:
            value = json.loads(raw_bytes.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            value = None
    record_class = classify(value)
    fields = object_fields(value)
    return ClassifiedRecord(
        name=path.name,
        raw_bytes=raw_bytes,
        raw_sha256=sha256_bytes(raw_bytes),
        record_class=record_class,
        fields=fields,
    )


def scan_records(bindings: pathlib.Path) -> tuple[Report, list[ClassifiedRecord]]:
    report = Report()
    records: list[ClassifiedRecord] = []
    for path in sorted(bindings.iterdir()):
        if not path.name.endswith(".json") or not path.is_file():
            continue
        record = read_and_classify(path)
        records.append(record)
        instance, sequence = identity_of(record.fields if record.fields is not None else {})
        owner = owner_of(record.fields) if record.fields is not None else "unreadable"
        holding = holding_of(record.record_class, record.fields)
        report.add(
            record.record_class,
            f"{record.record_class}: {path.name} instance_id={instance} observation_seq={sequence} "
            f"owner={owner} holds-back: {holding}",
        )
    return report, records


def scan(bindings: pathlib.Path) -> tuple[Report, dict[str, dict[str, Any] | None]]:
    report, records = scan_records(bindings)
    fields_by_file = {record.name: record.fields for record in records}
    return report, fields_by_file


def write_archive_atomic(archive_path: pathlib.Path, raw_bytes: bytes, raw_sha256: str) -> None:
    tmp_path = archive_path.with_name(f".{archive_path.name}.tmp.{os.getpid()}")
    try:
        tmp_path.write_bytes(raw_bytes)
        if sha256_of(tmp_path) != raw_sha256:
            tmp_path.unlink(missing_ok=True)
            raise SystemExit(f"archive temporary copy differs from classified bytes: {archive_path.name}")
        os.replace(tmp_path, archive_path)
    except OSError as exc:
        tmp_path.unlink(missing_ok=True)
        raise SystemExit(f"failed to write archive copy {archive_path}: {exc}") from exc


def write_out(
    bindings: pathlib.Path,
    archive: pathlib.Path,
    records: list[ClassifiedRecord] | None = None,
) -> list[str]:
    """Move the detached legacy records out of the container's read path.

    Destination pre-checks run across all detached legacy records before the
    first move. Each archive copy is written atomically from the exact bytes
    that were classified, and the source file is renamed only if its on-disk
    sha256 still matches those classified bytes. If a prior run crashed after
    publishing a byte-identical archive copy and before renaming the source,
    rerunning completes the rename; any differing archive or existing
    `.migrated` file aborts before the first move.
    """
    if records is None:
        _, records = scan_records(bindings)
    plan: list[tuple[ClassifiedRecord, bool]] = []
    for record in records:
        if record.record_class != DETACHED_LEGACY:
            continue
        path = bindings / record.name
        archive_path = archive / (record.name + LEGACY_SUFFIX)
        migrated_path = path.with_name(record.name + MIGRATED_SUFFIX)
        if migrated_path.exists():
            raise SystemExit(f"refusing to overwrite: {migrated_path} exists")
        resume_existing_archive = False
        if archive_path.exists():
            try:
                existing_sha = sha256_of(archive_path)
            except OSError as exc:
                raise SystemExit(f"refusing to overwrite unreadable archive {archive_path}: {exc}") from exc
            if existing_sha != record.raw_sha256:
                raise SystemExit(f"refusing to overwrite: {archive_path} exists with different bytes")
            resume_existing_archive = True
        plan.append((record, resume_existing_archive))
    moved: list[str] = []
    for record, resume_existing_archive in plan:
        path = bindings / record.name
        archive_path = archive / (record.name + LEGACY_SUFFIX)
        migrated_path = path.with_name(record.name + MIGRATED_SUFFIX)
        try:
            current_sha = sha256_of(path)
        except OSError as exc:
            raise SystemExit(f"failed to read source before move {path}: {exc}") from exc
        if current_sha != record.raw_sha256:
            raise SystemExit(f"source record changed since classification: {record.name}")
        if not resume_existing_archive:
            write_archive_atomic(archive_path, record.raw_bytes, record.raw_sha256)
        if sha256_of(archive_path) != record.raw_sha256:
            raise SystemExit(f"archive copy differs from source: {record.name}")
        if sha256_of(path) != record.raw_sha256:
            raise SystemExit(f"source record changed before rename: {record.name}")
        path.rename(migrated_path)
        moved.append(record.name)
        print(f"migrated: {path} -> {migrated_path} (archive copy at {archive_path})")
    return moved


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Classify (and optionally move) pre-v0.49.0 lane add-on binding records."
    )
    parser.add_argument(
        "--base-path",
        default=".",
        help="masc base path containing the lane_addon store (default: current directory)",
    )
    parser.add_argument(
        "--store-root",
        default=None,
        help="lane_addon store root (default: <base-path>/var/lib/masc/lane_addon)",
    )
    parser.add_argument(
        "--write-out",
        default=None,
        metavar="DIR",
        help="move detached legacy records out of the read path after archiving them to DIR (run with the server stopped)",
    )
    args = parser.parse_args(argv)
    store_root = (
        pathlib.Path(args.store_root)
        if args.store_root is not None
        else pathlib.Path(args.base_path) / "var" / "lib" / "masc" / "lane_addon"
    )
    bindings = store_root / BINDINGS_DIR
    if not bindings.is_dir():
        print(f"error: no bindings directory at {bindings}", file=sys.stderr)
        return 2
    report, records = scan_records(bindings)
    for line in report.lines:
        print(line)
    print(
        f"input records: {report.total()}"
        f" | detached-legacy: {report.counts[DETACHED_LEGACY]}"
        f" | non-detached-legacy: {report.counts[NON_DETACHED_LEGACY]}"
        f" | newer-readable: {report.counts[NEWER_READABLE]}"
        f" | newer-broken: {report.counts[NEWER_BROKEN]}"
        f" | unreadable: {report.counts[UNREADABLE]}"
    )
    if args.write_out is not None:
        archive = pathlib.Path(args.write_out)
        if not archive.is_dir():
            print(f"error: --write-out directory does not exist: {archive}", file=sys.stderr)
            return 2
        if archive.resolve() == bindings.resolve() or bindings.resolve() in archive.resolve().parents:
            print(
                "error: --write-out must differ from the bindings directory and not live inside it "
                "(the archive belongs outside the container's store)",
                file=sys.stderr,
            )
            return 2
        moved = write_out(bindings, archive, records)
        print(f"converted (moved away): {len(moved)} | rejected (left in place): {report.counts[NON_DETACHED_LEGACY]}")
    else:
        print("no changes made (default is classify-only; see --write-out)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
