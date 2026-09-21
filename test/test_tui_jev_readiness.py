"""Render every Board JEV readiness state in the actual TUI with synthetic HTTP."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
from typing import Any, cast

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "lib/server/server_standalone_lane_projection.ml",
    "lib/tui_decode.ml",
    "bin/masc_tui_render.ml",
)


def run(executable: str, captures: Path | None) -> None:
    cases = (
        ({"state": "off"}, "JEV OFF"),
        (
            {"state": "configured", "model": "jev-fixture"},
            "JEV CONFIGURED · jev-fixture",
        ),
        ({"state": "cli_only"}, "JEV unavailable: Board lane is CLI-only"),
        ({"state": "lane_unavailable"}, "JEV unavailable: Board lane is not ready"),
    )
    for state, expected in cases:
        fixtures = h.keeper_runtime_http_fixtures()
        status, payload = h.standalone_lanes_response()
        snapshot = cast(dict[str, Any], payload)
        board = snapshot["lanes"][0]
        board["jev"] = state
        if state["state"] in ("cli_only", "lane_unavailable"):
            board["admitted_slots"] = []
            board["cli_slots"] = ["cli-fixture"] if state["state"] == "cli_only" else []
        if state["state"] == "lane_unavailable":
            board["configured"] = False
            board["configuration_state"] = "unconfigured"
            board["status"] = "unavailable"
        fixtures[h.STANDALONE_LANES_PATH] = (status, snapshot)

        def interact(
            process: subprocess.Popen[bytes],
            fd: int,
            _slave: int,
            output: bytearray,
            _base: str,
        ) -> None:
            h.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
            h.wait_for_output(
                process, fd, output, expected.encode(), start=0, timeout=10
            )
            h.drain_until_quiet(process, fd, output)
            screen = h.screen_text(bytes(output))
            if expected.encode() not in screen:
                raise AssertionError(f"current screen omitted {expected!r}: {screen!r}")
            for _other_state, other in cases:
                if other != expected and other.encode() in screen:
                    raise AssertionError(f"current screen also claimed {other!r}")
            if captures is not None:
                captures.mkdir(parents=True, exist_ok=True)
                (captures / f"{state['state']}.pty").write_bytes(bytes(output))
                (captures / f"{state['state']}.txt").write_bytes(screen)
            os.write(fd, b"q")

        h.run_terminal_scenario(
            executable,
            description=f"Board JEV {state['state']}",
            interact=interact,
            http_fixtures=fixtures,
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("executable")
    parser.add_argument("--captures", type=Path)
    args = parser.parse_args()
    run(os.path.abspath(args.executable), args.captures)
    print("Board JEV readiness: PASS (off/configured/cli_only/lane_unavailable)")
