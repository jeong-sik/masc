"""The Runtime lanes reading edits lanes: a, x, J, K and D, pressed for real.

A new lane is named, given its first runtime, grown, reordered, trimmed and
removed; an edit pressed while the previous write is still out is refused on
screen; and the server's refusal to remove a lane a keeper is assigned to, or
a Fusion preset seat names, is drawn as the server wrote it. The main judgement is the body each press posts
to the routing API, compared whole at the end.
"""
import json
import os
import sys
import threading
import time
import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs a
# suite when a pull request changes a path the suite names.
SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_types.ml",
    "bin/masc_tui_keys.ml",
    "bin/masc_tui_http.ml",
    "lib/server/server_standalone_lane_projection.ml",
    "lib/tui_decode.ml",
)

ROUTING_PATH = "/api/v1/runtime/config/routing"
# Its name carries an [a] and an [e]: while the name field is open those are
# letters of the name, not the new-lane and add-candidate keys.
NEW_LANE = "ci-lane"
# Masc_tui_types.runtime_lane_notice_text Lane_write_pending: the line a lane
# key draws while the previous lane write is still being written or read back.
BUSY = b"the previous lane change is still being written"


def commit_receipt() -> dict[str, object]:
    return {
        "ok": True,
        "state": "committed",
        "commit": {
            "source_revision": "source-7",
            "order": "7",
            "durability": "durable",
            "warnings": [],
        },
        "application": {
            "operation": "routing",
            "routing": {
                "status": "applied",
                "requires_restart": False,
                "applied_at": "2026-08-26T03:00:00Z",
            },
            "keeper_overlay": {
                "status": "pending_restart",
                "configured_count": 1,
                "requires_restart": True,
                "pending_keys": ["turn.temperature"],
                "applied_keys": [],
                "preempted_keys": [],
                "applied_at": None,
            },
            "skills": {
                "state": "published",
                "input_source_revision": "source-7",
                "snapshot_revision": "snapshot-7",
                "catalog_revision": "catalog-7",
                "config_state": "configured",
            },
            "exact_output_registry": {
                "status": "applied",
                "requires_restart": False,
                "targets": "runtime_bindings",
            },
        },
    }


# The Fusion seats that name a lane, as [fusion.presets.<preset>].<seat>. The
# scenario's refused lane is also a preset's judge, the shape that broke every
# run of that preset when the lane was removed without a word.
FUSION_SEATS = {"primary": ["[fusion.presets.trio].judge"]}


def in_use_refusal(lane_id: str, keepers: list[str]) -> str:
    """The sentence Runtime.remove_runtime_lane answers for a lane keepers are
    assigned to or Fusion seats name (route_reference_to_string in
    lib/runtime/runtime.ml): assignments first, then seats."""
    sites = ", ".join(
        [f"[runtime.assignments].{keeper}" for keeper in keepers]
        + FUSION_SEATS.get(lane_id, [])
    )
    return f'lane "{lane_id}" is in use by {sites}'


