"""Runtime rows retain complete status/probe values and selected account evidence."""
import os
import sys
import time

import tui_keyboard_harness as h
import tui_keyboard_runtime as runtime


def fixtures(*, combined=False):
    result = h.overview_event_http_fixtures()
    _, resolved = runtime.runtime_resolved_response()
    _, probe = runtime.runtime_probe_response(fresh=True)
    assert isinstance(resolved, dict) and isinstance(probe, dict)
    observed = resolved["runtimes"][0 if combined else 2]
    observed.update({"quota_scope": "account:spent", "quota_exhausted": combined,
                     "quota_resets_at": None, "rate_limited": combined})
    resolved["provider_usage_windows"] = [{
        "scope": "account:spent", "scope_id": "spent-account",
        "providers": [{"id": observed["provider_id"], "display_name": observed["provider"]}],
        "state": "reported", "windows": [{
            "limit_id": None, "window": {"kind": "five_hour"},
            "role": "gates_model_calls", "utilization": {"unit": "percent", "value": 100},
            "resets_at": None, "observed_at": time.time(), "source": "fixture",
        }],
    }]
    result[h.RUNTIME_RESOLVED_PATH] = (200, resolved)
    result[runtime.RUNTIME_PROBE_PATH] = (200, probe)
    return result


def run(executable):
    for combined in (False, True):
        def interact(process, fd, _slave, output, _base):
            h.palette_go(process, fd, output, b"go Runtime", b"MASC System / Runtime")
            h.wait_for_output(process, fd, output, b"account limit spent", start=0, timeout=3.0)
            for columns in (132, 80):
                frame = h.resize_and_wait(process, fd, output, rows=40, columns=columns,
                    needle=b"MASC System / Runtime", controls=(h.FULL_REDRAW,),
                    final_cursor=b"\x1b[?25l")
                rows = h.screen_rows(frame)
                if combined:
                    screen = " ".join(" ".join(line.decode().strip(" │").split())
                                      for _, line in sorted(rows.items()))
                    for value in ("Account account:spent", "Connection fixture-provider", "Resolved A / model-a",
                                  "quota exhausted (no reset stated)", "rate limited",
                                  "account limit spent / reachable"):
                        if value not in screen:
                            raise AssertionError(f"Selected status lost {value!r} at {columns}: {screen!r}")
                else:
                    statuses = []
                    for candidate, wanted in ((b"1/2 runtime-a", b"usage unknown / reachable"),
                                              (b"1/1 runtime-c", b"account limit spent / reachable")):
                        line = next((line for line in rows.values() if candidate in line), b"")
                        if wanted not in line:
                            raise AssertionError(f"Runtime row cut {wanted!r} at {columns}: {line!r}")
                        statuses.append(line.index(wanted))
                    if statuses[0] != statuses[1]:
                        raise AssertionError(f"Runtime status columns moved between rows: {statuses}")
            # The terminal loses one navigation and one composer row: these
            # heights exercise the supported 14/15-row Runtime body directly.
            for height in (16, 17):
                for columns in (132, 80):
                    frame = h.resize_and_wait(process, fd, output, rows=height, columns=columns,
                        needle=b"MASC System / Runtime", controls=(h.FULL_REDRAW,),
                        final_cursor=b"\x1b[?25l")
                    if not any(b"1/2 runtime-a" in line for line in h.screen_rows(frame).values()):
                        raise AssertionError(f"Selected first row hidden at {height}x{columns}")
                    for key, candidate in ((b"j", b"2/2 runtime-b"), (b"j", b"1/1 runtime-c"),
                                           (b"k", b"2/2 runtime-b"), (b"k", b"1/2 runtime-a")):
                        h.send_and_wait(process, fd, output, key, candidate)
                        if not any(candidate in line for line in h.screen_rows(bytes(output)).values()):
                            raise AssertionError(f"Selected row hidden after {key!r}: {candidate!r}")
            os.write(fd, b"q")
        h.run_terminal_scenario(executable,
            description="Runtime complete combined status" if combined else "Runtime aligned complete status cells",
            interact=interact, http_fixtures=fixtures(combined=combined))


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Runtime complete status: PASS")
