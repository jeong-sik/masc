"""Run the shared cleanup payload through a real exec-shim on Linux.

Usage: python3 test/test_keeper_build_cleanup_transport.py /path/to/masc-exec-shim
"""

import base64
import json
import os
from pathlib import Path
import selectors
import struct
import subprocess
import sys
import tempfile
import time
import unittest

PAYLOAD = Path(__file__).resolve().parents[1] / "config/scripts/keeper-build-cleanup.py"


class CleanupTransport(unittest.TestCase):
    binary: Path

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="keeper-cleanup-transport-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / "checkout"
        self.build = self.repo / "_build"
        self.build.mkdir(parents=True)
        (self.repo / "dune-project").write_text("(lang dune 3.20)\n")
        (self.repo / "source.ml").write_text("let retained = true\n")
        (self.build / "artifact").write_text("generated\n")
        self.path = os.environ["PATH"]
        self.config = self.root / "shim.conf"

    def slow_dune(self) -> None:
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        dune = fake_bin / "dune"
        dune.write_text(
            "#!/usr/bin/python3\n"
            "import os, signal, subprocess, time\n"
            "from pathlib import Path\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "child = subprocess.Popen(['sleep', '60'])\n"
            "Path('cleanup-pids').write_text(f'{os.getpid()} {child.pid}')\n"
            "time.sleep(60)\n"
        )
        dune.chmod(0o755)
        self.path = f"{fake_bin}:{self.path}"

    def start(self, timeout: float) -> subprocess.Popen[bytes]:
        self.config.write_text(f"remote_root={self.root}\npath={self.path}\n")
        self.config.chmod(0o644)

        def encode(value: str) -> str:
            return base64.b64encode(value.encode()).decode()

        source = PAYLOAD.read_bytes()
        probe = json.loads(subprocess.check_output([str(self.binary), "--probe"]))
        argv = [
            "python3",
            "-",
            "--guest-root",
            str(self.root),
            "--idle-hours",
            "0",
            "--apply",
        ]
        request = {
            "v": int(probe["version"].split(".")[0]),
            "argv": [encode(arg) for arg in argv],
            "env": [],
            "cwd": encode(str(self.root)),
            "remote_root": encode(str(self.root)),
            "timeout_sec": timeout,
            "stdin_len": len(source),
            "mode": "effect",
        }
        header = json.dumps(request).encode()
        process = subprocess.Popen(
            [str(self.binary)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=dict(os.environ, MASC_EXEC_SHIM_CONFIG=str(self.config)),
        )
        self.addCleanup(self.stop, process)
        assert process.stdin is not None
        process.stdin.write(
            struct.pack(">Q", len(header) + len(source)) + header + source
        )
        process.stdin.flush()  # Keep the transport open; EOF means cancellation.
        return process

    @staticmethod
    def stop(process: subprocess.Popen[bytes]) -> None:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                stream.close()

    def finish(self, process: subprocess.Popen[bytes]) -> tuple[bytes, dict]:
        assert process.stdout is not None and process.stderr is not None
        output = {"stdout": bytearray(), "stderr": bytearray()}
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, "stdout")
            selector.register(process.stderr, selectors.EVENT_READ, "stderr")
            deadline = time.monotonic() + 15
            while selector.get_map():
                if time.monotonic() >= deadline:
                    self.fail("shim did not acknowledge completion")
                for key, _ in selector.select(timeout=0.1):
                    chunk = os.read(key.fd, 65536)
                    if chunk:
                        output[key.data].extend(chunk)
                    else:
                        selector.unregister(key.fileobj)
        process.wait(timeout=5)
        trailer = bytes(output["stderr"]).rsplit(b"\x1e", 2)
        self.assertEqual(len(trailer), 3, output["stderr"])
        return bytes(output["stdout"]), json.loads(trailer[1])["masc_exec_result"]

    def assert_cleanup_processes_stopped(self) -> None:
        pids = (self.repo / "cleanup-pids").read_text().split()
        self.assertEqual(len(pids), 2)
        for pid in pids:
            stat = Path(f"/proc/{pid}/stat")
            if stat.exists():
                self.assertEqual(stat.read_text().rsplit(")", 1)[1].split()[0], "Z")

    def test_payload_cleans_and_returns_exit_receipt(self) -> None:
        stdout, trailer = self.finish(self.start(10))
        self.assertEqual(trailer["exit"], 0)
        self.assertFalse(trailer["timed_out"])
        self.assertEqual(trailer["execution_receipt"]["boundary"], "sandbox_applied")
        self.assertEqual(json.loads(stdout)["entries"][0]["action"], "cleaned")
        self.assertFalse((self.build / "artifact").exists())
        self.assertTrue((self.repo / "source.ml").exists())

    def test_timeout_stops_cleanup_and_descendants(self) -> None:
        self.slow_dune()
        _, trailer = self.finish(self.start(2))
        self.assertTrue(trailer["timed_out"])
        self.assert_cleanup_processes_stopped()

    def test_transport_eof_stops_cleanup_and_descendants(self) -> None:
        self.slow_dune()
        process = self.start(20)
        deadline = time.monotonic() + 5
        while not (self.repo / "cleanup-pids").exists():
            if time.monotonic() >= deadline:
                self.fail("cleanup never started")
            time.sleep(0.01)
        assert process.stdin is not None
        process.stdin.close()
        _, trailer = self.finish(process)
        self.assertFalse(trailer["timed_out"])
        self.assertIsNotNone(trailer["signal"])
        self.assert_cleanup_processes_stopped()


if __name__ == "__main__":
    CleanupTransport.binary = Path(sys.argv.pop(1)).resolve()
    unittest.main()
