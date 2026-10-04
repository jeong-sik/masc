"""Runtime rows retain complete status/probe values and selected quota scope evidence."""
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
        "scope": "account:spent", "scope_id": "spent-quota-scope",
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
                if not any(b"LANE" in line for line in rows.values()):
                    raise AssertionError(f"Lane header disappeared at {columns}: {rows!r}")
                for lane, candidate in ((b"primary", b"1/2 runtime-a"),
                                        (b"degraded", b"1/1 runtime-c")):
                    line = next((line for line in rows.values() if candidate in line), b"")
                    if lane not in line:
                        raise AssertionError(f"Lane identity lost at {columns}: {line!r}")
                if combined:
                    screen = " ".join(" ".join(line.decode().strip(" │").split())
                                      for _, line in sorted(rows.items()))
                    for value in ("Quota scope spent-quota-scope", "Connection fixture-provider", "Resolved A / model-a",
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

    detail_fixture = fixtures()
    _, resolved = detail_fixture[h.RUNTIME_RESOLVED_PATH]
    selected = resolved["runtimes"][0]
    selected.update({"quota_scope": "account:1", "quota_exhausted": False})
    resolved["provider_usage_windows"].append({
        "scope": "account:1", "scope_id": "first-credential-scope",
        "providers": [{"id": selected["provider_id"], "display_name": selected["provider"]}],
        "state": "not_reported_since_start", "windows": [],
    })

    def detail_interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go Runtime", b"MASC System / Runtime")
        h.resize_and_wait(process, fd, output, rows=17, columns=132,
            needle=b"MASC System / Runtime", controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
        frame = h.send_and_wait(process, fd, output, b"\r", b"first-credential-scope")
        screen = b" ".join(h.screen_rows(frame).values())
        if b"Quota scope:" not in screen or b"first-credential-scope" not in screen:
            raise AssertionError(f"Enter detail lost the non-exhausted quota scope: {screen!r}")
        if b"Response-local quota scope:" not in screen or b"account:1" not in screen:
            raise AssertionError(f"Enter detail lost response-local correlation: {screen!r}")
        if b"Connection / provider ID:" not in screen or b"fixture-provider" not in screen:
            raise AssertionError(f"Enter detail conflated connection and quota scope: {screen!r}")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Runtime short detail preserves quota scope",
        interact=detail_interact, http_fixtures=detail_fixture)

    # A malformed Usage payload must not erase the Runtime response's local
    # correlation label or present that ordinal as a provider account ID.
    resolved["provider_usage_windows"] = None

    def missing_usage_interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go Runtime", b"MASC System / Runtime")
        frame = h.send_and_wait(process, fd, output, b"\r", b"Response-local quota scope:")
        screen = b" ".join(h.screen_rows(frame).values())
        for fact in (b"Quota scope:", b"unavailable; response-local scope account:1",
                     b"Response-local quota scope:", b"account:1"):
            if fact not in screen:
                raise AssertionError(f"Failed Usage join lost {fact!r}: {screen!r}")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Runtime missing Usage retains local quota correlation",
        interact=missing_usage_interact, http_fixtures=detail_fixture)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Runtime complete status: PASS")
