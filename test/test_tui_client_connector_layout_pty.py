"""Clients and Connectors retain observations in aligned narrow tables."""
import json
import os
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui_render.ml", "bin/masc_tui_table.ml")


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
    ]
    for row, last_seen in zip(clients["clients"], ("", "bad-clock")):
        row["last_seen"] = last_seen
    fixtures[h.CONNECTORS_PATH] = (200, {
        "total": 3, "active_count": 2,
        "connectors": [
            {"connector_id": "a", "display_name": "long-" + "connector" * 18 + "-END",
             "available": True, "connected": True, "status": "connected", "channel": "#connected"},
            {"connector_id": "b", "display_name": "한" * 40 + "-END",
             "available": True, "connected": False, "status": "disconnected", "channel": "#unreachable"},
            {"connector_id": "c", "display_name": "offline", "available": False,
             "connected": False, "status": "offline", "channel": None},
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
                if surface == "Clients":
                    header = next(row for row in rows if "LAST SEEN" in row and "STATUS" in row)
                    boundaries = [header.index("STATUS"), header.index("NAME"), header.index("LAST SEEN")]
                    for name, status, seen in (("long-", "active", "never"), ("한", "busy", "bad-clock")):
                        row = next(row for row in rows if name in row and seen in row)
                        assert cell_slice(row, boundaries[0], boundaries[1]) == status, row
                        assert cell_slice(row, boundaries[2], width - 2) == seen, row
                    assert ("ACTING FOR" in header) == (width == 120), header
                else:
                    header = next(row for row in rows if "REACHABLE" in row and "CHANNEL" in row)
                    reach, status, channel = (header.index(label) for label in ("REACHABLE", "STATUS", "CHANNEL"))
                    for name, reachable, state, route in (("long-", "yes", "connected", "#connected"),
                                                        ("한", "no", "disconnected", "#unreachable"),
                                                        ("offline", "no", "offline", "—")):
                        row = next(row for row in rows if name in row and state in row and "REACHABLE" not in row)
                        assert cell_slice(row, reach, status) == reachable, row
                        assert cell_slice(row, status, channel) == state, row
                        assert cell_slice(row, channel, width - 2) == route, row
                    assert ("CONFIGURED" in header) == (width >= 80), header
                print("CLIENT_CONNECTOR_LAYOUT " + json.dumps({"surface": surface, "width": width,
                      "rows": rows}, ensure_ascii=False), flush=True)
            h.resize_and_wait(process, fd, output, rows=26, columns=100,
                              needle=ready, final_cursor=b"\x1b[?25l")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Clients and Connectors align CJK names with observations",
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


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    run_tables(executable)
    run_read_states(executable, False)
    run_read_states(executable, True)
    print("Client and Connector responsive layout: PASS")
