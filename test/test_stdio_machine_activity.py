#!/usr/bin/env python3
"""Real isolated stdio machine admission; no machine is loaded or executed.

Only this temporary fixture disables auth to isolate activity admission.
Its model endpoint is unreachable loopback and autonomous work is disabled.
"""

import unittest
import json
import os
import selectors
import subprocess
import tempfile
import shutil
import time
import sys
from pathlib import Path

repo = Path(os.environ.get("DUNE_SOURCEROOT", Path(__file__).resolve().parents[1]))
binary = Path(sys.argv[1]).resolve()


def run(machine: str, enabled: bool) -> None:
    with tempfile.TemporaryDirectory(prefix="masc-stdio-machine-fixture-") as tmp:
        base = Path(tmp)
        cfg = base / ".masc/config"
        cfg.mkdir(parents=True)
        auth = base / ".masc/auth"
        auth.mkdir()
        (auth / "config.json").write_text(
            json.dumps(
                {
                    "enabled": False,
                    "workspace_secret_hash": None,
                    "require_token": False,
                    "token_expiry_hours": 24,
                }
            )
        )
        (cfg / "keepers").mkdir()
        shutil.copytree(repo / "config/prompts", cfg / "prompts")
        (cfg / "runtime.toml").write_text(
            '[providers.ollama]\nprotocol="ollama-http"\nendpoint="http://127.0.0.1:9"\n[models.fixture]\napi-name="hf.co/unsloth/gemma-4-E2B-it-qat-GGUF:UD-Q4_K_XL"\nmax-context=1024\n[ollama.fixture]\n[runtime]\ndefault="ollama.fixture"\n[machines.msx]\nenabled='
            + str(enabled).lower()
            + "\n[machines.dos]\nenabled="
            + str(enabled).lower()
            + "\n"
        )
        env = {
            "PATH": os.environ["PATH"],
            "HOME": tmp,
            "DUNE_SOURCEROOT": str(repo),
            "MASC_KEEPER_AUTONOMOUS_ENABLED": "false",
            "MASC_ORCHESTRATOR_ENABLED": "0",
            "MASC_CONFIG_BOOTSTRAP": "skip",
        }
        with open(base / "stderr.log", "wb") as err:
            p = subprocess.Popen(
                [str(binary), "--base-path", tmp],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=err,
                env=env,
                cwd=repo,
            )
            try:

                def call(i, method, params):
                    assert p.stdin is not None and p.stdout is not None
                    p.stdin.write(
                        (
                            json.dumps(
                                {
                                    "jsonrpc": "2.0",
                                    "id": i,
                                    "method": method,
                                    "params": params,
                                }
                            )
                            + "\n"
                        ).encode()
                    )
                    p.stdin.flush()
                    with selectors.DefaultSelector() as sel:
                        sel.register(p.stdout, selectors.EVENT_READ)
                        deadline = time.monotonic() + 30
                        while time.monotonic() < deadline:
                            if sel.select(0.2):
                                line = p.stdout.readline()
                                if not line:
                                    raise AssertionError(
                                        "stdio closed: "
                                        + (base / "stderr.log").read_text()[-3000:]
                                    )
                                answer = json.loads(line)
                                if answer.get("id") == i:
                                    return answer
                        raise AssertionError(
                            "stdio response timeout: "
                            + (base / "stderr.log").read_text()[-3000:]
                        )

                initialized = call(
                    1,
                    "initialize",
                    {
                        "protocolVersion": "2025-06-18",
                        "capabilities": {},
                        "clientInfo": {
                            "name": "machine-activity-fixture",
                            "version": "1",
                        },
                    },
                )
                assert "result" in initialized, initialized
                answer = call(
                    2,
                    "tools/call",
                    {
                        "name": f"masc_{machine}_step",
                        "arguments": {"frames" if machine == "msx" else "steps": 1},
                    },
                )
                assert "Model setup required" not in (base / "stderr.log").read_text()
                text = json.dumps(answer)
                expected = (
                    f"machines.{machine} is off; enable it before new machine work"
                    if not enabled
                    else f"no {machine.upper()} machine is loaded"
                )
                assert expected in text, answer
                assert "Machine activity configuration is unavailable" not in text, (
                    answer
                )
                print(
                    f"Stdio {machine.upper()} activity enabled={enabled}: PASS",
                    flush=True,
                )
            finally:
                p.terminate()
                try:
                    p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait()
                if p.stdin is not None:
                    p.stdin.close()
                if p.stdout is not None:
                    p.stdout.close()


class MachineStdioAdmission(unittest.TestCase):
    def test_msx_off(self):
        run("msx", False)

    def test_msx_on(self):
        run("msx", True)

    def test_dos_off(self):
        run("dos", False)

    def test_dos_on(self):
        run("dos", True)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
