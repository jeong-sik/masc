#!/usr/bin/env python3
"""Prepare a separate offline repaired copy from an attested exact backup.
Never writes either input. Supports only the explicit-write range-v1 contract.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat

FORMAT = "masc.memory-admission-recovery.range-v1"
SUFFIXES = (".memory-current.json", ".librarian-range-commit.json", ".memory-admission.json")


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def unique(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON key: " + key)
        value[key] = item
    return value


def decode(raw):
    return json.loads(raw, object_pairs_hook=unique,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))


def exact(value, fields):
    if not isinstance(value, dict) or set(value) != set(fields):
        raise ValueError("unsupported or malformed range-v1 schema")


def integer(value, minimum=0):
    if type(value) is not int or not minimum <= value <= (1 << 62) - 1:
        raise ValueError("invalid OCaml integer")
    return value


def text(value):
    if not isinstance(value, str) or not value or value.strip() != value:
        raise ValueError("invalid identity")
    return value


def sha(value):
    if not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
        raise ValueError("invalid SHA-256")
    return value


def queue(raw):
    value = decode(raw)
    exact(value, ("generation", "acknowledged", "pending"))
    text(value["generation"])
    previous = integer(value["acknowledged"])
    if not isinstance(value["pending"], list):
        raise ValueError("pending must be a list")
    seen = set()
    for row in value["pending"]:
        exact(row, ("sequence", "request_id", "fact"))
        if integer(row["sequence"], 1) != previous + 1:
            raise ValueError("pending sequence gap")
        previous = row["sequence"]
        request = text(row["request_id"])
        if request in seen or not isinstance(row["fact"], dict):
            raise ValueError("invalid candidate identity or fact")
        seen.add(request)
    return value


def snapshot(raw):
    value = decode(raw)
    exact(value, ("revision", "updated_at", "source", "facts", "change"))
    integer(value["revision"], 1)
    if not isinstance(value["facts"], list) or not isinstance(value["source"], dict) or not isinstance(value["change"], dict):
        raise ValueError("invalid snapshot containers")
    return value


def verify_receipts(raw, snap, snap_hash, generation, acknowledged):
    value = decode(raw)
    exact(value, ("receipts",))
    if not isinstance(value["receipts"], list):
        raise ValueError("invalid receipt list")
    matches = []
    for row in value["receipts"]:
        if not isinstance(row, dict):
            raise ValueError("invalid receipt")
        kinds = set(row) & {"range_id", "official_range_id", "explicit_write_range_id"}
        if len(kinds) != 1:
            raise ValueError("unsupported receipt identity schema")
        kind = kinds.pop()
        exact(row, ("state", kind, "snapshot_revision", "snapshot_sha256"))
        if row["state"] != "committed":
            raise ValueError("backup contains an unsettled receipt")
        revision = integer(row["snapshot_revision"], 1)
        sha(row["snapshot_sha256"])
        if revision > snap["revision"] or (revision == snap["revision"] and row["snapshot_sha256"] != snap_hash):
            raise ValueError("receipt snapshot mismatch")
        if kind == "explicit_write_range_id":
            scope = row[kind]
            exact(scope, ("receipt_scope", "after_sequence", "through_sequence", "input_sha256"))
            text(scope["receipt_scope"]); sha(scope["input_sha256"])
            after = integer(scope["after_sequence"])
            through = integer(scope["through_sequence"], 1)
            if after >= through:
                raise ValueError("invalid committed interval")
            if scope["receipt_scope"] == generation:
                matches.append(row)
    if len(matches) != 1:
        raise ValueError("backup must have one exact generation receipt")
    match = matches[0]
    if match["explicit_write_range_id"]["through_sequence"] != acknowledged:
        raise ValueError("backup receipt does not establish the acknowledged frontier")
    # Do not use an older receipt plus a later, unrelated snapshot as proof.
    if match["snapshot_revision"] != snap["revision"] or match["snapshot_sha256"] != snap_hash:
        raise ValueError("recovery requires the exact committed snapshot, not a later projection")


def inventory(directory):
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("input must be a real offline directory")
    files = {}
    for path in directory.rglob("*"):
        mode = path.lstat()
        if path.is_symlink() or mode.st_uid != os.getuid():
            raise ValueError("input contains a symlink or unowned entry")
        if stat.S_ISDIR(mode.st_mode):
            continue
        if not stat.S_ISREG(mode.st_mode) or mode.st_nlink != 1:
            raise ValueError("input contains a non-regular or shared file")
        files[str(path.relative_to(directory))] = path.read_bytes()
    return files


def write_durable(path, raw):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.open("wb") as stream:
        os.chmod(path, 0o600)
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())


def prepare(current_copy, backup, output, keeper, expected_snapshot_sha256, format_name):
    if format_name != FORMAT:
        raise ValueError("unsupported recovery format; do not translate a newer receipt schema")
    if not keeper or keeper in (".", "..") or Path(keeper).name != keeper:
        raise ValueError("keeper must be a single filename component")
    current_copy, backup, output = map(Path, (current_copy, backup, output))
    if output.exists() or output.is_symlink():
        raise ValueError("output must not exist")
    for source in (current_copy, backup):
        if source.resolve() == output.resolve() or source.resolve() in output.resolve().parents:
            raise ValueError("output must be outside both inputs")
    current, saved = inventory(current_copy), inventory(backup)
    names = [keeper + suffix for suffix in SUFFIXES]
    snapshot_name, receipt_name, queue_name = names
    saved_snapshot, saved_receipt, saved_queue = (saved[name] for name in names)
    snap_hash = digest(saved_snapshot)
    if snap_hash != sha(expected_snapshot_sha256):
        raise ValueError("backup differs from the independently attested snapshot hash")
    snap = snapshot(saved_snapshot)
    before, old = queue(current[queue_name]), queue(saved_queue)
    if before["generation"] != old["generation"] or before["acknowledged"] != old["acknowledged"]:
        raise ValueError("generation/frontier moved after backup; rollback is forbidden")
    if before["acknowledged"] == 0:
        raise ValueError("this tool repairs a lost acknowledged frontier only")
    if before["pending"][:len(old["pending"])] != old["pending"]:
        raise ValueError("backup pending prefix differs; accepted input must not be rewritten")
    verify_receipts(saved_receipt, snap, snap_hash, before["generation"], before["acknowledged"])
    journal = keeper + ".memory-journal.jsonl"
    # Unchanged journal bytes are a conservative freshness guard, not proof
    # that a missing/corrupt journal can reconstruct a snapshot.
    if journal not in saved or current.get(journal) != saved[journal]:
        raise ValueError("journal changed or absent; establish a newer coherent recovery cut")
    journal_rows = [decode(line) for line in saved[journal].splitlines() if line.strip()]
    committed_revisions = [integer(row["revision"], 1) for row in journal_rows
                           if isinstance(row, dict) and row.get("outcome") == "committed"]
    if not committed_revisions or max(committed_revisions) != snap["revision"]:
        raise ValueError("journal does not establish the backup snapshot revision")
    existing = current.get(snapshot_name)
    if existing is not None and existing != saved_snapshot:
        try:
            decode(existing)
        except (ValueError, UnicodeError):
            pass
        else:
            raise ValueError("a different JSON snapshot exists; never overwrite possible later memory")
    # Any surviving receipt newer/different than the backup is evidence, not
    # something the operator tool is allowed to erase.
    existing_receipt = current.get(receipt_name)
    if existing_receipt is not None and existing_receipt != saved_receipt:
        raise ValueError("a different receipt survives; exact recovery requires investigation")
    output.mkdir(mode=0o700)
    for name, raw in current.items():
        write_durable(output / "repaired" / name, raw)
    for name, raw in ((snapshot_name, saved_snapshot), (receipt_name, saved_receipt)):
        if name in current:
            write_durable(output / "original" / name, current[name])
        write_durable(output / "repaired" / name, raw)
    if inventory(current_copy) != current or inventory(backup) != saved:
        raise ValueError("offline input changed during preparation; discard output")
    manifest = {"format": FORMAT, "keeper": keeper, "generation": before["generation"],
                "acknowledged": before["acknowledged"], "snapshot_sha256": snap_hash,
                "queue_sha256": digest(current[queue_name]),
                "replacement_paths": [snapshot_name, receipt_name],
                "before": {name: digest(raw) for name, raw in current.items()},
                "after": {name: digest(raw) for name, raw in inventory(output / "repaired").items()}}
    write_durable(output / "manifest.json", (json.dumps(manifest, indent=2) + "\n").encode())
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("current-copy", "backup", "output", "keeper", "expected-snapshot-sha256", "format"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.current_copy, args.backup, args.output, args.keeper,
                             args.expected_snapshot_sha256, args.format), indent=2))
