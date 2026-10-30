#!/usr/bin/env python3
"""Exercise a candidate shim's actual config/frame and bind its artifact bytes."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import struct
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shim", type=Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--arch", choices=("arm64", "amd64"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    if source != args.source_commit:
        raise SystemExit("candidate checkout differs from requested source")
    expected_machine = {"arm64": "aarch64", "amd64": "x86_64"}[args.arch]
    if platform.system() != "Linux" or platform.machine() != expected_machine:
        raise SystemExit("shim must be exercised on its native Linux architecture")
    shim = args.shim.resolve(strict=True)
    binary_sha = hashlib.sha256(shim.read_bytes()).hexdigest()
    file_description = subprocess.check_output(["file", str(shim)], text=True).strip()
    if "statically linked" not in file_description:
        raise SystemExit("candidate shim is not statically linked")
    with tempfile.TemporaryDirectory(prefix="masc-shim-artifact-") as directory:
        root = Path(directory)
        workspace = root / "workspace with spaces"
        workspace.mkdir()
        scratch = root / "scratch"
        scratch.mkdir()
        env_file = root / "endpoint.env"
        env_file.write_text("SSH_ARTIFACT_MARKER=config-loaded\n")
        config = root / "shim.conf"
        config.write_text(f"remote_root={workspace}\nenv_allowlist=\n"
                          f"path=/usr/bin:/bin\nenv_file={env_file}\n"
                          f"scratch_root={scratch}\n")
        env = dict(os.environ, MASC_EXEC_SHIM_CONFIG=str(config))
        probe = json.loads(subprocess.check_output([str(shim), "--probe"], env=env))
        if probe.get("name") != "masc-exec-shim" or probe.get("version", "").split(".")[0] != "3":
            raise SystemExit("candidate did not report supported protocol 3")
        encode = lambda value: base64.b64encode(value.encode()).decode("ascii")
        argv = ["/bin/sh", "-c", 'printf "%s" "$SSH_ARTIFACT_MARKER"']
        request = dict(v=3, argv=list(map(encode, argv)), env=[],
                       cwd=encode(str(workspace)), remote_root=encode(str(workspace)),
                       timeout_sec=10.0, stdin_len=0, mode="effect")
        body = json.dumps(request).encode()
        # Hold stdin open until settlement, matching the real SSH transport.
        # File-backed captures let wait() reap without pipe-buffer deadlocks.
        with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
            with subprocess.Popen([str(shim)], stdin=subprocess.PIPE, stdout=stdout,
                                  stderr=stderr, env=env) as process:
                try:
                    process.stdin.write(struct.pack(">Q", len(body)) + body)
                    process.stdin.flush()
                    status = process.wait(timeout=60)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
                    process.stdin.close()
                stdout.seek(0)
                stderr.seek(0)
                output, errors = stdout.read(), stderr.read()
        pieces = errors.split(b"\x1e")
        if status != 0 or output != b"config-loaded" or len(pieces) != 3 or pieces[-1] != b"":
            raise SystemExit(f"framed config execution failed: status={status} stdout={output!r} stderr={errors!r}")
        trailer = json.loads(pieces[1])["masc_exec_result"]
        required = {"v", "exit", "signal", "timed_out", "shim_error"}
        if (type(trailer) is not dict or not required.issubset(trailer)
                or type(trailer["v"]) is not int or trailer["v"] != 3
                or type(trailer["exit"]) is not int or trailer["exit"] != 0
                or trailer["signal"] is not None or trailer["timed_out"] is not False
                or trailer["shim_error"] is not None):
            raise SystemExit(f"framed execution did not succeed: {trailer!r}")
    if hashlib.sha256(shim.read_bytes()).hexdigest() != binary_sha:
        raise SystemExit("candidate bytes changed during probe")
    receipt = dict(schema_version=1, source_commit=source,
                   source_tree=subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], text=True).strip(),
                   workflow_head=os.environ.get("GITHUB_SHA"),
                   run_id=os.environ.get("GITHUB_RUN_ID"), run_attempt=os.environ.get("GITHUB_RUN_ATTEMPT"),
                   platform="linux-" + args.arch, binary_sha256=binary_sha,
                   binary_bytes=shim.stat().st_size, file_description=file_description,
                   probe=probe, framed_config_execution=dict(exit=status, stdout=output.decode(), trailer=trailer),
                   driver_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                   installed=False, ssh_transport_exercised=False, keeper_exercised=False,
                   production=False, release_verified=False)
    args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Static shim {args.arch} config/frame execution PASS; source={source} sha256={binary_sha}")


if __name__ == "__main__":
    main()