class LaneStore:
    """A stand-in for the routing API's writer, Runtime's lane functions over
    runtime.toml. It applies a post to the lanes the next /resolved read
    returns, the way a committed write reaches that read on the server:

    - create declares the lane with the candidates it was given;
    - set replaces a lane's candidates with the list it was given;
    - an "exact/<name>" append adds one slot to the end of that standalone
      lane's declared slots and refuses one already declared
      (Runtime.append_exact_output_lane_slot). The declared slots include one
      the registry dropped, which the standalone lanes read never lists, as
      the server's registry would;
    - remove drops the lane, and is refused while [runtime.assignments] or a
      Fusion seat (FUSION_SEATS) names it, with the server's sentence.

    A lane here is exactly its candidates, as it is on the server since
    #37064: nothing appends the default runtime. The server's other checks --
    runtime ids, the default, verifier slots, the whole-file validation --
    are not repeated; the unit tests of Runtime cover them. What this
    scenario judges is the TUI: the body each key posts, and that a refusal
    reaches the screen as the server wrote it."""

    def __init__(self) -> None:
        _status, body = h.runtime_resolved_response()
        self.body = body
        self.lanes = [dict(lane) for lane in body["lanes"]]
        self.lock = threading.Lock()
        self.held: tuple[threading.Event, threading.Event] | None = None
        self.fail_next_resolved = False
        _status, standalone = h.standalone_lanes_response()
        self.standalone = standalone
        self.standalone_held: tuple[threading.Event, threading.Event] | None = None
        exact = self.exact_lane(EXACT_LANE)
        exact["dropped_slots"] = [DROPPED_SLOT]
        self.exact_declared = {EXACT_LANE: [DROPPED_SLOT, *exact["admitted_slots"]]}
        self.exact_declared_cli = {EXACT_LANE: []}
        # The projection now carries the file's own order beside the admission
        # lists; the fixture serves the one it tracks.
        exact["declared_slots"] = list(self.exact_declared[EXACT_LANE])

    def exact_lane(self, name: str) -> dict:
        return next(lane for lane in self.standalone["lanes"] if lane["lane_id"] == name)

    def resolved(self) -> h.HttpResponse:
        with self.lock:
            if self.fail_next_resolved:
                self.fail_next_resolved = False
                return 503, {"error": "resolved unavailable"}
            lanes = [
                {
                    "id": lane["id"],
                    "runtime_ids": list(lane["runtime_ids"]),
                    # Every lane this fixture serves is one its file declares;
                    # the assignment-made singleton has no row here.
                    "declared": True,
                }
                for lane in self.lanes
            ]
        return 200, {**self.body, "lanes": lanes}

    def standalone_lanes(self) -> h.HttpResponse:
        """The standalone lanes as they stand when the read arrives. A held
        read answers with that, after the release: a load that left before a
        write and lands after it."""
        with self.lock:
            held, self.standalone_held = self.standalone_held, None
            body = json.loads(json.dumps(self.standalone))
        if held is not None:
            arrived, release = held
            arrived.set()
            if not release.wait(timeout=10.0):
                return 504, {"error": "fixture hold was never released"}
        return 200, body

    def hold_next_standalone_read(self) -> tuple[threading.Event, threading.Event]:
        arrived, release = threading.Event(), threading.Event()
        with self.lock:
            self.standalone_held = (arrived, release)
        return arrived, release

    def hold_next_post(self) -> tuple[threading.Event, threading.Event]:
        """Hold the next routing post until the second event is set. The first
        is set once that post has arrived."""
        arrived, release = threading.Event(), threading.Event()
        with self.lock:
            self.held = (arrived, release)
        return arrived, release

    def replace_lane_from_another_client(
        self, lane_id: str, runtime_ids: list[str]
    ) -> None:
        """Apply a dashboard write after the TUI's last readable snapshot."""
        with self.lock:
            lane = next(lane for lane in self.lanes if lane["id"] == lane_id)
            lane["runtime_ids"] = list(runtime_ids)

    def lane_candidates(self, lane_id: str) -> list[str]:
        with self.lock:
            lane = next(lane for lane in self.lanes if lane["id"] == lane_id)
            return list(lane["runtime_ids"])

    def route(self, raw: bytes) -> h.HttpResponse:
        with self.lock:
            held, self.held = self.held, None
        if held is not None:
            arrived, release = held
            arrived.set()
            if not release.wait(timeout=10.0):
                return 504, {"error": "fixture hold was never released"}
        request = json.loads(raw)
        lane_id = request["lane"]
        action = request.get("action", "set")
        with self.lock:
            if lane_id.startswith("exact/"):
                name = lane_id[len("exact/"):]
                slot = request["runtime_id"]
                lane = self.exact_lane(name)
                declared = self.exact_declared.setdefault(name, list(lane["declared_slots"]))
                declared_cli = self.exact_declared_cli.setdefault(
                    name, list(lane["declared_cli_slots"])
                )
                if action == "append":
                    if slot in declared or slot in declared_cli:
                        return 400, {"error": f"{slot} is already a slot of {name}"}
                    runtime = next(
                        (row for row in self.body["runtimes"] if row["id"] == slot), None
                    )
                    if runtime is not None and runtime["exact_slot_group"] == "cli_slots":
                        declared_cli.append(slot)
                    else:
                        declared.append(slot)
                elif action in ("move", "drop"):
                    source = declared if slot in declared else declared_cli
                    if slot not in source:
                        return 400, {"error": f"{slot} is not a slot of {name}"}
                    if action == "drop":
                        source.remove(slot)
                    else:
                        index = source.index(slot)
                        neighbor = index + (1 if request["direction"] == "down" else -1)
                        if neighbor < 0 or neighbor >= len(source):
                            return 400, {"error": f"{slot} cannot move across slot groups"}
                        source[index], source[neighbor] = source[neighbor], source[index]
                else:
                    raise AssertionError(f"the TUI posted {action!r} to a standalone lane")
                lane["admitted_slots"] = [
                    s for s in declared if s not in lane["dropped_slots"]
                ]
                lane["declared_slots"] = list(declared)
                lane["declared_cli_slots"] = list(declared_cli)
                lane["cli_slots"] = list(declared_cli)
                return 200, commit_receipt()
            declared = [lane for lane in self.lanes if lane["id"] == lane_id]
            if action == "create":
                self.lanes.append(
                    {"id": lane_id, "runtime_ids": list(request["runtime_ids"])}
                )
            elif action == "set":
                declared[0]["runtime_ids"] = list(request["runtime_ids"])
            elif action == "remove":
                assigned = [
                    assignment["keeper"]
                    for assignment in self.body["assignments"]
                    if assignment["resolved"] == {"kind": "lane", "id": lane_id}
                ]
                if assigned or lane_id in FUSION_SEATS:
                    return 400, {"error": in_use_refusal(lane_id, assigned)}
                self.lanes.remove(declared[0])
            else:
                raise AssertionError(f"the TUI posted an unknown action {action!r}")
        return 200, commit_receipt()


