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
import stat
import sys


RECEIPT_SCHEMA = "masc.run-local-launch-binding.v1"
PROVENANCE_SCHEMA = "masc.run-local-executable-identity.v1"


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
    parser.add_argument("--private-root", required=True, type=Path)
    parser.add_argument("--executable", required=True, type=Path)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--fingerprint", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
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
