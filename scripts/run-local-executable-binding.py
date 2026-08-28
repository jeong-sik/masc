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
PROVENANCE_SCHEMA = "masc.run-local-executable-identity.v1"
SOURCE_ROOT_RECEIPT_SCHEMA = "masc.run-local-source-root.v1"
DASHBOARD_BUILD_RECEIPT_SCHEMA = "masc.run-local-dashboard-build.v1"
DASHBOARD_BUILD_INPUT_SCHEMA = "masc.run-local-dashboard-build-input.v1"
DASHBOARD_BUILD_RUNTIME_SCHEMA = "masc.run-local-dashboard-build-runtime.v1"
DASHBOARD_PACKAGE_MANAGER_RECEIPT_SCHEMA = "masc.run-local-dashboard-package-manager.v1"
DASHBOARD_BUILD_PRODUCER = (
    "scripts/build-dashboard-if-needed.sh --prepare-exact + --build-exact"
)
DASHBOARD_BUILD_MODE = "production"
DASHBOARD_BUILD_UNSET_ENVIRONMENT = [
    "BUNDLE_REPORT",
    "MASC_DASHBOARD_PROXY_TARGET",
    "NODE_OPTIONS",
]


class BindingError(RuntimeError):
    pass


DASHBOARD_RUNTIME_IDENTITY_FIELDS = (
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
    "node_executable",
    "node_executable_sha256",
    "node_version",
    "node_platform",
    "node_arch",
    "package_manager_kind",
    "package_manager_executable",
    "package_manager_executable_sha256",
    "pnpm_version",
    "environment_path",
    "environment_path_identity_sha256",
    "environment_path_executable_sha256",
    "environment_path_executable_count",
    "environment_profile_sha256",
)

DASHBOARD_BUILD_INPUT_FIELDS = (
    "schema",
    *DASHBOARD_RUNTIME_IDENTITY_FIELDS,
    "build_mode",
    "vite_version",
    "installed_graph_metadata_sha256",
    "installed_graph_metadata_count",
)


def is_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def is_git_oid(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) in (40, 64)
        and all(character in "0123456789abcdef" for character in value)
    )


def require_dashboard_phase_receipt(
    receipt: dict[str, object], *, runtime: bool
) -> None:
    expected_fields = (
        ("schema", *DASHBOARD_RUNTIME_IDENTITY_FIELDS)
        if runtime
        else DASHBOARD_BUILD_INPUT_FIELDS
    )
    if set(receipt) != set(expected_fields):
        raise BindingError("dashboard phase receipt fields differ")
    expected_schema = (
        DASHBOARD_BUILD_RUNTIME_SCHEMA if runtime else DASHBOARD_BUILD_INPUT_SCHEMA
    )
    if receipt["schema"] != expected_schema:
        raise BindingError("dashboard phase receipt schema differs")
    integer_fields = {
        "source_root_device",
        "source_root_inode",
        "input_file_count",
        "environment_path_executable_count",
        "installed_graph_metadata_count",
    }
    for field in integer_fields.intersection(receipt):
        value = receipt[field]
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise BindingError(f"dashboard phase receipt type differs: {field}")
    if not isinstance(receipt["input_matches_head"], bool):
        raise BindingError("dashboard phase receipt type differs: input_matches_head")
    for field, value in receipt.items():
        if field in integer_fields or field == "input_matches_head":
            continue
        if not isinstance(value, str) or not value:
            raise BindingError(f"dashboard phase receipt type differs: {field}")
    for field in (
        "input_sha256",
        "lock_sha256",
        "node_executable_sha256",
        "package_manager_executable_sha256",
        "environment_path_identity_sha256",
        "environment_path_executable_sha256",
        "environment_profile_sha256",
        "installed_graph_metadata_sha256",
    ):
        if field in receipt and not is_sha256(receipt[field]):
            raise BindingError(f"dashboard phase receipt digest differs: {field}")
    for field in ("source_commit", "head_tree", "index_tree"):
        if not is_git_oid(receipt[field]):
            raise BindingError(f"dashboard phase receipt git identity differs: {field}")
    if receipt["package_manager_kind"] not in ("pnpm", "corepack"):
        raise BindingError("dashboard phase package-manager kind differs")
    if not runtime and receipt["build_mode"] != DASHBOARD_BUILD_MODE:
        raise BindingError("dashboard phase build mode differs")
    for field in (
        "source_root",
        "node_executable",
        "package_manager_executable",
    ):
        try:
            canonical = Path(str(receipt[field])).resolve(strict=True)
        except OSError as error:
            raise BindingError(
                f"dashboard phase canonical path differs: {field}"
            ) from error
        if str(canonical) != receipt[field]:
            raise BindingError(f"dashboard phase canonical path differs: {field}")
    path_parts = str(receipt["environment_path"]).split(os.pathsep)
    if not path_parts or any(not part for part in path_parts):
        raise BindingError("dashboard phase PATH is empty")
    canonical_parts: list[str] = []
    for part in path_parts:
        try:
            canonical_part = Path(part).resolve(strict=True)
        except OSError as error:
            raise BindingError("dashboard phase PATH is not canonical") from error
        if not canonical_part.is_dir() or str(canonical_part) != part:
            raise BindingError("dashboard phase PATH is not canonical")
        canonical_parts.append(part)
    if len(set(canonical_parts)) != len(canonical_parts):
        raise BindingError("dashboard phase PATH contains duplicates")
    required_directories = {
        str(Path(str(receipt["node_executable"])).parent),
        str(Path(str(receipt["package_manager_executable"])).parent),
    }
    if not required_directories.issubset(canonical_parts):
        raise BindingError("dashboard phase PATH omits selected runtime")


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