def mark_output(fd, output) -> int:
    """Where the next press's output begins, so a wait does not match a row
    an earlier frame drew."""
    h.read_available(fd, output)
    return len(output)


def press(process, fd, output, key: bytes) -> None:
    """A key whose effect is a cursor move: nothing on screen names it, so it
    is judged by the next key that acts on the row it lands on."""
    h.read_available(fd, output)
    start = len(output)
    os.write(fd, key)
    h.wait_for_output(process, fd, output, h.FRAME_END, start=start, timeout=3.0)
    h.drain_until_quiet(process, fd, output)


def run(executable: str) -> None:
    store = LaneStore()
    fixtures = h.overview_event_http_fixtures()
    fixtures[h.RUNTIME_PROBE_PATH] = h.runtime_probe_response(fresh=True)
    fixtures[h.RUNTIME_PROBE_FORCE_PATH] = h.runtime_probe_response(fresh=True)
    fixtures[h.RUNTIME_RESOLVED_PATH] = store.resolved
    fixtures[ROUTING_PATH] = h.RequestHttpResponse(store.route)
    requests: h.HttpRequests = []

    def interact(process, fd, _slave, output, _base):
        h.tab_until(process, fd, output, b"MASC System")
        # 131 columns, as the Runtime scenario in test_tui_keyboard_input.py
        # uses: wide enough for the prompt rows, narrow enough to keep the
        # acting pane off the screen.
        h.resize_and_wait(
            process, fd, output, rows=30, columns=131,
            needle=b"MASC System", controls=(h.FULL_REDRAW,),
        )
        h.send_and_wait(process, fd, output, b"9", b"Lanes (3 lanes, 4 slots)")

        # [a] opens the name field; the letters typed after it are the name's.
        h.send_and_wait(process, fd, output, b"a", b"new lane name: _")
        h.send_and_wait(
            process, fd, output, NEW_LANE.encode(),
            f"new lane name: {NEW_LANE}_".encode(),
        )
        mark = mark_output(fd, output)
        h.send_and_wait(
            process, fd, output, b"\r",
            f"first runtime of new lane {NEW_LANE}".encode(),
        )
        # A lane with no candidates yet ranks the catalog by id. The catalog
        # is read when [a] opens the field, so its rows can trail the header.
        h.wait_for_output(process, fd, output, b"> runtime-a", start=mark, timeout=5.0)
        h.send_and_wait(process, fd, output, b"\r", b"Lanes (4 lanes, 5 slots)")

        # The new lane's row is the fifth. [e] there names the lane it adds
        # to, which is what shows the cursor stands on it.
        for _ in range(4):
            press(process, fd, output, b"j")
        mark = mark_output(fd, output)
        h.send_and_wait(
            process, fd, output, b"e",
            f"adding a candidate to the candidate order of {NEW_LANE}".encode(),
        )
        # The lane's own runtime ranks last; the other four come by id.
        h.wait_for_output(process, fd, output, b"> runtime-b", start=mark, timeout=5.0)
        for needle in (b"> runtime-c", b"> runtime-d", b"> runtime-e"):
            h.send_and_wait(process, fd, output, b"j", needle)
        h.send_and_wait(process, fd, output, b"\r", b"2/2 runtime-e")

        # [J] moves runtime-a below runtime-e, and the cursor goes with it.
        # The post is held: an [x] pressed before the move is read back would
        # be built from the order the move replaced, so it is refused on
        # screen and posts nothing, and it does not move the cursor the move
        # will leave on runtime-a.
        arrived, release = store.hold_next_post()
        os.write(fd, b"J")
        if not arrived.wait(timeout=5.0):
            raise AssertionError("J posted nothing")
        h.send_and_wait(
            process, fd, output, b"x",
            b"lane write refused: " + BUSY,
        )
        mark = mark_output(fd, output)
        release.set()
        h.wait_for_output(process, fd, output, b"1/2 runtime-e", start=mark, timeout=5.0)
        # [x] drops the row the cursor followed: runtime-a, not runtime-e.
        h.send_and_wait(process, fd, output, b"x", b"1/1 runtime-e")

        # [D] asks first; the second press removes the lane.
        h.send_and_wait(
            process, fd, output, b"D",
            f"press D again to remove lane {NEW_LANE}".encode(),
        )
        h.send_and_wait(process, fd, output, b"D", b"Lanes (3 lanes, 4 slots)")
        h.read_available(fd, output)
        if NEW_LANE.encode() in h.screen_text(bytes(output)):
            raise AssertionError(f"{NEW_LANE} is still on screen after its removal")

        # A lane a keeper is assigned to and a Fusion seat names is refused by
        # the server, and the TUI draws the server's sentence whole, the seat
        # at its end included.
        for _ in range(3):
            press(process, fd, output, b"k")
        h.send_and_wait(
            process, fd, output, b"D", b"press D again to remove lane primary",
        )
        h.send_and_wait(
            process, fd, output, b"D",
            b"lane write refused: HTTP 400: " + in_use_refusal("primary", ["sangsu"]).encode(),
        )
        # The refusal is about the row the key acted on: moving the cursor
        # ends it. The cursor comes back to primary's head for the next key.
        press(process, fd, output, b"j")
        screen_lacks(process, fd, output, b"lane write refused: HTTP 400", timeout=3.0)
        press(process, fd, output, b"k")

        # A refused write ends at once: J posts. Its read-back fails, and that
        # ends it too, with a line saying the list may be stale -- the screen
        # still shows the order from before J.
        store.fail_next_resolved = True
        h.send_and_wait(
            process, fd, output, b"J", b"the lane list could not be re-read",
        )
        # Another client now removes runtime-a. The TUI still shows the old
        # [runtime-a; runtime-b] order, where runtime-b is second. K used to
        # post that whole stale order and restore runtime-a. The unread list
        # now refuses the key without posting, so the authoritative removal
        # stays in place.
        store.replace_lane_from_another_client("primary", ["runtime-b"])
        h.send_and_wait(
            process, fd, output, b"K",
            b"lane write refused: the lane list may be stale",
        )
        # The conversation-lane picker uses the same whole stale order when it
        # adds a candidate. Opening it refreshes only the catalog. Enter must
        # refuse locally too, without restoring runtime-a beside the new id.
        mark = mark_output(fd, output)
        h.send_and_wait(process, fd, output, b"e", b"adding a candidate to the candidate order of primary")
        h.wait_for_output(process, fd, output, b"> runtime-c", start=mark, timeout=5.0)
        h.send_and_wait(
            process, fd, output, b"\r",
            b"lane write refused: the lane list may be stale",
        )
        os.write(fd, b"esc")

        # The request log is appended after the response goes out, so the
        # last post can trail the frame it produced.
        expected = [
            {"lane": NEW_LANE, "action": "create", "runtime_ids": ["runtime-a"]},
            {"lane": NEW_LANE, "runtime_ids": ["runtime-a", "runtime-e"]},
            {"lane": NEW_LANE, "runtime_ids": ["runtime-e", "runtime-a"]},
            {"lane": NEW_LANE, "runtime_ids": ["runtime-e"]},
            {"lane": NEW_LANE, "action": "remove"},
            {"lane": "primary", "action": "remove"},
            {"lane": "primary", "runtime_ids": ["runtime-b", "runtime-a"]},
        ]
        deadline = time.monotonic() + 3.0
        while True:
            posted = [json.loads(body) for path, body in requests if path == ROUTING_PATH]
            if len(posted) >= len(expected) or time.monotonic() > deadline:
                break
            time.sleep(0.05)
        if posted != expected:
            raise AssertionError(f"routing posts: {posted!r}, expected {expected!r}")
        primary = store.lane_candidates("primary")
        if primary != ["runtime-b"]:
            raise AssertionError(
                f"the stale TUI restored another client's removal: {primary!r}"
            )
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Runtime lanes reading edits lanes",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )


EXACT_LANE = "board_attention_exact"
# Declared on the lane and dropped by the registry: the standalone lanes read
# lists it under dropped_slots, never among the admitted slots the picker sees.
DROPPED_SLOT = "retired-catalog.slot"


def screen_lacks(process, fd, output, needle: bytes, timeout: float) -> None:
    """Wait until [needle] is gone from the screen the pane last painted."""
    deadline = time.monotonic() + timeout
    while True:
        h.drain_until_quiet(process, fd, output)
        if needle not in h.screen_text(bytes(output)):
            return
        if time.monotonic() > deadline:
            raise AssertionError(f"{needle!r} stayed on screen")


def run_exact(executable: str) -> None:
    """A standalone lane's slots are read back from the standalone lanes list.
    A load of that list already out when the write answers may have left
    before it, so the read-back is queued behind it; the next picker offers
    what the queued read returns. Each pick posts only the slot it adds, so
    the declared slot the registry dropped survives both."""
    store = LaneStore()
    fixtures = h.overview_event_http_fixtures()
    fixtures[h.RUNTIME_PROBE_PATH] = h.runtime_probe_response(fresh=True)
    fixtures[h.RUNTIME_PROBE_FORCE_PATH] = h.runtime_probe_response(fresh=True)
    fixtures[h.RUNTIME_RESOLVED_PATH] = store.resolved
    fixtures[h.STANDALONE_LANES_PATH] = store.standalone_lanes
    fixtures[ROUTING_PATH] = h.RequestHttpResponse(store.route)
    requests: h.HttpRequests = []
    picker = f"adding a candidate to the candidate order of {EXACT_LANE}".encode()

    def exact_posts() -> list[object]:
        return [json.loads(body) for path, body in requests if path == ROUTING_PATH]

    def wait_for_posts(count: int) -> list[object]:
        deadline = time.monotonic() + 5.0
        while len(exact_posts()) < count:
            if time.monotonic() > deadline:
                raise AssertionError(f"routing posts: {exact_posts()!r}")
            time.sleep(0.05)
        return exact_posts()

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
        h.wait_for_output(process, fd, output, b"Board Attention", start=0, timeout=10)
        # [r] sends a load of the list and the fixture holds it: it has left
        # before the write below.
        arrived, release = store.hold_next_standalone_read()
        os.write(fd, b"r")
        if not arrived.wait(timeout=5.0):
            raise AssertionError("r read no standalone lanes")
        mark = mark_output(fd, output)
        h.send_and_wait(process, fd, output, b"a", picker)
        h.wait_for_output(process, fd, output, b"> runtime-a", start=mark, timeout=5.0)
        os.write(fd, b"\r")
        wait_for_posts(1)
        # The write answered once the picker closes. Only then is the held
        # load let go: it lands with the slots from before the write.
        screen_lacks(process, fd, output, picker, timeout=5.0)
        mark = mark_output(fd, output)
        release.set()
        # The queued read-back is what draws the new slot. The held load
        # lands first, with slots that do not name runtime-a, and the picker
        # that did is closed.
        h.wait_for_output(process, fd, output, b"runtime-a", start=mark, timeout=5.0)
        # The second picker is built from that list, so runtime-a is no
        # longer offered and the cursor opens on runtime-b.
        mark = mark_output(fd, output)
        h.send_and_wait(process, fd, output, b"a", picker)
        h.wait_for_output(process, fd, output, b"> runtime-b", start=mark, timeout=5.0)
        os.write(fd, b"\r")
        posted = wait_for_posts(2)
        # A pick sends only the slot it adds. A whole order built from the
        # admitted slots would have left out the dropped one and deleted it.
        expected = [
            {"lane": f"exact/{EXACT_LANE}", "action": "append", "runtime_id": "runtime-a"},
            {"lane": f"exact/{EXACT_LANE}", "action": "append", "runtime_id": "runtime-b"},
        ]
        if posted != expected:
            raise AssertionError(f"exact posts: {posted!r}, expected {expected!r}")
        declared = store.exact_declared[EXACT_LANE]
        if declared != [DROPPED_SLOT, "glm-coding.glm-5-turbo", "runtime-a", "runtime-b"]:
            raise AssertionError(f"declared slots after the picks: {declared!r}")
        screen_lacks(process, fd, output, picker, timeout=5.0)
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Standalone lane picks wait for the standalone list",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )


def run_cli_editor(executable: str) -> None:
    """The Librarian editor reaches both arrays and explains their boundary."""
    store = LaneStore()
    new_cli = "aaa_cli.fixture"
    store.body["runtimes"].append({
        **h.runtime_resolved_runtime(new_cli, "Official client", "model"),
        "exact_slot_group": "cli_slots",
    })
    librarian = store.exact_lane("librarian_exact")
    cli = ["codex_subscription.gpt-6-luna", "claude_code.claude-sonnet-5"] + [
        f"codex_subscription.extra-{index}" for index in range(8)
    ]
    librarian["declared_cli_slots"] = list(cli)
    librarian["cli_slots"] = list(cli)
    store.exact_declared["librarian_exact"] = list(librarian["declared_slots"])
    store.exact_declared_cli["librarian_exact"] = list(cli)
    fixtures = h.overview_event_http_fixtures()
    fixtures[h.RUNTIME_RESOLVED_PATH] = store.resolved
    fixtures[h.STANDALONE_LANES_PATH] = store.standalone_lanes
    fixtures[ROUTING_PATH] = h.RequestHttpResponse(store.route)
    requests: h.HttpRequests = []

    def exact_posts() -> list[dict]:
        return [json.loads(body) for path, body in requests if path == ROUTING_PATH]

    def wait_for_posts(count: int) -> list[dict]:
        deadline = time.monotonic() + 5.0
        while len(exact_posts()) < count:
            if time.monotonic() > deadline:
                raise AssertionError(f"exact posts: {exact_posts()!r}")
            time.sleep(0.05)
        return exact_posts()

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
        h.resize_and_wait(process, fd, output, rows=30, columns=131,
                          needle=b"MASC Lanes", controls=(h.FULL_REDRAW,))
        h.send_and_wait(process, fd, output, b"j", b"HITL")
        h.send_and_wait(process, fd, output, b"j", b"Librarian")
        mark = mark_output(fd, output)
        h.send_and_wait(process, fd, output, b"s", b"MASC Lanes / Providers")
        h.wait_for_output(process, fd, output,
                          b"[CLI] codex_subscription.gpt-6-luna", start=mark, timeout=5.0)
        h.wait_for_output(process, fd, output,
                          b"[CLI] claude_code.claude-sonnet-5", start=mark, timeout=5.0)
        h.send_and_wait(process, fd, output, b"j", b"[CLI] codex_subscription.gpt-6-luna")
        h.send_and_wait(process, fd, output, b"K", b"HTTP slots run first")
        if exact_posts():
            raise AssertionError(f"a cross-boundary move posted: {exact_posts()!r}")
        h.send_and_wait(process, fd, output, b"j", b"[CLI] claude_code.claude-sonnet-5")
        mark = mark_output(fd, output)
        os.write(fd, b"K")
        posted = wait_for_posts(1)
        expected = [{"lane": "exact/librarian_exact", "action": "move",
                     "runtime_id": "claude_code.claude-sonnet-5", "direction": "up"}]
        if posted != expected:
            raise AssertionError(f"CLI reorder posted {posted!r}, expected {expected!r}")
        h.wait_for_output(process, fd, output,
                          b"> 2/11  [CLI] claude_code.claude-sonnet-5", start=mark, timeout=5.0)
        if store.exact_declared_cli["librarian_exact"] != [cli[1], cli[0], *cli[2:]]:
            raise AssertionError("the server fixture did not reorder the CLI declaration")
        h.resize_and_wait(process, fd, output, rows=15, columns=100,
                          needle=b"MASC Lanes / Providers", controls=(h.FULL_REDRAW,))
        h.send_and_wait(process, fd, output, b"j" * 9,
                        b"> 11/11  [CLI] codex_subscription.extra-7")
        h.send_and_wait(process, fd, output, b"a", b"add provider")
        h.send_and_wait(process, fd, output, b"e",
                        b"> 11/11  [CLI] codex_subscription.extra-7")
        h.send_and_wait(process, fd, output, b"k" * 10,
                        b"> 1/11  [HTTP]")
        mark = mark_output(fd, output)
        h.send_and_wait(process, fd, output, b"a", b"[CLI tail] aaa_cli.fixture")
        h.wait_for_output(process, fd, output,
                          b"[HTTP tail] runtime-a", start=mark, timeout=5.0)
        mark = mark_output(fd, output)
        os.write(fd, b"\r")
        posted = wait_for_posts(2)
        if posted[1] != {"lane": "exact/librarian_exact", "action": "append",
                         "runtime_id": new_cli}:
            raise AssertionError(f"CLI append posted {posted[1]!r}")
        h.wait_for_output(process, fd, output,
                          b"> 1/12  [HTTP]", start=mark, timeout=5.0)
        h.send_and_wait(process, fd, output, b"j" * 11,
                        b"> 12/12  [CLI] aaa_cli.fixture")
        if store.exact_declared_cli["librarian_exact"][-1] != new_cli:
            raise AssertionError("new official client did not append to CLI tail")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Librarian provider editor includes CLI fallback slots",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )


def run_curator_cli_refused(executable: str) -> None:
    """The workspace curator walks HTTP slots only. The lane projection says
    so (supports_cli_tail), the picker draws an official client disabled, and
    Enter on it posts nothing; an HTTP candidate in the same picker still
    appends."""
    store = LaneStore()
    new_cli = "aaa_cli.fixture"
    store.body["runtimes"].append({
        **h.runtime_resolved_runtime(new_cli, "Official client", "model"),
        "exact_slot_group": "cli_slots",
    })
    curator = store.exact_lane("workspace_curator_exact")
    if curator["supports_cli_tail"] is not False:
        raise AssertionError("the fixture's curator row claims a CLI tail")
    fixtures = h.overview_event_http_fixtures()
    fixtures[h.RUNTIME_RESOLVED_PATH] = store.resolved
    fixtures[h.STANDALONE_LANES_PATH] = store.standalone_lanes
    fixtures[ROUTING_PATH] = h.RequestHttpResponse(store.route)
    requests: h.HttpRequests = []

    def exact_posts() -> list[dict]:
        return [json.loads(body) for path, body in requests if path == ROUTING_PATH]

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
        h.resize_and_wait(process, fd, output, rows=30, columns=131,
                          needle=b"MASC Lanes", controls=(h.FULL_REDRAW,))
        h.send_and_wait(process, fd, output, b"j", b"HITL")
        h.send_and_wait(process, fd, output, b"j", b"Librarian")
        h.send_and_wait(process, fd, output, b"j", b"Workspace Curator")
        h.send_and_wait(process, fd, output, b"s", b"MASC Lanes / Providers")
        h.send_and_wait(process, fd, output, b"a",
                        b"> [CLI tail] aaa_cli.fixture")
        h.send_and_wait(process, fd, output, b"\r",
                        b"workspace_curator_exact walks HTTP slots only")
        # The refusal is drawn from the state alone; give a stray write the
        # time a real one takes to reach the fixture before judging.
        time.sleep(0.5)
        if exact_posts():
            raise AssertionError(f"a CLI pick on the curator posted: {exact_posts()!r}")
        h.send_and_wait(process, fd, output, b"j", b"> [HTTP tail] runtime-a")
        os.write(fd, b"\r")
        deadline = time.monotonic() + 5.0
        while not exact_posts():
            if time.monotonic() > deadline:
                raise AssertionError("the HTTP pick on the curator posted nothing")
            time.sleep(0.05)
        expected = [{"lane": "exact/workspace_curator_exact", "action": "append",
                     "runtime_id": "runtime-a"}]
        if exact_posts() != expected:
            raise AssertionError(f"curator posts {exact_posts()!r}, expected {expected!r}")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Workspace curator picker refuses official-client candidates",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )


def run_provider_jump(executable: str) -> None:
    """[d] on an HTTP slot opens its [providers.<id>] table in Config. The
    table key is the catalogue's provider_id, and the header is found by the
    key path the TOML grammar reads, so a quoted key with a trailing comment
    is the same table. While the picker is open, [d] stays with it."""
    store = LaneStore()
    slot = "glm-coding.glm-5-turbo"
    store.body["runtimes"].append(
        h.runtime_resolved_runtime(slot, "GLM Coding", "glm-5-turbo",
                                   provider_id="glm-coding")
    )
    fixtures = h.overview_event_http_fixtures()
    fixtures[h.RUNTIME_RESOLVED_PATH] = store.resolved
    fixtures[h.STANDALONE_LANES_PATH] = store.standalone_lanes
    fixtures[ROUTING_PATH] = h.RequestHttpResponse(store.route)
    status, config = h.standalone_lane_runtime_config_response()
    fixtures[h.RUNTIME_CONFIG_RAW_PATH] = (
        status,
        {
            **config,
            "source_text": config["source_text"]
            + '\n\n[providers."glm-coding"] # request window\n'
            + "exact-body-timeout-s = 1200\n",
        },
    )
    requests: h.HttpRequests = []

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
        h.resize_and_wait(process, fd, output, rows=30, columns=131,
                          needle=b"MASC Lanes", controls=(h.FULL_REDRAW,))
        h.send_and_wait(process, fd, output, b"j", b"HITL")
        h.send_and_wait(process, fd, output, b"j", b"Librarian")
        h.send_and_wait(process, fd, output, b"s", b"MASC Lanes / Providers")
        h.wait_for_output(process, fd, output,
                          b"> 1/1  [HTTP] glm-coding.glm-5-turbo", start=0, timeout=5.0)
        h.send_and_wait(process, fd, output, b"a", b"add provider")
        # The picker owns focus: [d] neither jumps nor closes it, so the
        # [e] after it lands on the picker and returns to the slot rows.
        os.write(fd, b"d")
        h.send_and_wait(process, fd, output, b"e",
                        b"> 1/1  [HTTP] glm-coding.glm-5-turbo")
        os.write(fd, b"d")
        # Config colours a header's pieces apart, so the drawn screen, not
        # the byte stream, is what names the table.
        wanted = (b'[providers."glm-coding"] # request window',
                  b"exact-body-timeout-s = 1200")
        deadline = time.monotonic() + 5.0
        while True:
            h.read_available(fd, output)
            screen = h.screen_text(bytes(output))
            if all(needle in screen for needle in wanted):
                break
            if time.monotonic() > deadline:
                raise AssertionError("[d] did not open the provider table")
            time.sleep(0.05)
        if any(path == ROUTING_PATH for path, _body in requests):
            raise AssertionError("the provider jump posted a routing write")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Slot editor opens an HTTP slot's provider table",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )


# SGR mouse wheel notches at column 5, row 5, clear of the Activity pane.
WHEEL_UP = b"\x1b[<64;5;5M"
WHEEL_DOWN = b"\x1b[<65;5;5M"
# The picker header's filter cursor, U+258F.
FILTER_CURSOR = "▏".encode()


