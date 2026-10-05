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
from datetime import datetime
import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_keepers as _keyboard_keepers
import tui_keyboard_runtime as _keyboard_runtime



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
    assigned to or Fusion seats name (Runtime_config_text.route_reference_to_string
    in lib/runtime/runtime_config_text.ml): assignments first, then seats."""
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
        _status, body = _keyboard_runtime.runtime_resolved_response()
        assert isinstance(body, dict)
        self.body = body
        self.lanes = [dict(lane) for lane in body["lanes"]]
        self.revision = 1
        self.lock = threading.Lock()
        self.held: tuple[threading.Event, threading.Event] | None = None
        self.fail_next_resolved = False
        # When set, an exact-lane append answers with this message instead of
        # committing: the server's own multi-line refusal, line breaks and all.
        self.exact_refusal: str | None = None
        _status, standalone = _keyboard_keepers.standalone_lanes_response()
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

    def resolved(self) -> _keyboard_harness.HttpResponse:
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

    def raw(self) -> _keyboard_harness.HttpResponse:
        with self.lock:
            source = "\n".join(
                f'[runtime.lanes.{lane["id"]}]\n'
                f'candidates = {json.dumps(lane["runtime_ids"])}\n'
                for lane in self.lanes
            )
            return 200, {"source_revision": f"{self.revision:064x}",
                         "source_text": source}

    def standalone_lanes(self) -> _keyboard_harness.HttpResponse:
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
            self.revision += 1

    def lane_candidates(self, lane_id: str) -> list[str]:
        with self.lock:
            lane = next(lane for lane in self.lanes if lane["id"] == lane_id)
            return list(lane["runtime_ids"])

    def route(self, raw: bytes) -> _keyboard_harness.HttpResponse:
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
            if action == "set" and lane_id != "default" and not lane_id.startswith("exact/"):
                if request.get("expected_source_revision") != f"{self.revision:064x}":
                    return 409, {"error": "runtime config source revision changed"}
            if lane_id == "default":
                route_id = request["runtime_id"]
                route = next((lane for lane in self.lanes if lane["id"] == route_id), None)
                entry_id = route["runtime_ids"][0] if route else route_id
                entry = next((runtime for runtime in self.body["runtimes"]
                              if runtime["id"] == entry_id), None)
                if entry is None:
                    return 400, {"error": "default route is unavailable"}
                self.body["default_route"] = route_id
                self.body["default_runtime"] = entry
                self.revision += 1
                return 200, commit_receipt()
            if lane_id.startswith("exact/"):
                name = lane_id[len("exact/"):]
                slot = request["runtime_id"]
                if self.exact_refusal is not None and action == "append":
                    return 400, {"error": self.exact_refusal}
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
                elif action in ("move", "drop", "replace"):
                    source = declared if slot in declared else declared_cli
                    if slot not in source:
                        return 400, {"error": f"{slot} is not a slot of {name}"}
                    if action == "drop":
                        source.remove(slot)
                    elif action == "replace":
                        replacement = request["replacement_runtime_id"]
                        if replacement in declared + declared_cli:
                            return 400, {"error": "replacement already declared"}
                        source[source.index(slot)] = replacement
                    elif request["direction"] == "first":
                        source.remove(slot)
                        source.insert(0, slot)
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
            self.revision += 1
        return 200, commit_receipt()


def mark_output(fd, output) -> int:
    """Where the next press's output begins, so a wait does not match a row
    an earlier frame drew."""
    _keyboard_harness.read_available(fd, output)
    return len(output)


def without_checked_revision(posted: list[dict]) -> list[dict]:
    result = []
    for request in posted:
        request = dict(request)
        if request.get("action", "set") == "set" and request["lane"] != "default" and not request["lane"].startswith("exact/"):
            revision = request.pop("expected_source_revision", None)
            if not isinstance(revision, str) or len(revision) != 64:
                raise AssertionError(f"named lane write lacked a source revision: {request!r}")
        result.append(request)
    return result


def press(process, fd, output, key: bytes) -> None:
    """A key whose effect is a cursor move: nothing on screen names it, so it
    is judged by the next key that acts on the row it lands on."""
    _keyboard_harness.read_available(fd, output)
    start = len(output)
    os.write(fd, key)
    _keyboard_harness.wait_for_output(process, fd, output, _keyboard_harness.FRAME_END, start=start, timeout=3.0)
    _keyboard_harness.drain_until_quiet(process, fd, output)


def run(executable: str) -> None:
    store = LaneStore()
    fixtures = _keyboard_harness.overview_event_http_fixtures()
    fixtures[_keyboard_runtime.RUNTIME_PROBE_PATH] = _keyboard_runtime.runtime_probe_response(fresh=True)
    fixtures[_keyboard_runtime.RUNTIME_PROBE_FORCE_PATH] = _keyboard_runtime.runtime_probe_response(fresh=True)
    fixtures[_keyboard_harness.RUNTIME_RESOLVED_PATH] = store.resolved
    fixtures[ROUTING_PATH] = _keyboard_harness.RequestHttpResponse(store.route)
    fixtures[_keyboard_runtime.RUNTIME_CONFIG_RAW_PATH] = store.raw
    requests: _keyboard_harness.HttpRequests = []
    recorded_at = datetime.fromisoformat(
        store.body["generated_at_iso"].replace("Z", "+00:00")
    )
    reading_time = f"reading {recorded_at.astimezone().strftime('%H:%M:%S')}".encode()

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.tab_until(process, fd, output, b"MASC System")
        # 131 columns, as the Runtime scenario in test_tui_keyboard_input.py
        # uses: wide enough for the prompt rows, narrow enough to keep the
        # acting pane off the screen.
        _keyboard_harness.resize_and_wait(
            process, fd, output, rows=30, columns=131,
            needle=b"MASC System", controls=(_keyboard_harness.FULL_REDRAW,),
        )
        frame = _keyboard_harness.send_and_wait(process, fd, output, b"9", b"Runtime lanes (3 lanes, 4 slots)")
        if reading_time not in _keyboard_harness.screen_text(frame):
            raise AssertionError("Runtime header did not use the resolved reading time")

        # [a] opens the name field; the letters typed after it are the name's.
        _keyboard_harness.send_and_wait(process, fd, output, b"a", b"new lane name: _")
        _keyboard_harness.send_and_wait(
            process, fd, output, NEW_LANE.encode(),
            f"new lane name: {NEW_LANE}_".encode(),
        )
        mark = mark_output(fd, output)
        _keyboard_harness.send_and_wait(
            process, fd, output, b"\r",
            f"first runtime of new lane {NEW_LANE}".encode(),
        )
        # A lane with no candidates yet ranks the catalog by id. The catalog
        # is read when [a] opens the field, so its rows can trail the header.
        _keyboard_harness.wait_for_output(process, fd, output, b"> runtime-a", start=mark, timeout=5.0)
        _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"Runtime lanes (4 lanes, 5 slots)")

        # The new lane's row is the fifth. [e] there names the lane it adds
        # to, which is what shows the cursor stands on it.
        for _ in range(4):
            press(process, fd, output, b"j")
        mark = mark_output(fd, output)
        _keyboard_harness.send_and_wait(
            process, fd, output, b"e",
            f"adding a candidate to the candidate order of {NEW_LANE}".encode(),
        )
        # The lane's own runtime ranks last; the other four come by id.
        _keyboard_harness.wait_for_output(process, fd, output, b"> runtime-b", start=mark, timeout=5.0)
        for needle in (b"> runtime-c", b"> runtime-d", b"> runtime-e"):
            _keyboard_harness.send_and_wait(process, fd, output, b"j", needle)
        _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"2/2 runtime-e")

        # [J] moves runtime-a below runtime-e, and the cursor goes with it.
        # The post is held: an [x] pressed before the move is read back would
        # be built from the order the move replaced, so it is refused on
        # screen and posts nothing, and it does not move the cursor the move
        # will leave on runtime-a.
        arrived, release = store.hold_next_post()
        os.write(fd, b"J")
        if not _keyboard_harness.wait_for_fixture_event(process, fd, output, arrived, timeout=5.0):
            raise AssertionError("J posted nothing")
        frame = _keyboard_harness.send_and_wait(
            process, fd, output, b"R",
            b"lane write refused: " + BUSY,
        )
        if f"rename lane {NEW_LANE} to:".encode() in _keyboard_harness.screen_text(frame):
            raise AssertionError("R opened a rename field while a write was pending")
        # Moving away and back clears the prior notice, so x must draw its
        # own refusal rather than satisfying the wait with R's old frame.
        press(process, fd, output, b"k")
        press(process, fd, output, b"j")
        _keyboard_harness.send_and_wait(
            process, fd, output, b"x",
            b"lane write refused: " + BUSY,
        )
        mark = mark_output(fd, output)
        release.set()
        _keyboard_harness.wait_for_output(process, fd, output, b"1/2 runtime-e", start=mark, timeout=5.0)
        # [x] drops the row the cursor followed: runtime-a, not runtime-e.
        _keyboard_harness.send_and_wait(process, fd, output, b"x", b"1/1 runtime-e")

        # [D] asks first; the second press removes the lane.
        _keyboard_harness.send_and_wait(
            process, fd, output, b"D",
            f"press D again to remove lane {NEW_LANE}".encode(),
        )
        _keyboard_harness.send_and_wait(process, fd, output, b"D", b"Runtime lanes (3 lanes, 4 slots)")
        _keyboard_harness.read_available(fd, output)
        if NEW_LANE.encode() in _keyboard_harness.screen_text(bytes(output)):
            raise AssertionError(f"{NEW_LANE} is still on screen after its removal")

        # A lane a keeper is assigned to and a Fusion seat names is refused by
        # the server, and the TUI draws the server's sentence whole, the seat
        # at its end included.
        for _ in range(3):
            press(process, fd, output, b"k")
        _keyboard_harness.send_and_wait(
            process, fd, output, b"D", b"press D again to remove lane primary",
        )
        _keyboard_harness.send_and_wait(
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
        _keyboard_harness.send_and_wait(
            process, fd, output, b"J", b"the lane list could not be re-read",
        )
        # A failed reread repaints only changed rows; the unchanged header
        # stays in terminal state even when it is absent from this frame.
        current_screen = _keyboard_harness.screen_text(bytes(output))
        if reading_time not in current_screen:
            raise AssertionError(
                f"failed refresh changed the Runtime reading time: expected {reading_time!r}; screen={current_screen[:1200]!r}"
            )
        # Another client now removes runtime-a. The TUI still shows the old
        # [runtime-a; runtime-b] order, where runtime-b is second. K used to
        # post that whole stale order and restore runtime-a. The unread list
        # now refuses the key without posting, so the authoritative removal
        # stays in place.
        store.replace_lane_from_another_client("primary", ["runtime-b"])
        _keyboard_harness.send_and_wait(
            process, fd, output, b"K",
            b"lane write refused: the lane list may be stale",
        )
        # The conversation-lane picker uses the same whole stale order when it
        # adds a candidate. Opening it refreshes only the catalog. Enter must
        # refuse locally too, without restoring runtime-a beside the new id.
        mark = mark_output(fd, output)
        _keyboard_harness.send_and_wait(process, fd, output, b"e", b"adding a candidate to the candidate order of primary")
        _keyboard_harness.wait_for_output(process, fd, output, b"> runtime-c", start=mark, timeout=5.0)
        _keyboard_harness.send_and_wait(
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
        if without_checked_revision(posted) != expected:
            raise AssertionError(f"routing posts: {posted!r}, expected {expected!r}")
        primary = store.lane_candidates("primary")
        if primary != ["runtime-b"]:
            raise AssertionError(
                f"the stale TUI restored another client's removal: {primary!r}"
            )
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
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
# The server's refusal to add an exact slot on a provider that declares no
# exact-body-timeout-s (Runtime_config_text, rule 3). It is two lines: the
# sentence naming the missing key, then the fix. The lane editor must draw
# both, so the operator can read what to declare. The first line is longer
# than the frame and is cut at its tail; the fix line is what the operator
# needs and must be whole.
EXACT_REFUSAL_LINES = (
    b"lane write refused: HTTP 400:",
    b"Add exact-body-timeout-s to [providers.openrouter] (for example 1200.0) and retry.",
)
EXACT_REFUSAL = (
    "/Users/dancer/me/.masc/config/runtime.toml: this change adds 1 exact-output "
    "slot(s) on a provider that declares no exact-body-timeout-s.\n"
    "Add exact-body-timeout-s to [providers.openrouter] (for example 1200.0) and retry."
)


def screen_lacks(process, fd, output, needle: bytes, timeout: float) -> None:
    """Wait until [needle] is gone from the screen the pane last painted."""
    deadline = time.monotonic() + timeout
    while True:
        _keyboard_harness.drain_until_quiet(process, fd, output)
        if needle not in _keyboard_harness.screen_text(bytes(output)):
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
    fixtures = _keyboard_harness.overview_event_http_fixtures()
    fixtures[_keyboard_runtime.RUNTIME_PROBE_PATH] = _keyboard_runtime.runtime_probe_response(fresh=True)
    fixtures[_keyboard_runtime.RUNTIME_PROBE_FORCE_PATH] = _keyboard_runtime.runtime_probe_response(fresh=True)
    fixtures[_keyboard_harness.RUNTIME_RESOLVED_PATH] = store.resolved
    fixtures[_keyboard_keepers.STANDALONE_LANES_PATH] = store.standalone_lanes
    fixtures[ROUTING_PATH] = _keyboard_harness.RequestHttpResponse(store.route)
    fixtures[_keyboard_runtime.RUNTIME_CONFIG_RAW_PATH] = store.raw
    requests: _keyboard_harness.HttpRequests = []
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
        _keyboard_harness.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
        _keyboard_harness.wait_for_output(process, fd, output, b"Board Attention", start=0, timeout=10)
        # [r] sends a load of the list and the fixture holds it: it has left
        # before the write below.
        arrived, release = store.hold_next_standalone_read()
        os.write(fd, b"r")
        if not _keyboard_harness.wait_for_fixture_event(process, fd, output, arrived, timeout=5.0):
            raise AssertionError("r read no standalone lanes")
        mark = mark_output(fd, output)
        _keyboard_harness.send_and_wait(process, fd, output, b"a", picker)
        _keyboard_harness.wait_for_output(process, fd, output, b"> model-a default", start=mark, timeout=5.0)
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
        _keyboard_harness.wait_for_output(process, fd, output, b"runtime-a", start=mark, timeout=5.0)
        # The second picker is built from that list, so runtime-a is no
        # longer offered and the cursor opens on runtime-b. The lanes picker
        # leads a row with the model title, not the runtime id (the id is on
        # the row's detail line), so the row reads "> model-b default".
        mark = mark_output(fd, output)
        _keyboard_harness.send_and_wait(process, fd, output, b"a", picker)
        _keyboard_harness.wait_for_output(process, fd, output, b"> model-b default", start=mark, timeout=5.0)
        os.write(fd, b"\r")
        posted = wait_for_posts(2)
        # A pick sends only the slot it adds. A whole order built from the
        # admitted slots would have left out the dropped one and deleted it.
        expected = [
            {"lane": f"exact/{EXACT_LANE}", "action": "append", "runtime_id": "runtime-a"},
            {"lane": f"exact/{EXACT_LANE}", "action": "append", "runtime_id": "runtime-b"},
        ]
        if without_checked_revision(posted) != expected:
            raise AssertionError(f"exact posts: {posted!r}, expected {expected!r}")
        declared = store.exact_declared[EXACT_LANE]
        if declared != [DROPPED_SLOT, "glm-coding.glm-5-turbo", "runtime-a", "runtime-b"]:
            raise AssertionError(f"declared slots after the picks: {declared!r}")
        screen_lacks(process, fd, output, picker, timeout=5.0)
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Standalone lane picks wait for the standalone list",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )


def run_exact_refusal(executable: str) -> None:
    """The exact-slot save refusal is the server's own message and carries its
    line breaks: it names the missing key on one line and the fix on the next.
    The lane editor must draw every line, so the operator can read what to
    declare instead of only the first line. This is the flow the operator hit
    (board p-70f480b8754a23c9aacc144a4c77b935): pick a candidate, press Enter,
    and the write is refused."""
    store = LaneStore()
    fixtures = _keyboard_harness.overview_event_http_fixtures()
    fixtures[_keyboard_runtime.RUNTIME_PROBE_PATH] = _keyboard_runtime.runtime_probe_response(fresh=True)
    fixtures[_keyboard_runtime.RUNTIME_PROBE_FORCE_PATH] = _keyboard_runtime.runtime_probe_response(fresh=True)
    fixtures[_keyboard_harness.RUNTIME_RESOLVED_PATH] = store.resolved
    fixtures[_keyboard_keepers.STANDALONE_LANES_PATH] = store.standalone_lanes
    fixtures[ROUTING_PATH] = _keyboard_harness.RequestHttpResponse(store.route)
    fixtures[_keyboard_runtime.RUNTIME_CONFIG_RAW_PATH] = store.raw
    requests: _keyboard_harness.HttpRequests = []
    picker = f"adding a candidate to the candidate order of {EXACT_LANE}".encode()
    store.exact_refusal = EXACT_REFUSAL

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
        _keyboard_harness.wait_for_output(process, fd, output, b"Board Attention", start=0, timeout=10)
        mark = mark_output(fd, output)
        _keyboard_harness.send_and_wait(process, fd, output, b"a", picker)
        _keyboard_harness.wait_for_output(process, fd, output, b"> model-a default", start=mark, timeout=5.0)
        mark = mark_output(fd, output)
        os.write(fd, b"\r")
        _keyboard_harness.wait_for_output(
            process, fd, output, b"lane write refused: HTTP 400", start=mark, timeout=5.0
        )
        _keyboard_harness.drain_until_quiet(process, fd, output)
        screen = _keyboard_harness.screen_text(bytes(output))
        for needle in EXACT_REFUSAL_LINES:
            if needle not in screen:
                raise AssertionError(
                    f"the refusal lost {needle!r}; screen tail={screen[-1600:]!r}"
                )
        if os.environ.get("MASC_CAPTURE_REFUSAL"):
            print("===== PLAINTEXT CAPTURE =====")
            print(screen.decode("utf-8", "replace"))
            print("===== END CAPTURE =====")
        # A refused write leaves the picker open so another candidate can be
        # picked; close it before quitting.
        os.write(fd, b"\x1b")
        _keyboard_harness.drain_until_quiet(process, fd, output)
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="A multi-line exact-slot refusal is drawn whole",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )


def run_cli_editor(executable: str) -> None:
    """The Librarian editor reaches both arrays and explains their boundary."""
    store = LaneStore()
    new_cli = "aaa_cli.fixture"
    store.body["runtimes"].append({
        **_keyboard_runtime.runtime_resolved_runtime(new_cli, "Official client", "model"),
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
    fixtures = _keyboard_harness.overview_event_http_fixtures()
    fixtures[_keyboard_harness.RUNTIME_RESOLVED_PATH] = store.resolved
    fixtures[_keyboard_keepers.STANDALONE_LANES_PATH] = store.standalone_lanes
    fixtures[ROUTING_PATH] = _keyboard_harness.RequestHttpResponse(store.route)
    fixtures[_keyboard_runtime.RUNTIME_CONFIG_RAW_PATH] = store.raw
    requests: _keyboard_harness.HttpRequests = []

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
        _keyboard_harness.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
        _keyboard_harness.resize_and_wait(process, fd, output, rows=30, columns=131,
                          needle=b"MASC Lanes", controls=(_keyboard_harness.FULL_REDRAW,))
        _keyboard_harness.send_and_wait(process, fd, output, b"j", b"HITL")
        _keyboard_harness.send_and_wait(process, fd, output, b"j", b"Librarian")
        mark = mark_output(fd, output)
        _keyboard_harness.send_and_wait(process, fd, output, b"s", b"Model order")
        _keyboard_harness.wait_for_output(process, fd, output,
                          b"[CLI] codex_subscription.gpt-6-luna", start=mark, timeout=5.0)
        _keyboard_harness.wait_for_output(process, fd, output,
                          b"[CLI] claude_code.claude-sonnet-5", start=mark, timeout=5.0)
        _keyboard_harness.send_and_wait(process, fd, output, b"j", b"[CLI] codex_subscription.gpt-6-luna")
        _keyboard_harness.send_and_wait(process, fd, output, b"K", b"HTTP slots run first")
        if exact_posts():
            raise AssertionError(f"a cross-boundary move posted: {exact_posts()!r}")
        _keyboard_harness.send_and_wait(process, fd, output, b"j", b"[CLI] claude_code.claude-sonnet-5")
        mark = mark_output(fd, output)
        os.write(fd, b"K")
        posted = wait_for_posts(1)
        expected = [{"lane": "exact/librarian_exact", "action": "move",
                     "runtime_id": "claude_code.claude-sonnet-5", "direction": "up"}]
        if posted != expected:
            raise AssertionError(f"CLI reorder posted {posted!r}, expected {expected!r}")
        _keyboard_harness.wait_for_output(process, fd, output,
                          b"> 2/11  [CLI] claude_code.claude-sonnet-5", start=mark, timeout=5.0)
        if store.exact_declared_cli["librarian_exact"] != [cli[1], cli[0], *cli[2:]]:
            raise AssertionError("the server fixture did not reorder the CLI declaration")
        _keyboard_harness.resize_and_wait(process, fd, output, rows=15, columns=100,
                          needle=b"Model order", controls=(_keyboard_harness.FULL_REDRAW,))
        _keyboard_harness.send_and_wait(process, fd, output, b"j" * 9,
                        b"> 11/11  [CLI] codex_subscription.extra-7")
        _keyboard_harness.send_and_wait(process, fd, output, b"a", b"Add fallback candidate")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b",
                        b"> 11/11  [CLI] codex_subscription.extra-7")
        _keyboard_harness.send_and_wait(process, fd, output, b"k" * 10,
                        b"> 1/11  [HTTP]")
        mark = mark_output(fd, output)
        _keyboard_harness.send_and_wait(process, fd, output, b"a", b"[CLI tail] model default")
        _keyboard_harness.wait_for_output(process, fd, output,
                          b"[HTTP tail] model-a default", start=mark, timeout=5.0)
        mark = mark_output(fd, output)
        os.write(fd, b"\r")
        posted = wait_for_posts(2)
        if posted[1] != {"lane": "exact/librarian_exact", "action": "append",
                         "runtime_id": new_cli}:
            raise AssertionError(f"CLI append posted {posted[1]!r}")
        _keyboard_harness.wait_for_output(process, fd, output,
                          b"> 1/12  [HTTP]", start=mark, timeout=5.0)
        _keyboard_harness.send_and_wait(process, fd, output, b"j" * 11,
                        b"> 12/12  [CLI] model default")
        if store.exact_declared_cli["librarian_exact"][-1] != new_cli:
            raise AssertionError("new official client did not append to CLI tail")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Librarian provider editor includes CLI fallback slots",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )


def run_empty_cli_group(executable: str) -> None:
    """A lane that walks a CLI tail with one HTTP slot and no CLI slot. j/k
    stop on slots, so the empty CLI group has no row to move into; its title
    says [a] fills it. An official client picked with [a] joins that group,
    and j then reaches it."""
    store = LaneStore()
    new_cli = "aaa_cli.fixture"
    store.body["runtimes"].append({
        **_keyboard_runtime.runtime_resolved_runtime(new_cli, "Official client", "model"),
        "exact_slot_group": "cli_slots",
    })
    fixtures = _keyboard_harness.overview_event_http_fixtures()
    fixtures[_keyboard_harness.RUNTIME_RESOLVED_PATH] = store.resolved
    fixtures[_keyboard_keepers.STANDALONE_LANES_PATH] = store.standalone_lanes
    fixtures[ROUTING_PATH] = _keyboard_harness.RequestHttpResponse(store.route)
    fixtures[_keyboard_runtime.RUNTIME_CONFIG_RAW_PATH] = store.raw
    requests: _keyboard_harness.HttpRequests = []

    def exact_posts() -> list[dict]:
        return [json.loads(body) for path, body in requests if path == ROUTING_PATH]

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
        _keyboard_harness.resize_and_wait(process, fd, output, rows=30, columns=131,
                          needle=b"MASC Lanes", controls=(_keyboard_harness.FULL_REDRAW,))
        _keyboard_harness.send_and_wait(process, fd, output, b"j", b"HITL")
        _keyboard_harness.send_and_wait(process, fd, output, b"j", b"Librarian")
        _keyboard_harness.send_and_wait(process, fd, output, b"s",
                        "CLI slots · tried after every HTTP slot (0) · a adds one".encode())
        _keyboard_harness.send_and_wait(process, fd, output, b"a", b"> [CLI tail] model default")
        mark = mark_output(fd, output)
        os.write(fd, b"\r")
        deadline = time.monotonic() + 5.0
        while not exact_posts():
            if time.monotonic() > deadline:
                raise AssertionError("the CLI pick on the Librarian posted nothing")
            time.sleep(0.05)
        expected = [{"lane": "exact/librarian_exact", "action": "append",
                     "runtime_id": new_cli}]
        if exact_posts() != expected:
            raise AssertionError(f"Librarian posts {exact_posts()!r}, expected {expected!r}")
        _keyboard_harness.wait_for_output(process, fd, output,
                          "CLI slots · tried after every HTTP slot (1)".encode(),
                          start=mark, timeout=5.0)
        _keyboard_harness.send_and_wait(process, fd, output, b"j", b"> 2/2  [CLI] model default")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="An empty CLI group says a fills it, and a CLI pick lands there",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )


def run_curator_takes_cli(executable: str) -> None:
    """The workspace curator walks CLI slots after its HTTP slots, as every
    exact lane does: its editor draws the CLI group and an official client
    appends there. A client with no output-schema channel fits no exact lane,
    so the picker lists it below every candidate that lands, led by the
    reason, and Enter on it posts nothing."""
    store = LaneStore()
    new_cli = "aaa_cli.fixture"
    schema_less = "aaa_muse.fixture"
    store.body["runtimes"].append({
        **_keyboard_runtime.runtime_resolved_runtime(new_cli, "Official client", "model"),
        "exact_slot_group": "cli_slots",
    })
    store.body["runtimes"].append({
        **_keyboard_runtime.runtime_resolved_runtime(schema_less, "Schema-less client", "model"),
        "exact_slot_group": None,
    })
    fixtures = _keyboard_harness.overview_event_http_fixtures()
    fixtures[_keyboard_harness.RUNTIME_RESOLVED_PATH] = store.resolved
    fixtures[_keyboard_keepers.STANDALONE_LANES_PATH] = store.standalone_lanes
    fixtures[ROUTING_PATH] = _keyboard_harness.RequestHttpResponse(store.route)
    fixtures[_keyboard_runtime.RUNTIME_CONFIG_RAW_PATH] = store.raw
    requests: _keyboard_harness.HttpRequests = []

    def exact_posts() -> list[dict]:
        return [json.loads(body) for path, body in requests if path == ROUTING_PATH]

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
        _keyboard_harness.resize_and_wait(process, fd, output, rows=30, columns=131,
                          needle=b"MASC Lanes", controls=(_keyboard_harness.FULL_REDRAW,))
        _keyboard_harness.send_and_wait(process, fd, output, b"j", b"HITL")
        _keyboard_harness.send_and_wait(process, fd, output, b"j", b"Librarian")
        _keyboard_harness.send_and_wait(process, fd, output, b"j", b"Workspace Curator")
        _keyboard_harness.send_and_wait(process, fd, output, b"s",
                        "CLI slots · tried after every HTTP slot (0) · a adds one".encode())
        # aaa_muse sorts before runtime-a by id; having no output-schema
        # channel is what puts it after every candidate that lands.
        _keyboard_harness.send_and_wait(process, fd, output, b"a", b"> [CLI tail] model default")
        _keyboard_harness.send_and_wait(process, fd, output, b"aaa_muse",
                        b"> [no output schema] model default")
        _keyboard_harness.send_and_wait(process, fd, output, b"\r",
                        b"aaa_muse.fixture has no output-schema channel")
        # The refusal is drawn from the state alone; give a stray write the
        # time a real one takes to reach the fixture before judging.
        time.sleep(0.5)
        if exact_posts():
            raise AssertionError(f"a schema-less pick posted: {exact_posts()!r}")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"Add fallback candidate")
        _keyboard_harness.send_and_wait(process, fd, output, b"/", b"filter:")
        _keyboard_harness.send_and_wait(process, fd, output, b"aaa_cli", b"> [CLI tail] model default")
        mark = mark_output(fd, output)
        os.write(fd, b"\r")
        deadline = time.monotonic() + 5.0
        while not exact_posts():
            if time.monotonic() > deadline:
                raise AssertionError("the CLI pick on the curator posted nothing")
            time.sleep(0.05)
        expected = [{"lane": "exact/workspace_curator_exact", "action": "append",
                     "runtime_id": new_cli}]
        if exact_posts() != expected:
            raise AssertionError(f"curator posts {exact_posts()!r}, expected {expected!r}")
        _keyboard_harness.wait_for_output(process, fd, output,
                          "CLI slots · tried after every HTTP slot (1)".encode(),
                          start=mark, timeout=5.0)
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Workspace curator takes CLI slots; schema-less clients sink and refuse",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )


def model_settings_config(*, cli_context=272000):
    status, config = _keyboard_keepers.standalone_lane_runtime_config_response()
    return status, {**config, "source_text": config["source_text"] + '\n'.join([
        "", '[providers."glm-coding"] # request window',
        'protocol = "openai-compatible-http"', 'kind = "openai_compat"',
        'endpoint = "https://usage.invalid/v1"', 'exact-body-timeout-s = 1200',
        '[models."glm-5-turbo"]', 'max-context = 131072',
        '["glm-coding"."glm-5-turbo"]', 'max-context = 65536', 'max-tokens = 4096',
        '[providers.codex_subscription]', 'protocol = "codex-app-server"',
        'command = "codex"', 'is-non-interactive = true',
        'account-home = "/tmp/fixture-codex-account"',
        '[models.luna]', 'api-name = "gpt-6-luna"', 'max-context = 500000',
        '[codex_subscription."luna"] # CLI binding', f'max-context = {cli_context}', 'max-tokens = 8192', "",
    ])}


def assert_model_form(output, *, provider, model, context):
    screen = _keyboard_harness.screen_text(bytes(output))
    expected = [("Edit model · " + provider).encode(), model.encode(), context.encode(),
                b"Context tokens", b"Max output tokens", b"Enter next/save", b"Esc cancel"]
    for needle in expected:
        if needle not in screen:
            raise AssertionError(f"shared model form omitted {needle!r}: {screen!r}")


def run_provider_jump(executable: str) -> None:
    """[d] on an HTTP slot opens the shared account/model form.
    The picker retains focus until closed; cancelling the form writes nothing."""
    store = LaneStore()
    slot = "glm-coding.glm-5-turbo"
    store.body["runtimes"].append(
        _keyboard_runtime.runtime_resolved_runtime(slot, "GLM Coding", "glm-5-turbo",
                                   provider_id="glm-coding")
    )
    fixtures = _keyboard_harness.overview_event_http_fixtures()
    fixtures[_keyboard_harness.RUNTIME_RESOLVED_PATH] = store.resolved
    fixtures[_keyboard_keepers.STANDALONE_LANES_PATH] = store.standalone_lanes
    fixtures[ROUTING_PATH] = _keyboard_harness.RequestHttpResponse(store.route)
    fixtures[_keyboard_runtime.RUNTIME_CONFIG_RAW_PATH] = model_settings_config()
    requests: _keyboard_harness.HttpRequests = []

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
        _keyboard_harness.resize_and_wait(process, fd, output, rows=30, columns=131,
                          needle=b"MASC Lanes", controls=(_keyboard_harness.FULL_REDRAW,))
        _keyboard_harness.send_and_wait(process, fd, output, b"j", b"HITL")
        _keyboard_harness.send_and_wait(process, fd, output, b"j", b"Librarian")
        _keyboard_harness.send_and_wait(process, fd, output, b"s", b"Model order")
        _keyboard_harness.wait_for_output(process, fd, output,
                          b"> 1/1  [HTTP] glm-coding.glm-5-turbo", start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, fd, output, b"a", b"Add fallback candidate")
        # The picker owns focus: [d] neither jumps nor closes it, so the
        # Esc after it lands on the picker and returns to the slot rows.
        os.write(fd, b"d")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"Add fallback candidate")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b",
                        b"> 1/1  [HTTP] glm-coding.glm-5-turbo")
        _keyboard_harness.send_and_wait(process, fd, output, b"d", "Edit model · glm-coding".encode())
        assert_model_form(output, provider="glm-coding", model="glm-5-turbo", context="65536_")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Models")
        if any(path in (ROUTING_PATH, _keyboard_runtime.RUNTIME_CONFIG_RAW_PATH)
               for path, _body in requests):
            raise AssertionError("opening or cancelling model settings posted a write")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Slot editor opens an HTTP slot in shared model settings",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )


def run_cli_binding_jump(executable: str, *, missing_binding: bool = False) -> None:
    """Enter edits a declared CLI binding even when the registry rejected its slot."""
    store = LaneStore()
    slot = "codex_subscription.retired" if missing_binding else "codex_subscription.luna"
    librarian = store.exact_lane("librarian_exact")
    librarian["declared_cli_slots"] = [slot]
    librarian["cli_slots"] = []
    store.exact_declared_cli["librarian_exact"] = [slot]
    fixtures = _keyboard_harness.overview_event_http_fixtures()
    fixtures[_keyboard_harness.RUNTIME_RESOLVED_PATH] = store.resolved
    fixtures[_keyboard_keepers.STANDALONE_LANES_PATH] = store.standalone_lanes
    fixtures[_keyboard_runtime.RUNTIME_CONFIG_RAW_PATH] = model_settings_config()

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
        _keyboard_harness.resize_and_wait(process, fd, output, rows=30, columns=131,
                          needle=b"MASC Lanes", controls=(_keyboard_harness.FULL_REDRAW,))
        _keyboard_harness.send_and_wait(process, fd, output, b"j", b"HITL")
        _keyboard_harness.send_and_wait(process, fd, output, b"j", b"Librarian")
        _keyboard_harness.send_and_wait(process, fd, output, b"s", b"Model order")
        _keyboard_harness.resize_and_wait(process, fd, output, rows=30, columns=132,
                          needle=b"CLI slots", controls=(_keyboard_harness.FULL_REDRAW,),
                          final_cursor=b"\x1b[?25l")
        screen = _keyboard_harness.screen_text(bytes(output))
        if b"HTTP slots" not in screen or b"CLI slots" not in screen:
            raise AssertionError(f"The slot groups are unclear: {screen!r}")
        _keyboard_harness.send_and_wait(process, fd, output, b"j",
                        b"> 2/2  [CLI] " + slot.encode() + b"  (not admitted)")
        if missing_binding:
            _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"[providers.codex_subscription]")
            screen = _keyboard_harness.screen_text(bytes(output))
            if b"Edit model" in screen or b"protocol" not in screen:
                raise AssertionError("a missing binding did not open its provider source for repair")
            os.write(fd, b"q")
            return
        _keyboard_harness.send_and_wait(process, fd, output, b"\r", "Edit model · codex_subscription".encode())
        assert_model_form(output, provider="codex_subscription", model="luna", context="272000_")
        _keyboard_harness.resize_and_wait(process, fd, output, rows=24, columns=80,
                          needle=b"Context tokens", controls=(_keyboard_harness.FULL_REDRAW,))
        assert_model_form(output, provider="codex_subscription", model="luna", context="272000_")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Models")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Rejected Librarian CLI slot opens " + ("raw repair source" if missing_binding else "shared model settings"),
        interact=interact,
        http_fixtures=fixtures,
    )


def run_model_settings_read_isolation(executable: str, *, old_fails: bool) -> None:
    """A superseded source read cannot open or consume the newer model intent."""
    store = LaneStore()
    slot = "codex_subscription.luna"
    librarian = store.exact_lane("librarian_exact")
    librarian["declared_cli_slots"] = [slot]
    librarian["cli_slots"] = []
    store.exact_declared_cli["librarian_exact"] = [slot]
    stale = ((503, {"error": "old source read failed"}) if old_fails
             else model_settings_config(cli_context=111111))
    older = _keyboard_harness.GatedHttpResponse(stale, hold_seconds=30.0)
    newer = _keyboard_harness.GatedHttpResponse(model_settings_config(), hold_seconds=30.0)
    queued = []
    lock = threading.Lock()

    def raw():
        with lock:
            gate = queued.pop(0) if queued else None
        return model_settings_config() if gate is None else gate()

    fixtures = _keyboard_harness.overview_event_http_fixtures()
    fixtures[_keyboard_harness.RUNTIME_RESOLVED_PATH] = store.resolved
    fixtures[_keyboard_keepers.STANDALONE_LANES_PATH] = store.standalone_lanes
    fixtures[_keyboard_runtime.RUNTIME_CONFIG_RAW_PATH] = raw
    requests: _keyboard_harness.HttpRequests = []

    def interact(process, fd, _slave, output, _base):
        def await_event(event, description):
            if not _keyboard_harness.wait_for_fixture_event(
                    process, fd, output, event, timeout=5.0):
                raise AssertionError(description)

        try:
            _keyboard_harness.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
            _keyboard_harness.resize_and_wait(process, fd, output, rows=30, columns=131,
                needle=b"MASC Lanes", controls=(_keyboard_harness.FULL_REDRAW,))
            _keyboard_harness.send_and_wait(process, fd, output, b"j", b"HITL")
            _keyboard_harness.send_and_wait(process, fd, output, b"j", b"Librarian")
            _keyboard_harness.send_and_wait(process, fd, output, b"s", b"Model order")
            _keyboard_harness.drain_until_quiet(process, fd, output)
            with lock:
                queued.append(older)
            _keyboard_harness.send_and_wait(process, fd, output, b"d", b"MASC Models")
            await_event(older.requested, "the first settings read was not requested")

            # Cancel the pending HTTP model, then request the CLI binding.
            _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
            _keyboard_harness.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
            _keyboard_harness.send_and_wait(process, fd, output, b"s", b"Model order")
            _keyboard_harness.send_and_wait(process, fd, output, b"j",
                b"> 2/2  [CLI] " + slot.encode() + b"  (not admitted)")
            with lock:
                queued.append(newer)
            _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"MASC Models")
            # Automatic ticks must neither start another read nor invalidate
            # this slow one. Edit/copy must not consume the retained cursor.
            os.write(fd, b"ec")
            if _keyboard_harness.wait_for_fixture_event(
                    process, fd, output, newer.requested, timeout=2.5):
                raise AssertionError("a second source read started before the first completed")
            if b"Edit model" in _keyboard_harness.screen_text(bytes(output)):
                raise AssertionError("edit used retained rows while the requested model was loading")
            older.release.set()
            await_event(newer.requested, "the queued settings read was not requested")
            await_event(older.completed, "the old settings read did not finish")
            _keyboard_harness.drain_until_quiet(process, fd, output)
            # Force a complete frame after the old callback has been delivered.
            _keyboard_harness.resize_and_wait(process, fd, output, rows=30, columns=132,
                needle=b"MASC Models", controls=(_keyboard_harness.FULL_REDRAW,))
            if b"Edit model" in _keyboard_harness.screen_text(bytes(output)):
                raise AssertionError("an old response opened the newer model with stale source")
            _keyboard_harness.release_and_wait_for_frame(process, fd, output, newer,
                "Edit model · codex_subscription".encode())
            assert_model_form(output, provider="codex_subscription", model="luna", context="272000_")
            _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Models")
            if any(path in (ROUTING_PATH, _keyboard_runtime.RUNTIME_CONFIG_RAW_PATH)
                   for path, _ in requests):
                raise AssertionError("cancelled settings posted a write")
            os.write(fd, b"q")
        finally:
            older.release.set()
            newer.release.set()

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Model settings ignore an older " + ("failed" if old_fails else "successful") + " source read",
        interact=interact, http_fixtures=fixtures, http_requests=requests,
    )


# SGR mouse wheel notches at column 5, row 5, clear of the Activity pane.
WHEEL_UP = b"\x1b[<64;5;5M"
WHEEL_DOWN = b"\x1b[<65;5;5M"
# The picker header's filter cursor, U+258F.
FILTER_CURSOR = "▏".encode()


def run_concurrent_edit(executable: str) -> None:
    """A successful screen read must not license a later whole-order overwrite."""
    store = LaneStore()
    fixtures = _keyboard_harness.overview_event_http_fixtures()
    # Keep the in-process resolved projection at R1 after the file moves to
    # R2. The writer must compare with raw source_text, not this stale read.
    fixtures[_keyboard_harness.RUNTIME_RESOLVED_PATH] = store.resolved()
    fixtures[_keyboard_runtime.RUNTIME_CONFIG_RAW_PATH] = store.raw
    fixtures[ROUTING_PATH] = _keyboard_harness.RequestHttpResponse(store.route)
    requests: _keyboard_harness.HttpRequests = []

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.tab_until(process, fd, output, b"MASC System")
        _keyboard_harness.resize_and_wait(process, fd, output, rows=30, columns=131,
                              needle=b"MASC System", controls=(_keyboard_harness.FULL_REDRAW,))
        _keyboard_harness.send_and_wait(process, fd, output, b"9", b"Runtime lanes (3 lanes, 4 slots)")
        # The screen has just read primary as [a, b]; another client writes
        # [b] before the operator presses Enter in the candidate picker.
        store.replace_lane_from_another_client("primary", ["runtime-b"])
        _keyboard_harness.send_and_wait(process, fd, output, b"e",
                        b"adding a candidate to the candidate order of primary")
        _keyboard_harness.send_and_wait(process, fd, output, b"\r",
                        b"differs from the displayed order")
        if store.lane_candidates("primary") != ["runtime-b"]:
            raise AssertionError("the TUI overwrote another client's lane edit")
        if any(path == ROUTING_PATH for path, _ in requests):
            raise AssertionError("the TUI posted a stale whole-order edit")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable,
                            description="Runtime lane concurrent edit is refused",
                            interact=interact, http_fixtures=fixtures,
                            http_requests=requests)


def run_invalid_runtime_config(executable: str) -> None:
    """A malformed file explains its path and never licenses a routing POST."""
    store = LaneStore()
    fixtures = _keyboard_harness.overview_event_http_fixtures()
    fixtures[_keyboard_harness.RUNTIME_RESOLVED_PATH] = store.resolved
    fixtures[_keyboard_runtime.RUNTIME_CONFIG_RAW_PATH] = (
        200,
        {"source_revision": "a" * 64,
         "source_text": "[runtime.lanes.primary]\ncandidates = 42\n"},
    )
    fixtures[ROUTING_PATH] = _keyboard_harness.RequestHttpResponse(store.route)
    requests: _keyboard_harness.HttpRequests = []

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.tab_until(process, fd, output, b"MASC System")
        _keyboard_harness.resize_and_wait(process, fd, output, rows=30, columns=131,
                              needle=b"MASC System", controls=(_keyboard_harness.FULL_REDRAW,))
        _keyboard_harness.send_and_wait(process, fd, output, b"9", b"Runtime lanes (3 lanes, 4 slots)")
        _keyboard_harness.send_and_wait(process, fd, output, b"e",
                        b"adding a candidate to the candidate order of primary")
        _keyboard_harness.send_and_wait(process, fd, output, b"\r",
                        b"runtime.toml parse error at runtime.lanes.primary.candidates")
        _keyboard_harness.drain_until_quiet(process, fd, output)
        if b"lane candidates must be an array" not in _keyboard_harness.screen_text(bytes(output)):
            raise AssertionError("runtime TOML parse reason was hidden from the operator")
        if any(path == ROUTING_PATH for path, _ in requests):
            raise AssertionError("a malformed runtime config authorized a lane write")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable,
                            description="Malformed runtime config explains lane refusal",
                            interact=interact, http_fixtures=fixtures,
                            http_requests=requests)


def run_filter(executable: str) -> None:
    """The candidate picker is walked without holding an arrow key: End, Home
    and PgDn jump, [/] narrows the list to the typed text, and Esc drops the
    filter before it closes the picker. Letters typed into the filter are the
    filter's, and Enter over an empty result posts nothing."""
    store = LaneStore()
    fixtures = _keyboard_harness.overview_event_http_fixtures()
    fixtures[_keyboard_runtime.RUNTIME_PROBE_PATH] = _keyboard_runtime.runtime_probe_response(fresh=True)
    fixtures[_keyboard_runtime.RUNTIME_PROBE_FORCE_PATH] = _keyboard_runtime.runtime_probe_response(fresh=True)
    fixtures[_keyboard_harness.RUNTIME_RESOLVED_PATH] = store.resolved
    fixtures[ROUTING_PATH] = _keyboard_harness.RequestHttpResponse(store.route)
    fixtures[_keyboard_runtime.RUNTIME_CONFIG_RAW_PATH] = store.raw
    requests: _keyboard_harness.HttpRequests = []
    picker = b"adding a candidate to the candidate order of primary"

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.tab_until(process, fd, output, b"MASC System")
        _keyboard_harness.resize_and_wait(
            process, fd, output, rows=30, columns=131,
            needle=b"MASC System", controls=(_keyboard_harness.FULL_REDRAW,),
        )
        _keyboard_harness.send_and_wait(process, fd, output, b"9", b"Runtime lanes (3 lanes, 4 slots)")
        # primary holds runtime-a and runtime-b, so the other three rank
        # first: c, d, e, then a, b.
        mark = mark_output(fd, output)
        _keyboard_harness.send_and_wait(process, fd, output, b"e", picker)
        _keyboard_harness.wait_for_output(process, fd, output, b"> runtime-c", start=mark, timeout=5.0)
        _keyboard_harness.wait_for_output(process, fd, output, "5 of 5 · / filter".encode(), start=mark, timeout=5.0)
        # The wheel moves the picker, not the lane list under it: primary's
        # rows are 0 and 1 there and degraded is 2, so two notches that
        # leaked would leave the list on degraded (checked at the end).
        _keyboard_harness.send_and_wait(process, fd, output, WHEEL_DOWN, b"> runtime-d")
        _keyboard_harness.send_and_wait(process, fd, output, WHEEL_DOWN, b"> runtime-e")
        _keyboard_harness.send_and_wait(process, fd, output, WHEEL_UP, b"> runtime-d")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b[F", b"> runtime-b")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b[H", b"> runtime-c")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b[6~", b"> runtime-a")

        _keyboard_harness.send_and_wait(process, fd, output, b"/", b"filter: " + FILTER_CURSOR + b" 5 of 5")
        mark = mark_output(fd, output)
        _keyboard_harness.send_and_wait(process, fd, output, b"-d", b"filter: -d" + FILTER_CURSOR + b" 1 of 5")
        _keyboard_harness.wait_for_output(process, fd, output, b"> runtime-d", start=mark, timeout=3.0)
        # [j] moves the picker outside a filter; inside one it is a letter.
        _keyboard_harness.send_and_wait(
            process, fd, output, b"j", b"(no runtime among 5 matches the filter)",
        )
        # Enter over no match changes nothing, so nothing repaints; the posts
        # compared at the end are what show it sent nothing.
        os.write(fd, b"\r")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x7f", b"filter: -d" + FILTER_CURSOR + b" 1 of 5")
        # Esc drops the filter and keeps runtime-d under the cursor.
        # runtime-d opens the window again, on the row it was drawn on under
        # the filter, so the frame does not redraw that row: read the screen.
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", "5 of 5 · / filter".encode())
        _keyboard_harness.drain_until_quiet(process, fd, output)
        if b"> runtime-d   Resolved D / model-d" not in _keyboard_harness.screen_text(bytes(output)):
            raise AssertionError("Esc did not keep runtime-d under the cursor")

        _keyboard_harness.send_and_wait(process, fd, output, b"/model-e", b"filter: model-e" + FILTER_CURSOR + b" 1 of 5")
        os.write(fd, b"\r")
        screen_lacks(process, fd, output, picker, timeout=5.0)

        expected = [{"lane": "primary", "runtime_ids": ["runtime-a", "runtime-b", "runtime-e"]}]
        deadline = time.monotonic() + 3.0
        while True:
            posted = [json.loads(body) for path, body in requests if path == ROUTING_PATH]
            if len(posted) >= len(expected) or time.monotonic() > deadline:
                break
            time.sleep(0.05)
        if without_checked_revision(posted) != expected:
            raise AssertionError(f"routing posts: {posted!r}, expected {expected!r}")
        # [e] opens the picker for the lane under the list's cursor: still
        # primary, so no wheel notch moved it while the picker was open.
        _keyboard_harness.send_and_wait(process, fd, output, b"e", picker)
        # Esc and q apart: written together they read as Alt-q.
        os.write(fd, b"\x1b")
        screen_lacks(process, fd, output, picker, timeout=5.0)
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Runtime candidate picker filters and pages",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )


def run_default_route(executable: str) -> None:
    """The default route picker can keep a declared failover lane intact."""
    store = LaneStore()
    store.body["default_route"] = "primary"
    fixtures = _keyboard_harness.overview_event_http_fixtures()
    fixtures[_keyboard_harness.RUNTIME_RESOLVED_PATH] = store.resolved
    fixtures[ROUTING_PATH] = _keyboard_harness.RequestHttpResponse(store.route)
    requests: _keyboard_harness.HttpRequests = []

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.tab_until(process, fd, output, b"MASC System")
        _keyboard_harness.resize_and_wait(process, fd, output, rows=30, columns=131,
                          needle=b"MASC System", controls=(_keyboard_harness.FULL_REDRAW,))
        _keyboard_harness.send_and_wait(process, fd, output, b"9", b"Runtime lanes (3 lanes, 4 slots)")
        _keyboard_harness.send_and_wait(process, fd, output, b"f", b"primary   lane")
        frame = _keyboard_harness.screen_text(bytes(output))
        assert b"Enter replace" in frame, frame
        assert b"primary   lane" in frame, frame
        os.write(fd, b"\r")
        assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
            lambda: any(path == ROUTING_PATH for path, _ in requests), timeout=3)
        posted = [json.loads(body) for path, body in requests if path == ROUTING_PATH]
        assert posted == [{"lane": "default", "runtime_id": "primary"}], posted
        assert store.body["default_route"] == "primary"
        assert store.body["default_runtime"]["id"] == "runtime-a"
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable,
        description="Runtime default route picker preserves a declared lane",
        interact=interact, http_fixtures=fixtures, http_requests=requests)