def path_executable_surface(
    path_directories: list[dict[str, object]],
) -> tuple[str, int]:
    def capture() -> list[dict[str, object]]:
        inventory: list[dict[str, object]] = []
        for directory in path_directories:
            directory_path = Path(str(directory["path"]))
            try:
                before_directory = directory_path.stat()
                children = sorted(
                    os.scandir(directory_path), key=lambda entry: entry.name
                )
                for child in children:
                    try:
                        child.name.encode("utf-8")
                    except UnicodeEncodeError as error:
                        raise BindingError(
                            "dashboard PATH entry name is not UTF-8"
                        ) from error
                    child_path = Path(child.path)
                    child_info = child_path.lstat()
                    if stat.S_ISREG(child_info.st_mode):
                        if not child_info.st_mode & 0o111:
                            continue
                        try:
                            payload, opened_info = read_regular_file_exact(child_path)
                        except PermissionError:
                            inventory.append(
                                {
                                    "directory": str(directory_path),
                                    "name": child.name,
                                    "type": "unreadable_regular",
                                    "device": child_info.st_dev,
                                    "inode": child_info.st_ino,
                                    "mode": stat.S_IMODE(child_info.st_mode),
                                    "owner": child_info.st_uid,
                                    "size": child_info.st_size,
                                    "mtime_ns": child_info.st_mtime_ns,
                                    "ctime_ns": child_info.st_ctime_ns,
                                }
                            )
                            continue
                        if not same_stat_identity(child_info, opened_info):
                            raise BindingError(
                                "dashboard PATH executable changed while reading"
                            )
                        inventory.append(
                            {
                                "directory": str(directory_path),
                                "name": child.name,
                                "type": "regular",
                                "device": opened_info.st_dev,
                                "inode": opened_info.st_ino,
                                "mode": stat.S_IMODE(opened_info.st_mode),
                                "owner": opened_info.st_uid,
                                "size": opened_info.st_size,
                                "sha256": digest_bytes(payload),
                            }
                        )
                    elif stat.S_ISLNK(child_info.st_mode):
                        try:
                            link_target = os.readlink(child_path)
                            link_target.encode("utf-8")
                        except UnicodeEncodeError as error:
                            raise BindingError(
                                "dashboard PATH symlink target is not UTF-8"
                            ) from error
                        try:
                            target = child_path.resolve(strict=True)
                        except OSError:
                            inventory.append(
                                {
                                    "directory": str(directory_path),
                                    "name": child.name,
                                    "type": "unresolved_symlink",
                                    "mode": stat.S_IMODE(child_info.st_mode),
                                    "owner": child_info.st_uid,
                                    "link_target": link_target,
                                }
                            )
                            continue
                        try:
                            target_text = str(target)
                            target_text.encode("utf-8")
                        except UnicodeEncodeError as error:
                            raise BindingError(
                                "dashboard PATH symlink target is not UTF-8"
                            ) from error
                        target_info = target.stat()
                        if not stat.S_ISREG(target_info.st_mode) or not (
                            target_info.st_mode & 0o111
                        ):
                            continue
                        try:
                            payload, opened_info = read_regular_file_exact(target)
                        except PermissionError:
                            inventory.append(
                                {
                                    "directory": str(directory_path),
                                    "name": child.name,
                                    "type": "unreadable_symlink_target",
                                    "mode": stat.S_IMODE(child_info.st_mode),
                                    "owner": child_info.st_uid,
                                    "link_target": link_target,
                                    "target": target_text,
                                    "target_device": target_info.st_dev,
                                    "target_inode": target_info.st_ino,
                                    "target_mode": stat.S_IMODE(target_info.st_mode),
                                    "target_owner": target_info.st_uid,
                                    "target_size": target_info.st_size,
                                    "target_mtime_ns": target_info.st_mtime_ns,
                                    "target_ctime_ns": target_info.st_ctime_ns,
                                }
                            )
                            continue
                        if not same_stat_identity(target_info, opened_info):
                            raise BindingError(
                                "dashboard PATH symlink target changed while reading"
                            )
                        inventory.append(
                            {
                                "directory": str(directory_path),
                                "name": child.name,
                                "type": "symlink",
                                "mode": stat.S_IMODE(child_info.st_mode),
                                "owner": child_info.st_uid,
                                "link_target": link_target,
                                "target": target_text,
                                "target_device": opened_info.st_dev,
                                "target_inode": opened_info.st_ino,
                                "target_mode": stat.S_IMODE(opened_info.st_mode),
                                "target_owner": opened_info.st_uid,
                                "target_size": opened_info.st_size,
                                "target_sha256": digest_bytes(payload),
                            }
                        )
                after_directory = directory_path.stat()
            except OSError as error:
                raise BindingError(
                    f"dashboard PATH inventory failed: {directory_path}"
                ) from error
            if not same_stat_identity(before_directory, after_directory):
                raise BindingError("dashboard PATH directory changed while reading")
        return inventory

    inventory = capture()
    return canonical_json_digest(inventory), len(inventory)


