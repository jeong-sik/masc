"""Long task titles leave their state and priority visible after resizing."""
import json
import os
import re
import sys
from pathlib import Path

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
    "bin/masc_tui_message_layout.ml",
    "bin/masc_tui_text_block.ml",
)


def prepare_colliding_ids(base_path):
    prepare(base_path)
    path = Path(base_path) / ".masc" / "tasks" / "backlog.json"
    payload = json.loads(path.read_text())
    original = payload["tasks"][1]
    payload["tasks"] = [dict(original, id=task_id) for task_id in ("task-1862", "task-1962")]
    path.write_text(json.dumps(payload))


def prepare(base_path):
    h.seed_row_budget_workspace(base_path)
    path = Path(base_path) / ".masc" / "tasks" / "backlog.json"
    payload = json.loads(path.read_text())
    original = payload["tasks"][0]
    payload["tasks"] = [
        dict(original, title="긴 작업 제목 " * 40),
        dict(original, id="task-2", title="검증 대기 작업 " * 40,
             status="awaiting_verification", assignee="wkbl-web-leader",
             started_at="2026-08-22T00:00:00Z",
             submitted_at="2026-08-22T01:00:00Z", verification_id="vrf-layout"),
    ]
    path.write_text(json.dumps(payload))


def prepare_short_titles(base_path):
    prepare_colliding_ids(base_path)
    path = Path(base_path) / ".masc" / "tasks" / "backlog.json"
    payload = json.loads(path.read_text())
    payload["tasks"] = [dict(task, id=f"task-{index}", title=title,
                             status="claimed", claimed_at="2026-08-22T00:00:00Z")
                        for index, (task, title) in enumerate(zip(payload["tasks"], ("x", "한")), 1)]
    path.write_text(json.dumps(payload))


def prepare_numeric_aliases(base_path):
    prepare_colliding_ids(base_path)
    path = Path(base_path) / ".masc" / "tasks" / "backlog.json"
    payload = json.loads(path.read_text())
    original = payload["tasks"][0]
    payload["tasks"] = [dict(original, id=task_id, title=title, priority=index)
                        for index, (task_id, title) in enumerate(zip(
                            ("task-1862", "1862", "row 1"),
                            ("PREFIXEDALIAS", "BAREALIAS", "RESERVEDALIAS")), 1)]
    path.write_text(json.dumps(payload))


OPAQUE_IDS = ("opaque-owner-first-" + "shared" * 8 + "-tail",
              "opaque-owner-second-" + "shared" * 8 + "-tail")


def prepare_opaque_ids(base_path):
    prepare_colliding_ids(base_path)
    path = Path(base_path) / ".masc" / "tasks" / "backlog.json"
    payload = json.loads(path.read_text())
    payload["tasks"] = [dict(task, id=task_id) for task, task_id
                        in zip(payload["tasks"], OPAQUE_IDS)]
    path.write_text(json.dumps(payload))


