"""Operator stop requests open the exact Task Review request from the agenda."""

import json
import os
from pathlib import Path
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_agenda.ml",
    "bin/masc_tui_loader.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_types.ml",
    "lib/operator_task_attention.ml",
)


def latest_frame(output):
    data = bytes(output)
    start = data.rfind(h.FRAME_START)
    return data[max(0, start):]


def rows():
    result = []
    for number in range(7):
        row = h.verification_request_row(f"task-stop-{number}")
        row.update(
            request_id=f"vr-stop-{number}",
            task_title=f"stop target {number}",
            intent="cancel",
            cancellation_reason=f"stop for specific test-{number}",
        )
        result.append(row)
    return result


def seed_stops(base_path):
    tasks = []
    for number in range(7):
        tasks.append(
            {
                "id": f"task-stop-{number}",
                "title": f"stop target {number}",
                "description": "fixture stop request",
                "status": "awaiting_verification",
                "assignee": "alpha",
                "started_at": "2026-08-01T00:00:00Z",
                "submitted_at": f"2026-08-{number + 2:02d}T00:00:00Z",
                "intent": "cancel",
                "verification_id": f"vr-stop-{number}",
                "priority": 1,
                "created_at": "2026-08-01T00:00:00Z",
            }
        )
    path = Path(base_path) / ".masc" / "tasks" / "backlog.json"
    path.write_text(
        json.dumps({"tasks": tasks, "last_updated": "2026-08-10T00:00:00Z", "version": 1}),
        encoding="utf-8",
    )


def open_agenda(process, master_fd, output):
    h.send_and_wait(process, master_fd, output, b";", b"MASC Agenda")
    h.wait_for_output(
        process, master_fd, output, "stop requests 7".encode(), start=0, timeout=3.0
    )
    h.wait_for_output(
        process, master_fd, output, "전체 7건 열기".encode(), start=0, timeout=3.0
    )


def full_queue(process, master_fd, _slave_fd, output, _base_path):
    open_agenda(process, master_fd, output)
    for _ in range(3):
        h.send_and_wait(process, master_fd, output, b"j", b"MASC Agenda")
    h.send_and_wait(process, master_fd, output, b"\r", b"awaiting 7")
    frame = h.CSI_RE.sub(b"", latest_frame(output))
    if b"task-stop-6" not in frame:
        raise AssertionError(f"the full queue omitted its seventh request: {frame!r}")
    if b"stop for specific test-0" in frame:
        raise AssertionError("the full queue opened an arbitrary detail")
    os.write(master_fd, b"q")


def exact_jump(gate):
    def interact(process, master_fd, _slave_fd, output, _base_path):
        open_agenda(process, master_fd, output)
        h.resize_and_wait(
            process, master_fd, output, rows=30, columns=60, needle=b"MASC Agenda"
        )
        narrow = h.CSI_RE.sub(b"", latest_frame(output))
        for count in (b"tool approvals 0", b"stop requests 7",
                      b"held without actor 0", b"unreadable producer 0"):
            if count not in narrow:
                raise AssertionError(f"narrow agenda clipped {count!r}: {narrow!r}")
        h.send_and_wait(process, master_fd, output, b"j", b"MASC Agenda")
        h.send_and_wait(process, master_fd, output, b"\r", b"Task Review")
        if not h.wait_for_fixture_event(process, master_fd, output, gate.requested, timeout=3.0):
            raise AssertionError("Task Review queue was not requested")
        gate.release.set()
        h.wait_for_output(
            process, master_fd, output, b"stop for specific test-1", start=0, timeout=3.0
        )
        frame = h.CSI_RE.sub(b"", latest_frame(output))
        for needle in (b"vr-stop-1", b"task-stop-1", b"a twice: cancel task"):
            if needle not in frame:
                raise AssertionError(f"jump lost {needle!r}: {frame!r}")
        if b"stop for specific test-0" in frame:
            raise AssertionError(f"jump opened the first request: {frame!r}")
        os.write(master_fd, b"q")

    return interact


def changed_request(gate):
    def interact(process, master_fd, _slave_fd, output, _base_path):
        open_agenda(process, master_fd, output)
        h.send_and_wait(process, master_fd, output, b"j", b"MASC Agenda")
        h.send_and_wait(process, master_fd, output, b"\r", b"Task Review")
        if not h.wait_for_fixture_event(process, master_fd, output, gate.requested, timeout=3.0):
            raise AssertionError("Task Review queue was not requested")
        gate.release.set()
        h.wait_for_output(
            process, master_fd, output, b"changed or closed", start=0, timeout=3.0
        )
        frame = h.CSI_RE.sub(b"", latest_frame(output))
        if b"VERIFICATION REQUEST" in frame:
            raise AssertionError(f"a changed request opened another detail: {frame!r}")
        os.write(master_fd, b"q")

    return interact


