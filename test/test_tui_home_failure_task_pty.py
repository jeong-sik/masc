"""Fixture acceptance for local Task cards and complete HTTP loss after bootstrap.

No product writes: the cancellation receipt is an isolated HTTP fixture.
Assertions cover navigation, blocked submission and retained drafts, not
cold-start identity failure or production availability.
"""
import json
import os
from pathlib import Path
import shlex
import sys
import tempfile
import threading
import time

import test_tui_home_decision_cards_pty as cards
import test_tui_home_journey_pty as home
import tui_keyboard_harness as h


STAMP = "2026-09-29T00:00:00Z"
TASK_A = "task-home-orphan-a"
TASK_B = "task-home-orphan-b"
GOAL = {
    "id": "goal-local-loss", "title": "Local loss confirmation",
    "criterion_revision": "r1", "phase": "awaiting_confirmation",
    "priority": 2, "created_at": STAMP, "updated_at": STAMP,
}


def task(task_id, status, description):
    # types_core.task_of_yojson reads the status fields at the task root.
    # Neither owner names a local Keeper: both must project Held_without_actor.
    return {
        "id": task_id, "title": "Orphan task " + task_id[-1],
        "description": description, "status": status,
        "assignee": "orphan-" + task_id[-1],
        ("claimed_at" if status == "claimed" else "started_at"): STAMP,
        "priority": 2, "created_at": STAMP, "files": [],
    }


def backlog(base):
    return Path(base, ".masc", "tasks", "backlog.json")


def write_tasks(base, rows):
    backlog(base).write_text(json.dumps({
        "version": 1, "last_updated": STAMP, "tasks": rows,
    }), encoding="utf-8")


def seed(base, *, goals=()):
    home.seed_goals(base, goals)
    write_tasks(base, [task(TASK_A, "claimed", "exact-detail-claimed-a"),
                       task(TASK_B, "in_progress", "exact-detail-running-b")])


def quiet_fixtures():
    fixtures, _items, _new = h.approval_selection_http_fixtures()
    fixtures[cards.OPERATOR_PATH] = h.approval_selection_snapshot([])
    fixtures["/api/v1/keepers/beta/chat/history"] = (200, [])
    return fixtures


def task_cards_and_deletion(executable):
    requests = []

    def interact(process, fd, _slave, output, base):
        original = backlog(base).read_bytes()
        h.wait_for_output(process, fd, output, TASK_B.encode(), start=0, timeout=10)
        visible = cards.frame(process, fd, output, "local-task-cards")
        for task_id in (TASK_A, TASK_B):
            assert b"Operator task" in visible and task_id.encode() in visible, visible
        for task_id, detail, other in (
            (TASK_A, b"exact-detail-claimed-a", b"exact-detail-running-b"),
            (TASK_B, b"exact-detail-running-b", b"exact-detail-claimed-a"),
        ):
            cards.select_home(process, fd, output, task_id.encode(), destinations=4)
            opened = h.send_and_wait(process, fd, output, b"\r", detail)
            screen = h.screen_text(opened)
            assert task_id.encode() in screen and detail in screen and other not in screen, screen
            assert backlog(base).read_bytes() == original
            home.assert_no_decision_posts(requests)
            h.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
            cards.assert_selected(output, task_id.encode())
        # Remove the selected B using the fixture, never a product mutation.
        rows = json.loads(original)["tasks"]
        write_tasks(base, [row for row in rows if row["id"] != TASK_B])
        after_delete = backlog(base).read_bytes()
        h.send_and_wait(process, fd, output, b"r", b"Selection changed")
        blocked = h.send_and_wait(process, fd, output, b"\r", b"Selection changed")
        screen = h.screen_text(blocked)
        assert b"exact-detail-claimed-a" not in screen and b"exact-detail-running-b" not in screen
        assert b"Enter:open" in screen, screen
        cards.select_home(process, fd, output, TASK_A.encode(), destinations=3)
        h.send_and_wait(process, fd, output, b"\r", b"exact-detail-claimed-a")
        h.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
        cards.assert_selected(output, TASK_A.encode())
        assert backlog(base).read_bytes() == after_delete
        home.assert_no_decision_posts(requests)
        os.write(fd, b"q")

    cards.run(executable, "Home orphan claimed and running Tasks open exact details; deletion reselects",
              quiet_fixtures(), interact, requests, prepare=seed)


