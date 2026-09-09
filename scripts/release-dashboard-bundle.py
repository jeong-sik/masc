#!/usr/bin/env python3
"""Package/install an immutable native release and dashboard. This is distribution metadata,
not run-local executable provenance: it claims no checkout device or inode.
"""
import argparse
import datetime
import hashlib
import io
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import signal
import stat
import subprocess
import tarfile
import tempfile

SCHEMA = "masc.installed-release.v2"
RECEIPT = "release.json"
TRANSACTION = ".masc-install-transaction"
COMPANIONS = {"masc-tui", "masc-browser-host", "masc-deployment-preflight-helper",
              "masc-check-runtime-deployment-preflight"}


def runtime_members(archive):
    with tarfile.open(archive, "r:gz") as source:
        entries = {}
        for member in source.getmembers():
            name = str(relative(member.name))
            if (not member.isfile() or name in entries or
                    not (name.startswith(("lib/", "python/", "licenses/")) or name == "runtime-provenance.json") or
                    member.mode not in (0o644, 0o755)):
                fail("unsafe runtime archive member")
            data = source.extractfile(member).read()
            entries[name] = ({"path": name, "sha256": digest(data), "size": len(data),
                              "mode": member.mode}, data)
        if not {"runtime-provenance.json", "python/bin/python3"} <= entries.keys():
            fail("runtime bootstrap or provenance missing")
        return entries


def validate_runtime(receipt):
    if not isinstance(receipt["companions"], dict) or not set(receipt["companions"]) <= COMPANIONS:
        fail("invalid companion receipt")
    for value in receipt["companions"].values():
        hex_value(value, 64)
    runtime = receipt["runtime"]
    if runtime is None:
        return
    exact_fields(runtime, ["asset", "sha256", "files"])
    if str(relative(runtime["asset"])) != "masc-runtime-" + receipt["binary_asset"][5:] + ".tar.gz":
        fail("runtime asset differs")
    hex_value(runtime["sha256"], 64)
    if not isinstance(runtime["files"], list):
        fail("invalid runtime file list")
    names = set()
    for entry in runtime["files"]:
        exact_fields(entry, ["path", "sha256", "size", "mode"])
        name = str(relative(entry["path"]))
        if name in names or not (name.startswith(("lib/", "python/", "licenses/")) or name == "runtime-provenance.json"):
            fail("invalid runtime receipt path")
        names.add(name)
        hex_value(entry["sha256"], 64)
        if (type(entry["size"]) is not int or entry["size"] < 0 or
                type(entry["mode"]) is not int or entry["mode"] not in (0o644, 0o755)):
            fail("invalid runtime receipt metadata")
    if not {"runtime-provenance.json", "python/bin/python3"} <= names:
        fail("runtime receipt bootstrap or provenance missing")



def digest(data):
    return hashlib.sha256(data).hexdigest()


def fail(message):
    raise ValueError(message)


def exact_fields(value, fields):
    if not isinstance(value, dict) or set(value) != set(fields):
        fail("unsupported receipt fields")


def hex_value(value, length):
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{%d}" % length, value) is None:
        fail("invalid receipt digest/commit")


def relative(value):
    if (not isinstance(value, str) or not value or "\\" in value
            or value.startswith("/") or any(p in ("", ".", "..") for p in value.split("/"))):
        fail("unsafe bundle path")
    return PurePosixPath(value)


def parse_json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                fail("duplicate receipt field")
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=unique)


def validate_receipt(receipt, asset):
    exact_fields(receipt, ["schema", "source_commit", "binary_asset", "binary_sha256", "files", "companions", "runtime"])
    if receipt["schema"] != SCHEMA or receipt["binary_asset"] != asset:
        fail("bundle schema or binary asset differs")
    validate_runtime(receipt)
    hex_value(receipt["source_commit"], 40)
    hex_value(receipt["binary_sha256"], 64)
    if not isinstance(receipt["files"], list):
        fail("bundle files must be a list")
    files = {}
    for entry in receipt["files"]:
        exact_fields(entry, ["path", "sha256", "size", "mtime"])
        name = str(relative(entry["path"]))
        if name in files:
            fail("duplicate bundle path")
        hex_value(entry["sha256"], 64)
        if type(entry["size"]) is not int or entry["size"] < 0:
            fail("invalid bundle size")
        if (type(entry["mtime"]) not in (int, float)
                or not math.isfinite(entry["mtime"]) or entry["mtime"] < 0):
            fail("invalid bundle mtime")
        files[name] = entry
    if not {"index.html", ".build-stamp"} <= files.keys():
        fail("dashboard index or actual build stamp missing")
    return files


