"""The Runtime lanes reading edits lanes: a, x, J, K and D, pressed for real.

A new lane is named, given its first runtime, grown, reordered, trimmed and
removed; an edit pressed while the previous write is still out is refused on
screen; and the server's refusal to remove a lane a keeper is assigned to is
drawn as the server wrote it. The main judgement is the body each press posts
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
        "commit": {"source_revision": "source-7", "order": "7", "durability": "durable"},
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
        },
    }


def in_use_refusal(lane_id: str, keepers: list[str]) -> str:
    """The sentence Runtime.remove_runtime_lane answers for a lane keepers are
    assigned to (lane_reference_to_string in lib/runtime/runtime.ml)."""
    sites = ", ".join(f"[runtime.assignments].{keeper}" for keeper in keepers)
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
    - remove drops the lane, and is refused while [runtime.assignments]
      names it, with the server's sentence.

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

    def exact_lane(self, name: str) -> dict:
        return next(lane for lane in self.standalone["lanes"] if lane["lane_id"] == name)

    def resolved(self) -> h.HttpResponse:
        with self.lock:
            if self.fail_next_resolved:
                self.fail_next_resolved = False
                return 503, {"error": "resolved unavailable"}
            lanes = [
                {"id": lane["id"], "runtime_ids": list(lane["runtime_ids"])}
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
                if action != "append":
                    raise AssertionError(f"the TUI posted {action!r} to a standalone lane")
                name = lane_id[len("exact/"):]
                slot = request["runtime_id"]
                declared = self.exact_declared[name]
                if slot in declared:
                    return 400, {"error": f"{slot} is already a slot of {name}"}
                declared.append(slot)
                lane = self.exact_lane(name)
                lane["admitted_slots"] = [
                    s for s in declared if s not in lane["dropped_slots"]
                ]
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
                if assigned:
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
        h.tab_until(process, fd, output, b"MASC Config")
        # 131 columns, as the Runtime scenario in test_tui_keyboard_input.py
        # uses: wide enough for the prompt rows, narrow enough to keep the
        # acting pane off the screen.
        h.resize_and_wait(
            process, fd, output, rows=30, columns=131,
            needle=b"MASC Config", controls=(h.FULL_REDRAW,),
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
            f"adding a failover candidate to {NEW_LANE}".encode(),
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

        # A lane a keeper is assigned to is refused by the server, and the
        # TUI draws the server's sentence as it came.
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
    picker = f"adding a failover candidate to {EXACT_LANE}".encode()

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


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    run_exact(os.path.abspath(sys.argv[1]))
    print("runtime lane editor: PASS")
