#!/usr/bin/env python3
"""Build an exact-head MASC TUI and emit fail-closed provenance evidence."""

from __future__ import annotations

import argparse
from collections.abc import Callable, Mapping, Sequence
from datetime import datetime, timezone
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Any


SCHEMA = "masc.tui-build-evidence/v1"
GIT_OBJECT_RE = re.compile(r"^[0-9a-f]{40}$")
TARGET = "bin/masc_tui.exe"
PRODUCER = "scripts/dune-local.sh"
ARTIFACT = "masc_tui.exe"
MANIFEST = "build-evidence.json"
INCOMPLETE = "INCOMPLETE"

# Only toolchain and locale values cross the subprocess boundary. In
# particular, no provider, GitHub, HTTP, or MASC credential variables do.
FORWARDED_ENV = (
    "CAML_LD_LIBRARY_PATH",
    "CPATH",
    "HOME",
    "LANG",
    "LC_ALL",
    "LIBRARY_PATH",
    "LOGNAME",
    "MANPATH",
    "OCAMLPATH",
    "OPAMROOT",
    "OPAMSWITCH",
    "PATH",
    "PKG_CONFIG_PATH",
    "SHELL",
    "TERM",
    "TMPDIR",
    "USER",
)

MACH_O_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}


class EvidenceError(RuntimeError):
    pass


CommandRunner = Callable[
    [Sequence[str], Path, Mapping[str, str]], subprocess.CompletedProcess[str]
]


def require(condition: bool, detail: str) -> None:
    if not condition:
        raise EvidenceError(detail)


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def digest_bytes(value: bytes) -> str:
    return sha256(value).hexdigest()


def write_json_atomic(path: Path, value: dict[str, Any]) -> bytes:
    payload = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_bytes(payload)
    temporary.replace(path)
    return payload


def scrubbed_environment(source: Mapping[str, str]) -> dict[str, str]:
    return {name: source[name] for name in FORWARDED_ENV if name in source}


def run_command(
    argv: Sequence[str], cwd: Path, environment: Mapping[str, str]
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(argv),
        cwd=cwd,
        env=dict(environment),
        check=False,
        capture_output=True,
        text=True,
    )


def command_output(
    runner: CommandRunner,
    argv: Sequence[str],
    cwd: Path,
    environment: Mapping[str, str],
    context: str,
) -> str:
    result = runner(argv, cwd, environment)
    require(
        result.returncode == 0,
        f"{context} failed with exit {result.returncode}: {result.stderr.strip()}",
    )
    return result.stdout.strip()


def source_snapshot(
    repo: Path, runner: CommandRunner, environment: Mapping[str, str]
) -> dict[str, Any]:
    head = command_output(
        runner, ("git", "rev-parse", "HEAD"), repo, environment, "git HEAD"
    )
    tree = command_output(
        runner,
        ("git", "rev-parse", "HEAD^{tree}"),
        repo,
        environment,
        "git tree",
    )
    require(GIT_OBJECT_RE.fullmatch(head) is not None, "HEAD is not a Git SHA")
    require(GIT_OBJECT_RE.fullmatch(tree) is not None, "source tree is not a Git SHA")
    status = command_output(
        runner,
        ("git", "status", "--porcelain=v1", "--untracked-files=no"),
        repo,
        environment,
        "git tracked status",
    )
    require(status == "", "tracked source is not clean")
    return {"commit": head, "tree": tree, "tracked_clean": True}


def require_plain_executable(path: Path, context: str) -> os.stat_result:
    require(path.exists(), f"{context} does not exist: {path}")
    require(not path.is_symlink(), f"{context} is a symlink: {path}")
    metadata = path.stat()
    require(stat.S_ISREG(metadata.st_mode), f"{context} is not a regular file: {path}")
    require(os.access(path, os.X_OK), f"{context} is not executable: {path}")
    return metadata


def executable_format(payload: bytes) -> str:
    require(len(payload) >= 4, "TUI executable is too short")
    if payload.startswith(b"\x7fELF"):
        return "elf"
    if payload[:4] in MACH_O_MAGICS:
        return "mach-o"
    raise EvidenceError("TUI executable is not ELF or Mach-O")


def inspect_tui(path: Path, expected_source_sha: str) -> dict[str, Any]:
    metadata = require_plain_executable(path, "TUI executable")
    payload = path.read_bytes()
    occurrences = payload.count(expected_source_sha.encode("ascii"))
    require(occurrences > 0, "TUI executable does not embed exact source SHA")
    return {
        "path": ARTIFACT,
        "bytes": metadata.st_size,
        "sha256": digest_bytes(payload),
        "format": executable_format(payload),
        "executable": True,
        "embedded_source_sha": expected_source_sha,
        "embedded_source_sha_occurrences": occurrences,
    }


def prepare_output(output: Path) -> Path:
    if output.exists():
        require(output.is_dir(), f"output is not a directory: {output}")
        require(not any(output.iterdir()), f"output directory is not empty: {output}")
    else:
        output.mkdir(parents=True)
    marker = output / INCOMPLETE
    marker.write_text("TUI build evidence is incomplete.\n")
    return marker


def producer_identity(repo: Path) -> dict[str, Any]:
    path = repo / PRODUCER
    metadata = require_plain_executable(path, "build producer")
    payload = path.read_bytes()
    return {
        "path": PRODUCER,
        "bytes": metadata.st_size,
        "sha256": digest_bytes(payload),
    }