def binary_commit(binary):
    result = subprocess.run([str(binary), "build-commit"], text=True, errors="replace",
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        if result.returncode < 0:
            termination = f"signal {signal.Signals(-result.returncode).name}"
        else:
            termination = f"exit status {result.returncode}"
        diagnostic = result.stderr.strip() or "The executable produced no stderr."
        fail(f"binary startup failed during build-commit ({termination}): {binary}\n"
             f"{diagnostic}")
    value = result.stdout.strip()
    hex_value(value, 40)
    return value


def stamp_valid(data):
    stamp = datetime.datetime.fromisoformat(data.decode().strip().replace("Z", "+00:00"))
    if stamp.tzinfo is None:
        fail("dashboard build stamp requires a timezone")


def package(binary, assets, source_commit, asset, archive, companions=(), runtime_archive=None, runtime_root=None):
    binary = binary.resolve(strict=True)
    probe = binary
    if runtime_archive is not None:
        if runtime_root is None or digest((runtime_root / "masc").read_bytes()) != digest(binary.read_bytes()):
            fail("portable package requires byte-matching staged executable")
        probe = (runtime_root / "masc").resolve(strict=True)
    if binary_commit(probe) != source_commit:
        fail("binary embedded commit differs from requested source commit")
    files, payloads = [], {}
    for entry in sorted(assets.rglob("*")):
        mode = entry.lstat().st_mode
        if stat.S_ISDIR(mode):
            continue
        if not stat.S_ISREG(mode):
            fail("dashboard contains a non-regular file")
        name = str(relative(entry.relative_to(assets).as_posix()))
        data = entry.read_bytes()
        files.append({"path": name, "sha256": digest(data), "size": len(data), "mtime": entry.stat().st_mtime})
        payloads["dashboard/" + name] = data
    receipt = {"schema": SCHEMA, "source_commit": source_commit, "binary_asset": asset,
               "binary_sha256": digest(binary.read_bytes()), "files": files,
               "companions": {name: digest(Path(path).read_bytes()) for name, path in companions},
               "runtime": None}
    if len(receipt["companions"]) != len(companions):
        fail("duplicate companion name")
    if runtime_archive is not None:
        entries = runtime_members(runtime_archive)
        provenance = parse_json(entries["runtime-provenance.json"][1])
        if provenance.get("source_commit") != source_commit or provenance.get("platform") != asset[5:]:
            fail("runtime source or platform differs")
        receipt["runtime"] = {"asset": runtime_archive.name, "sha256": digest(runtime_archive.read_bytes()),
                              "files": [entry for _, (entry, _) in sorted(entries.items())]}
    validate_receipt(receipt, asset)
    stamp_valid(payloads["dashboard/.build-stamp"])
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "w:gz") as output:
        data = (json.dumps(receipt, sort_keys=True, indent=2) + "\n").encode()
        info = tarfile.TarInfo(RECEIPT)
        info.size = len(data)
        info.mode = 0o644
        output.addfile(info, io.BytesIO(data))
        for entry in files:
            name = "dashboard/" + entry["path"]
            info = tarfile.TarInfo(name)
            info.size = entry["size"]
            info.mtime = entry["mtime"]
            info.mode = 0o644
            output.addfile(info, io.BytesIO(payloads[name]))


def extract_verified(archive, stage, asset):
    # No extractall: every member is a declared regular file written below a
    # new private directory. Tar links/devices, duplicate names, and traversal
    # are rejected before any write, including members absent from the receipt.
    with tarfile.open(archive, "r:gz") as source:
        members = {}
        for member in source.getmembers():
            relative(member.name)
            if not member.isfile() or member.name in members:
                fail("bundle contains duplicate or non-regular members")
            members[member.name] = member
        if RECEIPT not in members:
            fail("bundle receipt missing")
        receipt_data = source.extractfile(members[RECEIPT]).read()
        receipt = parse_json(receipt_data)
        files = validate_receipt(receipt, asset)
        if set(members) != {RECEIPT, *("dashboard/" + name for name in files)}:
            fail("bundle members differ from receipt")
        for name, entry in files.items():
            member = members["dashboard/" + name]
            if member.size != entry["size"] or member.mtime != entry["mtime"]:
                fail("bundle metadata differs from receipt")
            data = source.extractfile(member).read()
            if digest(data) != entry["sha256"]:
                fail("bundle file digest differs")
            if name == ".build-stamp":
                stamp_valid(data)
            dest = stage / "assets" / "dashboard" / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
            os.utime(dest, (entry["mtime"], entry["mtime"]))
        (stage / RECEIPT).write_bytes(receipt_data)
    return receipt


