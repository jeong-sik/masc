"""A screen opened during workspace discovery reads after discovery completes."""

import os
import subprocess
import sys
from typing import cast

import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui.ml",)


def run(executable: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[h.STANDALONE_LANES_PATH] = h.standalone_lanes_response()
    gate = h.GatedHttpResponse(
        cast(h.HttpResponse, fixtures["/api/v1/dashboard/briefing"]),
        hold_seconds=30.0,
    )
    fixtures["/api/v1/dashboard/briefing"] = gate

    def interact(
        process: subprocess.Popen[bytes],
        master: int,
        _slave: int,
        output: bytearray,
        _base: str,
    ) -> None:
        try:
            assert h.wait_for_fixture_event(
                process, master, output, gate.requested, timeout=10.0
            ), "initial workspace refresh never reached its fixture"
            h.palette_go(process, master, output, b"go lanes", b"MASC Lanes")
            gate.release.set()
            h.wait_for_output(
                process, master, output, b"Librarian", start=0, timeout=10.0
            )
            os.write(master, b"q")
        finally:
            gate.release.set()

    h.run_terminal_scenario(
        executable,
        description="Lanes selected during initial workspace verification",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Workspace discovery resumes the selected screen: PASS")
