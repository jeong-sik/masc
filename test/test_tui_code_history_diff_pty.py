"""Read recorded attempts in History without requesting today's Git diff."""
import os
import sys
import base64
import json
import hashlib
from copy import deepcopy

import tui_keyboard_harness as h
import test_tui_code_history_layout_pty as history


def select_row(process, fd, output, columns, row):
    current = history.window(output, columns)[0]
    if current != row:
        key = b"j" if row > current else b"k"
        h.send_and_wait(process, fd, output, key * abs(row - current), f"rows {row}-".encode())


def capture(process, fd, output, name, columns, needle):
    h.resize_and_wait(process, fd, output, rows=30, columns=columns + 1,
        needle=needle, controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
    frame = h.resize_and_wait(process, fd, output, rows=30, columns=columns,
        needle=needle, controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
    rows = h.screen_rows(frame)
    print("STUDIO_CAPTURE=" + json.dumps({
        "suite": "test_tui_code_history_diff_pty", "name": name,
        "rows": 30, "columns": columns, "provenance": "CI fixture PTY",
        "frame_b64": base64.b64encode(frame).decode(),
        "screen": b"\n".join(rows.get(row, b"") for row in range(1, 31)).decode(errors="replace")}), flush=True)


def run(executable, columns, succeeded, kind):
    requests = []
    fixtures = history.fixtures(False, requests)
    fixtures["/api/v1/git/log"] = (200, {"ok": True, "commits": []})
    original = fixtures["/api/v1/ide/file-activity"]
    status, payload = original.resolve("/api/v1/ide/file-activity")
    change = payload["data"]["changes"][0]
    edit_evidence = deepcopy(change["line_evidence"])
    change.update(keeper="alpha", task_id="task-record", execution_id="exec-record", succeeded=succeeded)
    if kind == "edit":
        change["change"].update(before="old-value " + "x" * 150 + " OLDTAIL",
            after="new-value " + "y" * 150 + " NEWTAIL", replace_all=True)
    elif kind == "write":
        change["change"] = {"kind": "write", "content": "written-content"}
        change["line_evidence"] = {"kind": "write", "new_range": {"start_line": 1, "end_line": 1}}
    elif kind == "indent":
        change["change"].update(before="  return  value\n\n  done",
            after="    return  value\n\n    done")
    if not succeeded:
        change.pop("line_evidence")
    second = deepcopy(change)
    second.update(keeper="beta", at=change["at"] - 1, succeeded=True)
    second["change"] = {"kind": "edit", "before": "second-before", "after": "second-after"}
    second["line_evidence"] = edit_evidence
    payload["data"]["changes"].append(second)
    payload["data"]["calls_in_window"] = 2
    fixtures["/api/v1/ide/file-activity"] = (status, payload)
    diff_requests = []
    def git_diff(path):
        diff_requests.append(path)
        return 500, {"error": "recorded history must not fetch working tree"}
    fixtures["/api/v1/git/diff"] = h.PathHttpResponse(git_diff)

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go code", b"[draft]")
        h.send_and_wait(process, fd, output, b"\r", b"local lock = 1")
        h.resize_and_wait(process, fd, output, rows=30, columns=columns,
            needle=b"local lock = 1", controls=(h.FULL_REDRAW,))
        h.send_and_wait(process, fd, output, b"H", b"Keeper: alpha")
        before_total = history.window(output, columns)[2]
        h.send_and_wait(process, fd, output, b"d", b"Recorded change" if succeeded else b"Recorded attempt")
        if columns == 60 and succeeded and kind == "indent":
            capture(process, fd, output, "recorded-indentation", columns, b"Recorded change")
        captured = {}
        while True:
            first, last, total, body = history.window(output, columns)
            captured.update((first + index, line.rstrip()) for index, line in enumerate(body))
            if last == total:
                break
            step = max(1, last - first)
            h.send_and_wait(process, fd, output, b"\x1b[6~", f"rows {min(total, first+step)}-".encode())
        document = " ".join(line.strip() for line in captured.values())
        if kind == "edit":
            for text in ("- old-value", "+ new-value", "OLDTAIL", "NEWTAIL", "replace_all"):
                assert text in document, (text, document)
        elif kind == "write":
            assert "+ written-content" in document, document
            assert "previous file bytes are not recorded" in document, document
        else:
            # Assert the actual code rows, retaining indentation after the
            # diff marker and the two spaces inside the recorded expression.
            for expected in ("-   return  value", "+     return  value", "-   done", "+     done", "-", "+"):
                assert expected in captured.values(), (expected, captured)
        if not succeeded:
            assert "call failed" in document, document
            assert "applied call" not in document, document
        assert total > before_total, (total, before_total)
        # Collapse while an expanded diff row is the selected/top row.
        target = next(row for row, text in captured.items() if text.startswith("+ "))
        select_row(process, fd, output, columns, 1)
        h.send_and_wait(process, fd, output, b"j" * (target - 1), f"rows {target}-".encode())
        h.send_and_wait(process, fd, output, b"d", b"rows 1-")
        assert history.window(output, columns)[2] == before_total
        # Switching from expanded alpha to later beta must account for the
        # rows removed when alpha collapses, including its wrapped diff.
        beta_expanded_row = next(row for row, text in captured.items() if text == "Keeper: beta")
        beta_collapsed_row = beta_expanded_row - (total - before_total)
        h.send_and_wait(process, fd, output, b"d", b"Recorded change" if succeeded else b"Recorded attempt")
        h.send_and_wait(process, fd, output, b"j" * (beta_expanded_row - 1),
            f"rows {beta_expanded_row}-".encode())
        h.send_and_wait(process, fd, output, b"d", f"rows {beta_collapsed_row}-".encode())
        first, _, _, beta_body = history.window(output, columns)
        assert first == beta_collapsed_row and beta_body[0].strip() == "Keeper: beta", beta_body
        assert any("+ second-after" in row for row in beta_body), beta_body
        h.send_and_wait(process, fd, output, b"d", f"rows {beta_collapsed_row}-".encode())
        assert history.window(output, columns)[2] == before_total
        assert not diff_requests, diff_requests
        select_row(process, fd, output, columns, 1)
        h.send_and_wait(process, fd, output, b"\r", b"local target = 2")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
        description=f"Code history recorded {kind} {columns} succeeded={succeeded}",
        interact=interact, http_fixtures=fixtures)


def run_duplicate_records(executable, columns):
    fixtures = history.fixtures(False, [])
    fixtures["/api/v1/git/log"] = (200, {"ok": True, "commits": [{
        "hash": "abc1234", "timestamp_ms": 1787600200000,
        "author": "author", "subject": "change without a PR"}]})
    status, payload = fixtures["/api/v1/ide/file-activity"].resolve("/api/v1/ide/file-activity")
    change = payload["data"]["changes"][0]
    change.update(keeper="same", task_id="task-record", execution_id="exec-record")
    change["change"] = {"kind": "edit", "before": "before", "after": "after"}
    payload["data"]["changes"] = [change, deepcopy(change)]
    payload["data"]["calls_in_window"] = 2
    fixtures["/api/v1/ide/file-activity"] = (status, payload)

    def read_document(process, fd, output):
        select_row(process, fd, output, columns, 1)
        captured = {}
        while True:
            first, last, total, body = history.window(output, columns)
            captured.update((first + index, row.rstrip()) for index, row in enumerate(body))
            if last == total:
                return captured
            h.send_and_wait(process, fd, output, b"\x1b[6~",
                f"rows {min(total, first + max(1, last - first))}-".encode())

    def select(process, fd, output, row):
        select_row(process, fd, output, columns, row)

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go code", b"[draft]")
        h.send_and_wait(process, fd, output, b"\r", b"local lock = 1")
        h.resize_and_wait(process, fd, output, rows=30, columns=columns,
            needle=b"local lock = 1", controls=(h.FULL_REDRAW,))
        h.send_and_wait(process, fd, output, b"H", b"Commit: abc1234")
        # Establish a meaningful file note before an invalid diff request.
        h.send_and_wait(process, fd, output, b"\r", b"rows 1-")
        baseline = read_document(process, fd, output)
        note = "Filenote:abc1234:noPRnumberinthissubject"
        assert note in "".join("".join(row.split()) for row in baseline.values()), baseline
        first_owner, second_owner = [row for row, text in baseline.items() if text == "Keeper: same"]
        select_row(process, fd, output, columns, 1)
        h.send_and_wait(process, fd, output, b"d", b"Select a Keeper record")

        # Equal payloads must expand only the selected second occurrence.
        select(process, fd, output, second_owner)
        h.send_and_wait(process, fd, output, b"d", f"rows {second_owner}-".encode())
        assert history.window(output, columns)[0] == second_owner
        assert b"Select a Keeper record" not in h.screen_text(history.completed(output))
        if columns == 120:
            capture(process, fd, output, "second-duplicate-selected", columns, b"Recorded change")
        expanded = read_document(process, fd, output)
        change_rows = [row for row, text in expanded.items() if text.startswith("Recorded change")]
        assert len(change_rows) == 1 and change_rows[0] > second_owner, expanded
        compact = "".join("".join(row.split()) for row in expanded.values())
        assert note in compact and "SelectaKeeperrecord" not in compact, expanded

        # Switch to the equal first occurrence, then back to the second.
        select(process, fd, output, first_owner)
        # Equal-size expansions leave the window counter unchanged. The moved
        # change block is the new output; its owner is checked below.
        h.send_and_wait(process, fd, output, b"d", b"Recorded change")
        expanded = read_document(process, fd, output)
        owners = [row for row, text in expanded.items() if text == "Keeper: same"]
        change_rows = [row for row, text in expanded.items() if text.startswith("Recorded change")]
        assert len(change_rows) == 1 and owners[0] < change_rows[0] < owners[1], expanded
        select(process, fd, output, owners[1])
        h.send_and_wait(process, fd, output, b"d", f"rows {second_owner}-".encode())
        assert history.window(output, columns)[0] == second_owner
        # A fresh listing must drop the old occurrence's expansion.
        select_row(process, fd, output, columns, 1)
        # apply_history clears expansion only after the refreshed list lands.
        # The unchanged Keeper label need not be repainted, but the restored
        # baseline document height must be.
        h.send_and_wait(process, fd, output, b"r", f"of {len(baseline)}".encode())
        refreshed = read_document(process, fd, output)
        assert list(refreshed.values()) == list(baseline.values()), (baseline, refreshed)
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
        description=f"Code history duplicate record ownership and transient notice {columns}",
        interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    with open(sys.argv[1], "rb") as binary:
        print("STUDIO_BINARY_SHA256=" + hashlib.file_digest(binary, "sha256").hexdigest(), flush=True)
    for width in (60, 120):
        for success in (False, True):
            for change_kind in ("edit", "write", "indent"):
                run(os.path.abspath(sys.argv[1]), width, success, change_kind)
        run_duplicate_records(os.path.abspath(sys.argv[1]), width)
    print("Code history recorded changes: PASS")