def verify_tree(root, asset):
    if any(p.is_symlink() for p in [root, root / RECEIPT, root / "masc"]):
        fail("installed release identity must not be a symlink")
    receipt = parse_json((root / RECEIPT).read_bytes())
    files = validate_receipt(receipt, asset)
    if digest((root / "masc").read_bytes()) != receipt["binary_sha256"]:
        fail("installed binary digest differs")
    for name, entry in files.items():
        target = root / "assets" / "dashboard" / name
        for component in [target, *target.parents]:
            if component == root:
                break
            if component.is_symlink():
                fail("installed dashboard contains a symlink")
        if (not target.is_file() or digest(target.read_bytes()) != entry["sha256"]
                or target.stat().st_mtime != entry["mtime"]):
            fail("installed dashboard digest or build mtime differs")
    for name, expected in receipt["companions"].items():
        target = root / name
        if target.is_symlink() or not target.is_file() or digest(target.read_bytes()) != expected:
            fail("installed companion digest differs")
    if receipt["runtime"] is not None:
        for entry in receipt["runtime"]["files"]:
            target = root / entry["path"]
            if any(p.is_symlink() for p in [target, *target.parents] if p != root and root in p.parents):
                fail("installed runtime contains a symlink")
            if (not target.is_file() or target.stat().st_size != entry["size"] or
                    target.stat().st_mode & 0o777 != entry["mode"] or digest(target.read_bytes()) != entry["sha256"]):
                fail("installed runtime digest or mode differs")
    return receipt


def fsync_dir(directory):
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def transaction_dir(prefix):
    journal = prefix / TRANSACTION
    if journal.is_symlink():
        fail("install transaction must not be a symlink")
    return journal


def restore_entry(entry, destination):
    previous = entry / "previous"
    if previous.is_symlink() or previous.exists():
        os.replace(previous, destination)
    elif (entry / "new-install").is_file():
        destination.unlink(missing_ok=True)
    else:
        fail("incomplete install transaction; preserving it for inspection")


def save_previous(destination, entry):
    if destination.is_symlink():
        (entry / "previous").symlink_to(os.readlink(destination))
    elif destination.exists():
        if not destination.is_file():
            fail("installed executable path is not a file")
        os.link(destination, entry / "previous")
    else:
        (entry / "new-install").touch()


def rollback(prefix):
    journal = transaction_dir(prefix)
    if not journal.exists():
        fail("install transaction missing; rollback cannot be confirmed")
    companions = journal / "companions"
    if companions.exists():
        for entry in companions.iterdir():
            if (entry / "ready").exists():
                restore_entry(entry, prefix / entry.name)
    restore_entry(journal, prefix / "masc")
    fsync_dir(prefix)
    shutil.rmtree(journal)


def commit(prefix):
    journal = transaction_dir(prefix)
    if not journal.is_dir():
        fail("install transaction missing")
    # Publication must be durable while the undo record still exists.
    # Cleanup is deliberately last: a cleanup failure must never be reported
    # as a successful rollback after the previous binary has been removed.
    fsync_dir(prefix)
    shutil.rmtree(journal)