def verdict_refresh(requests):
    def interact(process, master_fd, _slave_fd, output, _base_path):
        open_agenda(process, master_fd, output)
        h.send_and_wait(process, master_fd, output, b"\r", b"stop for specific test-0")
        detail = h.CSI_RE.sub(b"", latest_frame(output))
        if b"vr-stop-0" not in detail:
            raise AssertionError(f"the visible request ID is missing: {detail!r}")
        h.send_and_wait(process, master_fd, output, b"a", b"ARMED: press a again")
        if any(path == h.VERIFICATION_VERDICT_PATH for path, _ in requests):
            raise AssertionError("the first a sent a verdict")
        os.write(master_fd, b"a")
        approve = h.wait_for_http_request(
            process, master_fd, output, requests, path=h.VERIFICATION_VERDICT_PATH
        )
        if json.loads(approve) != {
            "task_id": "task-stop-0",
            "verification_id": "vr-stop-0",
            "verdict": "approve",
        }:
            raise AssertionError(f"approve used a different request: {approve!r}")
        h.wait_for_output(process, master_fd, output, b"awaiting 6", start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b";", b"MASC Agenda")
        h.wait_for_output(process, master_fd, output, b"stop requests 6", start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b";", b"Task Review")
        os.write(master_fd, b"x")
        if not h.wait_for_fixture_state(
            process, master_fd, output,
            lambda: sum(path == h.VERIFICATION_VERDICT_PATH for path, _ in requests) == 2,
            timeout=5.0,
        ):
            raise AssertionError("x did not submit the written reason")
        reject = [body for path, body in requests if path == h.VERIFICATION_VERDICT_PATH][1]
        if json.loads(reject) != {
            "task_id": "task-stop-1",
            "verification_id": "vr-stop-1",
            "verdict": "reject",
            "reason": "needs a repro",
        }:
            raise AssertionError(f"reject used a different request or reason: {reject!r}")
        h.wait_for_output(process, master_fd, output, b"awaiting 5", start=0, timeout=5.0)
        os.write(master_fd, b"q")

    return interact


def run(executable):
    queue = rows()
    h.run_terminal_scenario(
        executable,
        description="Stop agenda opens the full seven request queue",
        interact=full_queue,
        prepare_workspace=seed_stops,
        http_fixtures={h.VERIFICATION_QUEUE_PATH: (200, h.verification_snapshot(queue))},
    )
    gate = h.GatedHttpResponse((200, h.verification_snapshot(queue)))
    h.run_terminal_scenario(
        executable,
        description="Stop agenda preserves request identity through a delayed narrow load",
        interact=exact_jump(gate),
        prepare_workspace=seed_stops,
        http_fixtures={h.VERIFICATION_QUEUE_PATH: gate},
    )
    changed = rows()
    changed[1]["request_id"] = "vr-replaced-1"
    gate = h.GatedHttpResponse((200, h.verification_snapshot(changed)))
    h.run_terminal_scenario(
        executable,
        description="Stop agenda reports a replaced request without opening another",
        interact=changed_request(gate),
        prepare_workspace=seed_stops,
        http_fixtures={h.VERIFICATION_QUEUE_PATH: gate},
    )
    current = rows()
    workspace = {}
    requests = []

    def seed(base_path):
        seed_stops(base_path)
        workspace["base_path"] = base_path

    def queue_response():
        return 200, h.verification_snapshot(list(current))

    def record_verdict(body):
        verdict = json.loads(body)
        current[:] = [row for row in current if row["request_id"] != verdict["verification_id"]]
        path = Path(workspace["base_path"]) / ".masc" / "tasks" / "backlog.json"
        backlog = json.loads(path.read_text(encoding="utf-8"))
        backlog["tasks"] = [
            task for task in backlog["tasks"] if task["id"] != verdict["task_id"]
        ]
        pending = path.with_suffix(".pending")
        pending.write_text(json.dumps(backlog), encoding="utf-8")
        os.replace(pending, path)
        return 200, {"ok": True, "message": "verdict recorded", "noop": False}

    with h.reject_editor_script() as editor:
        h.run_terminal_scenario(
            executable,
            description="Stop verdict uses the visible request and refreshes the agenda count",
            interact=verdict_refresh(requests),
            prepare_workspace=seed,
            http_fixtures={
                h.VERIFICATION_QUEUE_PATH: queue_response,
                h.VERIFICATION_VERDICT_PATH: h.RequestHttpResponse(record_verdict),
            },
            http_requests=requests,
            extra_env={"EDITOR": editor},
        )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("TUI stop review navigation: PASS")