def produce(
    *,
    repo: Path,
    expected_source_sha: str,
    expected_source_tree: str,
    output: Path,
    environment_source: Mapping[str, str] = os.environ,
    runner: CommandRunner = run_command,
) -> str:
    require(repo.is_absolute(), "repo path must be absolute")
    require(output.is_absolute(), "output path must be absolute")
    require(
        GIT_OBJECT_RE.fullmatch(expected_source_sha) is not None,
        "expected source SHA is not a Git SHA",
    )
    require(
        GIT_OBJECT_RE.fullmatch(expected_source_tree) is not None,
        "expected source tree is not a Git SHA",
    )
    marker = prepare_output(output)
    environment = scrubbed_environment(environment_source)
    before = source_snapshot(repo, runner, environment)
    require(
        before["commit"] == expected_source_sha,
        "source HEAD does not match expected SHA",
    )
    require(
        before["tree"] == expected_source_tree,
        "source tree does not match expected tree",
    )
    with tempfile.TemporaryDirectory(prefix="masc-tui-source-") as source_directory:
        isolated_repo = (Path(source_directory) / "checkout").resolve()
        add_argv = (
            "git",
            "worktree",
            "add",
            "--detach",
            str(isolated_repo),
            expected_source_sha,
        )
        added = runner(add_argv, repo, environment)
        require(
            added.returncode == 0,
            f"isolated source checkout failed with exit {added.returncode}: "
            f"{added.stderr.strip()}",
        )
        try:
            isolated_before = source_snapshot(isolated_repo, runner, environment)
            require(
                isolated_before == before,
                "isolated source snapshot differs from requested source",
            )
            producer = producer_identity(isolated_repo)

            with tempfile.TemporaryDirectory(prefix="masc-tui-build-") as directory:
                build_dir = Path(directory).resolve()
                build_argv = (
                    str(isolated_repo / PRODUCER),
                    "build",
                    "--build-dir",
                    str(build_dir),
                    TARGET,
                )
                build = runner(build_argv, isolated_repo, environment)
                require(
                    build.returncode == 0,
                    f"TUI build failed with exit {build.returncode}: "
                    f"{build.stderr.strip()}",
                )
                built_tui = build_dir / "default" / TARGET
                built_artifact = inspect_tui(built_tui, expected_source_sha)

                copied_tui = output / ARTIFACT
                shutil.copy2(built_tui, copied_tui, follow_symlinks=False)
                artifact = inspect_tui(copied_tui, expected_source_sha)
                require(
                    artifact["bytes"] == built_artifact["bytes"]
                    and artifact["sha256"] == built_artifact["sha256"],
                    "copied TUI does not equal the built artifact",
                )

                probe_argv = (str(copied_tui), "--help")
                probe = runner(probe_argv, isolated_repo, environment)
                require(
                    probe.returncode == 0,
                    f"TUI help probe failed with exit {probe.returncode}: "
                    f"{probe.stderr.strip()}",
                )
                require(
                    "masc-tui" in probe.stdout,
                    "TUI help probe did not identify masc-tui",
                )

                isolated_after = source_snapshot(isolated_repo, runner, environment)
                require(
                    isolated_after == isolated_before,
                    "isolated source snapshot changed during TUI build",
                )
        finally:
            removed = runner(
                ("git", "worktree", "remove", "--force", str(isolated_repo)),
                repo,
                environment,
            )
            require(
                removed.returncode == 0,
                f"isolated source cleanup failed with exit {removed.returncode}: "
                f"{removed.stderr.strip()}",
            )

        manifest = {
            "schema": SCHEMA,
            "captured_at": utc_now(),
            "source": {
                "head": expected_source_sha,
                "tree": expected_source_tree,
                "tracked_checkout_clean": True,
                "expected_commit": expected_source_sha,
                "expected_tree": expected_source_tree,
                "origin": before,
                "before": isolated_before,
                "after": isolated_after,
                "isolation": "detached-temporary-worktree",
            },
            "build": {
                "producer": producer,
                "argv": [PRODUCER, "build", "--build-dir", "<fresh-build-dir>", TARGET],
                "environment": {
                    "policy": "allowlist/v1",
                    "forwarded_names": sorted(environment),
                },
                "returncode": build.returncode,
            },
            "probe": {
                "argv": [ARTIFACT, "--help"],
                "returncode": probe.returncode,
                "stdout_bytes": len(probe.stdout.encode()),
                "stdout_sha256": digest_bytes(probe.stdout.encode()),
            },
            "artifact": artifact,
        }
        manifest_payload = write_json_atomic(output / MANIFEST, manifest)
        marker.unlink()
        return digest_bytes(manifest_payload)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--expected-source-sha", required=True)
    parser.add_argument("--expected-source-tree", required=True)
    parser.add_argument("--out", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        manifest_hash = produce(
            repo=args.repo.resolve(),
            expected_source_sha=args.expected_source_sha,
            expected_source_tree=args.expected_source_tree,
            output=args.out.resolve(),
        )
    except (EvidenceError, OSError) as error:
        print(f"produce-tui-build-evidence: {error}", file=sys.stderr)
        return 1
    print(manifest_hash)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
