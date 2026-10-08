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


if __name__ == "__main__":
    for width in (60, 120):
        run(os.path.abspath(sys.argv[1]), width)
    print("Code history independent sources and retry: PASS")
