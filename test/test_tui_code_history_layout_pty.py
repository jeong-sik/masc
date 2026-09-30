"""Read complete history and open owners of wrapped or short records."""
import os
import re
import sys
import unicodedata
from urllib.parse import parse_qs, urlsplit
import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_keys.ml",
    "bin/masc_tui_render_code.ml",
    "bin/masc_tui_render_code.mli",
)
FILE = "notes/[draft](final).lua"
AUTHOR = "AUTHORHEAD-`literal`-" + "a" * 110 + "-AUTHORTAIL"
SUBJECT = "SUBJECTHEAD fix glob **/*.ml preserve `literal` " + "한글 history evidence " * 45 + " SUBJECTTAIL (#7654)"
TASK = "task-" + "t" * 95 + "-TASKTAIL"
EXECUTION = "exec-" + "e" * 115 + "-EXECTAIL"
WINDOW = re.compile(r"rows (\d+)-(\d+) of (\d+)")


def cell_width(text):
    return sum(0 if unicodedata.combining(char) else
               2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
               for char in text)


def from_cell(text, boundary):
    cells = 0
    for index, char in enumerate(text):
        if cells == boundary:
            return text[index:]
        cells += cell_width(char)
        assert cells <= boundary, (boundary, text)
    assert cells == boundary, (boundary, text)
    return ""


def completed(output):
    end = output.rfind(h.FRAME_END)
    assert end >= 0, "No completed redraw"
    return bytes(output[:end + len(h.FRAME_END)])


def window(output, columns):
    rows = h.screen_rows(completed(output))
    position, match = next((row, WINDOW.search(text.decode("utf-8")))
        for row, text in sorted(rows.items()) if WINDOW.search(text.decode("utf-8")))
    first, last, total = map(int, match.groups())
    # Locate the reader in the rendered frame: a wide terminal can reserve
    # an Activity pane and still render Code without its left tree.
    counter = rows[position].decode("utf-8", errors="strict")
    boundary = cell_width(counter[:match.start()])
    # The Recent pane starts one cell after its left border. Its header,
    # rather than any memo/history payload, identifies the right boundary.
    right = columns
    for text in rows.values():
        header = text.decode("utf-8", errors="strict")
        marker = header.find("[Recent]")
        if marker >= 0:
            right = cell_width(header[:marker]) - 1
            break
    assert boundary < right <= columns, (boundary, right, columns)
    body = []
    for index in range(last - first + 1):
        text = rows.get(position + 1 + index, b"").decode("utf-8", errors="strict")
        assert cell_width(text) <= columns, (columns, text)
        suffix = from_cell(text, right)
        prefix = text[:len(text) - len(suffix)]
        body.append(from_cell(prefix, boundary))
    return first, last, total, body


def fixtures(short, requests):
    result = h.code_memo_fixtures()
    result[h.WORKSPACE_TREE_ROOT_PATH] = (200, [{
        "path": FILE, "label": FILE, "depth": 0, "parent": "",
        "hasChildren": False, "diff": None, "keeperId": None, "hueIndex": None}])
    result["/api/v1/workspace/file"] = (200, {"ok": True, "content":
        "local lock = 1\nlocal target = 2\nlocal function read() return lock end\n"})
    commits = [{"hash": "abc1234", "timestamp_ms": 1787600200000,
                "author": "alpha" if short else AUTHOR,
                "subject": "first (#7654)" if short else SUBJECT}]
    if short:
        commits.append({"hash": "xyz7890", "timestamp_ms": 1787600100000,
                        "author": "beta", "subject": "second (#8765)"})
    result["/api/v1/git/log"] = (200, {"ok": True, "commits": commits})
    changes = [] if short else [{
        "at": 1787600100, "keeper": "keeper-" + "k" * 80 + "-KEEPERTAIL",
        "turn": 37, "task_id": TASK, "execution_id": EXECUTION,
        "location": {"kind": "repo", "repo_id": "masc", "path": FILE},
        "change": {"kind": "edit", "before": "local target = 1", "after": "local target = 2"},
        "succeeded": True, "line_evidence": {"kind": "edit", "occurrence_count": 1,
            "occurrences": [{"old_range": {"start_line": 2, "end_line": 2},
                             "new_range": {"start_line": 2, "end_line": 2}}]}}]
    result["/api/v1/ide/file-activity"] = (200, {"ok": True, "data": {
        "schema": "masc.ide.file_activity.v1", "codebase": "/fixture", "repo_id": "masc",
        "file_path": FILE, "window_hours": 24, "calls_in_window": len(changes),
        "changes": changes, "incomplete_over_budget": 0, "incomplete_malformed": 0,
        "unattributed_over_budget": 0, "unattributed_malformed": 0}})
    # The shared http_requests ledger records writes only. Capture these GET
    # routes through their actual fixture callbacks without changing that ledger.
    for endpoint in ("/api/v1/workspace/file", "/api/v1/git/log",
                     "/api/v1/ide/file-activity"):
        response = result[endpoint]
        def capture(path, response=response):
            requests.append((path, b""))
            return response
        result[endpoint] = h.PathHttpResponse(capture)
    return result