def install(binary, archive, prefix, asset, companions=(), runtime_archive=None):
    names = set()
    for name, source in companions:
        if name not in COMPANIONS or name in names:
            fail("unsupported or duplicate companion name")
        names.add(name)
        if not Path(source).is_file():
            fail("companion source is not a file")
    prefix.mkdir(parents=True, exist_ok=True)
    prefix = prefix.resolve(strict=True)
    releases = prefix / ".masc-releases"
    if releases.is_symlink():
        fail("release directory must not be a symlink")
    releases.mkdir(mode=0o700, exist_ok=True)
    journal = transaction_dir(prefix)
    if journal.exists():
        fail("unfinished install transaction; commit or rollback it first")
    with tempfile.TemporaryDirectory(prefix=".stage-", dir=releases) as tmp:
        stage = Path(tmp)
        receipt = extract_verified(archive, stage, asset)
        if names != set(receipt["companions"]):
            fail("provided companions differ from receipt")
        for name, source in companions:
            if digest(Path(source).read_bytes()) != receipt["companions"][name]:
                fail("companion digest differs from receipt")
            shutil.copy2(source, stage / name)
            (stage / name).chmod(0o755)
        runtime = receipt["runtime"]
        if (runtime is None) != (runtime_archive is None):
            fail("runtime archive presence differs from receipt")
        if runtime is not None:
            if digest(runtime_archive.read_bytes()) != runtime["sha256"]:
                fail("runtime archive digest differs")
            entries = runtime_members(runtime_archive)
            if [entry for _, (entry, _) in sorted(entries.items())] != runtime["files"]:
                fail("runtime file set differs from receipt")
            for name, (entry, data) in entries.items():
                target = stage / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                target.chmod(entry["mode"])
        identity = digest((stage / RECEIPT).read_bytes())
        installed = releases / identity
        if installed.is_symlink():
            fail("release identity must not be a symlink")
        if installed.exists():
            if (installed / RECEIPT).read_bytes() != (stage / RECEIPT).read_bytes():
                fail("release receipt identity differs")
            verify_tree(installed, asset)
            if digest(binary.read_bytes()) != receipt["binary_sha256"]:
                fail("installed binary digest differs")
            if binary_commit(installed / "masc") != receipt["source_commit"]:
                fail("installed binary embedded commit differs from bundle")
        else:
            shutil.copy2(binary, stage / "masc")
            (stage / "masc").chmod(0o755)
            verify_tree(stage, asset)
            if binary_commit(stage / "masc") != receipt["source_commit"]:
                fail("installed binary embedded commit differs from bundle")
            # Preserve immutable previous releases; publication replaces only
            # the binary pointer, never the old binary or dashboard bytes.
            for file in stage.rglob("*"):
                if file.is_file():
                    with file.open("rb") as stream:
                        os.fsync(stream.fileno())
            for directory in sorted((p for p in stage.rglob("*") if p.is_dir()), reverse=True):
                fsync_dir(directory)
            fsync_dir(stage)
            os.rename(stage, installed)
            stage.mkdir()  # TemporaryDirectory still owns its original name.
            fsync_dir(releases)
        journal.mkdir(mode=0o700)
        try:
            destination = prefix / "masc"
            save_previous(destination, journal)
            if companions:
                companion_journal = journal / "companions"
                companion_journal.mkdir()
                for name, source in companions:
                    entry = companion_journal / name
                    entry.mkdir()
                    (entry / "next").symlink_to(installed / name)
                    save_previous(prefix / name, entry)
                    (entry / "ready").touch()
                    fsync_dir(entry)
                fsync_dir(companion_journal)
            fsync_dir(journal)
            next_link = journal / "next"
            next_link.symlink_to(installed / "masc")
            for name, _ in companions:
                os.replace(journal / "companions" / name / "next", prefix / name)
            os.replace(next_link, destination)
            fsync_dir(prefix)
        except BaseException:
            rollback(prefix)
            raise
        print(installed / "assets", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    pack = commands.add_parser("package")
    for name in ("binary", "assets", "archive"):
        pack.add_argument("--" + name, type=Path, required=True)
    pack.add_argument("--source-commit", required=True)
    pack.add_argument("--binary-asset", required=True)
    pack.add_argument("--companion", nargs=2, action="append", default=[])
    pack.add_argument("--runtime-archive", type=Path)
    pack.add_argument("--runtime-root", type=Path)
    inst = commands.add_parser("install")
    for name in ("binary", "archive", "prefix"):
        inst.add_argument("--" + name, type=Path, required=True)
    inst.add_argument("--binary-asset", required=True)
    inst.add_argument("--runtime-archive", type=Path)
    inst.add_argument("--companion", nargs=2, action="append", default=[], metavar=("NAME", "PATH"))
    for name in ("commit", "rollback"):
        commands.add_parser(name).add_argument("--prefix", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "package":
        package(args.binary, args.assets, args.source_commit, args.binary_asset, args.archive, args.companion, args.runtime_archive, args.runtime_root)
    elif args.command == "install":
        install(args.binary, args.archive, args.prefix, args.binary_asset, args.companion, args.runtime_archive)
    elif args.command == "commit":
        commit(args.prefix.resolve())
    else:
        rollback(args.prefix.resolve())


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, tarfile.TarError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"release bundle: {error}")
