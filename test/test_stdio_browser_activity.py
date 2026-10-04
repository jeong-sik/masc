#!/usr/bin/env python3
"""Real isolated stdio admission; no browser backend or provider dispatch.

Only this temporary fixture disables auth to isolate activity admission.
Its model endpoint is unreachable loopback and autonomous work is disabled.
"""

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
for enabled in [False, True]:
    with tempfile.TemporaryDirectory(prefix="masc-stdio-browser-fixture-") as tmp:
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
            '[providers.ollama]\nprotocol="ollama-http"\nendpoint="http://127.0.0.1:9"\n[models.fixture]\napi-name="hf.co/unsloth/gemma-4-E2B-it-qat-GGUF:UD-Q4_K_XL"\nmax-context=1024\n[ollama.fixture]\n[runtime]\ndefault="ollama.fixture"\n[browser.automation]\nenabled='
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
                            "name": "browser-activity-fixture",
                            "version": "1",
                        },
                    },
                )
                assert "result" in initialized, initialized
                answer = call(
                    2,
                    "tools/call",
                    {"name": "masc_browser_tabs", "arguments": {"lane": "automation"}},
                )
                assert "Model setup required" not in (base / "stderr.log").read_text()
                if not enabled:
                    assert (
                        answer["result"]["structuredContent"]["error"]
                        == "browser_lane_off"
                    ), (answer, (base / "stderr.log").read_text())
                else:
                    text = json.dumps(answer)
                    assert "the automation lane has no WebDriver" in text, answer
                    assert "browser_activity_unavailable" not in text, answer
                print(f"Stdio Browser activity enabled={enabled}: PASS")
            finally:
                p.terminate()
                try:
                    p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait()
