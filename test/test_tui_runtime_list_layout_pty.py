"""Runtime candidate identity and route/probe survive narrow listings."""
import os
import sys
import unicodedata
import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_runtime as _keyboard_runtime


RUNTIME_ID = "fixture-runtime-한글-very-long-identity-tailZ"
LANE_ID = "fixture-lane-아주긴이름-primary-tailL"


def screen(output):
    raw = bytes(output)
    end = raw.rfind(_keyboard_harness.FRAME_END)
    assert end >= 0, "no completed terminal frame"
    return _keyboard_harness.screen_text(raw[:end + len(_keyboard_harness.FRAME_END)]).decode("utf-8", errors="strict")


def run(executable, no_color):
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    _, resolved = _keyboard_runtime.runtime_resolved_response()
    runtime = _keyboard_runtime.runtime_resolved_runtime(RUNTIME_ID, "fixture-provider", "fixture-model")
    resolved["runtimes"] = [runtime]
    resolved["default_runtime"] = runtime
    resolved["lanes"] = [{"id": LANE_ID, "runtime_ids": [RUNTIME_ID], "declared": True}]
    resolved["assignments"] = []
    _, probe = _keyboard_runtime.runtime_probe_response(fresh=True)
    probe["probe"]["providers"] = [_keyboard_runtime.runtime_probe_provider(RUNTIME_ID, status="reachable")]
    probe["probe"]["summary"].update({"runtimes": 1, "probed": 1,
        "reachable": 1, "failed": 0, "skipped": 0, "default_runtime_id": RUNTIME_ID})
    fixtures[_keyboard_harness.RUNTIME_RESOLVED_PATH] = (200, resolved)
    fixtures[_keyboard_runtime.RUNTIME_PROBE_PATH] = (200, probe)
    fixtures[_keyboard_runtime.RUNTIME_PROBE_FORCE_PATH] = (200, probe)

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.tab_until(process, fd, output, b"MASC System")
        _keyboard_harness.send_and_wait(process, fd, output, b"9", b"MASC System / Runtime")
        _keyboard_harness.wait_for_output(process, fd, output, b"tailZ", start=0, timeout=10)
        _keyboard_harness.wait_for_output(process, fd, output, b"reachable", start=0, timeout=10)
        for all_runtimes in (False, True):
            if all_runtimes:
                # The lane sweep already ended at120x32; an unchanged size
                # produces no redraw. Check geometry, then wait for mode change.
                size = os.get_terminal_size(fd)
                assert (size.columns, size.lines) == (120, 32), size
                _keyboard_harness.send_and_wait(process, fd, output, b"p", b"All runtimes")
            for columns in (30, 40, 60, 80, 120):
                resize_start = len(output)
                _keyboard_harness.resize_and_wait(process, fd, output, rows=32, columns=columns,
                                  needle=b"ROUTE / PROBE", controls=(_keyboard_harness.FULL_REDRAW,))
                clear = output.rfind(_keyboard_harness.FULL_REDRAW, resize_start)
                assert clear >= resize_start
                _keyboard_harness.wait_for_output(process, fd, output, _keyboard_harness.FRAME_END,
                    start=_keyboard_harness.end_of_needle(output, b"ROUTE / PROBE", clear), timeout=3)
                visible = screen(output)
                suffix = RUNTIME_ID[-4:] if columns == 30 else "tailZ"
                status = "ready / reach" if columns == 30 else "ready / reachable"
                candidate_rows = [row for row in visible.splitlines()
                                  if suffix in row and status in row]
                assert len(candidate_rows) == 1, (columns, all_runtimes, visible)
                cells = sum(0 if unicodedata.combining(char) else
                            2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
                            for char in candidate_rows[0])
                assert cells <= columns, (columns, cells, candidate_rows)
                assert "\\x1B" not in candidate_rows[0], candidate_rows
                if columns in (30, 40):
                    assert "…" in candidate_rows[0], candidate_rows
                # The full identity is read through the same selected row.
                _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"Runtime ID:")
                detail = screen(output)
                field = detail.split("Runtime ID:", 1)[1].split("Provider:", 1)[0]
                recovered = "".join(field.split())
                assert RUNTIME_ID in recovered, (columns, recovered, detail)
                _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"ROUTE / PROBE")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable,
        description=f"Runtime listing responsive identity and status NO_COLOR={no_color}",
        interact=interact, http_fixtures=fixtures,
        extra_env={"NO_COLOR": "1"} if no_color else {})


if __name__ == "__main__":
    for no_color in (False, True):
        run(os.path.abspath(sys.argv[1]), no_color)
    print("Runtime list responsive identity/status and full detail: PASS")
