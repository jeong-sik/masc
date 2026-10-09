"""History keeps independent sources visible and retries them from the reader."""
import os
import sys

import tui_keyboard_harness as h
import test_tui_code_history_layout_pty as history


def run(executable, columns):
    requests = []
    fixtures = history.fixtures(False, requests)
    # Capture the original callable payload, then vary each source independently.
    mode = {"git": False, "activity": True, "git_reads": 0, "activity_reads": 0}
    original_git = fixtures["/api/v1/git/log"]
    original_activity = fixtures["/api/v1/ide/file-activity"]

    def git(path):
        mode["git_reads"] += 1
        if not mode["git"]:
            return 503, {"error": "git source offline"}
        return original_git.resolve(path)

    def activity(path):
        mode["activity_reads"] += 1
        if not mode["activity"]:
            return 503, {"error": "activity source offline"}
        return original_activity.resolve(path)

    fixtures["/api/v1/git/log"] = h.PathHttpResponse(git)
    fixtures["/api/v1/ide/file-activity"] = h.PathHttpResponse(activity)

    def go_top(process, fd, output):
        # Home redraws only when the reader was scrolled. At its first row the
        # frame is unchanged and the presenter writes nothing, so a wait for a
        # newly drawn "rows 1-" never ends. Wait for the reader's state.
        h.write_all(fd, output, b"\x1b[H")
        assert h.wait_for_fixture_state(process, fd, output,
            lambda: history.window(output, columns)[0] == 1, timeout=3), \
            "history reader did not return to its first row"

    def read_document(process, fd, output):
        go_top(process, fd, output)
        parts = {}
        while True:
            first, last, total, body = history.window(output, columns)
            # PageDown preserves one row of overlap; collect each document
            # row once so a wrapped source error remains contiguous.
            parts.update((first + index, row) for index, row in enumerate(body))
            if last == total:
                return "".join("".join(parts[index].split()) for index in sorted(parts))
            step = max(1, last - first)
            h.send_and_wait(process, fd, output, b"\x1b[6~",
                f"rows {min(total, first + step)}-".encode())

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go code", b"[draft]")
        h.send_and_wait(process, fd, output, b"\r", b"local lock = 1")
        h.resize_and_wait(process, fd, output, rows=30, columns=columns,
            needle=b"local lock = 1", controls=(h.FULL_REDRAW,))
        # The source label and long Keeper name wrap separately at 60 columns.
        h.send_and_wait(process, fd, output, b"H", b"Keeper:")
        document = read_document(process, fd, output)
        assert "Githistoryunavailable" in document, document
        assert "KEEPERTAIL" in document, document
        assert "TASKTAIL" in document and "EXECTAIL" in document, document
        assert mode["activity_reads"] == 1, mode

        # r retries both sources without leaving the history overlay.
        mode.update(git=True, activity=False)
        go_top(process, fd, output)
        h.send_and_wait(process, fd, output, b"r", b"Commit: abc1234")
        document = read_document(process, fd, output)
        assert "activitysourceoffline" in document, document
        assert "KEEPERTAIL" not in document, document
        assert "Githistoryunavailable" not in document, document

        mode.update(git=False, activity=False)
        go_top(process, fd, output)
        # The HTTP error wraps after "source" at 60 columns. Wait for the
        # new source state, then check the complete error across its rows.
        h.send_and_wait(process, fd, output, b"r", b"Git history unavailable")
        document = read_document(process, fd, output)
        assert "gitsourceoffline" in document, document
        assert "activitysourceoffline" in document, document
        assert "abc1234" not in document, document
        assert "nocommitorexactKeeperchangetouches" not in document, document

        mode.update(git=True, activity=True)
        go_top(process, fd, output)
        h.send_and_wait(process, fd, output, b"r", b"Commit: abc1234")
        document = read_document(process, fd, output)
        assert "KEEPERTAIL" in document, document
        assert "unavailable" not in document, document
        assert mode["git_reads"] == mode["activity_reads"] == 4, mode
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
        description=f"Code history independent sources and retry {columns}",
        interact=interact, http_fixtures=fixtures)


def run_unconfirmed_first_overlay(executable, key):
    """Opening an overlay without an earlier fetch retains the selected file."""
    import threading
    from urllib.parse import parse_qs, urlsplit

    requests = []
    fixtures = history.fixtures(False, requests)
    lock = threading.Lock()
    state = {"unconfirmed": False}
    reads = []
    full_health = fixtures["/health?full=1"]

    def health(path):
        with lock:
            unread = state["unconfirmed"]
        if unread:
            return h.RawHttpResponse(503, b'{"error":"identity unread"}',
                                     content_type="application/json")
        return full_health if "full=1" in path else (200, {"status": "ok"})

    for path in ("/health", "/health?full=1"):
        fixtures[path] = h.PathHttpResponse(health)
    diff = (200, {"has_changes": True, "unified": [
        {"kind": "delete", "oldLine": 1, "newLine": None,
         "text": "previous-overlay-recovery-proof"}]})
    for endpoint in ("/api/v1/git/log", "/api/v1/ide/file-activity", "/api/v1/git/diff"):
        original = diff if endpoint == "/api/v1/git/diff" else fixtures[endpoint]
        def capture(path, original=original):
            with lock:
                reads.append((state["unconfirmed"], path))
            return original.resolve(path) if isinstance(original, h.PathHttpResponse) else original
        fixtures[endpoint] = h.PathHttpResponse(capture)

    def snapshot():
        with lock:
            return list(reads)

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go code", b"[draft]")
        h.send_and_wait(process, fd, output, b"\r", b"local lock = 1")
        h.resize_and_wait(process, fd, output, rows=40, columns=200,
                          needle=b"local lock = 1", controls=(h.FULL_REDRAW,))
        assert not snapshot(), ("fixture must open an overlay with no previous read", snapshot())
        with lock:
            state["unconfirmed"] = True
        h.send_and_wait(process, fd, output, b"r", b"workspace identity unconfirmed")
        title = b"history: " if key == b"H" else b"diff col 1 vs HEAD: "
        h.send_and_wait(process, fd, output, key, title)
        assert not snapshot(), ("unconfirmed first-open dispatched an overlay read", snapshot())
        with lock:
            state["unconfirmed"] = False
        # Only recovery is requested; H/d is not repeated to manufacture intent.
        expected = b"Commit: abc1234" if key == b"H" else b"previous-overlay-recovery-proof"
        h.send_and_wait(process, fd, output, b"r", expected)
        endpoint = "/api/v1/git/log" if key == b"H" else "/api/v1/git/diff"
        target_reads = [path for unread, path in snapshot()
                        if not unread and urlsplit(path).path == endpoint]
        assert target_reads, snapshot()
        assert all(parse_qs(urlsplit(path).query).get("path") == [history.FILE]
                   for path in target_reads), target_reads
        assert not any(unread for unread, _path in snapshot()), snapshot()
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
        description=f"Code {key.decode()} first-open intent resumes after workspace confirmation",
        interact=interact, http_fixtures=fixtures, refresh=60.0)


if __name__ == "__main__":
    for width in (60, 120):
        run(os.path.abspath(sys.argv[1]), width)
    for key in (b"H", b"d"):
        run_unconfirmed_first_overlay(os.path.abspath(sys.argv[1]), key)
    print("Code history independent sources, retry and first-open recovery: PASS")
