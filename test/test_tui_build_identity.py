"""Exercise copied TUI/server informational CLIs without a terminal or runtime.

The expectation is the generated stamp linked into the executables. Git is a
sentinel that records and rejects every invocation, including module startup.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import tempfile


def read_stamp(path: Path) -> tuple[str | None, int | None]:
    source = path.read_text().strip()
    match = re.fullmatch(
        r'let commit : string option = (?:Some "([0-9a-f]+)"|None)\n'
        r'let commit_unix_ts : int64 option = (?:Some ([0-9]+)L|None)', source)
    if match is None:
        raise AssertionError(f"Unrecognized generated build stamp: {source!r}")
    commit, timestamp = match.groups()
    if commit is None and timestamp is not None:
        raise AssertionError("A timestamp must belong to an embedded commit")
    return commit, int(timestamp) if timestamp is not None else None


def run(binary: Path, server_binary: Path, stamp: str | None,
        timestamp: int | None, expected_version: str) -> None:
    with tempfile.TemporaryDirectory(prefix="masc-tui-build-identity-") as temporary:
        root = Path(temporary)
        outside = root / "outside-repository"
        unrelated = root / "unrelated-repository"
        outside.mkdir()
        unrelated.mkdir()
        (unrelated / ".git").mkdir()
        copies = [("tui", root / "masc-tui"), ("server", root / "masc")]
        for (_, copied), source in zip(copies, (binary, server_binary)):
            shutil.copy2(source, copied)
        blocked_base = root / "not-a-directory"
        blocked_base.write_text("an informational flag must never resolve below this file")
        fake_bin = root / "fake-bin"
        fake_bin.mkdir()
        probes = root / "git-probes.log"
        probes.write_text("")
        fake_git = fake_bin / "git"
        fake_git.write_text(
            "#!/bin/sh\n"
            f"printf '%s\\n' \"$*\" >> {shlex.quote(str(probes))}\n"
            "exit 97\n"
        )
        fake_git.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = str(fake_bin)
        environment["MASC_BASE_PATH"] = str(blocked_base / "runtime")
        environment["MASC_BASE_PATH_INPUT"] = str(blocked_base / "runtime")

        def footprint() -> set[str]:
            return {str(path.relative_to(root)) for path in root.rglob("*")}

        initial_paths = footprint()
        readings = []
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            listener.setblocking(False)
            port = listener.getsockname()[1]
            cases = [
                (kind, copied, cwd, flag)
                for kind, copied in copies
                for cwd in (outside, unrelated)
                for flag in ("--help", "--version", "--build-commit")
            ]
            for kind, copied, cwd, flag in cases:
                probes.write_text("")
                argv = ([str(copied), "--base-path", str(blocked_base / "runtime"),
                         "--port", str(port), flag] if kind == "tui" else
                        [str(copied), {"--help": "--help=plain",
                                       "--build-commit": "build-commit"}.get(flag, flag)])
                result = subprocess.run(
                    argv,
                    cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20,
                )
                calls = probes.read_text().splitlines()
                if calls:
                    raise AssertionError(f"{kind} {flag} invoked Git before reporting its embedded identity: {calls!r}")
                if footprint() != initial_paths:
                    raise AssertionError(f"{flag} wrote runtime/workspace paths: {footprint() - initial_paths}")
                try:
                    connection, _ = listener.accept()
                except BlockingIOError:
                    pass
                else:
                    connection.close()
                    raise AssertionError(f"{flag} attempted to connect to the runtime")
                if flag == "--help":
                    if result.returncode != 0 or b"build-commit" not in result.stdout or result.stderr:
                        raise AssertionError(f"CLI help failed: {result!r}")
                else:
                    expected_stdout = (expected_version + "\n").encode() if flag == "--version" else (
                        (stamp + "\n").encode() if stamp is not None else b""
                    )
                    expected_code = 1 if flag == "--build-commit" and stamp is None else 0
                    expected_stderr = (
                        b"build commit is not embedded\n" if expected_code == 1 else b""
                    )
                    if (result.returncode, result.stdout, result.stderr) != (expected_code, expected_stdout, expected_stderr):
                        raise AssertionError(f"{flag} did not report the embedded build: {result!r}")
                readings.append({"binary": kind, "cwd": cwd.name, "flag": flag,
                                 "exit": result.returncode, "git_probe_count": len(calls),
                                 "git_probe_argv": calls, "stdout": result.stdout.decode(errors="replace")})
        print(json.dumps({"kind": "tui-build-identity-cli", "expected_embedded_commit": stamp,
                          "expected_embedded_commit_unix_ts": timestamp,
                          "no_tui_endpoint_connection": True,
                          "no_fixture_workspace_paths_created": True,
                          "no_tty": True, "no_git_probes": True, "readings": readings}, indent=2))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("generated_stamp", type=Path)
    parser.add_argument("--server-binary", required=True, type=Path)
    # Dune supplies the same package version used by linked build metadata.
    parser.add_argument("--expected-version", required=True)
    arguments = parser.parse_args()
    stamp, timestamp = read_stamp(arguments.generated_stamp)
    run(arguments.binary.resolve(), arguments.server_binary.resolve(), stamp, timestamp,
        arguments.expected_version)
    print("tui build identity CLI: PASS")


if __name__ == "__main__":
    main()
