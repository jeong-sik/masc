"""Clients and Connectors retain observations in aligned narrow tables."""
import json
import os
import sys
import threading

import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui_render.ml", "bin/masc_tui_table.ml", "bin/masc_tui.ml",
                  "bin/masc_tui_types.ml", "bin/masc_tui_keys.ml")
FUTURE = "2099-01-01T00:00:00Z"
MALFORMED = "unparseable-clock-reading"
LONG_STAMP = "unreadable-" + "longclock" * 30 + "-STAMPEND"


def screen(output):
    end = output.rfind(h.FRAME_END)
    return h.screen_rows(bytes(output[:end + len(h.FRAME_END)]) if end >= 0 else bytes(output))


def cell_slice(text, first, last):
    # This fixture uses ASCII and the harness's known two-cell Hangul glyph.
    position = 0
    result = []
    for char in text:
        if first <= position < last:
            result.append(char)
        position += h.fixture_cell_width(char)
    return "".join(result).strip()


def run_tables(executable):
    fixtures = h.clients_http_fixtures()
    _, clients = fixtures["/api/v1/dashboard/clients"]
    clients["clients"] = [
        h.clients_row("long-" + "client" * 20 + "-END", "codex", "active", "owner", "task-123"),
        h.clients_row("한" * 40 + "-END", "keeper", "busy", "other-owner", "task-456"),
        h.clients_row("future", "codex", "listening", None, None),
        h.clients_row("malformed", "codex", "inactive", None, None),
    ]
    for row, last_seen in zip(clients["clients"], ("", "bad-clock", FUTURE, MALFORMED)):
        row["last_seen"] = last_seen
    fixtures[h.CONNECTORS_PATH] = (200, {
        "total": 3, "active_count": 2,
        "connectors": [
            {"connector_id": "a", "display_name": "long-" + "connector" * 18 + "-END",
             "available": True, "connected": True, "status": "connected", "channel": "#connected",
             "configured_bindings": []},
            {"connector_id": "b", "display_name": "한" * 40 + "-END",
             "available": True, "connected": False, "status": "disconnected", "channel": "#unreachable",
             "configured_bindings": []},
            {"connector_id": "c", "display_name": "offline", "available": False,
             "connected": False, "status": "offline", "channel": None, "configured_bindings": []},
        ],
    })

    def interact(process, fd, _slave, output, _base):
        for surface in ("Clients", "Connectors"):
            ready = b"bad-clock" if surface == "Clients" else b"#unreachable"
            h.palette_go(process, fd, output, ("go " + surface).encode(), ready)
            for width in (60, 80, 120):
                h.resize_and_wait(process, fd, output, rows=26, columns=width,
                                  needle=ready, final_cursor=b"\x1b[?25l")
                h.drain_until_quiet(process, fd, output)
                rows = [row.decode("utf-8", "replace") for row in screen(output).values()]
                print("CLIENT_CONNECTOR_LAYOUT " + json.dumps({"surface": surface, "width": width,
                      "rows": rows}, ensure_ascii=False), flush=True)
                if surface == "Clients":
                    header = next(row for row in rows if "LAST SEEN" in row and "STATUS" in row)
                    boundaries = [header.index("STATUS"), header.index("NAME"), header.index("LAST SEEN")]
                    for name, status, seen in (("long-", "active", "never"), ("한", "busy", "bad-clock"),
                                              ("future", "listening", FUTURE), ("malformed", "inactive", MALFORMED)):
                        row = next(row for row in rows if name in row and seen in row)
                        assert cell_slice(row, boundaries[0], boundaries[1]) == status, row
                        assert cell_slice(row, boundaries[2], width - 2) == seen, row
                    assert ("ACTING FOR" in header) == (width == 120), header
                else:
                    header = next(row for row in rows if "REACHABLE" in row and "CHANNEL" in row)
                    reach, status, channel = (header.index(label) for label in ("REACHABLE", "STATUS", "CHANNEL"))
                    name_start = header.index("CONNECTOR")
                    name_end = header.index("CONFIGURED") if "CONFIGURED" in header else reach
                    for name, reachable, state, route in (("long", "yes", "connected", "#connected"),
                                                        ("한", "no", "disconnected", "#unreachable"),
                                                        ("offline", "no", "offline", "—")):
                        matches = [row for row in rows
                                   if cell_slice(row, channel, width - 2) == route
                                   and cell_slice(row, status, channel) == state]
                        assert len(matches) == 1, (surface, width, route, state, rows)
                        row = matches[0]
                        displayed_name = cell_slice(row, name_start, name_end)
                        assert displayed_name.startswith(name), (width, displayed_name, rows)
                        if name == "offline":
                            assert displayed_name == name, row
                        else:
                            assert displayed_name.endswith("-END") and "…" in displayed_name, row
                        assert cell_slice(row, reach, status) == reachable, row
                        assert cell_slice(row, status, channel) == state, row
                        assert cell_slice(row, channel, width - 2) == route, row
                    assert ("CONFIGURED" in header) == (width >= 80), header
            h.resize_and_wait(process, fd, output, rows=26, columns=100,
                              needle=ready, final_cursor=b"\x1b[?25l")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Clients and Connectors align CJK names with observations",
                            interact=interact, http_fixtures=fixtures)


