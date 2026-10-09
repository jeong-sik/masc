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
            before = fixtures.failures("/health")
            assert h.wait_for_fixture_state(
                process, fd, output,
                lambda: fixtures.failures("/health") > before,
                timeout=12,
            ), fixtures.failed_paths
            h.drain_until_quiet(process, fd, output)
            screen = h.screen_text(bytes(output))
            assert draft in screen, "identity outage discarded the unsent local draft"
            home.assert_no_decision_posts(requests)
        assert_no_chat_delivery()
        h.send_and_wait(process, fd, output, b"\x1b", b"decisions wait")
        visible = cards.frame(process, fd, output, "all-http-503-local-work")
        # A failed identity read keeps the last confirmed Home rows on screen
        # and says that decisions wait; it does not turn them into "not read".
        for label in (b"workspace identity unconfirmed \xc2\xb7 decisions wait",
                      b"Confirm Goal", b"goal-local-loss", TASK_A.encode(), TASK_B.encode()):
            assert label in visible, (label, visible)
        for label in (b"Goal confirmations not read", b"Operator tasks not read"):
            assert label not in visible, ("a failed read replaced the kept rows", label, visible)
        assert b"No decision is waiting" not in visible, visible
        home.assert_no_decision_posts(requests)
        # Unconfirmed Home offers no history reader; the unsent draft was
        # witnessed above before returning to this context.
        assert b"read history" not in visible and b"Continue with beta" not in visible, visible
        assert backlog(base).read_bytes() == original
        assert_no_chat_delivery()
        fixtures.lost.clear()
        h.send_and_wait(process, fd, output, b"r", b"Continue with beta")
        recovered = h.screen_text(bytes(output))
        for label in (b"Confirm Goal", b"goal-local-loss", TASK_A.encode(), TASK_B.encode()):
            assert label in recovered, ("admitted Home did not restore its cards", label, recovered)
        cards.select_home(process, fd, output, b"Continue with beta", destinations=6)
        h.send_and_wait(process, fd, output, b"\r", draft)
        assert draft in h.screen_text(bytes(output)), "the original workspace did not restore its draft"
        assert_no_chat_delivery()
        # Leave the composer before requesting exit: q is draft text in chat.
        h.send_and_wait(process, fd, output, b"\x1b", b"Continue with beta")
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
            # The mismatch footer includes both workspace identity and the
            # action refusal. Give this exact-reason assertion room for both.
            h.resize_and_wait(process, fd, output, rows=40, columns=240,
                              needle=b"MASC Dashboard")
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
                              b"Workspace identity changed or is unavailable; request withdrawn",
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


