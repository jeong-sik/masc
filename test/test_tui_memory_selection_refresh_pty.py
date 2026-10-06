"""Keep reading the same Keeper when a Memory refresh changes its ranking."""
import argparse
import base64
import copy
import hashlib
import json
import os
from pathlib import Path

import tui_keyboard_harness as h
from tui_keyboard_memory import memory_facts_http_fixtures


def run(executable, baseline=False):
    fixtures = memory_facts_http_fixtures()
    health = fixtures["/api/v1/dashboard/keeper-memory-health"][1]
    beta = copy.deepcopy(health["keepers"][0])
    beta.update(keeper_id="beta", facts=1, observed_facts=1)
    health["keepers"].append(beta)
    for key, value in health["totals"].items():
        if isinstance(value, int):
            health["totals"][key] = value * 2
    health["totals"].update(facts=3, observed_facts=3)
    sequence = h.SequencedHttpResponse([(200, copy.deepcopy(health))])
    fixtures["/api/v1/dashboard/keeper-memory-health"] = sequence
    for keeper in ("alpha", "beta"):
        fixtures[f"/api/v1/keepers/{keeper}/turn-records?limit=50"] = (
            200, {"keeper": keeper, "skipped_rows": 0, "entries": []})

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go Memory", b"MASC Memory")
        h.wait_for_output(process, fd, output, b"alpha \xc2\xb7 memory", start=0, timeout=10)

        def capture(name, selected):
            if name == "after-ranking-change":
                h.resize_and_wait(process, fd, output, rows=36, columns=100,
                                  needle=selected + b" \xc2\xb7 memory",
                                  controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
            frame = h.resize_and_wait(
                process, fd, output, rows=35, columns=100,
                needle=selected + b" \xc2\xb7 memory",
                controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
            print("STUDIO_CAPTURE=" + json.dumps({
                "name": name, "rows": 35, "columns": 100,
                "provenance": "existing binary fixture PTY baseline" if baseline else "candidate binary fixture PTY",
                "binary_sha256": hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
                "frame_b64": base64.b64encode(frame).decode(),
                "screen": h.screen_text(frame).decode(errors="replace"),
            }), flush=True)

        capture("before-refresh", b"alpha")
        updated = copy.deepcopy(health)
        updated["keepers"][1].update(facts=3, observed_facts=3)
        updated["totals"].update(facts=5, observed_facts=5)
        served = sequence.served
        sequence.responses.append((200, updated))
        h.wait_for_fixture_served(process, fd, output, sequence, after=served,
                                 description="updated Memory ranking", timeout=5)
        if baseline:
            h.wait_for_output(process, fd, output, b"beta \xc2\xb7 memory", start=0, timeout=5)
        else:
            # The new fact count must have been rendered before selection is
            # inspected. Repeated refreshes continue to serve this snapshot.
            h.wait_for_output(process, fd, output, b"5 ordinary + 2 source", start=0, timeout=5)
        capture("after-ranking-change", b"beta" if baseline else b"alpha")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Memory refresh retains Keeper",
                            interact=interact, http_fixtures=fixtures, refresh=0.2)
    print("Memory selection drift reproduced (baseline)" if baseline else "Memory selection refresh PTY: PASS")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("executable")
    parser.add_argument("--baseline", action="store_true")
    args = parser.parse_args()
    run(os.path.abspath(args.executable), args.baseline)
