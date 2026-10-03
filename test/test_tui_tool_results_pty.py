"""Tool results load through Gate clicks and observer-followed live journals."""

import json
import os
import threading
import urllib.parse
import sys

import test_tui_keyboard_input as h




def run(executable: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    argument = "GATE_CLICK " + "long-argument " * 16 + "GATE_TAIL"
    fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [{
        "id": "results-gate", "role": "system", "content": argument,
        "ts": 1787348491.3,
        "approval_lifecycle": {
            "approval_id": "gate-results", "phase": "requested",
            "tool_name": "Execute", "call_summary": argument,
        },
    }])
    fixtures["/api/v1/keepers/alpha/tool-calls?limit=100"] = (
        200, {"keeper": "alpha", "count": 0, "health": "ok", "entries": []},
    )
    changes = h.GatedHttpResponse((200, {
        "keeper": "alpha", "window_hours": 24.0, "calls_in_window": 0,
        "changes": [], "over_budget": 0, "malformed": 0,
    }))
    fixtures[h.FILE_CHANGES_ALPHA_PATH] = changes

    def interact(process, master_fd, _slave_fd, output, _base_path):
        try:
            h.resize_and_wait(process, master_fd, output, rows=30, columns=120,
                              needle=b"MASC Dashboard")
            # Palette Keeper entries come from the asynchronous roster; the
            # Dashboard title alone can arrive before alpha is selectable.
            h.send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
            h.select_keeper_row(process, master_fd, output, b"alpha")
            h.palette_go(process, master_fd, output, b"keeper alpha", b"GATE_CLICK")
            h.send_and_wait(process, master_fd, output, b"\x04", b"tools:results")
            h.drain_until_quiet(process, master_fd, output)
            before = h.screen_text(bytes(output))
            if b"GATE_TAIL" in before or changes.calls:
                raise AssertionError(f"results mode prematurely expanded details: {before!r}")
            h.wait_for_output(process, master_fd, output, b"KEEPERS", start=0, timeout=3.0)
            h.drain_until_quiet(process, master_fd, output)
            row = h.screen_row_of(h.screen_rows(bytes(output)), b"GATE_CLICK")
            if row < 0:
                raise AssertionError(f"folded Gate row missing: {before!r}")
            roster_click = b"\x1b[<0;6;%dM\x1b[<0;6;%dm" % (row, row)
            os.write(master_fd, roster_click)
            h.drain_until_quiet(process, master_fd, output)
            if b"tools:results" not in h.screen_text(bytes(output)) or changes.calls:
                raise AssertionError("roster click opened chat Gate details")
            h.send_and_wait(process, master_fd, output,
                            b"\x1b[<0;40;%dM\x1b[<0;40;%dm" % (row, row),
                            b"tools:full")
            if not h.wait_for_fixture_event(process, master_fd, output,
                                            changes.requested, timeout=3.0):
                raise AssertionError("Gate click did not request file-change details")
            response_start = len(output)
            changes.release.set()
            h.wait_for_output(process, master_fd, output, b"diffs 24h",
                              start=response_start, timeout=5.0)
            h.drain_until_quiet(process, master_fd, output)
            after = h.screen_text(bytes(output))
            if b"GATE_TAIL" not in after or b"diffs pending" in after:
                raise AssertionError(f"Gate click did not settle full details: {after!r}")
            # Palette chat returns to the roster, retaining its selected row.
            h.send_and_wait(process, master_fd, output, b"\x1b",
                            h.keeper_row_selected(b"alpha"))
            os.write(master_fd, b"q")
        finally:
            changes.release.set()

    h.run_terminal_scenario(
        executable, description="Results Gate click loads full details",
        interact=interact, http_fixtures=fixtures,
    )


