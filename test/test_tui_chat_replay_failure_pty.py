"""Reopening chat replays a terminal error, retaining partial output exactly once."""

import os
import sys
import threading
import urllib.parse

import tui_keyboard_harness as h


def run(executable: str, *, partial: bool, history_error: bool) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    operation = "cancelled-replay-probe"
    failure = "operator interrupted the turn"
    delivery_key = {"kind": "operation", "operation_id": operation}
    history = [{
        "id": "question", "role": "user", "content": "QUESTION_AWAITING_REPLY",
        "ts": 1791361837.87, "speaker_authority": "owner",
        "transcript_slot": {"kind": "accepted_user"}, "delivery_key": delivery_key,
    }]
    if history_error:
        history.append({
            "id": "failure", "role": "assistant", "kind": "transport_failure",
            "content": failure, "ts": 1791362060.42, "delivery_key": delivery_key,
        })
    events = [
        {"type": "run_started", "run_id": "cancelled-run", "thread_id": "keeper:alpha"},
        {"type": "text_message_start", "message_id": "cancelled-message", "role": "assistant"},
    ]
    if partial:
        events.append({"type": "text_delta", "delta": "PARTIAL_REPLY"})
    events.append({"type": "event_error", "message": failure})
    lines = [{"v": 1, "seq": seq, "ts": 1791361837.87 + seq, "event": event}
             for seq, event in enumerate(events)]
    requested = threading.Event()

    def journal(path):
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)
        if query.get("operation_id") != [operation]:
            return 400, {"error": "unexpected operation", "query": query}
        since = int(query.get("since_seq", ["-1"])[0])
        requested.set()
        return 200, {
            "schema": "masc.keeper_chat_events.v2", "operation_id": operation,
            "events": [line for line in lines if line["seq"] > since],
            "has_more": False, "next_since_seq": lines[-1]["seq"],
            "next_since_offset": 1000,
        }

    fixtures["/api/v1/keepers/alpha/chat/history"] = (200, history)
    fixtures["/api/v1/keepers/alpha/chat/events"] = h.PathHttpResponse(journal)
    fixtures["/api/v1/keepers/alpha/memory-journal?limit=20"] = (200, {"entries": []})

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"MASC Dashboard", start=0, timeout=5)
        h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.palette_go(process, fd, output, b"keeper alpha", b"QUESTION_AWAITING_REPLY")
        if not h.wait_for_fixture_event(process, fd, output, requested, timeout=5):
            raise AssertionError("opening the conversation did not read its journal")
        if partial:
            h.wait_for_output(process, fd, output, b"PARTIAL_REPLY", start=0, timeout=5)
        h.wait_for_output(process, fd, output, failure.encode(), start=0, timeout=5)
        h.drain_until_quiet(process, fd, output)
        screen = h.screen_text(bytes(output))
        for text, count in [(b"QUESTION_AWAITING_REPLY", 1), (failure.encode(), 1),
                            (b"PARTIAL_REPLY", int(partial)), (b"ERROR", 1)]:
            if screen.count(text) != count:
                raise AssertionError(f"expected {count} occurrences of {text!r}: {screen!r}")
        h.send_and_wait(process, fd, output, b"\x11", b"MASC Keepers")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable, description=f"Replayed chat failure partial={partial} history_error={history_error}",
        interact=interact, http_fixtures=fixtures, refresh=3600.0,
        terminal_rows=36, terminal_cols=120,
    )


if __name__ == "__main__":
    for partial in (False, True):
        for history_error in (False, True):
            run(os.path.abspath(sys.argv[1]), partial=partial, history_error=history_error)
    print("tui replayed chat failure: PASS")