def dashboard_runtime_selection(
    *,
    package_manager_executable: Path | None = None,
    package_manager_kind: str | None = None,
    node_executable: Path | None = None,
    environment_path: str | None = None,
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
    path_directories: list[dict[str, object]] = []
    seen_directories: set[str] = set()
    if environment_path is not None:
        candidates = environment_path.split(os.pathsep)
        if any(candidate == "" for candidate in candidates):
            raise BindingError("dashboard build PATH contains an empty entry")
    else:
        ambient_candidates = [
            candidate if candidate else os.getcwd()
            for candidate in os.environ.get("PATH", "").split(os.pathsep)
        ]
        candidates = [
            str(node_path.parent),
            str(package_manager_path.parent),
            *ambient_candidates,
        ]
    for candidate in candidates:
        try:
            canonical = Path(candidate).resolve(strict=True)
            info = canonical.stat()
        except OSError:
            continue
        canonical_text = str(canonical)
        if not stat.S_ISDIR(info.st_mode) or canonical_text in seen_directories:
            continue
        seen_directories.add(canonical_text)
        path_directories.append(
            {
                "path": canonical_text,
                "device": info.st_dev,
                "inode": info.st_ino,
                "mode": stat.S_IMODE(info.st_mode),
                "owner": info.st_uid,
            }
        )
    build_path = os.pathsep.join(str(entry["path"]) for entry in path_directories)
    if environment_path is not None and build_path != environment_path:
        raise BindingError("dashboard build PATH identity differs")
    executable_sha256, executable_count = path_executable_surface(path_directories)
    build_environment = os.environ.copy()
    for name in tuple(build_environment):
        if name.startswith("VITE_") or name in DASHBOARD_BUILD_UNSET_ENVIRONMENT:
            build_environment.pop(name, None)
    build_environment["NODE_ENV"] = DASHBOARD_BUILD_MODE
    build_environment["PATH"] = build_path
    node_version = subprocess.run(
        [str(node_path), "--version"],
        check=True,
        capture_output=True,
        text=True,
        env=build_environment,
    ).stdout.strip()
    node_platform_arch = subprocess.run(
        [str(node_path), "-p", 'process.platform + "\\n" + process.arch'],
        check=True,
        capture_output=True,
        text=True,
        env=build_environment,
    ).stdout.splitlines()
    if len(node_platform_arch) != 2:
        raise BindingError("Node platform identity is unavailable")
    package_manager = [str(node_path), str(package_manager_path)]
    if package_manager_kind == "corepack":
        package_manager.append("pnpm")
    pnpm_version = subprocess.run(
        [*package_manager, "--version"],
        check=True,
        capture_output=True,
        text=True,
        env=build_environment,
    ).stdout.strip()
    environment_profile = {
        "set": {"NODE_ENV": "production", "PATH": build_path},
        "path_identity": path_directories,
        "path_executable_sha256": executable_sha256,
        "path_executable_count": executable_count,
        "unset_exact": DASHBOARD_BUILD_UNSET_ENVIRONMENT,
        "unset_prefix": ["VITE_"],
    }
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
        "environment_path": build_path,
        "environment_path_identity_sha256": canonical_json_digest(path_directories),
        "environment_path_executable_sha256": executable_sha256,
        "environment_path_executable_count": executable_count,
        "environment_profile_sha256": canonical_json_digest(environment_profile),
    }


