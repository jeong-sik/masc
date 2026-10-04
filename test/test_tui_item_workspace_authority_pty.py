"""Real PTY Item reads cannot cross a server workspace boundary.

Synthetic HTTP observations exercise the real TUI, not a live deployment.
The same Keeper name deliberately appears in both workspaces.
"""
from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import sys

import tui_keyboard_harness as _keyboard_harness
import test_tui_remote_workspace_history_pty as authority


ITEM_PATH = "/api/v1/keepers/alpha/items"
CATALOG = (
    ("glasses", "face"), ("shades", "face"), ("eye_patch", "face"),
    ("plaster", "face"), ("freckles", "face"), ("beard", "face"),
    ("scarf", "neck"), ("bow_tie", "neck"), ("medal", "neck"),
    ("bow", "head"), ("crown", "head"), ("beanie", "head"),
    ("book", "hand"), ("mug", "hand"), ("quill", "hand"),
    ("dish_gilt", "base"), ("dish_silver", "base"), ("dish_oak", "base"),
)


def account(balance: str, owned: str, price: str, revision: str):
    return 200, {
        "status": "ready", "account_revision": revision * 64, "keeper": "alpha", "balance_milli": balance,
        "owned_items": [owned],
        "catalog": [
            {"id": item, "slot": slot, "price_status": "priced", "price_milli": price}
            for item, slot in CATALOG
        ],
    }


class ItemWire(authority.WorkspaceWire):
    def __init__(self, roster):
        super().__init__(roster)
        self.account_state = "ready"
        self.roster_unavailable = False
        self.observing_denied_retry = False
        self.malformed_revision = False
        self.missing_revision = False
        self.booting = False
        self.ready_after_boot = False
        self.returned_balance = "3250"

    def set_booting(self, booting):
        with self.lock:
            if self.booting and not booting:
                self.ready_after_boot = True
            self.booting = booting

    def health(self):
        response = super().health()
        payload = json.loads(response.body)
        with self.lock:
            booting = self.booting
            self.events.append({"event": "item-health", "booting": booting})
        payload["startup"] = {"state_ready": not booting}
        return _keyboard_harness.RawHttpResponse(200, json.dumps(payload).encode(), content_type="application/json")

    def set_roster_unavailable(self, unavailable):
        with self.lock:
            self.roster_unavailable = unavailable
            if not unavailable:
                self.observing_denied_retry = False

    def set_malformed_revision(self, malformed):
        with self.lock:
            self.malformed_revision = malformed

    def set_missing_revision(self, missing):
        with self.lock:
            self.missing_revision = missing

    def roster(self):
        with self.lock:
            unavailable = self.roster_unavailable
            malformed = self.malformed_revision
            missing = self.missing_revision
            state, phase = self.account_state, self.phase
            ready_after_boot = self.ready_after_boot
        if unavailable:
            return 503, {"error": "current roster unavailable"}
        status, payload = super().roster()
        revision = "a" if phase == "a" else "c" if phase == "a-returned" else "b"
        payload["candle"] = ({"status": "off"} if state == "off" else
            {"status": "ready", "issued_milli": "12500", "burned_milli": "0", "circulating_milli": "12500"})
        for row in payload["keepers"]:
            row["candle_account_revision"] = None if state == "off" else revision * 64
            row["candle_balance_milli"] = None if state == "off" else "12500"
            if row["name"] == "alpha":
                if ready_after_boot:
                    row["runtime_id"] = "a.boot.ready"
                if missing:
                    row.pop("candle_account_revision")
                elif malformed:
                    row["candle_account_revision"] = {"unexpected": "object"}
        return status, payload

    def change_account(self, state):
        assert state in ("ready", "failed", "off")
        with self.lock:
            self.account_state = state

    def arm_items(self):
        with self.lock:
            assert self.phase == "a" and not self.held_started.is_set()
            self.hold_next = True

    def items(self):
        with self.lock:
            phase, state = self.phase, self.account_state
            returned_balance = self.returned_balance
            held = self.hold_next and phase == "a"
            if held:
                self.hold_next = False
            self.events.append({"event": "items", "phase": phase, "state": state, "held": held,
                "roster_unavailable": self.roster_unavailable,
                "denied_retry_observation": self.observing_denied_retry,
                "missing_revision": self.missing_revision, "malformed_revision": self.malformed_revision})
        if held:
            self.held_started.set()
            if not self.release_held.wait(timeout=30.0):
                return 504, {"error": "held Item read timed out"}
            self.held_returned.set()
            return account("99999", "glasses", "99999", "a")
        if state == "failed":
            return 503, {"error": "current Item ledger unreadable"}
        if state == "off":
            return 200, {"status": "off", "account_revision": None, "keeper": "alpha"}
        if phase == "a":
            return account("12500", "glasses", "1000", "a")
        if phase == "a-returned":
            return account(returned_balance, "quill", "1750", "c")
        return account("7500", "crown", "2000", "b")