def run_observer_results(executable: str) -> None:
    # No pane-owned POST, chat-appended event or run-finished event is sent.
    # Only observer frames can cause the journal reads below; the long cadence
    # makes a result that only appears on the next poll fail the scenario.
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures.update(h.observer_http_fixtures())
    fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])
    releases = [threading.Event() for _ in range(5)]
    connected = threading.Event()
    calls_requested = threading.Event()
    calls_count = 0
    journal_count = 0
    durable_ready = False
    operation = "observed-result-turn"
    occurrence = {"stream_scope": 0, "block_index": 0}

    def line(seq, event):
        return {"v": 1, "seq": seq, "ts": 1787348491.0 + seq / 10, "event": event}

    def tool_event(kind, **fields):
        return {"type": kind, "occurrence": occurrence,
                "tool_call_id": "observed-call", **fields}

    result = line(4, tool_event("tool_result_ready", execution_id="observed-exec"))
    pages = [
        [line(0, {"type": "run_started", "run_id": "observed-run", "thread_id": "keeper:alpha"}),
         line(1, {"type": "text_delta", "delta": "OBSERVER_STARTED "}),
         line(2, tool_event("tool_call_start", tool_call_name="Read")),
         line(3, tool_event("tool_call_end"))],
        [result],
        # The endpoint repeats the result alongside new text: the reader folds
        # only the new seq and must not ask for the durable call a second time.
        [result, line(5, {"type": "text_delta", "delta": "REPLAY_FOLDED "})],
        [line(6, tool_event("tool_result_ready", execution_id="observed-exec")),
         line(7, {"type": "text_delta", "delta": "COMPACT_FOLDED "})],
    ]

    def journal(path):
        nonlocal journal_count
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)
        expected_cursor = [None, "3", "4", "5"][min(journal_count, 3)]
        if query.get("operation_id") != [operation] or query.get("since_seq", [None]) != [expected_cursor]:
            return 400, {"error": "fixture unexpected journal cursor", "query": query}
        page = pages[min(journal_count, len(pages) - 1)]
        journal_count += 1
        return 200, {"schema": "masc.keeper_chat_events.v2", "operation_id": operation,
                     "events": page, "has_more": False,
                     "next_since_seq": page[-1]["seq"], "next_since_offset": 100 * journal_count}

    def calls():
        nonlocal calls_count
        calls_count += 1
        calls_requested.set()
        entries = []
        if durable_ready:
            entries = [{"ts": 1787348491.4, "keeper": "alpha", "tool": "Read",
                        "input": "{}", "output": "OBSERVER_DURABLE_RESULT",
                        "wire_outcome": "ok", "duration_ms": 30,
                        "execution_id": "observed-exec", "tool_use_id": "observed-call"}]
        return 200, {"keeper": "alpha", "count": len(entries), "health": "ok", "entries": entries}

    def frame(seq):
        event = {"type": "keeper_chat_operation_event", "name": "alpha",
                 "operation_id": operation, "seq": seq, "ts_unix": 1787348491.0,
                 "ag_ui_event": {"type": "CUSTOM", "name": "fixture-journal-grew"}}
        return b"data: " + json.dumps(event).encode() + b"\n\n"

    def chunks():
        connected.set()
        yield b": fixture observer connected\n\n"
        for index, seq in enumerate([3, 4, 5, 7]):
            if not releases[index].wait(timeout=15):
                return
            yield frame(seq)
        releases[4].wait(timeout=15)

    fixtures["/mcp?sse_kind=observer"] = h.StreamingHttpResponse(chunks)
    fixtures["/api/v1/keepers/alpha/chat/events"] = h.PathHttpResponse(journal)
    fixtures["/api/v1/keepers/alpha/tool-calls?limit=100"] = calls
    fixtures[h.FILE_CHANGES_ALPHA_PATH] = (200, {
        "keeper": "alpha", "window_hours": 24.0, "calls_in_window": 0,
        "changes": [], "over_budget": 0, "malformed": 0,
    })

    def interact(process, master_fd, _slave_fd, output, _base_path):
        nonlocal durable_ready
        try:
            h.resize_and_wait(process, master_fd, output, rows=36, columns=120,
                              needle=b"MASC Dashboard")
            if not h.wait_for_fixture_event(process, master_fd, output, connected, timeout=5):
                raise AssertionError("observer stream never opened")
            h.send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
            h.select_keeper_row(process, master_fd, output, b"alpha")
            h.palette_go(process, master_fd, output, b"keeper alpha", b"alpha")
            h.send_and_wait(process, master_fd, output, b"\x04", b"tools:results")
            if not h.wait_for_fixture_event(process, master_fd, output, calls_requested, timeout=5):
                raise AssertionError("results view never loaded initial call snapshot")
            h.drain_until_quiet(process, master_fd, output)
            baseline = calls_count
            releases[0].set()
            h.wait_for_output(process, master_fd, output, b"OBSERVER_STARTED", start=0, timeout=5)
            h.drain_until_quiet(process, master_fd, output)
            if calls_count != baseline:
                raise AssertionError("journal without a result requested call-log refresh")
            durable_ready = True
            result_start = len(output)
            releases[1].set()
            h.wait_for_output(process, master_fd, output, b"OBSERVER_DURABLE_RESULT",
                              start=result_start, timeout=5)
            h.drain_until_quiet(process, master_fd, output)
            if calls_count != baseline + 1:
                raise AssertionError(f"expected one result refresh, got {calls_count - baseline}")
            releases[2].set()
            h.wait_for_output(process, master_fd, output, b"REPLAY_FOLDED", start=0, timeout=5)
            h.drain_until_quiet(process, master_fd, output)
            if calls_count != baseline + 1:
                raise AssertionError("replayed result requested another call-log refresh")
            h.send_and_wait(process, master_fd, output, b"\x04", b"tools:full")
            h.drain_until_quiet(process, master_fd, output)
            # Unchanged transcript rows need not be emitted by a diff frame.
            # Wait for the transition's frame, then inspect the composed view.
            compact_start = len(output)
            h.write_all(master_fd, output, b"\x04")
            h.wait_for_output(process, master_fd, output, h.FRAME_END,
                              start=compact_start, timeout=3.0)
            h.drain_until_quiet(process, master_fd, output)
            compact = h.screen_text(bytes(output))
            if b"tools:full" in compact or b"tools:results" in compact:
                raise AssertionError(f"Ctrl-D did not reach compact mode: {compact!r}")
            compact_baseline = calls_count
            releases[3].set()
            h.wait_for_output(process, master_fd, output, b"COMPACT_FOLDED", start=0, timeout=5)
            h.drain_until_quiet(process, master_fd, output)
            if calls_count != compact_baseline or journal_count != 4:
                raise AssertionError("compact journal result refreshed calls or journal cursor drifted")
            h.send_and_wait(process, master_fd, output, b"\x1b", h.keeper_row_selected(b"alpha"))
            os.write(master_fd, b"q")
        finally:
            for release in releases:
                release.set()

    h.run_terminal_scenario(executable, description="Observer journal refreshes live tool results",
                            interact=interact, http_fixtures=fixtures, refresh=3600.0)