def dashboard_runtime_identity(
    source_root: Path,
    *,
    package_manager_executable: Path | None = None,
    package_manager_kind: str | None = None,
    node_executable: Path | None = None,
    environment_path: str | None = None,
) -> dict[str, object]:
    selection = dashboard_runtime_selection(
        package_manager_executable=package_manager_executable,
        package_manager_kind=package_manager_kind,
        node_executable=node_executable,
        environment_path=environment_path,
    )
    package_manager = [
        str(selection["node_executable"]),
        str(selection["package_manager_executable"]),
    ]
    if selection["package_manager_kind"] == "corepack":
        package_manager.append("pnpm")
    build_environment = os.environ.copy()
    for name in tuple(build_environment):
        if name.startswith("VITE_") or name in DASHBOARD_BUILD_UNSET_ENVIRONMENT:
            build_environment.pop(name, None)
    build_environment["NODE_ENV"] = DASHBOARD_BUILD_MODE
    build_environment["PATH"] = str(selection["environment_path"])
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
        env=build_environment,
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
        **selection,
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
    environment_path: str | None = None,
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
        environment_path=environment_path,
    )
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
        **runtime,
    }


def dashboard_build_runtime_receipt(
    source_root: Path,
    *,
    package_manager_executable: Path | None = None,
    package_manager_kind: str | None = None,
    node_executable: Path | None = None,
    environment_path: str | None = None,
) -> dict[str, object]:
    canonical, info = inspect_source_root(source_root)
    source_commit = git_output(canonical, ["rev-parse", "HEAD"])
    head_tree = git_output(canonical, ["rev-parse", "HEAD^{tree}"])
    index_tree = git_output(canonical, ["write-tree"])
    input_sha256, input_file_count, input_matches_head, lock_sha256 = (
        dashboard_input_identity(canonical)
    )
    return {
        "schema": DASHBOARD_BUILD_RUNTIME_SCHEMA,
        "source_root": str(canonical),
        "source_root_device": info.st_dev,
        "source_root_inode": info.st_ino,
        "source_commit": source_commit,
        "head_tree": head_tree,
        "index_tree": index_tree,
        "input_sha256": input_sha256,
        "input_file_count": input_file_count,
        "input_matches_head": input_matches_head,
        "lock_sha256": lock_sha256,
        **dashboard_runtime_selection(
            package_manager_executable=package_manager_executable,
            package_manager_kind=package_manager_kind,
            node_executable=node_executable,
            environment_path=environment_path,
        ),
    }


def require_dashboard_runtime_transition(
    runtime_receipt: dict[str, object], build_input_receipt: dict[str, object]
) -> None:
    require_dashboard_phase_receipt(runtime_receipt, runtime=True)
    require_dashboard_phase_receipt(build_input_receipt, runtime=False)
    for field in DASHBOARD_RUNTIME_IDENTITY_FIELDS:
        if runtime_receipt.get(field) != build_input_receipt.get(field):
            raise BindingError(f"dashboard prepared runtime differs: {field}")