def run(executable, columns, no_color, short=False):
    requests = []
    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go code", b"[draft]")
        h.send_and_wait(process, fd, output, b"\r", b"local lock = 1")
        h.read_available(fd, output)
        start = len(output)
        h.resize_and_wait(process, fd, output, rows=40 if short else 18, columns=columns,
                          needle=b"local lock = 1", controls=(h.FULL_REDRAW,))
        h.wait_for_output(process, fd, output, h.FRAME_END,
                          start=h.end_of_needle(output, b"local lock = 1", start), timeout=3)
        h.send_and_wait(process, fd, output, b"H", b"Commit: abc1234")
        screen = h.screen_text(completed(output)).decode("utf-8")
        assert "Esc:back" in screen, (columns, no_color, screen)
        if short:
            first, last, total, _ = window(output, columns)
            assert first == 1 and last == total, (first, last, total)
            h.send_and_wait(process, fd, output, b"jjjj", b"rows 5-")
            assert window(output, columns)[3][0].strip() == "Commit: xyz7890"
            h.send_and_wait(process, fd, output, b"\r", b"#8765 --")
            h.send_and_wait(process, fd, output, b"\x1b[H", b"rows 1-")
            h.send_and_wait(process, fd, output, b"\r", b"#7654 --")
        else:
            captured = {}
            while True:
                first, last, total, body = window(output, columns)
                captured.update((first + index, line.strip()) for index, line in enumerate(body))
                if last == total:
                    break
                height = last - first + 1
                expected_first = min(total, first + max(1, height - 1))
                h.send_and_wait(process, fd, output, b"\x1b[6~", f"rows {expected_first}-".encode())
            compact = "".join("".join(captured[index].split()) for index in sorted(captured))
            for field in (AUTHOR, SUBJECT, TASK, EXECUTION, "KEEPERTAIL", "Turn:37", "Result:applied", "File:" + FILE, "Scope:Project", "Coverage:"):
                assert "".join(field.split()) in compact, (columns, field, compact)
            h.send_and_wait(process, fd, output, b"\x1b[F", f"rows {total}-".encode())
            assert window(output, columns)[:2] == (total, total)
            h.send_and_wait(process, fd, output, b"\x1b[H", b"rows 1-")
            # A continuation of a long author still belongs to the commit.
            author_first = next(index for index, line in captured.items() if line.startswith("Author:"))
            target = author_first + 1
            h.send_and_wait(process, fd, output, b"j" * (target-1), f"rows {target}-".encode())
            # Enter adds a wrapped file note. Its total changes the counter
            # even when the title cannot fit the PR number at30 columns.
            h.send_and_wait(process, fd, output, b"\r", b"rows ")
            h.send_and_wait(process, fd, output, b"\x1b[H", b"rows 1-")
            answered = {}
            while True:
                first, last, total, body = window(output, columns)
                answered.update((first + index, line) for index, line in enumerate(body))
                if last == total:
                    break
                step = max(1, last - first)
                h.send_and_wait(process, fd, output, b"\x1b[6~", f"rows {min(total, first+step)}-".encode())
            answer_text = "".join("".join(answered[index].split()) for index in sorted(answered))
            assert "Filenote:#7654--thisscopehasno" in answer_text, (columns, answer_text)
            h.send_and_wait(process, fd, output, b"\x1b[H", b"rows 1-")
            keeper_first = next(index for index, line in captured.items() if line.startswith("Keeper:"))
            h.send_and_wait(process, fd, output, b"j" * keeper_first,
                            f"rows {keeper_first+1}-".encode())
            jumped = h.send_and_wait(process, fd, output, b"\r", b"local target = 2")
            assert re.search(rb"\x1b\[7m\s+2\x1b\[0m", jumped), jumped
            h.send_and_wait(process, fd, output, b"H", b"rows 1-")
            assert window(output, columns)[0] == 1
        # Query escaping belongs to the client; compare the decoded identity.
        for endpoint, field in (("/api/v1/workspace/file", "path"),
                                ("/api/v1/git/log", "path"),
                                ("/api/v1/ide/file-activity", "file_path")):
            queries = [parse_qs(urlsplit(path).query) for path, _ in requests
                       if urlsplit(path).path == endpoint]
            assert queries and all(query.get(field) == [FILE] for query in queries), (endpoint, queries)
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
        description=f"Code history full metadata/owner {columns} NO_COLOR={no_color} short={short}",
        interact=interact, http_fixtures=fixtures(short, requests),
        extra_env={"NO_COLOR": "1"} if no_color else {})


if __name__ == "__main__":
    for plain in (False, True):
        for width in (30, 40, 60, 80, 120, 160):
            run(os.path.abspath(sys.argv[1]), width, plain)
        run(os.path.abspath(sys.argv[1]), 100, plain, short=True)
    print("Code history complete metadata and top-row owner selection: PASS")
