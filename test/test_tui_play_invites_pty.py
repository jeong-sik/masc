"""TUI play-invite commands use the admin API and keep the one-time link local."""

import json
import os
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_command.ml",
    "bin/masc_tui_http.ml",
)

LINK = "https://play.example.test/play#fixture-secret"


def run(executable: str) -> None:
    requests: h.HttpRequests = []

    def invites(body: bytes) -> h.HttpResponse:
        if body:
            payload = json.loads(body)
            if payload != {"name": "guest1", "hours": 24}:
                raise AssertionError(f"wrong invite request: {payload!r}")
            return 201, {"name": "guest1", "expires_at": "2026-09-30T00:00:00Z", "link": LINK}
        return 200, {"invites": [
            {"name": "guest1", "expires_at": "2026-09-30T00:00:00Z",
             "expired": False, "holds_controller": False},
            {"name": "old", "expires_at": None,
             "expired": False, "holds_controller": False},
        ]}

    def interact(process, master, _slave, output, _base):
        h.send_and_wait(process, master, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, master, output, b"alpha")
        h.send_and_wait(process, master, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, master, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")

        def command(line: bytes, answer: bytes) -> None:
            h.send_and_wait(process, master, output, line, h.composer_showing(line))
            h.send_and_wait(process, master, output, b"\r", answer)

        command(b"/play invite guest1 24", LINK.encode())
        h.wait_for_http_request(process, master, output, requests,
                                path="/api/v1/play/invites")
        command(b"/play link", b"Last play link issued")
        command(b"/play invites", b"old \xc2\xb7 expires not recorded")
        command(b"/play revoke guest1", b"controller released")
        h.wait_for_http_request(process, master, output, requests,
                                path="/api/v1/play/invites/guest1")
        command(b"/play link", b"No play link has been issued")
        paths = [path for path, _ in requests]
        if paths.count("/api/v1/play/invites") != 1 or "/api/v1/play/invites/guest1" not in paths:
            raise AssertionError(f"the TUI did not issue and revoke through the play API: {paths!r}")
        h.send_and_wait(process, master, output, b"\x1b", b"MASC Keepers")
        os.write(master, b"q")

    h.run_terminal_scenario(
        executable,
        description="TUI issues, recalls, lists and revokes a shared DOS play link",
        interact=interact,
        http_fixtures={
            "/api/v1/play/invites": h.RequestHttpResponse(invites),
            "/api/v1/play/invites/guest1":
                (200, {"name": "guest1", "revoked": True, "released_controller": True}),
        },
        http_requests=requests,
    )
    print("tui play invites: PASS")


if __name__ == "__main__":
    run(sys.argv[1])
