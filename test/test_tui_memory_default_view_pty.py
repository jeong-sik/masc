"""Memory draws a keeper's state, last save and actions; d draws the ledger (#39831).

The block under the selected keeper used to draw eight rows of ledger
coordinates on every visit. The default view keeps one status row -- the
keeper, its state word and when memory was last saved -- plus an action row
only when there is something to do. The detail toggle draws every row it drew
before, so nothing the ledger said is lost, only folded.
"""

import os
import sys

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_memory as _keyboard_memory



# The ledger coordinates the default view folds: the snapshot revision, the
# trace the saved context points at, and the prepared-request row that reads
# like a model success but is not one.
LEDGER = (b"snapshot r7", b"trace-alpha-1", b"Request prepared")

STATUS = b"Memory saved"


def run(executable: str) -> None:
    fixtures = _keyboard_memory.memory_facts_http_fixtures()
    _status, health = fixtures["/api/v1/dashboard/keeper-memory-health"]
    health["keepers"][0]["context_cycle"]["saved"] = {
        "trace_id": "trace-alpha-1",
        "end_atom": 12,
        "boundary_line": 3,
    }

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.palette_go(process, fd, output, b"go Memory", b"MASC Memory")
        _keyboard_harness.wait_for_output(process, fd, output, STATUS, start=0, timeout=10)
        _keyboard_harness.resize_and_wait(
            process, fd, output, rows=40, columns=160,
            needle=STATUS, controls=(_keyboard_harness.FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        folded = _keyboard_harness.screen_text(bytes(output))
        status_rows = [
            row for row in folded.splitlines()
            if b"alpha \xc2\xb7 " in row and STATUS in row
        ]
        if len(status_rows) != 1:
            raise AssertionError(
                f"Memory did not draw one status row for alpha: {folded!r}"
            )
        for needle in LEDGER:
            if needle in folded:
                raise AssertionError(
                    f"the default Memory view drew {needle!r}: {folded!r}"
                )
        start = len(output)
        os.write(fd, b"d")
        _keyboard_harness.wait_for_output(
            process, fd, output, b"Request prepared", start=start, timeout=10
        )
        detailed = _keyboard_harness.screen_text(bytes(output))
        for needle in LEDGER:
            if needle not in detailed:
                raise AssertionError(
                    f"the Memory detail view lost {needle!r}: {detailed!r}"
                )
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Memory folds the ledger until d asks for it",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Memory default view folds the ledger behind d: PASS")