def run_client_exact_read(executable):
    fixtures = h.clients_http_fixtures()
    _, payload = fixtures["/api/v1/dashboard/clients"]
    row = h.clients_row("raw-clock-client", "codex", "active", "owner", "task-123")
    row["last_seen"] = LONG_STAMP
    payload["clients"] = [row]

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go Clients", b"raw-clock-client")
        h.resize_and_wait(process, fd, output, rows=24, columns=60,
                          needle=b"raw-clock-client", final_cursor=b"\x1b[?25l")
        h.send_and_wait(process, fd, output, b"\r", b"MASC Client Detail")
        # A tall frame reconstructs the entire raw observation, while G in
        # a normal-height frame reaches its wrapped final evidence row.
        h.resize_and_wait(process, fd, output, rows=100, columns=60,
                          needle=b"STAMPEND", final_cursor=b"\x1b[?25l")
        h.drain_until_quiet(process, fd, output)
        compact = b"".join(b"".join(screen(output).values()).split())
        compact = h.unwrapped(compact).replace(b" ", b"")
        assert LONG_STAMP.encode() in compact, compact
        h.resize_and_wait(process, fd, output, rows=24, columns=60,
                          needle=b"MASC Client Detail", final_cursor=b"\x1b[?25l")
        h.send_and_wait(process, fd, output, b"G", b"STAMPEND")
        h.drain_until_quiet(process, fd, output)
        assert any(b"STAMPEND" in line for line in screen(output).values()), screen(output)
        h.send_and_wait(process, fd, output, b"g", b"raw-clock-client")
        # Enter and refresh inside the read cannot change the roster cursor
        # or substitute another client; Esc returns to the same row.
        os.write(fd, b"r\r")
        h.drain_until_quiet(process, fd, output)
        assert any(b"MASC Client Detail" in line for line in screen(output).values()), screen(output)
        h.send_and_wait(process, fd, output, b"\x1b", b"LAST SEEN")
        assert any(b"raw-clock-client" in line for line in screen(output).values()), screen(output)
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Client detail retains arbitrarily long observation evidence",
                            interact=interact, http_fixtures=fixtures)


def run_retained_read(executable):
    fixtures = h.clients_http_fixtures()
    _, payload = fixtures["/api/v1/dashboard/clients"]
    failed = threading.Event()
    fixtures["/api/v1/dashboard/clients"] = lambda: ((503, {"error": "reading failed"})
                                                        if failed.is_set() else (200, payload))
    connector_payload = {"total": 1, "active_count": 1, "connectors": [{
        "connector_id": "discord", "display_name": "RetainedConnector", "available": True,
        "connected": True, "status": "connected", "channel": "#retained", "configured_bindings": []}]}
    fixtures[h.CONNECTORS_PATH] = lambda: ((503, {"error": "reading failed"})
                                          if failed.is_set() else (200, connector_payload))

    def interact(process, fd, _slave, output, _base):
        for surface, retained in (("Clients", b"analyst-agent"), ("Connectors", b"#retained")):
            failed.clear()
            h.palette_go(process, fd, output, ("go " + surface).encode(), retained)
            failed.set()
            h.send_and_wait(process, fd, output, b"r", b"HTTP 503")
            h.drain_until_quiet(process, fd, output)
            rows = screen(output)
            assert any(retained in row for row in rows.values()), rows
            assert not any(b"nothing here is a reading" in row for row in rows.values()), rows
            print("CLIENT_CONNECTOR_RETAINED_READ " + json.dumps({"surface": surface,
                  "rows": [row.decode("utf-8", "replace") for row in rows.values()]}), flush=True)
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Client and Connector failed refreshes retain read rows",
                            interact=interact, http_fixtures=fixtures)


