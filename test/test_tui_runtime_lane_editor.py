"""The Runtime lanes reading edits lanes: a, x, J, K and D, pressed for real.

A new lane is named, given its first runtime, grown, reordered, trimmed and
removed, and a lane a keeper is assigned to is refused. Each press is judged by
the body it posts to the routing API and by the list the surface re-reads.
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


class LaneStore:
    """The lanes the fixture server reads back after each write, changed by
    the routing posts the way runtime.toml is: create refuses a declared
    name, and remove refuses a lane a keeper is assigned to."""

    def __init__(self) -> None:
        _status, body = h.runtime_resolved_response()
        self.body = body
        self.lanes = [dict(lane) for lane in body["lanes"]]
        self.lock = threading.Lock()

    def resolved(self) -> h.HttpResponse:
        with self.lock:
            lanes = [
                {"id": lane["id"], "runtime_ids": list(lane["runtime_ids"])}
                for lane in self.lanes
            ]
        return 200, {**self.body, "lanes": lanes}

    def route(self, raw: bytes) -> h.HttpResponse:
        request = json.loads(raw)
        lane_id = request["lane"]
        action = request.get("action", "set")
        with self.lock:
            declared = [lane for lane in self.lanes if lane["id"] == lane_id]
            if action == "create":
                if declared:
                    return 400, {"error": f'lane "{lane_id}" already exists'}
                self.lanes.append(
                    {"id": lane_id, "runtime_ids": list(request["runtime_ids"])}
                )
            elif action == "set":
                if not declared:
                    return 400, {"error": f'unknown lane "{lane_id}"'}
                declared[0]["runtime_ids"] = list(request["runtime_ids"])
            elif action == "remove":
                assigned = [
                    assignment["keeper"]
                    for assignment in self.body["assignments"]
                    if assignment["resolved"] == {"kind": "lane", "id": lane_id}
                ]
                if assigned:
                    return 400, {
                        "error": (
                            f'lane "{lane_id}" is assigned to {", ".join(assigned)}; '
                            "assign them elsewhere before removing the lane"
                        )
                    }
                self.lanes.remove(declared[0])
            else:
                return 400, {"error": f"unknown action {action!r}"}
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
        h.send_and_wait(process, fd, output, b"J", b"1/2 runtime-e")
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

        # A lane a keeper is assigned to is refused, and the refusal says
        # which keeper holds it.
        for _ in range(3):
            press(process, fd, output, b"k")
        h.send_and_wait(
            process, fd, output, b"D", b"press D again to remove lane primary",
        )
        h.send_and_wait(process, fd, output, b"D", b"lane write refused: HTTP 400")
        h.read_available(fd, output)
        screen = h.screen_text(bytes(output))
        if b"is assigned to sangsu" not in screen:
            raise AssertionError(f"the refusal did not name the keeper: {screen!r}")

        # The request log is appended after the response goes out, so the
        # last post can trail the frame it produced.
        expected = [
            {"lane": NEW_LANE, "action": "create", "runtime_ids": ["runtime-a"]},
            {"lane": NEW_LANE, "runtime_ids": ["runtime-a", "runtime-e"]},
            {"lane": NEW_LANE, "runtime_ids": ["runtime-e", "runtime-a"]},
            {"lane": NEW_LANE, "runtime_ids": ["runtime-e"]},
            {"lane": NEW_LANE, "action": "remove"},
            {"lane": "primary", "action": "remove"},
        ]
        deadline = time.monotonic() + 3.0
        while True:
            posted = [json.loads(body) for path, body in requests if path == ROUTING_PATH]
            if len(posted) >= len(expected) or time.monotonic() > deadline:
                break
            time.sleep(0.05)
        if posted != expected:
            raise AssertionError(f"routing posts: {posted!r}, expected {expected!r}")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Runtime lanes reading edits lanes",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("runtime lane editor: PASS")