def run_filter(executable: str) -> None:
    """The candidate picker is walked without holding an arrow key: End, Home
    and PgDn jump, [/] narrows the list to the typed text, and Esc drops the
    filter before it closes the picker. Letters typed into the filter are the
    filter's, and Enter over an empty result posts nothing."""
    store = LaneStore()
    fixtures = h.overview_event_http_fixtures()
    fixtures[h.RUNTIME_PROBE_PATH] = h.runtime_probe_response(fresh=True)
    fixtures[h.RUNTIME_PROBE_FORCE_PATH] = h.runtime_probe_response(fresh=True)
    fixtures[h.RUNTIME_RESOLVED_PATH] = store.resolved
    fixtures[ROUTING_PATH] = h.RequestHttpResponse(store.route)
    requests: h.HttpRequests = []
    picker = b"adding a candidate to the candidate order of primary"

    def interact(process, fd, _slave, output, _base):
        h.tab_until(process, fd, output, b"MASC System")
        h.resize_and_wait(
            process, fd, output, rows=30, columns=131,
            needle=b"MASC System", controls=(h.FULL_REDRAW,),
        )
        h.send_and_wait(process, fd, output, b"9", b"Lanes (3 lanes, 4 slots)")
        # primary holds runtime-a and runtime-b, so the other three rank
        # first: c, d, e, then a, b.
        mark = mark_output(fd, output)
        h.send_and_wait(process, fd, output, b"e", picker)
        h.wait_for_output(process, fd, output, b"> runtime-c", start=mark, timeout=5.0)
        h.wait_for_output(process, fd, output, "5 of 5 · / filter".encode(), start=mark, timeout=5.0)
        # The wheel moves the picker, not the lane list under it: primary's
        # rows are 0 and 1 there and degraded is 2, so two notches that
        # leaked would leave the list on degraded (checked at the end).
        h.send_and_wait(process, fd, output, WHEEL_DOWN, b"> runtime-d")
        h.send_and_wait(process, fd, output, WHEEL_DOWN, b"> runtime-e")
        h.send_and_wait(process, fd, output, WHEEL_UP, b"> runtime-d")
        h.send_and_wait(process, fd, output, b"\x1b[F", b"> runtime-b")
        h.send_and_wait(process, fd, output, b"\x1b[H", b"> runtime-c")
        h.send_and_wait(process, fd, output, b"\x1b[6~", b"> runtime-a")

        h.send_and_wait(process, fd, output, b"/", b"filter: " + FILTER_CURSOR + b" 5 of 5")
        mark = mark_output(fd, output)
        h.send_and_wait(process, fd, output, b"-d", b"filter: -d" + FILTER_CURSOR + b" 1 of 5")
        h.wait_for_output(process, fd, output, b"> runtime-d", start=mark, timeout=3.0)
        # [j] moves the picker outside a filter; inside one it is a letter.
        h.send_and_wait(
            process, fd, output, b"j", b"(no runtime among 5 matches the filter)",
        )
        # Enter over no match changes nothing, so nothing repaints; the posts
        # compared at the end are what show it sent nothing.
        os.write(fd, b"\r")
        h.send_and_wait(process, fd, output, b"\x7f", b"filter: -d" + FILTER_CURSOR + b" 1 of 5")
        # Esc drops the filter and keeps runtime-d under the cursor.
        # runtime-d opens the window again, on the row it was drawn on under
        # the filter, so the frame does not redraw that row: read the screen.
        h.send_and_wait(process, fd, output, b"\x1b", "5 of 5 · / filter".encode())
        h.drain_until_quiet(process, fd, output)
        if b"> runtime-d   Resolved D / model-d" not in h.screen_text(bytes(output)):
            raise AssertionError("Esc did not keep runtime-d under the cursor")

        h.send_and_wait(process, fd, output, b"/model-e", b"filter: model-e" + FILTER_CURSOR + b" 1 of 5")
        os.write(fd, b"\r")
        screen_lacks(process, fd, output, picker, timeout=5.0)

        expected = [{"lane": "primary", "runtime_ids": ["runtime-a", "runtime-b", "runtime-e"]}]
        deadline = time.monotonic() + 3.0
        while True:
            posted = [json.loads(body) for path, body in requests if path == ROUTING_PATH]
            if len(posted) >= len(expected) or time.monotonic() > deadline:
                break
            time.sleep(0.05)
        if posted != expected:
            raise AssertionError(f"routing posts: {posted!r}, expected {expected!r}")
        # [e] opens the picker for the lane under the list's cursor: still
        # primary, so no wheel notch moved it while the picker was open.
        h.send_and_wait(process, fd, output, b"e", picker)
        # Esc and q apart: written together they read as Alt-q.
        os.write(fd, b"\x1b")
        screen_lacks(process, fd, output, picker, timeout=5.0)
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Runtime candidate picker filters and pages",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    run_exact(os.path.abspath(sys.argv[1]))
    run_cli_editor(os.path.abspath(sys.argv[1]))
    run_curator_cli_refused(os.path.abspath(sys.argv[1]))
    run_filter(os.path.abspath(sys.argv[1]))
    run_provider_jump(os.path.abspath(sys.argv[1]))
    print("runtime lane editor: PASS")
