"""Invoke the real worker's argv boundary, before SDK/socket admission.

The SDK bait can only write an owned marker and exit. The non-Ego control uses
external_host, whose fallback path cannot launch a browser even if admission
regresses. No real SDK, browser, model, server or credential is used.
"""

import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


BINARY = str(Path(sys.argv.pop(1)).resolve())


class EgoWorkerCli(unittest.TestCase):
    def refuse(self, *, ego, store, message):
        with tempfile.TemporaryDirectory(prefix="ego-input-argv-") as directory:
            root = Path(directory)
            marker = root / "sdk-executed"
            sdk = root / "sdk-bait"
            sdk.write_text("#!/bin/sh\nprintf executed > " + shlex.quote(str(marker)) + "\nexit 97\n")
            sdk.chmod(0o700)
            socket = root / "worker.sock"
            retained = root / "retained-lane-addons"
            argv = [BINARY, "--backend", "ego" if ego else "external_host",
                    "--socket", str(socket), "--incarnation", "0b000000-0000-4000-8000-000000000073",
                    "--max-message-bytes", "65536"]
            if ego:
                argv += ["--live-ego-command", str(sdk), "--live-ego-space", "owned-argv-fixture"]
            if store == "relative":
                argv += ["--ego-input-store", "retained-lane-addons"]
            elif store == "absolute":
                argv += ["--ego-input-store", str(retained)]
            env = dict(os.environ, MASC_BASE_PATH=str(root / "base"), MASC_CONFIG_BOOTSTRAP="skip")
            result = subprocess.run(argv, cwd=root, env=env, stdin=subprocess.DEVNULL,
                                    text=True, capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(message, result.stderr)
            self.assertFalse(marker.exists(), "SDK command ran before input-store admission")
            self.assertFalse(socket.exists(), "refused worker left a socket")
            self.assertFalse(retained.exists(), "refused worker created retained state")

    def test_ego_missing_store(self):
        self.refuse(ego=True, store=None,
                    message="the ego source requires an absolute host-selected --ego-input-store")

    def test_ego_relative_store(self):
        self.refuse(ego=True, store="relative",
                    message="the ego source requires an absolute host-selected --ego-input-store")

    def test_non_ego_cannot_consume_ego_store(self):
        self.refuse(ego=False, store="absolute", message="--ego-input-store belongs to the ego source")


if __name__ == "__main__":
    unittest.main()