class RefreshCompletionGate:
    """Admission set over the refresh tail's /health exchanges.

    While armed, every exchange registers when its handler enters and
    completes when the fixture dispatcher has written its response to the
    socket (the response's [on_sent] callback) -- or when that write is
    lost to a dropped peer, which also ends the exchange. [quiesced] --
    nothing held and nothing registered for [span] seconds -- is then a
    completion boundary: the refresh chain's last identity exchange has
    been answered on the wire and none is still running. The span is an
    observation guard over what remains after that handoff, not a proven
    bound on the client: the receive, the applied bundle, and the chained
    next request all still happen after the write. Keying the boundary on
    the fixture callable's own exit would leave a wider gap -- the bytes
    themselves are still unsent at that return. Read counters cannot
    prove completion at all; a quiet span over them is how the original
    race passed its settle loop with a response still outstanding.

    The wire boundary is the settling stage, not the whole settle: what
    the client does between the last response and the first missing
    follow-up -- receiving, applying the last bundle, chaining -- is not
    observed by the gate and can outrun [span]. So the settle closes on
    an applied generation, observed on the screen: a second refresh
    press is delivered with the fixture serving a visibly different
    answer, and the frames that answer draws are the client's proof that
    the press's refresh reached the server, came back, and was applied
    to the model that draws. An older exchange cannot forge that -- the
    answer only appears after the client processed this press's
    response -- and what the mailbox applies happens before the next
    frame is drawn, because the main loop handles the applied-bundle
    message and the redraw on the same thread, in order (masc_tui.ml
    Http_refresh_done -> apply_http_surfaces). The receipt window then
    keys on that generation's last exchange completing into a whole
    span of silence. Registrations are logged per request: complete()
    moves the gate clock too, so the boundary is recognized by the
    generation's logged entries and their own completion stamps, never
    by clock movement alone.
    """

    def __init__(self, span=0.5):
        self._lock = threading.Lock()
        self.span = span
        self.held = 0
        self.exchanges = 0
        self.durations = []
        self.last_event = time.monotonic()
        self.changed = threading.Event()

    def register(self):
        with self._lock:
            self.held += 1
            self.exchanges += 1
            self.last_event = time.monotonic()
            self.changed.set()

    def complete(self, length):
        with self._lock:
            self.held -= 1
            self.durations.append(length)
            self.last_event = time.monotonic()
            self.changed.set()

    def quiesced(self):
        with self._lock:
            return self.held == 0 and time.monotonic() - self.last_event >= self.span

    def last_event_time(self):
        """The gate's own clock of the last register/complete, read under the
        same lock the mutators take: (held, last_event) torn across two
        calls could mistake a just-registered exchange for a long-clean
        window."""
        with self._lock:
            return self.last_event

    def snapshot(self):
        with self._lock:
            return (self.held, self.exchanges)