def verify_dashboard_runtime_receipt(
    receipt_path: Path,
    *,
    package_manager_executable: Path,
    package_manager_kind: str,
    node_executable: Path,
    environment_path: str,
) -> dict[str, object]:
    payload, _info = read_regular_file_exact(receipt_path)
    receipt = json.loads(payload)
    if not isinstance(receipt, dict):
        raise BindingError("dashboard runtime receipt is not an object")
    require_dashboard_phase_receipt(receipt, runtime=True)
    source_root, source_info = inspect_source_root(Path(str(receipt["source_root"])))
    if (
        source_info.st_dev != receipt["source_root_device"]
        or source_info.st_ino != receipt["source_root_inode"]
    ):
        raise BindingError("dashboard runtime source-root identity differs")
    current = dashboard_build_runtime_receipt(
        source_root,
        package_manager_executable=package_manager_executable,
        package_manager_kind=package_manager_kind,
        node_executable=node_executable,
        environment_path=environment_path,
    )
    if current != receipt:
        raise BindingError("dashboard runtime receipt differs from current identity")
    return receipt


def verify_dashboard_build_input_receipt(
    receipt_path: Path,
    *,
    runtime_receipt_path: Path,
    package_manager_executable: Path,
    package_manager_kind: str,
    node_executable: Path,
    environment_path: str,
) -> dict[str, object]:
    payload, _info = read_regular_file_exact(receipt_path)
    receipt = json.loads(payload)
    if not isinstance(receipt, dict):
        raise BindingError("dashboard build input receipt is not an object")
    require_dashboard_phase_receipt(receipt, runtime=False)
    runtime_payload, _runtime_info = read_regular_file_exact(runtime_receipt_path)
    runtime_receipt = json.loads(runtime_payload)
    if not isinstance(runtime_receipt, dict):
        raise BindingError("dashboard runtime receipt is not an object")
    require_dashboard_runtime_transition(runtime_receipt, receipt)
    current = dashboard_build_input_receipt(
        Path(str(receipt["source_root"])),
        package_manager_executable=package_manager_executable,
        package_manager_kind=package_manager_kind,
        node_executable=node_executable,
        environment_path=environment_path,
    )
    if current != receipt:
        raise BindingError(
            "dashboard build input receipt differs from current identity"
        )
    return receipt