class LossFixtures(dict):
    """Exact-key catch-all overrides even the harness's successful defaults.

    Bootstrap normally so local identity is known; after lose(), every path
    (including health, MCP, query variants and unlisted routes) returns 503.
    """
    def __init__(self):
        super().__init__(quiet_fixtures())
        self.lost = threading.Event()
        self.lock = threading.Lock()
        self.failed_paths = []

    def __contains__(self, key):
        return self.lost.is_set() or super().__contains__(key)

    def __getitem__(self, key):
        if self.lost.is_set():
            return h.PathHttpResponse(self.fail)
        return super().__getitem__(key)

    def fail(self, path):
        with self.lock:
            self.failed_paths.append(path)
        return 503, {"error": "all HTTP unavailable"}

    def failures(self, path):
        with self.lock:
            return self.failed_paths.count(path)


def full_http_loss_retains_local_work_and_draft(executable):
    fixtures = LossFixtures()
    requests = []
    draft = b"beta-loss-unsent-draft"
    chat_path = "/api/v1/keepers/chat/stream"

    def assert_no_chat_delivery():
        # The harness logs POSTs after responding, including 503 responses.
        # fail() records paths during resolution, before that POST log append.
        assert not any(path.split("?", 1)[0] == chat_path
                       for path, _body in requests), requests
        assert fixtures.failures(chat_path) == 0, fixtures.failed_paths

    def prepare(base):
        seed(base, goals=[GOAL])

    def interact(process, fd, _slave, output, base):
        original = backlog(base).read_bytes()
        h.wait_for_output(process, fd, output, TASK_B.encode(), start=0, timeout=10)
        h.palette_go(process, fd, output, b"go keepers", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"beta")
        h.send_and_wait(process, fd, output, b"c", b"Esc:list")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.palette_go(process, fd, output, b"go dashboard", b"Continue with beta")
        cards.select_home(process, fd, output, b"Continue with beta", destinations=6)
        h.send_and_wait(process, fd, output, b"\r", b"Esc:Dashboard")
        h.send_and_wait(process, fd, output, draft, draft)
        fixtures.lost.set()
        # Observe separate failed polling rounds while the composer is open.
        for _round in (1, 2):
            before = fixtures.failures(cards.OPERATOR_PATH)
            assert h.wait_for_fixture_state(
                process, fd, output,
                lambda: fixtures.failures(cards.OPERATOR_PATH) > before,
                timeout=12,
            ), fixtures.failed_paths
            h.drain_until_quiet(process, fd, output)
            screen = h.screen_text(bytes(output))
            assert draft in screen and "Keepers ▸ beta ▸ chat".encode() in screen and b"Esc:Dashboard" in screen, screen
            home.assert_no_decision_posts(requests)
        h.send_and_wait(process, fd, output, b"\r",
                        b"Cannot send: workspace identity is unverified")
        blocked = cards.frame(process, fd, output, "all-http-503-send-blocked")
        assert b"workspace identity is unverified" in blocked, blocked
        assert b"draft retained" in blocked and draft in blocked, blocked
        assert "Keepers ▸ beta ▸ chat".encode() in blocked and b"Esc:Dashboard" in blocked, blocked
        assert_no_chat_delivery()
        home.assert_no_decision_posts(requests)
        h.send_and_wait(process, fd, output, b"\x1b", b"Last conversation beta unavailable")
        visible = cards.frame(process, fd, output, "all-http-503-local-work")
        for label in (b"Confirm Goal", b"goal-local-loss", TASK_A.encode(), TASK_B.encode(),
                      b"Last conversation beta unavailable", b"not fully read"):
            assert label in visible, (label, visible)
        assert b"No decision is waiting" not in visible, visible
        assert b"workspace identity not read" in visible, visible
        # Unverified Home offers no history reader; the unsent draft was
        # witnessed above before returning to this nonactionable context.
        assert b"read history" not in visible and b"Continue with beta" not in visible, visible
        assert backlog(base).read_bytes() == original
        assert_no_chat_delivery()
        os.write(fd, b"q")

    cards.run(executable, "Home full HTTP loss hides the history shortcut and retains local Goal Tasks and unsent draft",
              fixtures, interact, requests, prepare=prepare, refresh=1.0)
    assert fixtures.failed_paths, "outage never served a failed HTTP request"
    assert_no_chat_delivery()