class PartialRosterWire(ItemWire):
    def __init__(self, roster):
        super().__init__(roster)
        self.complete = False
        self.partial_reads = 0

    def roster(self):
        status, payload = authority.WorkspaceWire.roster(self)
        template = next(row for row in payload["keepers"] if row["name"] == "beta")
        rows = []
        # The real endpoint caps its rows at 200; local alpha is outside that
        # observed prefix, with its Item account still owned by /items.
        for index in range(200):
            row = copy.deepcopy(template)
            row["name"] = f"observed-{index:03d}"
            row["meta"] = _keyboard_harness.keeper_roster_meta(row["name"])
            rows.append(row)
        with self.lock:
            complete = self.complete
            if not complete:
                self.partial_reads += 1
            self.events.append({"event": "partial-roster", "complete": complete})
        payload.update(keepers=rows, count=len(rows), total=200 if complete else 201,
                       truncated=not complete,
                       candle={"status": "ready", "issued_milli": "12500",
                               "burned_milli": "0", "circulating_milli": "12500"})
        return status, payload

    def items(self):
        response = super().items()
        if self.held_returned.is_set() and response[0] == 200:
            return account("99999", "glasses", "99999", "a")
        return response


def run_partial_roster(binary, captures):
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    roster_fixture = fixtures[authority.ROSTER_PATH]
    assert isinstance(roster_fixture, tuple)
    wire = PartialRosterWire(roster_fixture[1])
    fixtures[authority.ROSTER_PATH] = wire.roster
    fixtures["/api/v1/gate/keepers"] = wire.roster
    fixtures["/health"] = _keyboard_harness.HeadersHttpResponse(lambda _headers: wire.health())
    fixtures["/health?full=1"] = _keyboard_harness.HeadersHttpResponse(lambda _headers: wire.health())
    fixtures[ITEM_PATH] = wire.items

    def interact(process, fd, _slave, output, _base):
        def wait(predicate, label):
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
                lambda: predicate(authority.screen(output)), timeout=authority.WAIT_SECONDS), \
                f"{label}: {authority.screen(output)!r}"

        try:
            _keyboard_harness.tab_until(process, fd, output, b"MASC Keepers")
            _keyboard_harness.select_keeper_row(process, fd, output, b"alpha")
            _keyboard_harness.send_and_wait(process, fd, output, b"\r", "▸Info".encode())
            _keyboard_harness.send_and_wait(process, fd, output, b"]", "▸Items".encode())
            wait(lambda text: b"Balance 12.500 Candle" in text, "unobserved alpha Item read")
            wire.arm_items()
            assert _keyboard_harness.wait_for_fixture_event(process, fd, output, wire.held_started,
                timeout=authority.WAIT_SECONDS), "cadence did not refresh alpha's Item account"
            with wire.lock:
                prior_reads = wire.partial_reads

            def later_roster_reads(_text):
                with wire.lock:
                    return wire.partial_reads >= prior_reads + 2

            wait(later_roster_reads, "partial roster cadence did not continue during Item read")
            _keyboard_harness.resize_and_wait(process, fd, output, rows=35,
                columns=authority.TERMINAL_COLUMNS, needle="▸Items".encode(),
                controls=(_keyboard_harness.FULL_REDRAW,))
            assert b"Balance 12.500 Candle" in authority.screen(output), \
                "partial roster refresh withdrew the authoritative pending Item account"
            if captures is not None:
                (captures / "partial-roster-held.txt").write_bytes(authority.screen(output))
            wire.release_held.set()
            wait(lambda text: b"Balance 99.999 Candle" in text, "current Item response was lost")
            wire.change_account("failed")
            wait(lambda text: b"current Item ledger unreadable" in text,
                 "endpoint failure retained the old account")
            assert b"Balance " not in authority.screen(output)
            wire.change_account("ready")
            wait(lambda text: b"Balance 99.999 Candle" in text, "Item account did not recover")
            with wire.lock:
                wire.complete = True
            wait(lambda text: b"Keeper is not observed in the current roster" in text,
                 "a complete roster's absence did not withdraw the Item account")
            assert b"Balance " not in authority.screen(output)
            os.write(fd, b"q")
        finally:
            wire.release_held.set()
            if captures is not None:
                (captures / "partial-roster.pty").write_bytes(output)
                with wire.lock:
                    events = list(wire.events)
                (captures / "partial-roster-requests.json").write_text(json.dumps(events, indent=2) + "\n")

    _keyboard_harness.run_terminal_scenario(binary, description="Partial roster retains authoritative Item account",
        interact=interact, prepare_workspace=wire.prepare, http_fixtures=fixtures,
        refresh=0.5, terminal_rows=34, terminal_cols=authority.TERMINAL_COLUMNS)


