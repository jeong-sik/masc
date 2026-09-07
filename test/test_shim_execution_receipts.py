"""Exercise receipts from the real shim binary, with stdin held open as its transport."""

import base64
import hashlib
import json
import os
from pathlib import Path
import selectors
import struct
import subprocess
import sys
import tempfile
import time


def call(binary: Path, root: Path, config: Path, major: int, mode: str, argv: list[str]):
    encode = lambda value: base64.b64encode(value.encode()).decode()
    request = {"v": major, "argv": [encode(arg) for arg in argv], "env": [],
               "cwd": encode(str(root)), "remote_root": encode(str(root)),
               "timeout_sec": 10, "stdin_len": 0, "mode": mode}
    payload = json.dumps(request).encode()
    environment = dict(os.environ, MASC_EXEC_SHIM_CONFIG=str(config))
    with subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env=environment) as process:
        assert process.stdin and process.stdout and process.stderr
        process.stdin.write(struct.pack(">Q", len(payload)) + payload)
        process.stdin.flush()
        output = {"stdout": bytearray(), "stderr": bytearray()}
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, "stdout")
            selector.register(process.stderr, selectors.EVENT_READ, "stderr")
            deadline = time.monotonic() + 20
            while selector.get_map():
                if time.monotonic() >= deadline:
                    process.kill()
                    raise AssertionError("shim did not finish its bounded fixture")
                for key, _ in selector.select(timeout=0.1):
                    chunk = os.read(key.fd, 65536)
                    if chunk:
                        output[key.data].extend(chunk)
                    else:
                        selector.unregister(key.fileobj)
        process.stdin.close()
        status = process.wait(timeout=5)
    parts = bytes(output["stderr"]).rsplit(b"\x1e", 2)
    if len(parts) != 3 or parts[-1] != b"":
        raise AssertionError(f"no complete result trailer: {output!r}")
    trailer = json.loads(parts[1])["masc_exec_result"]
    return status, bytes(output["stdout"]), trailer


def main():
    binary = Path(sys.argv[1]).resolve()
    probe = json.loads(subprocess.check_output([str(binary), "--probe"]))
    if "observe" not in probe["capabilities"]:
        raise AssertionError("Linux feature fixture requires actual Observe support")
    major = int(probe["version"].split(".")[0])
    records = []
    with tempfile.TemporaryDirectory(prefix="masc-shim-receipts-") as temporary:
        root = Path(temporary)
        config = root / "shim.conf"
        config.write_text(f"remote_root={root}\nscratch_root={root}\n")
        cases = [
            ("effect", ["/bin/sh", "-c", "exit 127"], "sandbox_applied", "unrestricted", 127),
            ("observe", ["/bin/sh", "-c", "printf discard >/dev/null"],
             "sandbox_applied", "filesystem_and_network_box", 0),
            ("guest_local", ["/bin/sh", "-c", "printf guest >guest-output"],
             "sandbox_applied", "network_box", 0),
            ("observe", [str(root / "missing-executable")],
             "exec_failed", "filesystem_and_network_box", 127),
        ]
        for mode, argv, boundary, plan, expected_exit in cases:
            status, stdout, trailer = call(binary, root, config, major, mode, argv)
            expected_receipt = {"mode": mode, "plan": plan, "boundary": boundary}
            if status != 0 or trailer["exit"] != expected_exit or trailer["execution_receipt"] != expected_receipt:
                raise AssertionError(f"receipt/status mismatch: {status}, {trailer!r}")
            if trailer["signal"] is not None or trailer["timed_out"] or trailer["shim_error"] is not None:
                raise AssertionError(f"unexpected transport outcome: {trailer!r}")
            records.append({"transport_exit": status, "stdout_bytes": len(stdout), "trailer": trailer})
        if (root / "guest-output").read_text() != "guest":
            raise AssertionError("Guest_local did not execute the fixture write")
        status, _, trailer = call(binary, root, root / "missing-config", major, "observe", ["/bin/true"])
        if status != 1 or trailer["exit"] is not None or trailer["execution_receipt"] != {
                "mode": "observe", "plan": "filesystem_and_network_box", "boundary": "refused"}:
            raise AssertionError(f"pre-spawn refusal mislabeled as applied: {status}, {trailer!r}")
        records.append({"transport_exit": status, "boundary": trailer["execution_receipt"]})
    print(json.dumps({"kind": "actual-shim-execution-receipts",
                      "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                      "records": records}, indent=2))


if __name__ == "__main__":
    main()
