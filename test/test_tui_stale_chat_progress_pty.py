"""Open chat with a failed, unterminated old journal beside a current execution."""

import os
import sys
import threading
import time
import urllib.parse

import tui_keyboard_harness as h


def run(executable: str, *, refresh_fails: bool = False) -> None:
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
            if refresh_fails:
                if len(current_state_reads) > 1:
                    return 503, {"error": "operation refresh temporarily unavailable"}
                result.update(state="Running", started_at=now - 5)
            elif len(current_state_reads) == 1:
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
            raise AssertionError("the nonterminal observation was not rechecked after the journal read")
        if len(progress) != 1 or b"CURRENT_RUNTIME" not in progress[0] or b"OLD_RUNTIME" in progress[0]:
            raise AssertionError(f"progress does not identify the current execution: {screen!r}")
        h.send_and_wait(process, fd, output, b"\x11", b"MASC Keepers")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
                            description=("A failed operation recheck preserves current progress"
                                         if refresh_fails else
                                         "Historical failed journal cannot own current progress"),
                            interact=interact, http_fixtures=fixtures, refresh=3600.0,
                            terminal_rows=42, terminal_cols=140)


def unavailable_journal_operation_recovers(executable: str) -> None:
    """A later history refresh recovers the operation without retrying its lost journal.

    The first read retains partial output. The next read loses both endpoints;
    journal pruning is permanent, whereas the operation's 503 is temporary.
    A third explicit refresh must display the recovered exact failure without
    another journal GET, a fabricated final reply, or a replayed POST.
    """
    fixtures = h.keeper_runtime_http_fixtures()
    operation_id = "operation-with-pruned-journal"
    now = time.time()
    partial = b"PARTIAL_BEFORE_JOURNAL_PRUNING"
    failure = b"RECOVERED_EXACT_OPERATION_FAILURE"
    lock = threading.Lock()
    phase = "initial"
    reads = []
    posts = []
    history_path = "/api/v1/keepers/alpha/chat/history"
    operation_path = f"/api/v1/keepers/alpha/chat/operations/{operation_id}"
    events = [
        {"type": "run_started", "run_id": operation_id, "thread_id": "keeper:alpha"},
        {"type": "text_message_start", "message_id": "partial-message", "role": "assistant"},
        {"type": "text_delta", "delta": partial.decode()},
    ]
    rows = [{"v": 1, "seq": seq, "ts": now + seq, "event": event}
            for seq, event in enumerate(events)]

    def snapshot(kind):
        with lock:
            current = phase
            reads.append((kind, current))
            return current

    def history():
        current = snapshot("history")
        question = "QUESTION_TO_RECOVER_FINAL_CHECK" if current == "verified" else "QUESTION_TO_RECOVER"
        return 200, [{"id": operation_id, "role": "user", "content": question,
                      "ts": now, "speaker_authority": "owner",
                      "transcript_slot": {"kind": "accepted_user"},
                      "delivery_key": {"kind": "operation", "operation_id": operation_id}}]

    def operation():
        current = snapshot("operation")
        if current == "broken":
            return 503, {"error": "operation temporarily unavailable"}
        result = {"schema": "masc.keeper_chat_operation.v1", "operation_id": operation_id}
        if current == "initial":
            result.update(state="Running", started_at=now)
        else:
            result.update(state="Failed", completed_at=now + 10,
                          failure_kind="Turn_cancelled", failure_detail=failure.decode())
        return 200, result

    def journal(path):
        current = snapshot("journal")
        if current != "initial":
            return 410, {"error": "journal_pruned", "message": "fixture journal was pruned"}
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)
        since = int(query.get("since_seq", ["-1"])[0])
        return 200, {"schema": "masc.keeper_chat_events.v2", "operation_id": operation_id,
                     "events": [row for row in rows if row["seq"] > since],
                     "has_more": False, "next_since_seq": rows[-1]["seq"],
                     "next_since_offset": 1000}

    fixtures[history_path] = history
    fixtures[operation_path] = operation
    fixtures["/api/v1/keepers/alpha/chat/events"] = h.PathHttpResponse(journal)
    fixtures["/api/v1/keepers/alpha/memory-journal?limit=20"] = (200, {"entries": []})

    def interact(process, fd, _slave, output, _base):
        nonlocal phase

        def visible():
            return h.screen_text(bytes(output))

        def wait_screen(needle):
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: needle in visible(), timeout=8), visible()

        def reopen():
            h.send_and_wait(process, fd, output, b"\x11", b"MASC Keepers")
            h.palette_go(process, fd, output, b"keeper alpha", b"QUESTION_TO_RECOVER")

        h.wait_for_output(process, fd, output, b"MASC Dashboard", start=0, timeout=8)
        h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.palette_go(process, fd, output, b"keeper alpha", b"QUESTION_TO_RECOVER")
        wait_screen(partial)
        with lock:
            phase = "broken"
        reopen()
        wait_screen("저널 갱신 불가".encode())
        with lock:
            assert ("operation", "broken") in reads, reads
            assert ("journal", "broken") in reads, reads
            journal_reads = sum(kind == "journal" for kind, _ in reads)
            operation_reads = sum(kind == "operation" for kind, _ in reads)
            phase = "recovered"
        reopen()
        wait_screen(failure)
        assert visible().count(partial) == 1, visible()
        assert visible().count(failure) == 1, visible()
        with lock:
            assert sum(kind == "operation" for kind, _ in reads) == operation_reads + 1, reads
            assert sum(kind == "journal" for kind, _ in reads) == journal_reads, reads
            operation_reads += 1
            phase = "verified"
        reopen()
        # Changed history content proves this refresh was applied, not only
        # that a fixture handler returned or an old failure remained visible.
        wait_screen(b"QUESTION_TO_RECOVER_FINAL_CHECK")
        h.drain_until_quiet(process, fd, output)
        wait_screen(failure)
        with lock:
            assert sum(kind == "operation" for kind, _ in reads) == operation_reads, reads
            assert sum(kind == "journal" for kind, _ in reads) == journal_reads, reads
        assert not [path for path, _ in posts if path != "/mcp"], posts
        h.send_and_wait(process, fd, output, b"\x11", b"MASC Keepers")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
        description="A pruned journal cannot suppress exact operation recovery",
        interact=interact, http_fixtures=fixtures, http_requests=posts,
        refresh=3600.0, terminal_rows=42, terminal_cols=140)
    assert not [path for path, _ in posts if path != "/mcp"], posts


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    run(executable)
    run(executable, refresh_fails=True)
    unavailable_journal_operation_recovers(executable)
    print("tui stale chat progress: PASS (3 scenarios)")