def task_cancel_editor_replacement(executable):
    """The task selected in A cannot cancel the same id served by B."""
    fixtures = quiet_fixtures()
    requests = []
    state = {"foreign": False}
    with tempfile.TemporaryDirectory(prefix="masc-task-cancel-editor-") as directory:
        editor_root = Path(directory)
        editor = editor_root / "editor.py"
        editor.write_text(
            "from pathlib import Path\nimport sys,time\n"
            f"root = Path({directory!r})\n"
            "(root / 'entered').write_text('1')\n"
            "deadline = time.monotonic() + 10\n"
            "while not (root / 'release').exists() and time.monotonic() < deadline:\n"
            "    time.sleep(0.02)\n"
            "if not (root / 'release').exists(): sys.exit(1)\n"
            "Path(sys.argv[1]).write_text('{\"reason\":\"wrong task scope\"}')\n",
            encoding="utf-8",
        )

        def prepare(base):
            seed(base)
            local = Path(base).resolve()
            foreign = local / "task-cancel-foreign-B"
            (foreign / ".masc").mkdir(parents=True)

            def health():
                root = foreign if state["foreign"] else local
                return h.RawHttpResponse(200, json.dumps({
                    "status": "ok", "paths": {
                        "cwd": str(root), "effective_base_path": str(root),
                        "effective_masc_root": str(root / ".masc"),
                        "effective_has_masc_dir": True,
                    },
                }).encode(), content_type="application/json")

            fixtures["/health"] = health
            fixtures["/health?full=1"] = health

        def interact(process, fd, _slave, output, base):
            original = backlog(base).read_bytes()
            h.wait_for_output(process, fd, output, TASK_A.encode(), start=0, timeout=10)
            cards.select_home(process, fd, output, TASK_A.encode(), destinations=4)
            h.send_and_wait(process, fd, output, b"\r", b"exact-detail-claimed-a")
            os.write(fd, b"x")
            deadline = time.monotonic() + 10
            while not (editor_root / "entered").exists() and time.monotonic() < deadline:
                assert process.poll() is None, "TUI exited before cancel editor"
                time.sleep(0.02)
            assert (editor_root / "entered").exists(), "cancel editor never opened"
            state["foreign"] = True
            start = len(output)
            (editor_root / "release").write_text("1")
            h.wait_for_output(process, fd, output,
                              b"workspace changed before the action completed",
                              start=start, timeout=10)
            assert backlog(base).read_bytes() == original
            assert not [body for path, body in requests if path == "/mcp"
                        and json.loads(body).get("method") == "tools/call"], requests
            os.write(fd, b"q")

        h.run_terminal_scenario(
            executable, description="Task cancel editor refuses B replacement",
            interact=interact, http_fixtures=fixtures, http_requests=requests,
            prepare_workspace=prepare, refresh=60.0,
            extra_env={"EDITOR": f"{shlex.quote(sys.executable)} {shlex.quote(str(editor))}"},
        )