def run(executable):
    def interact(process, master_fd, _slave_fd, output, _base_path):
        h.palette_go(process, master_fd, output, b"go Work", b"MASC Work")
        h.send_and_wait(process, master_fd, output, b"t", b"MASC Work / Tasks")
        h.wait_for_output(process, master_fd, output, b"task-1", start=0, timeout=10)
        for width in (80, 120, 60, 30, 40):
            h.resize_and_wait(process, master_fd, output, rows=32, columns=width,
                              needle=b"1]", final_cursor=b"\x1b[?25l")
            h.drain_until_quiet(process, master_fd, output)
            end = output.rfind(h.FRAME_END)
            rows = h.screen_rows(bytes(output[:end + len(h.FRAME_END)]))
            for task_id, status in ((b"1]", b"todo"),
                                    (b"2]", b"verify" if width <= 40 else b"awaiting_verification")):
                row = rows[h.screen_row_of(rows, task_id)]
                if status not in row or b"!" not in row:
                    raise AssertionError(f"state or priority lost at {width} columns: {row!r}")
                if "…".encode() not in row:
                    raise AssertionError(f"long field not abbreviated at {width} columns: {row!r}")
            verification_row = rows[h.screen_row_of(rows, b"2]")]
            if width >= 60 and b"@wkbl" not in verification_row:
                raise AssertionError(f"owner missing at {width} columns: {verification_row!r}")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(executable, description="Work task rows preserve state on resize",
                            interact=interact, prepare_workspace=prepare)

    def distinguish(process, master_fd, _slave_fd, output, _base_path):
        h.palette_go(process, master_fd, output, b"go Work", b"MASC Work")
        h.send_and_wait(process, master_fd, output, b"t", b"MASC Work / Tasks")
        h.wait_for_output(process, master_fd, output, b"1862]", start=0, timeout=10)
        for width in (30, 40):
            frame = h.resize_and_wait(process, master_fd, output, rows=32, columns=width,
                                      needle=b"1962]", final_cursor=b"\x1b[?25l")
            rows = h.screen_rows(frame)
            for task_id in (b"1862]", b"1962]"):
                row = rows[h.screen_row_of(rows, task_id)]
                if b"verify" not in row or b"!" not in row:
                    raise AssertionError(f"Task number or state lost: {row!r}")
            h.send_and_wait(process, master_fd, output, b"\r", b"task-1862")
            h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Work / Tasks")
            h.send_and_wait(process, master_fd, output, b"j\r", b"task-1962")
            h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Work / Tasks")
            h.send_and_wait(process, master_fd, output, b"k", b"1862]")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(executable, description="Work distinguishes same-suffix Task numbers and opens each",
                            interact=distinguish, prepare_workspace=prepare_colliding_ids)


    def short_titles(process, master_fd, _slave_fd, output, _base_path):
        h.palette_go(process, master_fd, output, b"go Work", b"MASC Work")
        h.send_and_wait(process, master_fd, output, b"t", b"MASC Work / Tasks")
        h.wait_for_output(process, master_fd, output, b"wkbl-web-leader", start=0, timeout=10)
        for width in (50, 60):
            frame = h.resize_and_wait(process, master_fd, output, rows=32, columns=width,
                                      needle=b"2]", final_cursor=b"\x1b[?25l")
            rows = h.screen_rows(frame)
            for task_id, title in ((b"1]", b"x"), (b"2]", "한".encode())):
                row = rows[h.screen_row_of(rows, task_id)]
                assert b"@wkbl-web-leader" in row and title in row, (width, row)
                assert b"claimed" in row and b"!" in row, (width, row)
                assert "…".encode() not in row, (width, row)
        os.write(master_fd, b"q")

    h.run_terminal_scenario(executable, description="Short Task titles leave room for exact owner identity",
                            interact=short_titles, prepare_workspace=prepare_short_titles)

    def numeric_aliases(process, master_fd, _slave_fd, output, _base_path):
        h.palette_go(process, master_fd, output, b"go Work", b"MASC Work")
        h.send_and_wait(process, master_fd, output, b"t", b"MASC Work / Tasks")
        h.wait_for_output(process, master_fd, output, b"row 3]", start=0, timeout=10)
        frame = h.resize_and_wait(process, master_fd, output, rows=32, columns=30,
                                  needle=b"row 3]", final_cursor=b"\x1b[?25l")
        rows = h.screen_rows(frame)
        positions = [h.screen_row_of(rows, label) for label in (b"row 1]", b"row 2]", b"row 3]")]
        assert min(positions) >= 0 and len(set(positions)) == 3, rows
        h.send_and_wait(process, master_fd, output, b"\r", b"PREFIXEDALIAS")
        h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Work / Tasks")
        h.send_and_wait(process, master_fd, output, b"j\r", b"BAREALIAS")
        h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Work / Tasks")
        h.send_and_wait(process, master_fd, output, b"j\r", b"RESERVEDALIAS")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(executable, description="Prefixed and bare numeric Task IDs stay distinct",
                            interact=numeric_aliases, prepare_workspace=prepare_numeric_aliases)


    def opaque(process, master_fd, _slave_fd, output, _base_path):
        h.palette_go(process, master_fd, output, b"go Work", b"MASC Work")
        h.send_and_wait(process, master_fd, output, b"t", b"MASC Work / Tasks")
        h.wait_for_output(process, master_fd, output, b"tail]", start=0, timeout=10)
        for width in (30, 40):
            frame = h.resize_and_wait(process, master_fd, output, rows=40, columns=width,
                                      needle=b"row 2]", final_cursor=b"\x1b[?25l")
            rows = h.screen_rows(frame)
            positions = [h.screen_row_of(rows, ordinal)
                         for ordinal in (b"row 1]", b"row 2]")]
            if min(positions) < 0 or positions[0] == positions[1]:
                raise AssertionError(f"opaque Task rows are indistinguishable: {rows!r}")
            for index, task_id in enumerate(OPAQUE_IDS):
                h.send_and_wait(process, master_fd, output, b"\r", b"MASC Task")
                # Metadata is one scrolling document. A tall frame exposes
                # the full ID after the long title at this same narrow width.
                detail_frame = h.resize_and_wait(process, master_fd, output, rows=150, columns=width,
                                                needle=b"id: ", final_cursor=b"\x1b[?25l")
                detail_rows = h.screen_rows(detail_frame)
                ordered = [detail_rows[key] for key in sorted(detail_rows)]
                id_row = next((i for i, row in enumerate(ordered)
                               if re.match(rb"^\s*id: ", row)), None)
                if id_row is None:
                    raise AssertionError(f"opaque ID metadata row missing: {ordered!r}")
                column = ordered[id_row].index(b"id: ") + len(b"id: ")
                parts = [ordered[id_row][column:].rstrip()]
                for row in ordered[id_row + 1:]:
                    if row[:column].strip() or not row[column:].strip():
                        break
                    parts.append(row[column:].rstrip())
                if b"".join(parts) != task_id.encode():
                    raise AssertionError(f"opaque ID reconstructed incorrectly: {parts!r}, {task_id!r}")
                h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Work / Tasks")
                h.resize_and_wait(process, master_fd, output, rows=40, columns=width,
                                  needle=b"row 2]", final_cursor=b"\x1b[?25l")
                if index == 0:
                    h.send_and_wait(process, master_fd, output, b"j", b"row 2]")
            h.send_and_wait(process, master_fd, output, b"k", b"row 1]")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(executable, description="Work distinguishes opaque IDs and reads complete detail",
                            interact=opaque, prepare_workspace=prepare_opaque_ids)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Work task row layout: PASS")