def dashboard_build_receipt(
    source_root: Path,
    commit: str,
    expected_input: dict[str, object],
    *,
    package_manager_executable: Path | None = None,
    package_manager_kind: str | None = None,
    node_executable: Path | None = None,
    environment_path: str | None = None,
) -> dict[str, object]:
    require_dashboard_phase_receipt(expected_input, runtime=False)
    current_input = dashboard_build_input_receipt(
        source_root,
        package_manager_executable=package_manager_executable,
        package_manager_kind=package_manager_kind,
        node_executable=node_executable,
        environment_path=environment_path,
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
        "environment_path_identity_sha256": current_input[
            "environment_path_identity_sha256"
        ],
        "environment_path_executable_sha256": current_input[
            "environment_path_executable_sha256"
        ],
        "environment_path_executable_count": current_input[
            "environment_path_executable_count"
        ],
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


def materialize(
    *, private_root: Path, executable: Path, commit: str, fingerprint: str
) -> tuple[Path, str, Path, str, int, int]:
    if not executable.is_file() or executable.is_symlink():
        raise BindingError("Dune executable is not a regular file")
    if len(commit) != 40 or any(char not in "0123456789abcdef" for char in commit):
        raise BindingError("binary commit is not a full Git SHA")
    if len(fingerprint) != 64 or any(
        char not in "0123456789abcdef" for char in fingerprint
    ):
        raise BindingError("build-input fingerprint is not SHA-256")
    ensure_private_directory(private_root)
    with materialization_lock(private_root):
        return materialize_locked(
            private_root=private_root,
            executable=executable,
            commit=commit,
            fingerprint=fingerprint,
        )


def materialize_locked(
    *, private_root: Path, executable: Path, commit: str, fingerprint: str
) -> tuple[Path, str, Path, str, int, int]:
    executable_dir = private_root / "executables"
    provenance_dir = private_root / "provenance"
    ensure_private_directory(executable_dir)
    ensure_private_directory(provenance_dir)

    executable_payload = executable.read_bytes()
    executable_sha256 = digest_bytes(executable_payload)
    bound_executable = executable_dir / f"{executable_sha256}-main_eio.exe"
    executable_info = write_once(bound_executable, executable_payload, 0o500)
    if digest_file(bound_executable) != executable_sha256:
        raise BindingError("materialized executable digest differs")

    provenance_payload = (
        json.dumps(
            {
                "schema": PROVENANCE_SCHEMA,
                "binary_commit": commit,
                "build_input_fingerprint": fingerprint,
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
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--inspect-source-root", type=Path)
    action.add_argument("--capture-dashboard-build-input", action="store_true")
    action.add_argument("--capture-dashboard-build-runtime", action="store_true")
    action.add_argument("--emit-dashboard-build-receipt", action="store_true")
    action.add_argument("--read-dashboard-package-manager", type=Path)
    action.add_argument("--verify-dashboard-build-runtime", action="store_true")
    action.add_argument("--verify-dashboard-build-input", action="store_true")
    action.add_argument("--verify-dashboard-runtime-transition", action="store_true")
    parser.add_argument("--dashboard-build-runtime-receipt", type=Path)
    parser.add_argument("--dashboard-build-input-receipt", type=Path)
    parser.add_argument("--dashboard-package-manager-executable", type=Path)
    parser.add_argument("--dashboard-node-executable", type=Path)
    parser.add_argument("--dashboard-node-sha256")
    parser.add_argument("--dashboard-package-manager-sha256")
    parser.add_argument("--dashboard-environment-path")
    parser.add_argument("--dashboard-environment-profile-sha256")
    parser.add_argument(
        "--dashboard-package-manager-kind", choices=("pnpm", "corepack")
    )
    parser.add_argument("--private-root", type=Path)
    parser.add_argument("--executable", type=Path)
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--expected-source-root", type=Path)
    parser.add_argument("--expected-source-root-device", type=int)
    parser.add_argument("--expected-source-root-inode", type=int)
    parser.add_argument("--commit")
    parser.add_argument("--fingerprint")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        expected_source_values = (
            args.expected_source_root,
            args.expected_source_root_device,
            args.expected_source_root_inode,
        )
        if any(value is not None for value in expected_source_values):
            if any(value is None for value in expected_source_values):
                raise BindingError("expected source-root identity is incomplete")
            assert args.source_root is not None
            assert args.expected_source_root is not None
            assert args.expected_source_root_device is not None
            assert args.expected_source_root_inode is not None
            require_source_root_identity(
                args.source_root,
                expected_path=args.expected_source_root,
                expected_device=args.expected_source_root_device,
                expected_inode=args.expected_source_root_inode,
            )
        if args.verify_dashboard_build_runtime:
            runtime_values = (
                args.dashboard_build_runtime_receipt,
                args.dashboard_node_executable,
                args.dashboard_node_sha256,
                args.dashboard_package_manager_executable,
                args.dashboard_package_manager_sha256,
                args.dashboard_package_manager_kind,
                args.dashboard_environment_path,
                args.dashboard_environment_profile_sha256,
            )
            if any(value is None for value in runtime_values):
                raise BindingError("dashboard build runtime identity is incomplete")
            assert args.dashboard_node_executable is not None
            assert args.dashboard_node_sha256 is not None
            assert args.dashboard_package_manager_executable is not None
            assert args.dashboard_package_manager_sha256 is not None
            assert args.dashboard_package_manager_kind is not None
            assert args.dashboard_environment_path is not None
            assert args.dashboard_environment_profile_sha256 is not None
            assert args.dashboard_build_runtime_receipt is not None
            receipt = verify_dashboard_runtime_receipt(
                args.dashboard_build_runtime_receipt,
                package_manager_executable=args.dashboard_package_manager_executable,
                package_manager_kind=args.dashboard_package_manager_kind,
                node_executable=args.dashboard_node_executable,
                environment_path=args.dashboard_environment_path,
            )
            if (
                receipt["node_executable_sha256"] != args.dashboard_node_sha256
                or receipt["package_manager_executable_sha256"]
                != args.dashboard_package_manager_sha256
                or receipt["environment_profile_sha256"]
                != args.dashboard_environment_profile_sha256
            ):
                raise BindingError("dashboard build environment identity differs")
            return 0
        if args.verify_dashboard_build_input:
            input_values = (
                args.dashboard_build_input_receipt,
                args.dashboard_build_runtime_receipt,
                args.dashboard_node_executable,
                args.dashboard_package_manager_executable,
                args.dashboard_package_manager_kind,
                args.dashboard_environment_path,
            )
            if any(value is None for value in input_values):
                raise BindingError("dashboard build input identity is incomplete")
            assert args.dashboard_build_input_receipt is not None
            assert args.dashboard_build_runtime_receipt is not None
            assert args.dashboard_node_executable is not None
            assert args.dashboard_package_manager_executable is not None
            assert args.dashboard_package_manager_kind is not None
            assert args.dashboard_environment_path is not None
            verify_dashboard_build_input_receipt(
                args.dashboard_build_input_receipt,
                runtime_receipt_path=args.dashboard_build_runtime_receipt,
                package_manager_executable=args.dashboard_package_manager_executable,
                package_manager_kind=args.dashboard_package_manager_kind,
                node_executable=args.dashboard_node_executable,
                environment_path=args.dashboard_environment_path,
            )
            return 0
        if args.verify_dashboard_runtime_transition:
            if (
                args.dashboard_build_runtime_receipt is None
                or args.dashboard_build_input_receipt is None
            ):
                raise BindingError(
                    "dashboard runtime transition receipts are incomplete"
                )
            runtime_receipt = json.loads(
                args.dashboard_build_runtime_receipt.read_text()
            )
            build_input_receipt = json.loads(
                args.dashboard_build_input_receipt.read_text()
            )
            if not isinstance(runtime_receipt, dict) or not isinstance(
                build_input_receipt, dict
            ):
                raise BindingError("dashboard runtime transition receipt is invalid")
            require_dashboard_runtime_transition(runtime_receipt, build_input_receipt)
            return 0
        if args.read_dashboard_package_manager is not None:
            receipt = json.loads(args.read_dashboard_package_manager.read_text())
            if not isinstance(receipt, dict):
                raise BindingError("dashboard build input receipt is not an object")
            if receipt.get("schema") != DASHBOARD_BUILD_RUNTIME_SCHEMA:
                raise BindingError("dashboard build runtime receipt schema differs")
            require_dashboard_phase_receipt(receipt, runtime=True)
            kind = receipt.get("package_manager_kind")
            executable = receipt.get("package_manager_executable")
            executable_sha256 = receipt.get("package_manager_executable_sha256")
            node_executable = receipt.get("node_executable")
            node_sha256 = receipt.get("node_executable_sha256")
            environment_path = receipt.get("environment_path")
            environment_profile_sha256 = receipt.get("environment_profile_sha256")
            if kind not in ("pnpm", "corepack") or not isinstance(executable, str):
                raise BindingError("dashboard package-manager receipt is invalid")
            canonical = Path(executable).resolve(strict=True)
            if (
                not isinstance(node_executable, str)
                or not isinstance(environment_path, str)
                or not isinstance(environment_profile_sha256, str)
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
            print(environment_profile_sha256)
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
        if args.capture_dashboard_build_runtime:
            if args.source_root is None:
                raise BindingError("dashboard build runtime arguments are incomplete")
            receipt = dashboard_build_runtime_receipt(args.source_root)
            if args.expected_source_root is not None:
                require_source_root_identity(
                    args.source_root,
                    expected_path=args.expected_source_root,
                    expected_device=int(args.expected_source_root_device),
                    expected_inode=int(args.expected_source_root_inode),
                )
            print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
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
            receipt = dashboard_build_receipt(
                args.source_root,
                args.commit,
                expected_input,
                package_manager_executable=args.dashboard_package_manager_executable,
                package_manager_kind=args.dashboard_package_manager_kind,
                node_executable=args.dashboard_node_executable,
                environment_path=args.dashboard_environment_path,
            )
            if args.expected_source_root is not None:
                require_source_root_identity(
                    args.source_root,
                    expected_path=args.expected_source_root,
                    expected_device=int(args.expected_source_root_device),
                    expected_inode=int(args.expected_source_root_inode),
                )
            print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
            return 0
        if args.capture_dashboard_build_input:
            if args.source_root is None:
                raise BindingError("dashboard build input arguments are incomplete")
            receipt = dashboard_build_input_receipt(
                args.source_root,
                package_manager_executable=args.dashboard_package_manager_executable,
                package_manager_kind=args.dashboard_package_manager_kind,
                node_executable=args.dashboard_node_executable,
                environment_path=args.dashboard_environment_path,
            )
            if args.expected_source_root is not None:
                require_source_root_identity(
                    args.source_root,
                    expected_path=args.expected_source_root,
                    expected_device=int(args.expected_source_root_device),
                    expected_inode=int(args.expected_source_root_inode),
                )
            print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
            return 0
        required = (
            args.private_root,
            args.executable,
            args.commit,
            args.fingerprint,
        )
        if any(value is None for value in required):
            raise BindingError("materialization arguments are incomplete")
        assert args.private_root is not None
        assert args.executable is not None
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
