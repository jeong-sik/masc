"""Runtime candidate identity and route/probe survive narrow listings."""
import os
import sys
import unicodedata
import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui_render.ml",)
RUNTIME_ID = "fixture-runtime-한글-very-long-identity-tailZ"
LANE_ID = "fixture-lane-아주긴이름-primary-tailL"


def screen(output):
    return h.screen_text(bytes(output)).decode("utf-8", errors="strict")


def run(executable, no_color):
    fixtures = h.keeper_runtime_http_fixtures()
    _, resolved = h.runtime_resolved_response()
    runtime = h.runtime_resolved_runtime(RUNTIME_ID, "fixture-provider", "fixture-model")
    resolved["runtimes"] = [runtime]
    resolved["default_runtime"] = runtime
    resolved["lanes"] = [{"id": LANE_ID, "runtime_ids": [RUNTIME_ID], "declared": True}]
    resolved["assignments"] = []
    _, probe = h.runtime_probe_response(fresh=True)
    probe["probe"]["providers"] = [h.runtime_probe_provider(RUNTIME_ID, status="reachable")]
    fixtures[h.RUNTIME_RESOLVED_PATH] = (200, resolved)
    fixtures[h.RUNTIME_PROBE_PATH] = (200, probe)
    fixtures[h.RUNTIME_PROBE_FORCE_PATH] = (200, probe)

    def interact(process, fd, _slave, output, _base):
        h.tab_until(process, fd, output, b"MASC System")
        h.send_and_wait(process, fd, output, b"9", b"MASC System / Runtime")
        h.wait_for_output(process, fd, output, b"tailZ", start=0, timeout=10)
        for all_runtimes in (False, True):
            if all_runtimes:
                h.resize_and_wait(process, fd, output, rows=32, columns=120,
                                  needle=b"ROUTE / PROBE", controls=(h.FULL_REDRAW,))
                h.send_and_wait(process, fd, output, b"p", b"All runtimes")
            for columns in (40, 60, 80, 120):
                h.resize_and_wait(process, fd, output, rows=32, columns=columns,
                                  needle=b"ROUTE / PROBE", controls=(h.FULL_REDRAW,))
                visible = screen(output)
                candidate_rows = [row for row in visible.splitlines()
                                  if "tailZ" in row and "ready / reachable" in row]
                assert len(candidate_rows) == 1, (columns, all_runtimes, visible)
                cells = sum(0 if unicodedata.combining(char) else
                            2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
                            for char in candidate_rows[0])
                assert cells <= columns, (columns, cells, candidate_rows)
                assert "\\x1B" not in candidate_rows[0], candidate_rows
                if columns == 40:
                    assert "…" in candidate_rows[0], candidate_rows
                # The full identity is read through the same selected row.
                h.send_and_wait(process, fd, output, b"\r", b"Runtime ID:")
                detail = screen(output)
                field = detail.split("Runtime ID:", 1)[1].split("Provider:", 1)[0]
                recovered = "".join(field.split())
                assert RUNTIME_ID in recovered, (columns, recovered, detail)
                h.send_and_wait(process, fd, output, b"\x1b", b"ROUTE / PROBE")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
        description=f"Runtime listing responsive identity and status NO_COLOR={no_color}",
        interact=interact, http_fixtures=fixtures,
        extra_env={"NO_COLOR": "1"} if no_color else {"NO_COLOR": None})


if __name__ == "__main__":
    for no_color in (False, True):
        run(os.path.abspath(sys.argv[1]), no_color)
    print("Runtime list responsive identity/status and full detail: PASS")