def task_cancel_previous_workspace_receipt(executable, *, unconfirmed=False):
    """Accepted A cancellation remains visible after a refresh observes B."""
    fixtures = quiet_fixtures()
    requests = []
    accepted = threading.Event()
    release = threading.Event()
    gate = RefreshCompletionGate()
    state = {"foreign": False, "unread": False, "health_reads": 0, "history_reads": 0,
             "health_gate": gate, "drill_delay": 0.0,
             "exchange_log": []}
    transitions = []
    with tempfile.TemporaryDirectory(prefix="masc-task-cancel-receipt-") as directory:
        editor = Path(directory, "editor.py")
        editor.write_text("from pathlib import Path\nimport sys\n"
                          "Path(sys.argv[1]).write_text('{\"reason\":\"receipt fixture\"}')\n")

        def prepare(base):
            seed(base)
            local = Path(base).resolve()
            foreign_b = local / "task-receipt-foreign-B"
            (foreign_b / ".masc").mkdir(parents=True)
            foreign_c = local / "task-receipt-foreign-C"
            (foreign_c / ".masc").mkdir(parents=True)

            def health():
                state["health_reads"] += 1
                gate = state["health_gate"]
                entry = None
                root = state.get("workspace_root", foreign_b if state.get("foreign") else local)
                if gate is not None:
                    entered = time.monotonic()
                    gate.register()
                    entry = {
                        "registered": entered,
                        "completed": None,
                        "root": str(root),
                    }
                    state["exchange_log"].append(entry)
                    try:
                        drill = state["drill_delay"]
                        if drill:
                            state["drill_delay"] = 0.0
                            # The rehearsal: this response lands later than
                            # the whole quiet span the previous settle loop
                            # trusted, and the window must still wait for
                            # this completion.
                            time.sleep(drill)
                    except BaseException:
                        gate.complete(time.monotonic() - entered)
                        raise
                on_sent = None
                if gate is not None:
                    # Capture this exact exchange's gate, entry, and entry time.
                    # Under ThreadingHTTPServer, another exchange can enter before
                    # this response write completes; indexing [-1] would attribute
                    # completion to whatever request registered most recently.
                    def record_sent(g=gate, e=entry, t=entered):
                        g.complete(time.monotonic() - t)
                        e["completed"] = time.monotonic()

                    on_sent = record_sent
                if state["unread"]:
                    return h.RawHttpResponse(503, b'{"error":"identity temporarily unread"}',
                        content_type="application/json", on_sent=on_sent)
                return h.RawHttpResponse(200, json.dumps({
                    "status": "ok", "paths": {
                        "cwd": str(root), "effective_base_path": str(root),
                        "effective_masc_root": str(root / ".masc"),
                        "effective_has_masc_dir": True,
                    },
                }).encode(), content_type="application/json",
                    on_sent=on_sent)

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
            fixtures["/mcp"] = h.RequestHttpResponse(
                rpc, get_response=(405, {"error": "MCP event stream is unavailable"}))
            history_path = "/api/v1/dashboard/tasks/history"
            previous_history = fixtures.get(history_path, (404, {"error": "no fixture history"}))

            def history():
                state["history_reads"] += 1
                if unconfirmed:
                    return 200, [{"ts": STAMP, "action": "cancel", "to_status": "cancelled",
                        "handoff_context": {"summary": "RECOVERED_CANCEL_HISTORY" if release.is_set()
                                            else "INITIAL_TASK_HISTORY"}}]
                return previous_history() if callable(previous_history) else previous_history

            fixtures[history_path] = history

        def interact(process, fd, _slave, output, _base):
            local_base = str(Path(_base).resolve())
            foreign_b = Path(local_base, "task-receipt-foreign-B")
            foreign_c = Path(local_base, "task-receipt-foreign-C")
            try:
                h.resize_and_wait(process, fd, output, rows=40, columns=320,
                                  needle=b"MASC Dashboard")
                h.wait_for_output(process, fd, output, TASK_A.encode(), start=0, timeout=10)
                h.wait_for_output(process, fd, output,
                                  ("Base: " + local_base).encode(), start=0, timeout=10)
                initial_settle_deadline = time.monotonic() + 10
                while not gate.quiesced():
                    if time.monotonic() > initial_settle_deadline:
                        raise AssertionError(
                            "initial local refresh did not settle: " + repr(state["exchange_log"]))
                    gate.changed.clear()
                    h.wait_for_fixture_event(process, fd, output, gate.changed, timeout=0.25)
                cards.select_home(process, fd, output, TASK_A.encode(), destinations=4)
                h.send_and_wait(process, fd, output, b"\r", b"exact-detail-claimed-a")
                os.write(fd, b"x")
                assert h.wait_for_fixture_event(process, fd, output, accepted, timeout=10)
                if unconfirmed:
                    state["foreign"] = not unconfirmed
                    state["unread"] = unconfirmed
                    h.send_and_wait(process, fd, output, b"r",
                        b"[workspace unconfirmed]" if unconfirmed else b"[workspace mismatch]")
                    h.drain_until_quiet(process, fd, output)
                    settle_deadline = time.monotonic() + 10
                    while not gate.quiesced():
                        if time.monotonic() > settle_deadline:
                            raise AssertionError("unconfirmed identity response did not settle")
                        gate.changed.clear()
                        h.wait_for_fixture_event(process, fd, output, gate.changed, timeout=0.25)
                    window_opened_at = gate.last_event_time()
                else:
                    state["foreign"] = True
                    state["drill_delay"] = 0.75
                    try:
                        # This single key owns the B revalidation pass. The
                        # initial local pass was rendered and quiet before the
                        # key, so it cannot leave a queued Revalidate intent.
                        b_press_output_start = len(output)
                        h.send_and_wait(process, fd, output, b"r", b"[workspace mismatch]")
                        h.wait_for_output(
                            process, fd, output, b"task-receipt-foreign-B",
                            start=b_press_output_start, timeout=10)
                        assert h.drain_until_quiet(process, fd, output, cap=10), (
                            "TUI output did not settle after foreign-B applied: " + repr(bytes(output)))
                        # The B frame proves the client applied the first refresh;
                        # then wait for every response already registered by that
                        # generation and a complete quiet span before starting C.
                        prior_settle_deadline = time.monotonic() + 10
                        while not gate.quiesced():
                            if time.monotonic() > prior_settle_deadline:
                                raise AssertionError(
                                    "prior refresh tail did not settle after foreign-B applied: "
                                    + repr(state["exchange_log"])
                                    + f" held={gate.held} reads="
                                    + repr((state["health_reads"], state["history_reads"])))
                            gate.changed.clear()
                            h.wait_for_fixture_event(process, fd, output, gate.changed, timeout=0.25)
                        assert gate.held == 0, f"exchange still held before second press: {gate.snapshot()}"
                        pre_press_count = len(state["exchange_log"])
                        assert all(e["completed"] is not None for e in state["exchange_log"]), (
                            "pre-press exchange is still running before second press: "
                            + repr(state["exchange_log"]))
                        assert all(e.get("root") == str(foreign_b) or e.get("root") == local_base
                                   for e in state["exchange_log"][:pre_press_count]), (
                            "pre-press exchange log contaminated with unexpected root: "
                            + repr(state["exchange_log"][:pre_press_count]))

                        # The boundary out of the settle segment is a client-side
                        # identifiable completion event, not elapsed time alone:
                        # we configure the fixture to return a unique workspace
                        # root foreign_C ("task-receipt-foreign-C"), then deliver
                        # a fresh refresh press ('r').
                        # Observing that the screen renders the new workspace identity
                        # ("task-receipt-foreign-C") proves that:
                        # 1. The client processed the fresh 'r' key and dispatched HTTP.
                        # 2. The second refresh reached the server, received foreign_C,
                        #    and completed surface collection on the wire.
                        # 3. The client applied the bundle, updated state.server_identity,
                        #    and painted the frame to the PTY.
                        # Producer code (bin/masc_tui.ml:10435-10470, 10980-11050, 11840-11870)
                        # guarantees that identity_after (/health) is the final call in
                        # load_http_surfaces. Because Workspace_identity_mismatch
                        # is established, all scoped surface application and authority-change
                        # follow-up refreshes are skipped (:11865).
                        # Side reads launched on authority change (:11850-11857) target
                        # /turns and /schedules, which do not touch /health or /tasks/history.
                        # Furthermore, because http_refresh_inflight was false when 'r'
                        # was pressed, scoped_refresh_followup remained No_scoped_followup,
                        # so start_scoped_refresh_followup launches no subsequent pass.
                        # Zero trailing /health or /tasks/history reads follow this screen observation.
                        state["workspace_root"] = foreign_c
                        second_press_output_start = len(output)
                        second_pressed_at = time.monotonic()
                        os.write(fd, b"r")
                        h.wait_for_output(
                            process, fd, output, b"task-receipt-foreign-C",
                            start=second_press_output_start, timeout=15)

                        settle_deadline = time.monotonic() + 15
                        while not gate.quiesced():
                            if time.monotonic() > settle_deadline:
                                raise AssertionError(
                                    "refresh tail did not quiesce after foreign_C applied: "
                                    + repr(state["exchange_log"])
                                    + f" held={gate.held} reads="
                                    + repr((state["health_reads"], state["history_reads"])))
                            gate.changed.clear()
                            h.wait_for_fixture_event(process, fd, output, gate.changed, timeout=0.25)
                        boundary = [entry for entry in state["exchange_log"][pre_press_count:]
                                    if entry.get("root") == str(foreign_c)
                                    and entry["registered"] >= second_pressed_at]
                        assert boundary, (
                            "settled without any foreign_C registration: "
                            + repr(state["exchange_log"]))
                        assert all(entry["completed"] is not None for entry in boundary), (
                            "a post-press exchange is still running at settle time: "
                            + repr(boundary))
                        assert len(boundary) == len(state["exchange_log"][pre_press_count:]), (
                            "unexpected extra exchanges occurred outside boundary: "
                            + repr(state["exchange_log"][pre_press_count:]))
                        assert any(length >= 0.5 for length in gate.durations), (
                            "the completion gate never held the drill's slow exchange: "
                            + repr(gate.durations))
                        window_opened_at = boundary[-1]["completed"]
                    finally:
                        state["drill_delay"] = 0.0
                    # The gate stays armed through the receipt window: any
                    # exchange that arrives or completes there still registers
                    # and completes on the wire, so the assertions below see it.
                    assert h.drain_until_quiet(process, fd, output), (
                        "TUI output did not settle after refresh applied: " + repr(bytes(output)))
                before = (state["health_reads"], state["history_reads"])
                before_gate = gate.snapshot()
                # The window must not open over a still-running exchange:
                # an exchange that registered but has not completed yet
                # leaves held > 0, and an equal (held, exchanges) snapshot
                # later could not distinguish it from a clean window.
                # Reading the snapshot and the log entries under the same
                # quiescence the loop already proved keeps the pair
                # honest: the log is append-only, so a clean snapshot can
                # only hide a future registration, never an old one.
                assert before_gate[0] == 0, (
                    "the receipt window opened while an exchange was still running: "
                    + repr(before_gate))
                # Settle segment and receipt segment are separate: the
                # settle loop above refused to close until the client had
                # applied a refresh generation this scenario produced --
                # the readable confirm summary drawn -- so a window that
                # would have opened before the refresh tail's late
                # receive/apply landed cannot be reused here. This window
                # is keyed on a client-applied state, not on quiet
                # streaks that predate it.
                window_start = time.monotonic()
                assert window_start - window_opened_at >= gate.span, (
                    "the receipt window did not open after a settled span: "
                    + repr({"settled_at": window_opened_at, "opened_at": window_start,
                            "span": gate.span}))
                start = len(output)
                release.set()
                receipt = ("task " + TASK_A + " cancelled" +
                           ("" if unconfirmed else " in the previous workspace")).encode()
                h.wait_for_output(process, fd, output, receipt, start=start, timeout=10)
                h.drain_until_quiet(process, fd, output)
                after = (state["health_reads"], state["history_reads"])
                assert after == before, {"before": before, "after": after}
                after_gate = gate.snapshot()
                assert after_gate == before_gate, (
                    "an exchange ran during the receipt window: "
                    + repr({"before": before_gate, "after": after_gate,
                            "reads": {"before": before, "after": after}}))
                assert len(transitions) == 1, transitions
                if unconfirmed:
                    assert b"previous workspace" not in h.screen_text(bytes(output)), output[-4000:]
                    state["unread"] = False
                    start = len(output)
                    os.write(fd, b"r")
                    assert h.wait_for_fixture_state(process, fd, output,
                        lambda: state["history_reads"] > before[1], timeout=10), state
                    h.wait_for_output(process, fd, output, b"RECOVERED_CANCEL_HISTORY",
                        start=start, timeout=10)
                    assert len(transitions) == 1, "recovery repeated the cancellation POST"
                else:
                    # Liveness backstop: any read the window wrongly swallowed
                    # still arrives after the release, and turns this red.
                    os.write(fd, b"r")
                    reads_before_probe = (state["health_reads"], state["history_reads"])
                    h.drain_until_quiet(process, fd, output)
                    leaked = (state["health_reads"], state["history_reads"])
                    assert leaked != reads_before_probe, (
                        "the refresh chain never re-fired after the receipt window: "
                        + repr({"window": before, "after_probe": leaked}))
                os.write(fd, b"q")
            finally:
                release.set()

        h.run_terminal_scenario(
            executable, description=("accepted Task cancel waits for same-workspace history recovery"
                if unconfirmed else "accepted Task cancel reports previous workspace without refresh"),
            interact=interact, http_fixtures=fixtures, http_requests=requests,
            prepare_workspace=prepare, refresh=3600.0,
            extra_env={"EDITOR": f"{shlex.quote(sys.executable)} {shlex.quote(str(editor))}"},
        )


if __name__ == "__main__":
    exe = os.path.abspath(sys.argv[1])
    task_cards_and_deletion(exe)
    full_http_loss_retains_local_work_and_draft(exe)
    task_cancel_editor_replacement(exe)
    task_cancel_previous_workspace_receipt(exe)
    task_cancel_previous_workspace_receipt(exe, unconfirmed=True)
    print("Home failure and Task PTY: PASS (5 scenarios)")
