"""Exercise the real TUI's informational CLI without a terminal or runtime.

The stamp expectation comes from the same generated source linked into the
binary. A fake Git repository deliberately reports a different HEAD. Existing
Build_identity module-initialization probes are measured against --help; this
suite does not describe those existing subprocesses as a probe-free startup.
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


def read_stamp(path: Path) -> str | None:
    source = path.read_text().strip()
    if source == "let commit : string option = None":
        return None
    match = re.fullmatch(r'let commit : string option = Some "([0-9a-f]+)"', source)
    if match is None:
        raise AssertionError(f"Unrecognized generated build stamp: {source!r}")
    return match.group(1)


def run(binary: Path, stamp: str | None, expected_version: str) -> None:
    with tempfile.TemporaryDirectory(prefix="masc-tui-build-identity-") as temporary:
        root = Path(temporary)
        cwd = root / "unrelated-repository"
        cwd.mkdir()
        (cwd / ".git").mkdir()
        copied_binary = root / "masc-tui"
        shutil.copy2(binary, copied_binary)
        blocked_base = root / "not-a-directory"
        blocked_base.write_text("an informational flag must never resolve below this file")
        fake_bin = root / "fake-bin"
        fake_bin.mkdir()
        probes = root / "git-probes.log"
        probes.write_text("")
        fake_head = "f" * 40 if stamp != "f" * 40 else "e" * 40
        fake_git = fake_bin / "git"
        fake_git.write_text(
            "#!/bin/sh\n"
            f"printf '%s\\n' \"$*\" >> {shlex.quote(str(probes))}\n"
            "case \"$*\" in\n"
            f"  *rev-parse*) printf '%s\\n' {shlex.quote(fake_head)} ;;\n"
            "  *log*) printf '%s\\n' 1700000000 ;;\n"
            "  *) exit 1 ;;\n"
            "esac\n"
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
            for flag in ("--help", "--version", "--build-commit"):
                probes.write_text("")
                result = subprocess.run(
                    [str(copied_binary), "--base-path", str(blocked_base / "runtime"),
                     "--port", str(port), flag],
                    cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20,
                )
                calls = probes.read_text().splitlines()
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
                    if result.returncode != 0 or b"--build-commit" not in result.stdout:
                        raise AssertionError(f"CLI help failed: {result!r}")
                    baseline_calls, baseline_stderr = calls, result.stderr
                else:
                    if calls != baseline_calls:
                        raise AssertionError(f"{flag} added Git probes beyond --help: {calls!r} versus {baseline_calls!r}")
                    expected_stdout = (expected_version + "\n").encode() if flag == "--version" else (
                        (stamp + "\n").encode() if stamp is not None else b""
                    )
                    expected_code = 1 if flag == "--build-commit" and stamp is None else 0
                    expected_stderr = baseline_stderr + (
                        b"build commit is not embedded\n" if expected_code == 1 else b""
                    )
                    if (result.returncode, result.stdout, result.stderr) != (expected_code, expected_stdout, expected_stderr):
                        raise AssertionError(f"{flag} did not report the embedded build: {result!r}")
                    if fake_head.encode() in result.stdout:
                        raise AssertionError("The surrounding repository HEAD replaced binary identity")
                readings.append({"flag": flag, "exit": result.returncode, "git_probe_count": len(calls),
                                 "git_probe_argv": calls, "stdout": result.stdout.decode(errors="replace")})
        print(json.dumps({"kind": "tui-build-identity-cli", "expected_embedded_commit": stamp,
                          "no_runtime_connection": True, "no_workspace_writes": True,
                          "no_tty": True, "existing_module_probes": readings}, indent=2))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("generated_stamp", type=Path)
    # Dune supplies the same package version used by linked build metadata.
    parser.add_argument("--expected-version", required=True)
    arguments = parser.parse_args()
    run(arguments.binary.resolve(), read_stamp(arguments.generated_stamp), arguments.expected_version)
    print("tui build identity CLI: PASS")


if __name__ == "__main__":
    main()