def run(binary, captures):
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures(alpha_runtime_id="a.current")
    wire = ItemWire(fixtures[authority.ROSTER_PATH][1])
    fixtures[authority.ROSTER_PATH] = wire.roster
    fixtures["/api/v1/gate/keepers"] = wire.roster
    fixtures["/health"] = wire.health
    fixtures["/health?full=1"] = wire.health
    fixtures[ITEM_PATH] = wire.items
    posts: _keyboard_harness.HttpRequests = []

    def interact(process, fd, _slave, output, _base):
        def visible():
            return authority.screen(output)

        def wait(predicate, label):
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
                lambda: predicate(visible()), timeout=authority.WAIT_SECONDS), \
                f"{label}: {visible()!r}"

        def capture(name):
            if captures is not None:
                (captures / (name + ".txt")).write_bytes(visible())
                (captures / (name + ".pty")).write_bytes(output)
            print("ITEM_AUTHORITY_FRAME " + name + "\n" + visible().decode(errors="replace"), flush=True)

        def booting_observed():
            with wire.lock:
                return any(event["event"] == "item-health" and event["booting"]
                    for event in wire.events)

        def item_row(name):
            rows = [line for line in visible().splitlines() if name in line]
            assert rows, f"{name!r} absent: {visible()!r}"
            return b"\n".join(rows)

        def open_items(*, first=False):
            _keyboard_harness.select_keeper_row(process, fd, output, b"alpha")
            _keyboard_harness.send_and_wait(process, fd, output, b"\r",
                "▸Info".encode() if first else "▸Items".encode())
            if first:
                _keyboard_harness.send_and_wait(process, fd, output, b"]", "▸Items".encode())

        try:
            _keyboard_harness.tab_until(process, fd, output, b"MASC Keepers")
            wait(lambda text: b"a.current" in text and b"MISMATCH" not in text, "A roster")
            open_items(first=True)
            wait(lambda text: b"Balance 12.500 Candle" in text and b"owned" in text, "A Item account")
            assert b"1.000" in item_row(b"glasses") and b"owned" in item_row(b"glasses")
            capture("a-ready")
            wire.arm_items()
            os.write(fd, b"r")
            assert _keyboard_harness.wait_for_fixture_event(process, fd, output, wire.held_started,
                timeout=authority.WAIT_SECONDS), "refresh did not launch the held A Item read"
            wire.publish("b")
            wait(lambda text: b"b.current" in text and b"MISMATCH local " in text
                and b"MASC Keepers" in text and "▸Items".encode() not in text,
                "workspace B did not withdraw A's Item detail")
            assert b"12.500" not in visible() and b"owned" not in visible()
            capture("b-with-a-read-held")
            after_b = len(output)
            wire.release_held.set()
            assert _keyboard_harness.wait_for_fixture_event(process, fd, output, wire.held_returned,
                timeout=authority.WAIT_SECONDS), "held A Item response was not released"
            wire.publish("b-after-late")
            wait(lambda text: b"b.settled" in text, "fresh B roster after release")
            _keyboard_harness.resize_and_wait(process, fd, output, rows=35,
                columns=authority.TERMINAL_COLUMNS, needle=b"b.settled", controls=(_keyboard_harness.FULL_REDRAW,))
            # B is intentionally foreign to the local workspace. Its roster
            # remains observable, but Item reads never acquire admission.
            assert b"MISMATCH local " in visible()
            assert b"Balance " not in visible() and b"owned" not in visible()
            assert "▸Items".encode() not in visible()
            assert b"99.999" not in _keyboard_harness.CSI_RE.sub(b"", bytes(output[after_b:])), \
                "late A Item money was rendered while B was unadmitted"
            with wire.lock:
                assert not [event for event in wire.events
                    if event["event"] == "items" and event["phase"].startswith("b")], \
                    "foreign B acquired an Item account read"
            capture("b-unadmitted-after-late-a")
            wire.publish("a-returned")
            wait(lambda text: b"a.returned" in text and b"MISMATCH" not in text
                and "▸Items".encode() not in text, "return to A retained B Item detail")
            open_items()
            wait(lambda text: b"Balance 3.250 Candle" in text, "A did not re-read its current Item account")
            assert b"7.500" not in visible() and b"99.999" not in visible()
            assert b"1.750" in item_row(b"glasses") and b"owned" not in item_row(b"glasses")
            assert b"99.999" not in _keyboard_harness.CSI_RE.sub(b"", bytes(output[after_b:])), \
                "late A Item money was rendered after the workspace boundary"
            capture("a-current-after-return")
            _keyboard_harness.send_and_wait(process, fd, output, b"j" * 14, b"Items 15/18")
            wait(lambda text: b"quill" in text and b"owned" in text, "returned A's owned quill")
            assert b"1.750" in item_row(b"quill") and b"owned" in item_row(b"quill")
            _keyboard_harness.send_and_wait(process, fd, output, b"k" * 14, b"Items 1/18")
            wire.change_account("failed")
            os.write(fd, b"r")
            wait(lambda text: b"Account unavailable:" in text and b"current Item ledger unreadable" in text,
                "admitted A's failed current read was hidden")
            assert b"Balance " not in visible() and b"owned" not in visible()
            capture("a-unread")
            wire.change_account("off")
            os.write(fd, b"r")
            wait(lambda text: b"Candle off" in text, "Off retained a monetary reading")
            assert b"Balance " not in visible() and b"owned" not in visible()
            capture("a-off")
            wire.change_account("ready")
            os.write(fd, b"r")
            wait(lambda text: b"Balance 3.250 Candle" in text, "admitted A account did not recover")
            capture("a-recovered")
            wire.set_roster_unavailable(True)
            wait(lambda text: b"Account unavailable:" in text
                 and (b"Keeper is not observed in the current roster" in text
                      or b"Keeper roster authority is unavailable" in text),
                 "an unavailable roster retained monetary facts")
            with wire.lock:
                # The rendered refusal establishes that the client applied
                # the failed roster. Earlier in-flight reads were admitted
                # before that observation and are not this denied retry.
                wire.observing_denied_retry = True
                item_reads = sum(event["event"] == "items" for event in wire.events)
            # The refusal may already be drawn. Moving the selection after
            # retrying proves the input was processed without requiring the
            # unchanged error to be emitted again.
            _keyboard_harness.send_and_wait(process, fd, output, b"rj", b"Items 2/18")
            _keyboard_harness.send_and_wait(process, fd, output, b"k", b"Items 1/18")
            def unexpected_item_read():
                with wire.lock:
                    return sum(event["event"] == "items" for event in wire.events) != item_reads
            # Keyboard frames do not settle asynchronous HTTP work. Keep the
            # TUI draining and authority unavailable for the whole existing
            # fixture deadline, failing if any account request arrives.
            assert not _keyboard_harness.wait_for_fixture_state(process, fd, output, unexpected_item_read,
                timeout=authority.WAIT_SECONDS), \
                "explicit Item retry asynchronously read the account without roster authority"
            assert process.poll() is None, "TUI exited during denied Item retry observation"
            assert b"Keeper roster authority is unavailable" in visible()
            with wire.lock:
                assert sum(event["event"] == "items" for event in wire.events) == item_reads, \
                    "explicit Item retry read the account without roster authority"
            assert b"Balance " not in visible() and b"owned" not in visible(), \
                "explicit Item retry bypassed unavailable roster authority"
            capture("a-revision-unavailable")
            wire.set_roster_unavailable(False)
            wait(lambda text: b"Balance 3.250 Candle" in text,
                 "same-revision roster recovery did not reload the account")
            # Public revision fields cannot suppress a fresh private account.
            # Changed balances prove the returned body replaced the old reading.
            for public_revision, balance, rendered_balance in (
                ("missing", "4250", b"Balance 4.250 Candle"),
                ("malformed", "5250", b"Balance 5.250 Candle"),
            ):
                with wire.lock:
                    before_events = len(wire.events)
                    wire.missing_revision = public_revision == "missing"
                    wire.malformed_revision = public_revision == "malformed"
                    wire.returned_balance = balance
                os.write(fd, b"r")
                def fresh_items():
                    with wire.lock:
                        return any(event["event"] == "items"
                            and event[public_revision + "_revision"]
                            for event in wire.events[before_events:])
                assert _keyboard_harness.wait_for_fixture_state(process, fd, output, fresh_items,
                    timeout=authority.WAIT_SECONDS), "public revision blocked the authenticated Item read"
                wait(lambda text: rendered_balance in text and b"quill" in text and b"owned" in text,
                     "fresh private Item facts were not applied with " + public_revision + " public revision")
                capture("a-public-revision-" + public_revision)
                wire.set_missing_revision(False)
                wire.set_malformed_revision(False)
            with wire.lock:
                wire.returned_balance = "3250"
            wire.set_booting(True)
            wait(lambda text: booting_observed() and b"No keeper selected." in text
                 and "▸Items".encode() not in text,
                 "booting server did not withdraw the Item detail")
            assert b"Balance " not in visible() and b"owned" not in visible()
            capture("a-booting")
            wire.set_booting(False)
            # Item authority requires a fresh explicit detail read; unlike
            # other detail tabs, it is not automatically restored on recovery.
            wait(lambda text: b"MASC Keepers" in text and b"a.boot.ready" in text
                 and "▸Items".encode() not in text,
                 "ready server did not publish its fresh roster after boot")
            assert b"Balance " not in visible() and b"owned" not in visible()
            open_items()
            wait(lambda text: "▸ alpha".encode() in text and "▸Items".encode() in text
                 and b"Balance 3.250 Candle" in text,
                 "explicit readmission did not reload the Keeper Item account")
            assert not [p for p, _ in posts if p.startswith("/api/v1/keepers/")], \
                "read-only Item navigation submitted Keeper work"
            os.write(fd, b"q")
        finally:
            wire.release_held.set()
            if captures is not None:
                (captures / "complete.pty").write_bytes(output)
                with wire.lock:
                    events = list(wire.events)
                (captures / "requests.json").write_text(json.dumps({
                    "gets": events, "posts": [{"path": p, "body": json.loads(b)} for p, b in posts],
                }, indent=2) + "\n")

    _keyboard_harness.run_terminal_scenario(binary, description="Item accounts follow A/B/A workspace authority",
        interact=interact, prepare_workspace=wire.prepare, http_fixtures=fixtures,
        http_requests=posts, refresh=0.5, terminal_rows=34,
        terminal_cols=authority.TERMINAL_COLUMNS)
    # The fixture joins all handlers before returning. Include requests that
    # arrive after the immediate keyboard assertions in the final ledger.
    with wire.lock:
        assert not [event for event in wire.events
                    if event["event"] == "items" and event["denied_retry_observation"]], \
            "an Item request was admitted during the denied retry observation"


if __name__ == "__main__":
    binary = str(Path(sys.argv[1]).resolve())
    root = os.environ.get("RUNNER_TEMP")
    captures = Path(root, "tui-item-workspace-authority") if root else None
    if captures is not None:
        captures.mkdir(parents=True, exist_ok=True)
        (captures / "manifest.json").write_text(json.dumps({
            "scope": "synthetic HTTP A/B/A Item accounts through a real PTY; no live deployment",
            "binary_sha256": hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
            "scenario_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        }, indent=2) + "\n")
    run(binary, captures)
    run_partial_roster(binary, captures)
    print("Item workspace authority: PASS (withdrawal, late response, failure, Off, recovery)")