def task_cancel_previous_workspace_receipt(executable):
    """Accepted A cancellation remains visible after a refresh observes B."""
    fixtures = quiet_fixtures()
    requests = []
    accepted = threading.Event()
    release = threading.Event()
    state = {"foreign": False, "health_reads": 0, "history_reads": 0}
    transitions = []
    with tempfile.TemporaryDirectory(prefix="masc-task-cancel-receipt-") as directory:
        editor = Path(directory, "editor.py")
        editor.write_text("from pathlib import Path\nimport sys\n"
                          "Path(sys.argv[1]).write_text('{\"reason\":\"receipt fixture\"}')\n")

        def prepare(base):
            seed(base)
            local = Path(base).resolve()
            foreign = local / "task-receipt-foreign-B"
            (foreign / ".masc").mkdir(parents=True)

            def health():
                state["health_reads"] += 1
                root = foreign if state["foreign"] else local
                return h.RawHttpResponse(200, json.dumps({
                    "status": "ok", "paths": {
                        "cwd": str(root), "effective_base_path": str(root),
                        "effective_masc_root": str(root / ".masc"),
                        "effective_has_masc_dir": True,
                    },
                }).encode(), content_type="application/json")

            def rpc(body):
                request = json.loads(body)
                method = request.get("method")
                if method == "tools/call":
                    params = request["params"]
                    assert params["name"] == "masc_transition", request
                    args = params["arguments"]
                    assert args["task_id"] == TASK_A and args["action"] == "cancel", args
                    assert args["expected_workspace"] == {
                        "base_path": str(local), "masc_root": str(local / ".masc")}, args
                    transitions.append(request)
                    accepted.set()
                    assert release.wait(30), "fixture cancellation response was not released"
                    result = {"content": [{"type": "text", "text": "cancelled fixture"}],
                              "isError": False}
                elif method == "initialize":
                    result = {}
                else:
                    return h.RawHttpResponse(204, b"", content_type="application/json")
                return h.RawHttpResponse(200, json.dumps({
                    "jsonrpc": "2.0", "id": request["id"], "result": result,
                }).encode(), content_type="application/json",
                    headers=(("Mcp-Session-Id", "mcp_fixture_session"),))

            fixtures["/health"] = health
            fixtures["/health?full=1"] = health
            fixtures["/mcp"] = h.RequestHttpResponse(rpc)
            history_path = "/api/v1/dashboard/tasks/history"
            previous_history = fixtures.get(history_path, (404, {"error": "no fixture history"}))

            def history():
                state["history_reads"] += 1
                return previous_history() if callable(previous_history) else previous_history

            fixtures[history_path] = history

        def interact(process, fd, _slave, output, _base):
            try:
                h.wait_for_output(process, fd, output, TASK_A.encode(), start=0, timeout=10)
                cards.select_home(process, fd, output, TASK_A.encode(), destinations=4)
                h.send_and_wait(process, fd, output, b"\r", b"exact-detail-claimed-a")
                os.write(fd, b"x")
                assert h.wait_for_fixture_event(process, fd, output, accepted, timeout=10)
                state["foreign"] = True
                h.send_and_wait(process, fd, output, b"r", b"[workspace mismatch]")
                h.drain_until_quiet(process, fd, output)
                before = (state["health_reads"], state["history_reads"])
                start = len(output)
                release.set()
                h.wait_for_output(process, fd, output,
                                  ("task " + TASK_A + " cancelled in the previous workspace").encode(),
                                  start=start, timeout=10)
                h.drain_until_quiet(process, fd, output)
                assert (state["health_reads"], state["history_reads"]) == before, state
                assert len(transitions) == 1, transitions
                os.write(fd, b"q")
            finally:
                release.set()

        h.run_terminal_scenario(
            executable, description="accepted Task cancel reports previous workspace without refresh",
            interact=interact, http_fixtures=fixtures, http_requests=requests,
            prepare_workspace=prepare, refresh=60.0,
            extra_env={"EDITOR": f"{shlex.quote(sys.executable)} {shlex.quote(str(editor))}"},
        )


if __name__ == "__main__":
    exe = os.path.abspath(sys.argv[1])
    task_cards_and_deletion(exe)
    full_http_loss_retains_local_work_and_draft(exe)
    task_cancel_editor_replacement(exe)
    task_cancel_previous_workspace_receipt(exe)
    print("Home failure and Task PTY: PASS (4 scenarios)")
