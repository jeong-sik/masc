"""Same-named Keeper statistics and late health reads stay with their workspace."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import threading
from typing import Any, cast

import tui_keyboard_harness as h
from tui_keyboard_memory import memory_facts_http_fixtures

INPUT = "/api/v1/keepers/alpha/turn-records?limit=50"
HEALTH = "/api/v1/dashboard/keeper-memory-health"


def run(binary: str, *, held_kind: str, baseline: bool = False) -> None:
    fixtures = memory_facts_http_fixtures()
    initial_health = copy.deepcopy(
        cast(tuple[int, dict[str, Any]], fixtures[HEALTH])[1]
    )
    template = cast(tuple[int, dict[str, Any]], h.context_inspector_fixtures()[INPUT])[
        1
    ]["entries"][0]["record"]
    phase = "a"
    base = ""
    armed = threading.Event()
    old_started, old_release, old_returned = (threading.Event() for _ in range(3))
    new_started, new_release = threading.Event(), threading.Event()
    new_health_started, new_health_release = threading.Event(), threading.Event()

    def page(tokens: int) -> h.HttpResponse:
        record = copy.deepcopy(template)
        record.update(input_tokens=tokens, usage_scope="per_request")
        record.pop("cache_read_input_tokens", None)
        return 200, {
            "keeper": "alpha",
            "skipped_rows": 0,
            "entries": [{"record": record, "diff_vs_prev": None}],
        }

    def identity():
        if phase == "unknown":
            return h.RawHttpResponse(
                503,
                b'{"error":"identity unavailable"}',
                content_type="application/json",
            )
        root = base if phase == "a" else str(Path(base, "workspace-b"))
        _, raw_payload = h.fleet_safety_fixture()
        payload = cast(dict[str, Any], raw_payload)
        payload["paths"] = {
            "effective_base_path": root,
            "effective_masc_root": str(Path(root, ".masc")),
        }
        return h.RawHttpResponse(
            200, json.dumps(payload).encode(), content_type="application/json"
        )

    def hold_old():
        old_started.set()
        assert old_release.wait(20), "old fixture was not released"
        old_returned.set()

    def health() -> h.HttpResponse:
        origin = phase
        if held_kind == "health" and origin == "a" and armed.is_set():
            hold_old()
            payload = copy.deepcopy(initial_health)
            payload["keepers"][0].update(facts=999, observed_facts=999)
            payload["totals"].update(facts=999, observed_facts=999)
            return 200, payload
        if origin == "b" and held_kind == "health":
            new_health_started.set()
            assert new_health_release.wait(20), "new health fixture was not released"
        return 200, copy.deepcopy(initial_health)

    def inputs() -> h.HttpResponse:
        origin = phase
        if origin == "a" and held_kind == "input" and armed.is_set():
            hold_old()
            return page(777)
        if origin == "b":
            new_started.set()
            assert new_release.wait(20), "new fixture was not released"
            return page(222)
        return page(111)

    fixtures.update({INPUT: inputs, HEALTH: health})
    fixtures["/health"] = cast(h.HttpFixture, identity)
    fixtures["/health?full=1"] = cast(h.HttpFixture, identity)

    def prepare(path):
        nonlocal base
        base = str(Path(path).resolve())

    def interact(process, fd, _slave, output, _base):
        nonlocal phase

        def screen():
            end = output.rfind(h.FRAME_END)
            return (
                h.screen_text(bytes(output[: end + len(h.FRAME_END)]))
                if end >= 0
                else b""
            )

        def until(predicate, description):
            assert h.wait_for_fixture_state(
                process, fd, output, predicate, timeout=8
            ), (description, screen())

        try:
            h.palette_go(process, fd, output, b"go Memory", b"MASC Memory")
            until(lambda: b"avg 111" in screen(), "initial A input missing")
            armed.set()
            until(old_started.is_set, "A refresh was not held")
            phase = "unknown"
            h.palette_go(
                process,
                fd,
                output,
                b"go System / runtime.toml",
                b"server identity unread",
            )
            h.palette_go(process, fd, output, b"go Memory", b"MASC Memory")
            if not baseline:
                assert b"avg 111" not in screen(), (
                    "cached A input survived identity withdrawal"
                )
            phase = "b"
            until(lambda: b"[workspace mismatch]" in screen(), "B identity missing")
            old_release.set()
            until(old_returned.is_set, "old callback was not released")
            if baseline:
                needle = b"avg 777" if held_kind == "input" else b"999 ordinary"
                until(lambda: needle in screen(), "baseline contamination missing")
                print(
                    "BASELINE_FOREIGN_MEMORY=" + screen().decode(errors="replace"),
                    flush=True,
                )
            else:
                if held_kind == "health":
                    until(new_health_started.is_set, "B health was not launched")
                else:
                    until(new_started.is_set, "B input was not launched")
                # A fresh complete frame after the old callback was delivered.
                frame = h.resize_and_wait(
                    process,
                    fd,
                    output,
                    rows=41,
                    columns=140,
                    needle=b"MASC Memory",
                    controls=(h.FULL_REDRAW,),
                    final_cursor=b"\x1b[?25l",
                )
                for marker in (b"avg 111", b"avg 777", b"999 ordinary"):
                    assert marker not in h.screen_text(frame), (
                        marker,
                        h.screen_text(frame),
                    )
                new_health_release.set()
                until(new_started.is_set, "B input was not launched after health")
                new_release.set()
                until(lambda: b"avg 222" in screen(), "B input missing")
                assert b"avg 777" not in screen() and b"999 ordinary" not in screen()
                print(f"Memory workspace {held_kind}: PASS", flush=True)
            os.write(fd, b"q")
        finally:
            old_release.set()
            new_release.set()
            new_health_release.set()

    h.run_terminal_scenario(
        binary,
        description=f"Memory workspace held {held_kind}",
        interact=interact,
        prepare_workspace=prepare,
        http_fixtures=fixtures,
        refresh=0.2,
        terminal_cols=140,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
    parser.add_argument("--baseline", action="store_true")
    args = parser.parse_args()
    binary = os.path.abspath(args.binary)
    print(
        "STUDIO_BINARY_SHA256=" + hashlib.sha256(Path(binary).read_bytes()).hexdigest()
    )
    for kind in ("input", "health"):
        run(binary, held_kind=kind, baseline=args.baseline)
