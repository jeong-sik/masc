#!/usr/bin/env python3
"""Materialize immutable executable/provenance launch artifacts."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys


RECEIPT_SCHEMA = "masc.run-local-launch-binding.v1"
PROVENANCE_SCHEMA = "masc.run-local-executable-identity.v2"
SOURCE_ROOT_RECEIPT_SCHEMA = "masc.run-local-source-root.v1"
DASHBOARD_ASSETS_SCHEMA = "masc.run-local-dashboard-assets.v1"
DASHBOARD_BUILD_RECEIPT_SCHEMA = "masc.run-local-dashboard-build.v1"
DASHBOARD_BUILD_INPUT_SCHEMA = "masc.run-local-dashboard-build-input.v1"
DASHBOARD_PACKAGE_MANAGER_RECEIPT_SCHEMA = "masc.run-local-dashboard-package-manager.v1"
DASHBOARD_BUILD_PRODUCER = "scripts/build-dashboard-if-needed.sh --force"
DASHBOARD_BUILD_MODE = "production"
DASHBOARD_BUILD_UNSET_ENVIRONMENT = [
    "BUNDLE_REPORT",
    "MASC_DASHBOARD_PROXY_TARGET",
    "NODE_OPTIONS",
]


class BindingError(RuntimeError):
    pass


def digest_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(io.DEFAULT_BUFFER_SIZE), b""):
            digest.update(block)
    return digest.hexdigest()


def inspect_source_root(path: Path) -> tuple[Path, os.stat_result]:
    canonical = path.resolve(strict=True)
    info = canonical.stat()
    if not stat.S_ISDIR(info.st_mode):
        raise BindingError("source root is not a directory")
    return canonical, info


def require_source_root_identity(
    path: Path, *, expected_path: Path, expected_device: int, expected_inode: int
) -> tuple[Path, os.stat_result]:
    canonical, info = inspect_source_root(path)
    if canonical != expected_path:
        raise BindingError("source root path differs from initial identity")
    if info.st_dev != expected_device:
        raise BindingError("source root device differs from initial identity")
    if info.st_ino != expected_inode:
        raise BindingError("source root inode differs from initial identity")
    return canonical, info


def same_stat_identity(first: os.stat_result, second: os.stat_result) -> bool:
    return (
        first.st_dev,
        first.st_ino,
        first.st_mode,
        first.st_uid,
        first.st_size,
        first.st_mtime_ns,
        first.st_ctime_ns,
    ) == (
        second.st_dev,
        second.st_ino,
        second.st_mode,
        second.st_uid,
        second.st_size,
        second.st_mtime_ns,
        second.st_ctime_ns,
    )


def read_regular_file_exact(path: Path) -> tuple[bytes, os.stat_result]:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise BindingError(f"build input is not a regular file: {path}")
        with os.fdopen(os.dup(descriptor), "rb", closefd=True) as handle:
            payload = handle.read()
        after = os.fstat(descriptor)
        if not same_stat_identity(before, after) or len(payload) != before.st_size:
            raise BindingError(f"build input changed while reading: {path}")
        return payload, before
    finally:
        os.close(descriptor)


def canonical_json_digest(value: object) -> str:
    return digest_bytes(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    )


def decode_git_paths(raw: bytes) -> list[str]:
    try:
        return sorted(path.decode("utf-8") for path in raw.split(b"\0") if path)
    except UnicodeDecodeError as error:
        raise BindingError("dashboard build input path is not UTF-8") from error


def dashboard_input_identity(source_root: Path) -> tuple[str, int, bool, str]:
    command = [
        "git",
        "-C",
        str(source_root),
        "ls-files",
        "--cached",
        "--others",
        "--exclude-standard",
        "--",
        "dashboard",
        "pnpm-lock.yaml",
        "pnpm-workspace.yaml",
        "package.json",
        "scripts/build-dashboard-if-needed.sh",
        "scripts/run-local-executable-binding.py",
    ]
    command.insert(6, "-z")
    result = subprocess.run(command, check=True, capture_output=True)
    paths = decode_git_paths(result.stdout)
    discovered_paths = set(paths)
    explicit_environment_input = False
    for environment_file in sorted((source_root / "dashboard").glob(".env*")):
        if environment_file.is_file() and not environment_file.is_symlink():
            relative = environment_file.relative_to(source_root).as_posix()
            if relative not in paths:
                paths.append(relative)
                explicit_environment_input = True
    paths.sort()
    if not paths:
        raise BindingError("dashboard build input inventory is empty")

    def capture() -> list[dict[str, object]]:
        entries: list[dict[str, object]] = []
        for relative in paths:
            payload, info = read_regular_file_exact(source_root / relative)
            entries.append(
                {
                    "path": relative,
                    "size": info.st_size,
                    "sha256": digest_bytes(payload),
                    "device": info.st_dev,
                    "inode": info.st_ino,
                    "mtime_ns": info.st_mtime_ns,
                    "ctime_ns": info.st_ctime_ns,
                }
            )
        return entries

    first = capture()
    second = capture()
    if first != second:
        raise BindingError("dashboard build input inventory changed")
    digest_entries = [
        {"path": entry["path"], "size": entry["size"], "sha256": entry["sha256"]}
        for entry in second
    ]
    diff_result = subprocess.run(
        [
            "git",
            "-C",
            str(source_root),
            "diff",
            "--quiet",
            "HEAD",
            "--",
            "dashboard",
            "pnpm-lock.yaml",
            "pnpm-workspace.yaml",
            "package.json",
            "scripts/build-dashboard-if-needed.sh",
            "scripts/run-local-executable-binding.py",
        ],
        check=False,
        capture_output=True,
    )
    if diff_result.returncode not in (0, 1):
        raise BindingError("dashboard tracked-input comparison failed")
    tracked_matches_head = diff_result.returncode == 0
    untracked_command = [
        "git",
        "-C",
        str(source_root),
        "ls-files",
        "--others",
        "--exclude-standard",
        "-z",
        "--",
        "dashboard",
        "pnpm-lock.yaml",
        "pnpm-workspace.yaml",
        "package.json",
        "scripts/build-dashboard-if-needed.sh",
        "scripts/run-local-executable-binding.py",
    ]
    untracked = subprocess.run(
        untracked_command, check=True, capture_output=True
    ).stdout
    lock_entries = [
        entry
        for entry in digest_entries
        if entry["path"] in ("pnpm-lock.yaml", "dashboard/pnpm-lock.yaml")
    ]
    if not lock_entries:
        raise BindingError("dashboard lockfile is missing from build inputs")
    return (
        canonical_json_digest(digest_entries),
        len(digest_entries),
        tracked_matches_head
        and not untracked
        and not explicit_environment_input
        and len(discovered_paths) == len(paths),
        canonical_json_digest(lock_entries),
    )


def git_output(source_root: Path, arguments: list[str]) -> str:
    result = subprocess.run(
        ["git", "-C", str(source_root), *arguments],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def dashboard_runtime_identity(
    source_root: Path,
    *,
    package_manager_executable: Path | None = None,
    package_manager_kind: str | None = None,
    node_executable: Path | None = None,
) -> dict[str, object]:
    node = str(node_executable) if node_executable is not None else shutil.which("node")
    if package_manager_executable is None:
        pnpm = shutil.which("pnpm")
        corepack = shutil.which("corepack")
        package_manager_executable = Path(pnpm or corepack or "")
        package_manager_kind = "pnpm" if pnpm is not None else "corepack"
    if node is None or not str(package_manager_executable):
        raise BindingError("dashboard build runtime is unavailable")
    if package_manager_kind not in ("pnpm", "corepack"):
        raise BindingError("dashboard package-manager invocation kind is invalid")
    node_path = Path(node).resolve(strict=True)
    package_manager_path = package_manager_executable.resolve(strict=True)
    node_version = subprocess.run(
        [str(node_path), "--version"], check=True, capture_output=True, text=True
    ).stdout.strip()
    node_platform_arch = subprocess.run(
        [str(node_path), "-p", 'process.platform + "\\n" + process.arch'],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.splitlines()
    if len(node_platform_arch) != 2:
        raise BindingError("Node platform identity is unavailable")
    package_manager = [str(node_path), str(package_manager_path)]
    if package_manager_kind == "corepack":
        package_manager.append("pnpm")
    pnpm_version = subprocess.run(
        [*package_manager, "--version"], check=True, capture_output=True, text=True
    ).stdout.strip()
    vite_package = source_root / "dashboard" / "node_modules" / "vite" / "package.json"
    vite_payload, _vite_info = read_regular_file_exact(vite_package)
    vite_json = json.loads(vite_payload)
    vite_version = vite_json.get("version") if isinstance(vite_json, dict) else None
    if not isinstance(vite_version, str) or not vite_version:
        raise BindingError("installed Vite version is unavailable")
    graph_result = subprocess.run(
        [
            *package_manager,
            "--dir",
            str(source_root / "dashboard"),
            "list",
            "--json",
            "--depth",
            "Infinity",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    graph = json.loads(graph_result.stdout)

    def graph_count(value: object) -> int:
        count = 0
        pending = list(value) if isinstance(value, list) else [value]
        while pending:
            item = pending.pop()
            if not isinstance(item, dict):
                continue
            if isinstance(item.get("name"), str) or isinstance(
                item.get("version"), str
            ):
                count += 1
            for field in ("dependencies", "devDependencies", "optionalDependencies"):
                dependencies = item.get(field)
                if isinstance(dependencies, dict):
                    pending.extend(dependencies.values())
        return count

    return {
        "node_executable": str(node_path),
        "node_executable_sha256": digest_file(node_path),
        "node_version": node_version,
        "node_platform": node_platform_arch[0],
        "node_arch": node_platform_arch[1],
        "package_manager_kind": package_manager_kind,
        "package_manager_executable": str(package_manager_path),
        "package_manager_executable_sha256": digest_file(package_manager_path),
        "pnpm_version": pnpm_version,
        "vite_version": vite_version,
        "installed_graph_metadata_sha256": canonical_json_digest(graph),
        "installed_graph_metadata_count": graph_count(graph),
    }


def dashboard_build_input_receipt(
    source_root: Path,
    *,
    package_manager_executable: Path | None = None,
    package_manager_kind: str | None = None,
    node_executable: Path | None = None,
) -> dict[str, object]:
    canonical, info = inspect_source_root(source_root)
    input_sha256, input_file_count, input_matches_head, lock_sha256 = (
        dashboard_input_identity(canonical)
    )
    runtime = dashboard_runtime_identity(
        canonical,
        package_manager_executable=package_manager_executable,
        package_manager_kind=package_manager_kind,
        node_executable=node_executable,
    )
    build_path = os.pathsep.join(
        dict.fromkeys(
            [
                str(Path(str(runtime["node_executable"])).parent),
                str(Path(str(runtime["package_manager_executable"])).parent),
            ]
        )
    )
    environment_profile = {
        "set": {"NODE_ENV": "production", "PATH": build_path},
        "unset_exact": DASHBOARD_BUILD_UNSET_ENVIRONMENT,
        "unset_prefix": ["VITE_"],
    }
    return {
        "schema": DASHBOARD_BUILD_INPUT_SCHEMA,
        "source_root": str(canonical),
        "source_root_device": info.st_dev,
        "source_root_inode": info.st_ino,
        "source_commit": git_output(canonical, ["rev-parse", "HEAD"]),
        "head_tree": git_output(canonical, ["rev-parse", "HEAD^{tree}"]),
        "index_tree": git_output(canonical, ["write-tree"]),
        "input_sha256": input_sha256,
        "input_file_count": input_file_count,
        "input_matches_head": input_matches_head,
        "lock_sha256": lock_sha256,
        "build_mode": DASHBOARD_BUILD_MODE,
        "environment_path": build_path,
        "environment_profile_sha256": canonical_json_digest(environment_profile),
        **runtime,
    }


def dashboard_build_receipt(
    source_root: Path,
    commit: str,
    expected_input: dict[str, object],
    *,
    package_manager_executable: Path | None = None,
    package_manager_kind: str | None = None,
    node_executable: Path | None = None,
) -> dict[str, object]:
    current_input = dashboard_build_input_receipt(
        source_root,
        package_manager_executable=package_manager_executable,
        package_manager_kind=package_manager_kind,
        node_executable=node_executable,
    )
    if current_input != expected_input:
        raise BindingError("dashboard build inputs changed across force build")
    if current_input["source_commit"] != commit:
        raise BindingError("dashboard build source commit differs from binary commit")
    canonical = Path(str(current_input["source_root"]))
    _dashboard_root, output_entries, _payloads = dashboard_source_entries(canonical)
    return {
        "schema": DASHBOARD_BUILD_RECEIPT_SCHEMA,
        "producer": DASHBOARD_BUILD_PRODUCER,
        "source_root": str(canonical),
        "source_root_device": current_input["source_root_device"],
        "source_root_inode": current_input["source_root_inode"],
        "source_commit": commit,
        "head_tree": current_input["head_tree"],
        "index_tree": current_input["index_tree"],
        "input_sha256": current_input["input_sha256"],
        "input_file_count": current_input["input_file_count"],
        "input_matches_head": current_input["input_matches_head"],
        "lock_sha256": current_input["lock_sha256"],
        "build_mode": current_input["build_mode"],
        "environment_path": current_input["environment_path"],
        "environment_profile_sha256": current_input["environment_profile_sha256"],
        "node_executable": current_input["node_executable"],
        "node_executable_sha256": current_input["node_executable_sha256"],
        "node_version": current_input["node_version"],
        "node_platform": current_input["node_platform"],
        "node_arch": current_input["node_arch"],
        "package_manager_kind": current_input["package_manager_kind"],
        "package_manager_executable": current_input["package_manager_executable"],
        "package_manager_executable_sha256": current_input[
            "package_manager_executable_sha256"
        ],
        "pnpm_version": current_input["pnpm_version"],
        "vite_version": current_input["vite_version"],
        "installed_graph_metadata_sha256": current_input[
            "installed_graph_metadata_sha256"
        ],
        "installed_graph_metadata_count": current_input[
            "installed_graph_metadata_count"
        ],
        "output_tree_sha256": dashboard_tree_sha256(output_entries),
        "output_file_count": len(output_entries),
    }


def dashboard_source_entries(
    source_root: Path,
) -> tuple[Path, list[dict[str, object]], dict[str, bytes]]:
    dashboard_root = source_root / "assets" / "dashboard"
    if not dashboard_root.is_dir() or dashboard_root.is_symlink():
        raise BindingError("dashboard asset root is missing or not a directory")

    def capture():
        entries: list[dict[str, object]] = []
        payloads: dict[str, bytes] = {}
        metadata: dict[str, tuple[int, int, int, int, int, int, int]] = {}
        open_directories: list[tuple[int, os.stat_result, str]] = []
        try:
            for directory, directory_names, file_names, directory_fd in os.fwalk(
                dashboard_root, topdown=True, follow_symlinks=False
            ):
                relative_directory = Path(directory).relative_to(dashboard_root)
                duplicate_directory_fd = os.dup(directory_fd)
                directory_info = os.fstat(duplicate_directory_fd)
                open_directories.append(
                    (
                        duplicate_directory_fd,
                        directory_info,
                        relative_directory.as_posix(),
                    )
                )
                for name in sorted(directory_names):
                    info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                    if not stat.S_ISDIR(info.st_mode):
                        raise BindingError(
                            f"dashboard directory entry is not a directory: {name}"
                        )
                for name in sorted(file_names):
                    relative = (relative_directory / name).as_posix()
                    descriptor = os.open(
                        name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd
                    )
                    try:
                        info = os.fstat(descriptor)
                        if not stat.S_ISREG(info.st_mode):
                            raise BindingError(
                                f"dashboard asset is not a regular file: {relative}"
                            )
                        with os.fdopen(
                            os.dup(descriptor), "rb", closefd=True
                        ) as handle:
                            payload = handle.read()
                        if not same_stat_identity(info, os.fstat(descriptor)):
                            raise BindingError(
                                f"dashboard asset changed while reading: {relative}"
                            )
                    finally:
                        os.close(descriptor)
                    entries.append(
                        {
                            "path": relative,
                            "size": len(payload),
                            "sha256": digest_bytes(payload),
                        }
                    )
                    payloads[relative] = payload
                    metadata[relative] = (
                        info.st_dev,
                        info.st_ino,
                        info.st_mode,
                        info.st_uid,
                        info.st_size,
                        info.st_mtime_ns,
                        info.st_ctime_ns,
                    )
            for descriptor, before, relative in open_directories:
                if not same_stat_identity(before, os.fstat(descriptor)):
                    raise BindingError(
                        f"dashboard directory changed during inventory: {relative}"
                    )
        finally:
            for descriptor, _before, _relative in open_directories:
                os.close(descriptor)
        entries.sort(key=lambda entry: str(entry["path"]))
        return entries, payloads, metadata

    entries, payloads, metadata = capture()
    confirmed_entries, confirmed_payloads, confirmed_metadata = capture()
    if (
        confirmed_entries != entries
        or confirmed_payloads != payloads
        or confirmed_metadata != metadata
    ):
        raise BindingError("dashboard asset inventory changed before snapshot")
    if not any(entry["path"] == "index.html" for entry in entries):
        raise BindingError("dashboard asset manifest has no index.html")
    return dashboard_root, entries, payloads


def dashboard_tree_sha256(entries: list[dict[str, object]]) -> str:
    payload = json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()
    return digest_bytes(payload)


def require_snapshot_tree(
    snapshot_root: Path, entries: list[dict[str, object]]
) -> os.stat_result:
    root_info = snapshot_root.lstat()
    if (
        not stat.S_ISDIR(root_info.st_mode)
        or root_info.st_uid != os.geteuid()
        or stat.S_IMODE(root_info.st_mode) != 0o700
    ):
        raise BindingError(f"dashboard snapshot root metadata differs: {snapshot_root}")
    expected_blobs = {str(entry["sha256"]): entry for entry in entries}
    for digest, expected in expected_blobs.items():
        path = snapshot_root / digest
        payload, info = read_regular_file_exact(path)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != 0o600
            or info.st_nlink != 1
            or info.st_size != expected["size"]
            or digest_bytes(payload) != expected["sha256"]
        ):
            raise BindingError(f"dashboard blob differs: {digest}")
    return root_info


def materialize_dashboard_snapshot(
    private_root: Path,
    entries: list[dict[str, object]],
    payloads: dict[str, bytes],
) -> tuple[Path, str, os.stat_result]:
    tree_sha256 = dashboard_tree_sha256(entries)
    snapshot_root = private_root / "dashboard-blobs"
    ensure_private_directory(snapshot_root)
    fsync_directory(private_root)
    for entry in entries:
        payload = payloads[str(entry["path"])]
        if len(payload) != entry["size"] or digest_bytes(payload) != entry["sha256"]:
            raise BindingError(
                f"dashboard source changed while snapshotting: {entry['path']}"
            )
        write_once(snapshot_root / str(entry["sha256"]), payload, 0o600)
    fsync_directory(snapshot_root)
    return snapshot_root, tree_sha256, require_snapshot_tree(snapshot_root, entries)


def require_trusted_parent(path: Path) -> None:
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
        raise BindingError(f"launch binding parent is not owned by this user: {path}")
    if stat.S_IMODE(info.st_mode) & 0o022:
        raise BindingError(f"launch binding parent is writable by another user: {path}")


def require_private_directory(path: Path) -> None:
    require_trusted_parent(path)
    if stat.S_IMODE(path.lstat().st_mode) != 0o700:
        raise BindingError(f"launch binding directory is not mode 0700: {path}")


def ensure_private_directory(path: Path) -> None:
    parent = path.parent.resolve(strict=True)
    require_trusted_parent(parent)
    try:
        path.mkdir(mode=0o700)
    except FileExistsError:
        pass
    require_private_directory(path)


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


@contextmanager
def materialization_lock(private_root: Path):
    lock_path = private_root / ".materialize.lock"
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        require_artifact_info(lock_path, os.fstat(descriptor), 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def require_artifact_info(
    path: Path, info: os.stat_result, mode: int
) -> os.stat_result:
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.geteuid()
        or stat.S_IMODE(info.st_mode) != mode
        or info.st_nlink != 1
    ):
        raise BindingError(f"launch artifact metadata differs: {path}")
    return info


def write_once(path: Path, payload: bytes, mode: int) -> os.stat_result:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, mode)
    except FileExistsError:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb", closefd=True) as handle:
            info = require_artifact_info(path, os.fstat(handle.fileno()), mode)
            observed = handle.read()
        if observed != payload:
            raise BindingError(f"content-addressed launch artifact differs: {path}")
        return info
    opened_info = os.fstat(descriptor)
    created_info: os.stat_result | None = None
    try:
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            os.fchmod(handle.fileno(), mode)
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
            created_info = require_artifact_info(path, os.fstat(handle.fileno()), mode)
    except BaseException:
        try:
            current = path.lstat()
            if (current.st_dev, current.st_ino) == (
                opened_info.st_dev,
                opened_info.st_ino,
            ):
                path.unlink()
        except FileNotFoundError:
            pass
        raise
    if created_info is None:
        raise BindingError(f"launch artifact was not materialized: {path}")
    return created_info


def validate_dashboard_build_binding(
    source_root: Path,
    commit: str,
    receipt_path: Path | None,
) -> tuple[
    tuple[Path, list[dict[str, object]], dict[str, bytes]] | None,
    dict[str, object] | None,
]:
    if receipt_path is None:
        return None, None
    raw_receipt = json.loads(receipt_path.read_text())
    if not isinstance(raw_receipt, dict):
        raise BindingError("dashboard build receipt is not an object")
    input_fields = (
        "source_root",
        "source_root_device",
        "source_root_inode",
        "source_commit",
        "head_tree",
        "index_tree",
        "input_sha256",
        "input_file_count",
        "input_matches_head",
        "lock_sha256",
        "build_mode",
        "environment_path",
        "environment_profile_sha256",
        "node_executable",
        "node_executable_sha256",
        "node_version",
        "node_platform",
        "node_arch",
        "package_manager_kind",
        "package_manager_executable",
        "package_manager_executable_sha256",
        "pnpm_version",
        "vite_version",
        "installed_graph_metadata_sha256",
        "installed_graph_metadata_count",
    )
    expected_input = {
        "schema": DASHBOARD_BUILD_INPUT_SCHEMA,
        **{field: raw_receipt.get(field) for field in input_fields},
    }
    expected_receipt = dashboard_build_receipt(
        source_root,
        commit,
        expected_input,
        package_manager_executable=Path(
            str(expected_input["package_manager_executable"])
        ),
        package_manager_kind=str(expected_input["package_manager_kind"]),
        node_executable=Path(str(expected_input["node_executable"])),
    )
    if raw_receipt != expected_receipt:
        raise BindingError(
            "dashboard build receipt differs from current input/output identity"
        )
    return dashboard_source_entries(source_root), expected_receipt


def materialize(
    *,
    private_root: Path,
    executable: Path,
    source_root: Path,
    expected_source_root: Path,
    expected_source_root_device: int,
    expected_source_root_inode: int,
    dashboard_build_receipt_path: Path | None,
    commit: str,
    fingerprint: str,
) -> tuple[Path, str, Path, str, int, int]:
    if not executable.is_file() or executable.is_symlink():
        raise BindingError("Dune executable is not a regular file")
    if len(commit) != 40 or any(char not in "0123456789abcdef" for char in commit):
        raise BindingError("binary commit is not a full Git SHA")
    if len(fingerprint) != 64 or any(
        char not in "0123456789abcdef" for char in fingerprint
    ):
        raise BindingError("build-input fingerprint is not SHA-256")
    source_root, source_root_info = require_source_root_identity(
        source_root,
        expected_path=expected_source_root,
        expected_device=expected_source_root_device,
        expected_inode=expected_source_root_inode,
    )
    ensure_private_directory(private_root)
    with materialization_lock(private_root):
        source_root, source_root_info = require_source_root_identity(
            source_root,
            expected_path=expected_source_root,
            expected_device=expected_source_root_device,
            expected_inode=expected_source_root_inode,
        )
        dashboard_capture, dashboard_receipt = validate_dashboard_build_binding(
            source_root, commit, dashboard_build_receipt_path
        )
        return materialize_locked(
            private_root=private_root,
            executable=executable,
            source_root=source_root,
            source_root_info=source_root_info,
            dashboard_capture=dashboard_capture,
            dashboard_receipt=dashboard_receipt,
            commit=commit,
            fingerprint=fingerprint,
        )


def materialize_locked(
    *,
    private_root: Path,
    executable: Path,
    source_root: Path,
    source_root_info: os.stat_result,
    dashboard_capture: tuple[Path, list[dict[str, object]], dict[str, bytes]] | None,
    dashboard_receipt: dict[str, object] | None,
    commit: str,
    fingerprint: str,
) -> tuple[Path, str, Path, str, int, int]:
    executable_dir = private_root / "executables"
    provenance_dir = private_root / "provenance"
    ensure_private_directory(executable_dir)
    ensure_private_directory(provenance_dir)
    fsync_directory(private_root)

    executable_payload = executable.read_bytes()
    executable_sha256 = digest_bytes(executable_payload)
    bound_executable = executable_dir / f"{executable_sha256}-main_eio.exe"
    executable_info = write_once(bound_executable, executable_payload, 0o500)
    fsync_directory(executable_dir)
    if digest_file(bound_executable) != executable_sha256:
        raise BindingError("materialized executable digest differs")

    if dashboard_capture is None or dashboard_receipt is None:
        dashboard_assets: dict[str, object] = {
            "state": "unavailable",
            "reason": "build_receipt_missing",
        }
    else:
        dashboard_root, dashboard_entries, dashboard_payloads = dashboard_capture
        (
            dashboard_snapshot_root,
            dashboard_tree_sha256_value,
            dashboard_snapshot_info,
        ) = materialize_dashboard_snapshot(
            private_root, dashboard_entries, dashboard_payloads
        )
        dashboard_assets = {
            "state": "available",
            "schema": DASHBOARD_ASSETS_SCHEMA,
            "source_root": str(dashboard_root),
            "snapshot_root": str(dashboard_snapshot_root),
            "snapshot_device": dashboard_snapshot_info.st_dev,
            "snapshot_inode": dashboard_snapshot_info.st_ino,
            "tree_sha256": dashboard_tree_sha256_value,
            "file_count": len(dashboard_entries),
            "files": dashboard_entries,
            "build_receipt": dashboard_receipt,
        }
    provenance_payload = (
        json.dumps(
            {
                "schema": PROVENANCE_SCHEMA,
                "binary_commit": commit,
                "build_input_fingerprint": fingerprint,
                "source_root": str(source_root),
                "source_root_device": source_root_info.st_dev,
                "source_root_inode": source_root_info.st_ino,
                "dashboard_assets": dashboard_assets,
                "executable_sha256": executable_sha256,
                "executable_device": executable_info.st_dev,
                "executable_inode": executable_info.st_ino,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode()
    provenance_sha256 = digest_bytes(provenance_payload)
    provenance_path = provenance_dir / f"{provenance_sha256}.json"
    provenance_info = write_once(provenance_path, provenance_payload, 0o400)
    fsync_directory(provenance_dir)
    if digest_file(provenance_path) != provenance_sha256:
        raise BindingError("materialized provenance digest differs")
    return (
        bound_executable,
        executable_sha256,
        provenance_path,
        provenance_sha256,
        provenance_info.st_dev,
        provenance_info.st_ino,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inspect-source-root", type=Path)
    parser.add_argument("--capture-dashboard-build-input", action="store_true")
    parser.add_argument("--emit-dashboard-build-receipt", action="store_true")
    parser.add_argument("--read-dashboard-package-manager", type=Path)
    parser.add_argument("--dashboard-build-input-receipt", type=Path)
    parser.add_argument("--dashboard-package-manager-executable", type=Path)
    parser.add_argument("--dashboard-node-executable", type=Path)
    parser.add_argument(
        "--dashboard-package-manager-kind", choices=("pnpm", "corepack")
    )
    parser.add_argument("--private-root", type=Path)
    parser.add_argument("--executable", type=Path)
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--expected-source-root", type=Path)
    parser.add_argument("--expected-source-root-device", type=int)
    parser.add_argument("--expected-source-root-inode", type=int)
    parser.add_argument("--dashboard-build-receipt", type=Path)
    parser.add_argument("--commit")
    parser.add_argument("--fingerprint")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.read_dashboard_package_manager is not None:
            receipt = json.loads(args.read_dashboard_package_manager.read_text())
            if not isinstance(receipt, dict):
                raise BindingError("dashboard build input receipt is not an object")
            if receipt.get("schema") != DASHBOARD_BUILD_INPUT_SCHEMA:
                raise BindingError("dashboard build input receipt schema differs")
            kind = receipt.get("package_manager_kind")
            executable = receipt.get("package_manager_executable")
            executable_sha256 = receipt.get("package_manager_executable_sha256")
            node_executable = receipt.get("node_executable")
            node_sha256 = receipt.get("node_executable_sha256")
            environment_path = receipt.get("environment_path")
            if kind not in ("pnpm", "corepack") or not isinstance(executable, str):
                raise BindingError("dashboard package-manager receipt is invalid")
            canonical = Path(executable).resolve(strict=True)
            if not isinstance(node_executable, str) or not isinstance(
                environment_path, str
            ):
                raise BindingError("dashboard build runtime receipt is invalid")
            canonical_node = Path(node_executable).resolve(strict=True)
            if (
                str(canonical) != executable
                or digest_file(canonical) != executable_sha256
                or str(canonical_node) != node_executable
                or digest_file(canonical_node) != node_sha256
            ):
                raise BindingError("dashboard build runtime executable differs")
            print(DASHBOARD_PACKAGE_MANAGER_RECEIPT_SCHEMA)
            print(kind)
            print(executable)
            print(executable_sha256)
            print(node_executable)
            print(node_sha256)
            print(environment_path)
            return 0
        if args.inspect_source_root is not None:
            source_root, source_root_info = inspect_source_root(
                args.inspect_source_root
            )
            print(SOURCE_ROOT_RECEIPT_SCHEMA)
            print(source_root)
            print(source_root_info.st_dev)
            print(source_root_info.st_ino)
            return 0
        if args.emit_dashboard_build_receipt:
            if (
                args.source_root is None
                or args.commit is None
                or args.dashboard_build_input_receipt is None
            ):
                raise BindingError("dashboard build receipt arguments are incomplete")
            expected_input = json.loads(args.dashboard_build_input_receipt.read_text())
            if not isinstance(expected_input, dict):
                raise BindingError("dashboard build input receipt is not an object")
            print(
                json.dumps(
                    dashboard_build_receipt(
                        args.source_root,
                        args.commit,
                        expected_input,
                        package_manager_executable=args.dashboard_package_manager_executable,
                        package_manager_kind=args.dashboard_package_manager_kind,
                        node_executable=args.dashboard_node_executable,
                    ),
                    sort_keys=True,
                    separators=(",", ":"),
                )
            )
            return 0
        if args.capture_dashboard_build_input:
            if args.source_root is None:
                raise BindingError("dashboard build input arguments are incomplete")
            print(
                json.dumps(
                    dashboard_build_input_receipt(
                        args.source_root,
                        package_manager_executable=args.dashboard_package_manager_executable,
                        package_manager_kind=args.dashboard_package_manager_kind,
                        node_executable=args.dashboard_node_executable,
                    ),
                    sort_keys=True,
                    separators=(",", ":"),
                )
            )
            return 0
        required = (
            args.private_root,
            args.executable,
            args.source_root,
            args.expected_source_root,
            args.expected_source_root_device,
            args.expected_source_root_inode,
            args.commit,
            args.fingerprint,
        )
        if any(value is None for value in required):
            raise BindingError("materialization arguments are incomplete")
        assert args.private_root is not None
        assert args.executable is not None
        assert args.source_root is not None
        assert args.expected_source_root is not None
        assert args.expected_source_root_device is not None
        assert args.expected_source_root_inode is not None
        assert args.commit is not None
        assert args.fingerprint is not None
        (
            executable,
            executable_sha256,
            provenance,
            provenance_sha256,
            provenance_device,
            provenance_inode,
        ) = materialize(
            private_root=args.private_root,
            executable=args.executable,
            source_root=args.source_root,
            expected_source_root=args.expected_source_root,
            expected_source_root_device=args.expected_source_root_device,
            expected_source_root_inode=args.expected_source_root_inode,
            dashboard_build_receipt_path=args.dashboard_build_receipt,
            commit=args.commit,
            fingerprint=args.fingerprint,
        )
        print(RECEIPT_SCHEMA)
        print(executable)
        print(executable_sha256)
        print(provenance)
        print(provenance_sha256)
        print(provenance_device)
        print(provenance_inode)
    except (BindingError, OSError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