def run_replace_and_promote(executable: str) -> None:
    """Model/effort search replaces in place even with an older read in flight."""
    store = LaneStore()
    current, backup, replacement = "account.current", "account.backup", "account.luna-medium"
    assert isinstance(store.body, dict)
    runtimes = store.body["runtimes"]
    assert isinstance(runtimes, list)
    for runtime_id, model, effort in (
        (current, "gpt-6-sol", "low"),
        (backup, "gpt-6-sol", "high"),
        (replacement, "gpt-6-luna", "medium"),
    ):
        runtimes.append({
            **_keyboard_runtime.runtime_resolved_runtime(runtime_id, "Selected account", model,
                                         provider_id="account"),
            "exact_slot_group": "cli_slots",
            "declared_reasoning_effort": effort,
            "effective_max_context": 750000,
        })
    lane = store.exact_lane("librarian_exact")
    lane.update(declared_slots=[], admitted_slots=[], dropped_slots=[],
                declared_cli_slots=[backup, current], cli_slots=[backup, current])
    store.exact_declared["librarian_exact"] = []
    store.exact_declared_cli["librarian_exact"] = [backup, current]
    fixtures = _keyboard_harness.overview_event_http_fixtures()
    hold_catalog = threading.Event()
    catalog_arrived = threading.Event()
    release_catalog = threading.Event()

    def resolved():
        if hold_catalog.is_set():
            hold_catalog.clear()
            catalog_arrived.set()
            if not release_catalog.wait(timeout=10.0):
                return 504, {"error": "catalogue hold was never released"}
        return store.resolved()

    refresh_called = threading.Event()

    def forced_probe():
        refresh_called.set()
        return _keyboard_runtime.runtime_probe_response(fresh=True)

    routing_calls: list[bytes] = []

    def route(raw: bytes):
        # The shared request log records completed replies. Count arrivals
        # here as well so the deliberately held POST remains observable.
        routing_calls.append(raw)
        return store.route(raw)

    fixtures[_keyboard_runtime.RUNTIME_PROBE_PATH] = _keyboard_runtime.runtime_probe_response(fresh=True)
    fixtures[_keyboard_runtime.RUNTIME_PROBE_FORCE_PATH] = forced_probe
    fixtures[_keyboard_harness.RUNTIME_RESOLVED_PATH] = resolved
    fixtures[_keyboard_keepers.STANDALONE_LANES_PATH] = store.standalone_lanes
    fixtures[ROUTING_PATH] = _keyboard_harness.RequestHttpResponse(route)
    fixtures[_keyboard_runtime.RUNTIME_CONFIG_RAW_PATH] = store.raw
    requests: _keyboard_harness.HttpRequests = []

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
        _keyboard_harness.resize_and_wait(process, fd, output, rows=30, columns=131,
                          needle=b"MASC Lanes", controls=(_keyboard_harness.FULL_REDRAW,))
        _keyboard_harness.send_and_wait(process, fd, output, b"j", b"HITL")
        _keyboard_harness.send_and_wait(process, fd, output, b"j", b"Librarian")
        # Prime the model catalogue, then hold a fresh read while the same
        # runtime ID is still cached. Actions must be labelled by slot ID.
        _keyboard_harness.send_and_wait(process, fd, output, b"s", b"gpt-6-sol high")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"Librarian")
        hold_catalog.set()
        _keyboard_harness.send_and_wait(process, fd, output, b"s", b"runtime catalogue loading")
        try:
            if not _keyboard_harness.wait_for_fixture_event(process, fd, output, catalog_arrived, timeout=5.0):
                raise AssertionError("editor catalogue did not start loading")
            if b"account.backup" not in _keyboard_harness.screen_text(bytes(output)):
                raise AssertionError("loading editor did not show the declared slot ID")
            if b"gpt-6-sol high" in _keyboard_harness.screen_text(bytes(output)):
                raise AssertionError("editable candidate kept its cached model label")
        finally:
            release_catalog.set()
        _keyboard_harness.wait_for_output(process, fd, output, b"gpt-6-sol high", start=len(output), timeout=5.0)
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"Librarian")
        catalog_arrived.clear()
        release_catalog.clear()
        arrived, release = store.hold_next_standalone_read()
        try:
            os.write(fd, b"r")
            if not _keyboard_harness.wait_for_fixture_event(process, fd, output, arrived, timeout=5.0):
                raise AssertionError("the old lane read did not start")
            _keyboard_harness.send_and_wait(process, fd, output, b"s", b"Model order")
            _keyboard_harness.send_and_wait(process, fd, output, b"j", b"> 2/2  [CLI] gpt-6-sol low")
            hold_catalog.set()
            _keyboard_harness.send_and_wait(process, fd, output, b"r", b"runtime catalogue loading")
            try:
                if not _keyboard_harness.wait_for_fixture_event(process, fd, output, catalog_arrived, timeout=5.0):
                    raise AssertionError("replacement catalogue did not start loading")
                _keyboard_harness.send_and_wait(process, fd, output, b"luna medium", b"filter: luna medium")
                if b"runtime catalogue loading" not in _keyboard_harness.screen_text(bytes(output)):
                    raise AssertionError("replacement search lost its pending catalogue state")
                _keyboard_harness.write_all(fd, output, b"\r")
                # A refused Enter need not redraw. A subsequent filter edit
                # confirms the input queue passed it before releasing the read.
                _keyboard_harness.send_and_wait(process, fd, output, b"\x7f", b"filter: luna mediu")
                _keyboard_harness.send_and_wait(process, fd, output, b"m", b"filter: luna medium")
                if routing_calls:
                    raise AssertionError("Enter submitted a cached replacement during refresh")
            finally:
                release_catalog.set()
            _keyboard_harness.wait_for_output(process, fd, output, b"gpt-6-luna medium", start=0, timeout=5.0)
            _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"Reloading saved candidate order")
        finally:
            release.set()
        _keyboard_harness.wait_for_output(process, fd, output, b"> 2/2  [CLI] gpt-6-luna medium",
                          start=0, timeout=5.0)
        _keyboard_harness.wait_for_output(process, fd, output, b"current candidate order reloaded",
                          start=0, timeout=5.0)
        posted = [json.loads(body) for path, body in requests if path == ROUTING_PATH]
        expected = [{"lane": "exact/librarian_exact", "action": "replace",
                     "runtime_id": current, "replacement_runtime_id": replacement}]
        if posted != expected or store.exact_declared_cli["librarian_exact"] != [backup, replacement]:
            raise AssertionError(f"replacement did not preserve position: {posted!r}")
        arrived, release = store.hold_next_post()
        mark = mark_output(fd, output)
        try:
            os.write(fd, b"1")
            if not _keyboard_harness.wait_for_fixture_event(process, fd, output, arrived, timeout=5.0):
                raise AssertionError("promotion write did not reach the fixture")
            _keyboard_harness.send_and_wait(process, fd, output, b"r", BUSY)
            if BUSY not in _keyboard_harness.screen_text(bytes(output)):
                raise AssertionError("pending write notice is not visible")
            if b"Replace selected candidate" in _keyboard_harness.screen_text(bytes(output)):
                raise AssertionError("replacement search opened during the previous write")
            if len(routing_calls) != 2:
                raise AssertionError("pending replacement search posted another write")
        finally:
            release.set()
        _keyboard_harness.wait_for_output(process, fd, output, b"> 1/2  [CLI] gpt-6-luna medium",
                          start=mark, timeout=5.0)
        _keyboard_harness.wait_for_output(process, fd, output, b"current candidate order reloaded",
                          start=mark, timeout=5.0)
        posted = [json.loads(body) for path, body in requests if path == ROUTING_PATH]
        if posted[-1] != {"lane": "exact/librarian_exact", "action": "move",
                          "runtime_id": replacement, "direction": "first"}:
            raise AssertionError(f"promotion posted {posted[-1]!r}")
        if store.exact_declared_cli["librarian_exact"] != [replacement, backup]:
            raise AssertionError("promotion lost or reordered other candidates")
        _keyboard_harness.send_and_wait(process, fd, output, b"a", b"Add fallback candidate")
        _keyboard_harness.resize_and_wait(process, fd, output, rows=40, columns=131,
                          needle=b"gpt-6-luna medium", controls=(_keyboard_harness.FULL_REDRAW,),
                          final_cursor=b"\x1b[?25l")
        screen = _keyboard_harness.screen_text(bytes(output))
        if screen.count(b"context") <= 3:
            raise AssertionError("a tall terminal still shows only three model choices")
        if b"model-e default" not in screen or b"gpt-6-luna medium" not in screen:
            raise AssertionError("expanded model choices are not visible")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"> 1/2  [CLI] gpt-6-luna medium")
        if b"Model order" not in _keyboard_harness.screen_text(bytes(output)):
            raise AssertionError("closing the picker lost the model order editor")
        _keyboard_harness.send_and_wait(process, fd, output, b"p", b"MASC System / Runtime")
        mark = mark_output(fd, output)
        refresh_called.clear()
        _keyboard_harness.write_all(fd, output, b"r")
        if not _keyboard_harness.wait_for_fixture_event(process, fd, output, refresh_called, timeout=5.0):
            raise AssertionError("Runtime r was swallowed by the previous Lane editor")
        frame = _keyboard_harness.screen_text(bytes(output[mark:]))
        if b"Replace selected candidate" in frame or b"Model order" in frame:
            raise AssertionError("Runtime refresh reopened a hidden Lane editor")
        if len([path for path, _ in requests if path == ROUTING_PATH]) != 2:
            raise AssertionError("leaving the Lane editor changed its candidate order")
        _keyboard_harness.drain_until_quiet(process, fd, output)
        _keyboard_harness.send_and_wait(process, fd, output, b"m",
                                        b"the order the vision runtimes are called in")
        writes_before_refresh = list(requests)
        refresh_called.clear()
        _keyboard_harness.write_all(fd, output, b"r")
        if not _keyboard_harness.wait_for_fixture_event(process, fd, output, refresh_called, timeout=5.0):
            raise AssertionError("media editor swallowed Runtime refresh")
        if b"the order the vision runtimes are called in" not in _keyboard_harness.screen_text(bytes(output)):
            raise AssertionError("Runtime refresh closed the media editor")
        if requests != writes_before_refresh:
            raise AssertionError("refreshing Runtime from the media editor posted a write")
        _keyboard_harness.drain_until_quiet(process, fd, output)
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable, description="Librarian replaces model and effort and promotes within its group",
        interact=interact, http_fixtures=fixtures, http_requests=requests,
    )



if __name__ == "__main__":
    run_replace_and_promote(os.path.abspath(sys.argv[1]))
    run(os.path.abspath(sys.argv[1]))
    run_exact(os.path.abspath(sys.argv[1]))
    run_exact_refusal(os.path.abspath(sys.argv[1]))
    run_cli_editor(os.path.abspath(sys.argv[1]))
    run_empty_cli_group(os.path.abspath(sys.argv[1]))
    run_curator_takes_cli(os.path.abspath(sys.argv[1]))
    run_concurrent_edit(os.path.abspath(sys.argv[1]))
    run_invalid_runtime_config(os.path.abspath(sys.argv[1]))
    run_filter(os.path.abspath(sys.argv[1]))
    run_provider_jump(os.path.abspath(sys.argv[1]))
    run_cli_binding_jump(os.path.abspath(sys.argv[1]))
    run_default_route(os.path.abspath(sys.argv[1]))
    run_cli_binding_jump(os.path.abspath(sys.argv[1]), missing_binding=True)
    run_model_settings_read_isolation(os.path.abspath(sys.argv[1]), old_fails=False)
    run_model_settings_read_isolation(os.path.abspath(sys.argv[1]), old_fails=True)
    print("runtime lane editor: PASS")
