"""Runtime detail draws exact runtime history, missing cache and original spec.

Two account runtimes share an API model. Only runtime-a has a sample, and a
small viewport must expose all evidence through its existing scrolling keys.
"""
import os
import sys
import time
from pathlib import Path

import tui_keyboard_harness as h
import tui_keyboard_runtime as runtime


def scenario(binary):
    fixtures = h.overview_event_http_fixtures()
    status, resolved = runtime.runtime_resolved_response()
    resolved["runtimes"][0]["provider_id"] = "account-one"
    resolved["runtimes"][1]["provider_id"] = "account-two"
    resolved["runtimes"][1]["model"] = resolved["runtimes"][0]["model"]
    fixtures[h.RUNTIME_RESOLVED_PATH] = status, resolved
    fixtures[runtime.RUNTIME_PROBE_PATH] = runtime.runtime_probe_response(fresh=True)
    fixtures[runtime.RUNTIME_PROBE_FORCE_PATH] = runtime.runtime_probe_response(fresh=True)
    fixtures["/api/v1/runtime/metrics"] = 200, {
        "specifications": [{"runtime_id": "runtime-a", "catalog_context": 272000,
            "catalog_max_output": 8192, "model_context": 200000,
            "provider_context": None, "binding_context": 100000}],
        "history": {"state": "ready", "window_minutes": 1440, "unattributed_entries": 3, "observed_at": 1704067200.0,
            "cache": {"state": "fresh", "generated_at": 1704067200.0},
            "cost_read": {"state": "available", "malformed_rows": 0,
                          "schema_violation_rows": 0, "identity_conflict_rows": 0},
            "runtimes": [{"runtime_id": "runtime-a", "entry_count": 2,
                "success_count": 1, "error_count": 1, "usage_sample_count": 1,
                "telemetry_sample_count": 0, "total_cost_usd": None,
                "cached_input": {"input_tokens": 100, "cache_read_tokens": 0, "sample_count": 1},
                "recent_entries": [{"ts_unix": 1704067100.0, "outcome": "success",
                                    "input_tokens": 100, "output_tokens": 25}]}]}}

    def collect(process, fd, output, needles):
        seen = bytearray(h.screen_text(bytes(output)))
        deadline = time.monotonic() + 10.0
        while not all(needle in seen for needle in needles):
            assert time.monotonic() < deadline, f"unreachable runtime evidence: {needles!r}: {seen!r}"
            os.write(fd, b"j")
            h.drain_until_quiet(process, fd, output)
            seen.extend(h.screen_text(bytes(output)))
        return seen

    def interact(process, fd, _slave, output, _base_path):
        h.tab_until(process, fd, output, b"MASC System")
        h.send_and_wait(process, fd, output, b"9", b"1/2 runtime-a")
        h.send_and_wait(process, fd, output, b"\r", b"Runtime ID: runtime-a")
        collect(process, fd, output, [b"Catalog context: 272000", b"binding 100000 tokens",
            b"2 recorded / 1 non-error / 1 errors", b"Cache hit: 0.0%", b"1/1 non-error samples",
            b"Last non-error turn: 2023-12-31 23:58:20", b"Recorded cost: not reported"])
        h.send_and_wait(process, fd, output, b"\x1b", b"CANDIDATE")
        h.send_and_wait(process, fd, output, b"j\r", b"Runtime ID: runtime-b")
        seen = collect(process, fd, output, [b"none attributed in this window", b"Cache hit: not reported"])
        assert b"2 recorded / 1 non-error" not in seen, "same API model borrowed the other account's history"
        h.send_and_wait(process, fd, output, b"\x1b", b"CANDIDATE")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC System")
        os.write(fd, b"q")

    h.run_terminal_scenario(binary, description="runtime evidence preserves account identity and missing observations",
        interact=interact, http_fixtures=fixtures, terminal_cols=100, terminal_rows=24,
        extra_env={"TZ": "UTC"})


if __name__ == "__main__":
    scenario(str(Path(sys.argv[1]).resolve()))
    print("tui runtime evidence: PASS")