def run_client_modal_boundary(executable):
    fixtures = h.clients_http_fixtures()

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go Clients", b"analyst-agent")
        # Search Enter settles the query for n/N; the next Enter reads the
        # matching client. A detail must not steal the first submission.
        h.send_and_wait(process, fd, output, b"/analyst", b"/analyst")
        h.send_and_wait(process, fd, output, b"\r", b"/analyst")
        h.drain_until_quiet(process, fd, output)
        rows = screen(output)
        assert not any(b"MASC Client Detail" in row for row in rows.values()), rows
        search = next(row for row in rows.values() if b"/analyst" in row)
        assert b"n/N" in search and "▌".encode() not in search, search
        h.send_and_wait(process, fd, output, b"\r", b"MASC Client Detail")
        h.drain_until_quiet(process, fd, output)
        assert any(b"analyst-agent" in row for row in screen(output).values()), screen(output)
        # The global strip is still visible above an overlay, but its tabs
        # cannot change the caller underneath an open client reading.
        strip = screen(output).get(1, b"")
        index = strip.find(b"Board")
        if index < 0:
            raise AssertionError(f"the client detail lost its surface strip: {strip!r}")
        column = len(strip[:index].decode("utf-8")) + 1
        click = b"\x1b[<0;%d;1M\x1b[<0;%d;1m" % (column, column)
        os.write(fd, click)
        h.drain_until_quiet(process, fd, output)
        assert any(b"MASC Client Detail" in row for row in screen(output).values()), screen(output)
        # Keys still belong to the visible overlay after that pointer event.
        os.write(fd, b"j")
        h.drain_until_quiet(process, fd, output)
        assert any(b"MASC Client Detail" in row for row in screen(output).values()), screen(output)
        h.send_and_wait(process, fd, output, b"\x1b", b"LAST SEEN")
        h.drain_until_quiet(process, fd, output)
        assert any(b"analyst-agent" in row for row in screen(output).values()), screen(output)
        assert any(b"/analyst" in row and b"n/N" in row for row in screen(output).values()), screen(output)
        h.send_and_wait(process, fd, output, b"\r", b"MASC Client Detail")
        h.drain_until_quiet(process, fd, output)
        assert any(b"analyst-agent" in row for row in screen(output).values()), screen(output)
        assert not any(b"codex-mcp-client" in row for row in screen(output).values()), screen(output)
        h.send_and_wait(process, fd, output, b"\x1b", b"LAST SEEN")
        # Closing the modal restores real strip navigation and the new
        # surface receives its own keys, without a hidden client key owner.
        h.press_label_on_screen(process, fd, output, b"Board", row=1, needle=b"MASC Board")
        h.send_and_wait(process, fd, output, b"?", b"MASC Cheat Sheet")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Board")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Client detail is a global overlay and search owns its Enter",
                            interact=interact, http_fixtures=fixtures)


def run_read_states(executable, failed):
    fixtures = h.overview_event_http_fixtures()
    client_payload = {"schema": "masc.dashboard.clients.v1", "generated_at": "2026-09-30T00:00:00Z",
                      "observation_only": True, "clients": []}
    connector_payload = {"total": 0, "active_count": 0, "connectors": []}
    gates = []
    for path, payload in (("/api/v1/dashboard/clients", client_payload), (h.CONNECTORS_PATH, connector_payload)):
        response = (503, {"error": "reading failed"}) if failed else (200, payload)
        gate = h.GatedHttpResponse(response, hold_seconds=20)
        fixtures[path] = gate
        gates.append(gate)

    def interact(process, fd, _slave, output, _base):
        for surface, gate, empty in zip(("Clients", "Connectors"), gates,
                                        (b"nobody attached", b"no connectors registered")):
            h.palette_go(process, fd, output, ("go " + surface).encode(), b"not loaded yet")
            assert not any(empty in row for row in screen(output).values()), screen(output)
            print("CLIENT_CONNECTOR_READ_STATE " + json.dumps({"surface": surface, "state": "unread",
                  "rows": [row.decode("utf-8", "replace") for row in screen(output).values()]}), flush=True)
            gate.release.set()
            needle = b"nothing here is a reading" if failed else empty
            h.wait_for_output(process, fd, output, needle, start=len(output), timeout=10)
            h.drain_until_quiet(process, fd, output)
            assert any(needle in row for row in screen(output).values()), screen(output)
            if failed:
                assert not any(empty in row for row in screen(output).values()), screen(output)
            print("CLIENT_CONNECTOR_READ_STATE " + json.dumps({"surface": surface,
                  "state": "failed" if failed else "empty",
                  "rows": [row.decode("utf-8", "replace") for row in screen(output).values()]}), flush=True)
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Client and Connector " + ("failed reads" if failed else "unread to empty reads"),
                            interact=interact, http_fixtures=fixtures)