def run_coverage_gap_results(executable: str) -> None:
    # A result whose execution id is absent from a coverage-gap snapshot must
    # read as an incomplete log, not as a definitively missing row. Another
    # exact row retained in that same gapped snapshot must still preview.
    # A later complete snapshot restores the formerly missing preview too.
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures.update(h.observer_http_fixtures())
    fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])
    releases = [threading.Event() for _ in range(3)]
    connected = threading.Event()
    calls_requested = threading.Event()
    journal_count = 0
    gap_open = True
    operation = "gap-result-turn"
    occurrence_one = {"stream_scope": 0, "block_index": 0}
    occurrence_two = {"stream_scope": 0, "block_index": 1}

    def line(seq, event):
        return {"v": 1, "seq": seq, "ts": 1787348491.0 + seq / 10, "event": event}

    def tool_event(kind, occurrence, call_id, **fields):
        return {"type": kind, "occurrence": occurrence,
                "tool_call_id": call_id, **fields}

    pages = [
        [line(0, {"type": "run_started", "run_id": "gap-run", "thread_id": "keeper:alpha"}),
         line(1, {"type": "text_delta", "delta": "GAP_STARTED "}),
         line(2, tool_event("tool_call_start", occurrence_one, "gap-call-1", tool_call_name="Read")),
         line(3, tool_event("tool_call_end", occurrence_one, "gap-call-1"))],
        [line(4, tool_event("tool_result_ready", occurrence_one, "gap-call-1",
                            execution_id="gap-exec-1")),
         line(5, tool_event("tool_call_start", occurrence_two, "gap-call-2", tool_call_name="Read")),
         line(6, tool_event("tool_call_end", occurrence_two, "gap-call-2")),
         line(7, tool_event("tool_result_ready", occurrence_two, "gap-call-2",
                            execution_id="gap-exec-2"))],
        [line(8, tool_event("tool_result_ready", occurrence_one, "gap-call-1",
                            execution_id="gap-exec-1"))],
    ]

    def journal(path):
        nonlocal journal_count
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)
        expected_cursor = [None, "3", "7"][min(journal_count, 2)]
        if query.get("operation_id") != [operation] or query.get("since_seq", [None]) != [expected_cursor]:
            return 400, {"error": "fixture unexpected journal cursor", "query": query}
        page = pages[min(journal_count, len(pages) - 1)]
        journal_count += 1
        return 200, {"schema": "masc.keeper_chat_events.v2", "operation_id": operation,
                     "events": page, "has_more": False,
                     "next_since_seq": page[-1]["seq"], "next_since_offset": 100 * journal_count}

    def calls():
        calls_requested.set()
        retained = {"ts": 1787348491.7, "keeper": "alpha", "tool": "Read",
                    "input": "{}", "output": "GAP_RETAINED_RESULT",
                    "wire_outcome": "ok", "duration_ms": 30,
                    "execution_id": "gap-exec-2", "tool_use_id": "gap-call-2"}
        if gap_open:
            return 200, {"keeper": "alpha", "count": 1, "health": "coverage_gap",
                         "stale_reason": "append failed", "entries": [retained]}
        row = {"ts": 1787348491.4, "keeper": "alpha", "tool": "Read",
               "input": "{}", "output": "GAP_DURABLE_RESULT",
               "wire_outcome": "ok", "duration_ms": 30,
               "execution_id": "gap-exec-1", "tool_use_id": "gap-call-1"}
        return 200, {"keeper": "alpha", "count": 2, "health": "ok", "entries": [row, retained]}

    def frame(seq):
        event = {"type": "keeper_chat_operation_event", "name": "alpha",
                 "operation_id": operation, "seq": seq, "ts_unix": 1787348491.0,
                 "ag_ui_event": {"type": "CUSTOM", "name": "fixture-journal-grew"}}
        return b"data: " + json.dumps(event).encode() + b"\n\n"

    def chunks():
        connected.set()
        yield b": fixture observer connected\n\n"
        for index, seq in enumerate([3, 7, 8]):
            if not releases[index].wait(timeout=15):
                return
            yield frame(seq)
        releases[2].wait(timeout=15)

    fixtures["/mcp?sse_kind=observer"] = h.StreamingHttpResponse(chunks)
    fixtures["/api/v1/keepers/alpha/chat/events"] = h.PathHttpResponse(journal)
    fixtures["/api/v1/keepers/alpha/tool-calls?limit=100"] = calls
    fixtures[h.FILE_CHANGES_ALPHA_PATH] = (200, {
        "keeper": "alpha", "window_hours": 24.0, "calls_in_window": 0,
        "changes": [], "over_budget": 0, "malformed": 0,
    })

    def interact(process, master_fd, _slave_fd, output, _base_path):
        nonlocal gap_open
        try:
            h.resize_and_wait(process, master_fd, output, rows=36, columns=120,
                              needle=b"MASC Dashboard")
            if not h.wait_for_fixture_event(process, master_fd, output, connected, timeout=5):
                raise AssertionError("observer stream never opened")
            h.send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
            h.select_keeper_row(process, master_fd, output, b"alpha")
            h.palette_go(process, master_fd, output, b"keeper alpha", b"alpha")
            h.send_and_wait(process, master_fd, output, b"\x04", b"tools:results")
            if not h.wait_for_fixture_event(process, master_fd, output, calls_requested, timeout=5):
                raise AssertionError("results view never loaded initial call snapshot")
            releases[0].set()
            h.wait_for_output(process, master_fd, output, b"GAP_STARTED", start=0, timeout=5)
            releases[1].set()
            h.wait_for_output(process, master_fd, output, b"call log incomplete", start=0, timeout=5)
            h.wait_for_output(process, master_fd, output, b"GAP_RETAINED_RESULT", start=0, timeout=5)
            h.drain_until_quiet(process, master_fd, output)
            gap_screen = h.screen_text(bytes(output))
            if (b"call log incomplete" not in gap_screen
                    or b"GAP_RETAINED_RESULT" not in gap_screen
                    or b"no call-log row" in gap_screen):
                raise AssertionError(f"gapped log lost its retained result or missing-row uncertainty: {gap_screen!r}")
            gap_open = False
            releases[2].set()
            h.wait_for_output(process, master_fd, output, b"GAP_DURABLE_RESULT",
                              start=0, timeout=5)
            h.drain_until_quiet(process, master_fd, output)
            healed = h.screen_text(bytes(output))
            if (b"call log incomplete" in healed or b"GAP_DURABLE_RESULT" not in healed
                    or b"GAP_RETAINED_RESULT" not in healed):
                raise AssertionError(f"complete log did not retain both previews: {healed!r}")
            h.send_and_wait(process, master_fd, output, b"\x1b", h.keeper_row_selected(b"alpha"))
            os.write(master_fd, b"q")
        finally:
            for release in releases:
                release.set()

    h.run_terminal_scenario(executable, description="Coverage gap reads incomplete, exact row still previews",
                            interact=interact, http_fixtures=fixtures, refresh=3600.0)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("tui tool results Gate click: PASS")
    run_observer_results(os.path.abspath(sys.argv[1]))
    print("tui observer journal tool results: PASS")
    run_coverage_gap_results(os.path.abspath(sys.argv[1]))
    print("tui coverage gap tool results: PASS")
