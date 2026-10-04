"""Loading warnings stay short; their full details remain local and readable."""
import json
import os
import sys

import tui_keyboard_chat as _keyboard_chat
import tui_keyboard_harness as _keyboard_harness


HISTORY = "history-cause " + "transport diagnostic " * 5 + "history-tail 증거"
MEMORY = "journal-cause " + "journal diagnostic " * 4 + "journal-tail 증거"


def snapshot(process, fd, output):
    _keyboard_harness.drain_until_quiet(process, fd, output)
    rows = _keyboard_harness.screen_rows(bytes(output))
    return rows, _keyboard_chat.unwrapped(b"\n".join(rows.values()))


def inspect_errors(process, fd, output, needle):
    _keyboard_harness.send_and_wait(process, fd, output, b"/err", b"Commands  1/1")
    # Accept the suggestion, then execute the local command.
    _keyboard_harness.send_and_wait(process, fd, output, b"\r", _keyboard_harness.composer_showing(b"/errors"))
    _keyboard_harness.send_and_wait(process, fd, output, b"\r", needle)


def run(binary):
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    reads = {"history": 0, "memory": 0}
    requests = []

    def failure(subject, detail):
        def response():
            reads[subject] += 1
            return _keyboard_harness.RawHttpResponse(
                503, json.dumps({"error": detail}, ensure_ascii=False).encode(),
                content_type="application/json",
            )
        return response

    fixtures["/api/v1/keepers/alpha/chat/history"] = failure("history", HISTORY)
    fixtures["/api/v1/keepers/alpha/memory-journal?limit=20"] = failure("memory", MEMORY)
    beta_history = _keyboard_harness.GatedHttpResponse((200, []), hold_seconds=20.0)
    fixtures["/api/v1/keepers/beta/chat/history"] = beta_history
    fixtures["/api/v1/keepers/beta/memory-journal?limit=20"] = (200, {"keeper": "beta", "entries": []})

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.resize_and_wait(process, fd, output, rows=48, columns=50, needle=b"MASC Dashboard")
        _keyboard_harness.send_and_wait(process, fd, output, b"3", b"alpha")
        _keyboard_harness.palette_go(process, fd, output, b"keeper alpha", b"History load failed")
        _keyboard_harness.wait_for_output(process, fd, output, b"Memory load failed", start=0, timeout=3.0)
        rows, plain = snapshot(process, fd, output)
        assert b"History load failed" in plain and b"Memory load failed" in plain
        for label in (b"History load failed", b"Memory load failed"):
            warning = rows[_keyboard_harness.screen_row_of(rows, label)]
            assert b"/errors" in warning, "short warning lost its detail action"
        assert b"history-cause" not in plain and b"journal-cause" not in plain, "raw failures still crowd the input"
        # Summary -> full -> hidden; inspection must still include the failure.
        for _ in range(2):
            _keyboard_harness.write_all(fd, output, b"\x0e")
            _keyboard_harness.drain_until_quiet(process, fd, output)
        rows, _ = snapshot(process, fd, output)
        assert _keyboard_harness.screen_row_of(rows, b"Memory load failed") == -1, "memory warning was not hidden"
        before_reads, before_posts = reads.copy(), len(requests)
        inspect_errors(process, fd, output, b"journal-tail")
        rows, plain = snapshot(process, fd, output)
        for detail in (HISTORY, MEMORY):
            assert _keyboard_chat.unwrapped(detail.encode()) in plain, f"full error was cut or reordered: {plain!r}"
        assert reads == before_reads, "reading errors retried a history or journal request"
        assert len(requests) == before_posts, "reading errors sent work to a Keeper"
        assert all(_keyboard_harness.fixture_cell_width(row.decode()) <= 50 for row in rows.values()), "narrow error view overflowed"
        print("CHAT_LOAD_ERRORS_FRAME " + json.dumps({str(k): v.decode() for k, v in rows.items()}, ensure_ascii=False))
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        _keyboard_harness.palette_go(process, fd, output, b"keeper beta", "Keepers ▸ beta ▸ chat".encode())
        try:
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output, beta_history.requested.is_set, timeout=3.0), "beta history request did not start"
            assert not beta_history.completed.is_set(), "beta gate ended before error inspection"
            # At 50 columns the local notice wraps before "recorded.".
            # Wait for its first line, then check the complete screen text.
            inspect_errors(process, fd, output, b"No chat loading errors")
            _, plain = snapshot(process, fd, output)
            assert b"No chat loading errors recorded." in plain, "empty-error notice lost its wrapped tail"
            assert b"history-cause" not in plain and b"journal-cause" not in plain, "another Keeper inherited alpha's errors"
        finally:
            beta_history.release.set()
        assert _keyboard_harness.wait_for_fixture_state(process, fd, output, beta_history.completed.is_set, timeout=3.0)
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        binary, description="Chat loading errors retain full details without retry or cross-Keeper leakage",
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        extra_env={"NO_COLOR": "1"},
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("chat loading error details: PASS")