def run_connector_startup_identity(executable, *, failed=False, leave=False):
    fixtures = h.keeper_runtime_http_fixtures()
    health = h.GatedHttpResponse((200, {}), hold_seconds=20)
    full_health = h.GatedHttpResponse(h.fleet_safety_fixture(), hold_seconds=20)
    requests: list[str] = []
    lock = threading.Lock()

    def record(path):
        with lock:
            requests.append(path)

    def count(path):
        with lock:
            return requests.count(path)

    def compact_response():
        response = health()
        record("/health")
        return response

    def full_response():
        response = full_health()
        record("/health?full=1")
        return response

    def connector_response():
        record(h.CONNECTORS_PATH)
        return ((503, {"error": "startup connector failure"}) if failed else
                (200, {"total": 0, "active_count": 0, "connectors": []}))

    fixtures["/health"] = compact_response
    fixtures["/health?full=1"] = full_response
    fixtures[h.CONNECTORS_PATH] = connector_response

    def interact(process, fd, _slave, output, base):
        matching = h.with_workspace_identity({
            "/health": (200, {}), "/health?full=1": h.fleet_safety_fixture()}, base)
        compact = matching["/health"]
        full = matching["/health?full=1"]
        assert isinstance(compact, tuple) and isinstance(full, tuple)
        health.response, full_health.response = compact, full
        try:
            assert h.wait_for_fixture_event(process, fd, output, health.requested, timeout=3.0)
            h.palette_go(process, fd, output, b"go Connectors", b"not loaded yet")
            assert not health.completed.is_set(), "initial identity gate expired before navigation"
            assert count(h.CONNECTORS_PATH) == 0, requests
            assert any(b"not loaded yet" in row for row in screen(output).values()), screen(output)
            if leave:
                h.palette_go(process, fd, output, b"go Dashboard", b"MASC Dashboard")
            start = len(output)
            health.release.set()
            full_health.release.set()
            needle = b"nothing here is a reading" if failed else b"no connectors registered"
            if not leave:
                # No refresh or navigation key: identity completion owns this read.
                h.wait_for_output(process, fd, output, needle, start=start, timeout=3.0)
                h.drain_until_quiet(process, fd, output)
                assert count(h.CONNECTORS_PATH) == 1, requests
                assert any(needle in row for row in screen(output).values()), screen(output)
                if failed:
                    assert not any(b"no connectors registered" in row
                                   for row in screen(output).values()), screen(output)
            if leave:
                # Discovery can settle without selecting a conversation.
                assert h.wait_for_fixture_event(process, fd, output,
                    health.completed, timeout=3.0)
                h.drain_until_quiet(process, fd, output)
                assert count(h.CONNECTORS_PATH) == 0, requests
            else:
                # A deliberate refresh remains available after either outcome.
                os.write(fd, b"r")
                assert h.wait_for_fixture_state(process, fd, output,
                    lambda: count(h.CONNECTORS_PATH) == 2, timeout=3.0), requests
                h.drain_until_quiet(process, fd, output)
                assert count(h.CONNECTORS_PATH) == 2, requests
            expected_frame = b"MASC Dashboard" if leave else needle
            assert any(expected_frame in row for row in screen(output).values()), screen(output)
            print("CONNECTOR_STARTUP_IDENTITY " + json.dumps({
                "case": "left" if leave else "failed" if failed else "empty",
                "connector_requests": count(h.CONNECTORS_PATH)}), flush=True)
            os.write(fd, b"q")
        finally:
            health.release.set()
            full_health.release.set()

    h.run_terminal_scenario(executable,
        description="Connector initial identity " + ("left surface" if leave else "failed read" if failed else "automatic empty read"),
        interact=interact, http_fixtures=fixtures, refresh=60.0, terminal_cols=160)


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    run_connector_startup_identity(executable)
    run_connector_startup_identity(executable, failed=True)
    run_connector_startup_identity(executable, leave=True)
    run_tables(executable)
    run_client_exact_read(executable)
    run_client_modal_boundary(executable)
    run_retained_read(executable)
    run_read_states(executable, False)
    run_read_states(executable, True)
    print("Client and Connector responsive layout: PASS")
