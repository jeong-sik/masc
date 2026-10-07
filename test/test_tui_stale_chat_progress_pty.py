"""Open chat with a failed, unterminated old journal beside a current execution."""

import os
import sys
import threading
import time
import urllib.parse

import tui_keyboard_harness as h


def run(executable: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    now = time.time()
    old, current = "yesterday-cancelled", "current-execution"
    failure = "OWNER_CANCELLED_YESTERDAY"
    history = [
        {"id": operation, "role": "user", "content": question, "ts": at,
         "speaker_authority": "owner", "transcript_slot": {"kind": "accepted_user"},
         "delivery_key": {"kind": "operation", "operation_id": operation}}
        for operation, question, at in [
            (old, "OLD_QUESTION", now - 105000), (current, "CURRENT_QUESTION", now - 5)]
    ]
    journals = {}
    for operation, at, runtime in [(old, now - 105000, "OLD_RUNTIME"),
                                   (current, now - 5, "CURRENT_RUNTIME")]:
        events = [
            {"type": "run_started", "run_id": operation, "thread_id": "keeper:alpha"},
            {"type": "text_message_start", "message_id": operation + "-message", "role": "assistant"},
            {"type": "agent_core_runtime_attempt_started", "runtime_id": runtime, "attempt_index": 0},
            {"type": "text_delta", "delta": "OLD_PARTIAL" if operation == old else "CURRENT_PARTIAL"},
        ]
        journals[operation] = [{"v": 1, "seq": seq, "ts": at + seq, "event": event}
                               for seq, event in enumerate(events)]
    read_old_state = threading.Event()
    current_state_reads = []

    def operation(path):
        identity = urllib.parse.unquote(urllib.parse.urlsplit(path).path.rsplit("/", 1)[-1])
        result = {"schema": "masc.keeper_chat_operation.v1", "operation_id": identity}
        if identity == old:
            read_old_state.set()
            result.update(state="Failed", completed_at=now - 104990,
                          failure_kind="Turn_cancelled", failure_detail=failure)
        elif identity == current:
            current_state_reads.append(identity)
            if len(current_state_reads) == 1:
                result.update(state="Queued")
            else:
                result.update(state="Running", started_at=now - 5)
        else:
            return 404, {"error": "unknown_operation"}
        return 200, result

    def journal(path):
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)
        identity = query["operation_id"][0]
        rows = journals[identity]
        since = int(query.get("since_seq", ["-1"])[0])
        return 200, {"schema": "masc.keeper_chat_events.v2", "operation_id": identity,
                     "events": [row for row in rows if row["seq"] > since],
                     "has_more": False, "next_since_seq": rows[-1]["seq"], "next_since_offset": 1000}

    fixtures["/api/v1/keepers/alpha/chat/history"] = (200, history)
    fixtures["/api/v1/keepers/alpha/chat/events"] = h.PathHttpResponse(journal)
    for identity in (old, current):
        fixtures[f"/api/v1/keepers/alpha/chat/operations/{identity}"] = h.PathHttpResponse(operation)
    fixtures["/api/v1/keepers/alpha/memory-journal?limit=20"] = (200, {"entries": []})

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"MASC Dashboard", start=0, timeout=5)
        h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.palette_go(process, fd, output, b"keeper alpha", b"CURRENT_QUESTION")
        h.wait_for_output(process, fd, output, b"OLD_PARTIAL", start=0, timeout=5)
        if not h.wait_for_fixture_event(process, fd, output, read_old_state, timeout=5):
            raise AssertionError("reopened incomplete journal never reconciled its exact operation")
        h.wait_for_output(process, fd, output, failure.encode(), start=0, timeout=5)
        h.drain_until_quiet(process, fd, output)
        screen = h.screen_text(bytes(output))
        for text in (b"OLD_PARTIAL", b"CURRENT_PARTIAL", failure.encode()):
            if screen.count(text) != 1:
                raise AssertionError(f"expected one retained {text!r}: {screen!r}")
        progress = [line for line in screen.splitlines() if b"IN PROGRESS" in line]
        if len(current_state_reads) < 2:
            raise AssertionError("the queued observation was not reconciled after the journal read")
        if len(progress) != 1 or b"CURRENT_RUNTIME" not in progress[0] or b"OLD_RUNTIME" in progress[0]:
            raise AssertionError(f"progress does not identify the current execution: {screen!r}")
        h.send_and_wait(process, fd, output, b"\x11", b"MASC Keepers")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Historical failed journal cannot own current progress",
                            interact=interact, http_fixtures=fixtures, refresh=3600.0,
                            terminal_rows=42, terminal_cols=140)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("tui stale chat progress: PASS")
