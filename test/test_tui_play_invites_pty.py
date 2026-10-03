"""TUI play-invite commands use the admin API and keep the one-time link local."""

import json
import os
import sys

import tui_keyboard_harness as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_command.ml",
    "bin/masc_tui_http.ml",
    "bin/masc_tui_play_card.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_types.ml",
    "lib/tui_decode.ml",
    "test/tui_keyboard_harness.py",
)

LINK = "https://play.example.test/play#fixture-secret"
CHAT = "Keepers ▸ alpha ▸ chat".encode()


def assert_only_play_admin_requests(requests):
    for path, body in requests:
        if path in ("/api/v1/play/invites", "/api/v1/play/invites/guest1"):
            continue
        # The observer can initialize MCP while the TUI starts. It must not
        # call a tool, submit a Keeper turn, or send an invite token elsewhere.
        if path == "/mcp":
            try:
                message = json.loads(body)
            except (ValueError, UnicodeDecodeError):
                message = None
            if (isinstance(message, dict) and message.get("jsonrpc") == "2.0"
                    and message.get("method") in ("initialize", "notifications/initialized")):
                continue
        raise AssertionError(f"Play command caused a non-admin effect at {path!r}")


def run(executable: str) -> None:
    requests: h.HttpRequests = []
    revoke_methods: list[str] = []
    list_reads = []
    first_invite = h.GatedHttpResponse(
        (201, {"name": "guest1", "expires_at": "2026-09-30T00:00:00Z", "link": LINK}),
        subsequent_response=(201, {"name": "guest1", "expires_at": "2026-09-30T00:00:00Z", "link": LINK}),
        hold_seconds=10.0,
    )
    revokes = h.SequencedHttpResponse([
        (200, {"name": "guest1", "revoked": True,
               "released_controller": False, "release_error": "disk fault"}),
        (500, {"error": "guest1 holds the DOS controller and it could not be released: "
                        "controller still busy",
               "code": "release_failed", "name": "guest1",
               "released_controller": False, "release_error": "controller still busy"}),
        (200, {"name": "guest1", "revoked": False,
               "released_controller": True}),
        (404, {"error": "no invite is named guest1", "code": "no_such_invite"}),
    ])

    def revoke(method: str) -> h.HttpResponse:
        revoke_methods.append(method)
        return revokes()

    def invites(body: bytes) -> h.HttpResponse:
        if body:
            payload = json.loads(body)
            if payload != {"name": "guest1", "hours": 24}:
                raise AssertionError(f"wrong invite request: {payload!r}")
            return first_invite()
        list_reads.append(True)
        return 200, {"invites": [
            {"name": "guest1", "expires_at": "2026-09-30T00:00:00Z",
             "expired": False, "holds_controller": False},
            {"name": "old", "expires_at": None,
             "expired": False, "holds_controller": False},
        ]}

    def interact(process, master, _slave, output, _base):
        h.send_and_wait(process, master, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, master, output, b"alpha")
        h.send_and_wait(process, master, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, master, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")

        def command(line: bytes, answer: bytes) -> None:
            h.send_and_wait(process, master, output, line, h.composer_showing(line))
            h.send_and_wait(process, master, output, b"\r", answer)

        def close_card() -> None:
            h.send_and_wait(process, master, output, b"\x1b", CHAT)

        # The link is drawn only on its local invite card.
        # Navigating and accepting the picker only changes the draft.
        h.send_and_wait(process, master, output, b"/play ", b"Commands  1/4")
        h.send_and_wait(process, master, output, b"\x1b[B", b"Commands  2/4")
        h.send_and_wait(process, master, output, b"\r", h.composer_showing(b"/play invite"))
        h.drain_until_quiet(process, master, output)
        assert not list_reads and not revoke_methods, "selecting a Play action called the admin API"
        assert not any(path.startswith("/api/v1/play/") for path, _ in requests), "accepting a suggestion executed a Play action"
        assert_only_play_admin_requests(requests)
        # Only an explicit expiry and a further Enter issue the invite.
        h.send_and_wait(process, master, output, b" guest1 24", h.composer_showing(b"/play invite guest1 24"))
        os.write(master, b"\r")
        try:
            assert h.wait_for_fixture_event(process, master, output,
                first_invite.requested, timeout=3.0), "held invite POST did not arrive"
            assert not first_invite.completed.is_set(), "invite response completed before the quit race"
            h.escape_to_keeper_detail(process, master, output, name=b"alpha")
            h.send_and_wait(process, master, output, b"q", b"q: press again to quit")
        finally:
            first_invite.release.set()
        h.wait_for_http_request(process, master, output, requests,
                                path="/api/v1/play/invites")
        h.wait_for_output(process, master, output, LINK.encode(), start=0, timeout=10)
        h.send_and_wait(process, master, output, b"q", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, master, output, b"q", b"q: press again to quit")
        assert process.poll() is None, "card dismissal retained an earlier quit arm"
        h.send_and_wait(process, master, output, b"m", CHAT)
        command(b"/play link", b"MASC Play invite")
        h.wait_for_http_request(process, master, output, requests,
                                path="/api/v1/play/invites")
        close_card()
        h.drain_until_quiet(process, master, output)
        if LINK.encode() in h.screen_text(bytes(output)):
            raise AssertionError("the invite link stayed on screen after its card closed")
        command(b"/play link", b"MASC Play invite")
        close_card()
        command(b"/play invites", b"old \xc2\xb7 expires not recorded")
        command(b"/play revoke guest1", b"retry /play revoke guest1")
        h.wait_for_output(process, master, output, b"disk fault", start=0, timeout=5.0)
        h.wait_for_http_request(process, master, output, requests,
                                path="/api/v1/play/invites/guest1")
        command(b"/play link", b"No play link has been issued")
        command(b"/play revoke guest1", b"controller still busy")
        command(b"/play revoke guest1", b"controller released")
        command(b"/play invite guest1 24", LINK.encode())
        close_card()
        command(b"/play revoke guest1", b"is absent (no invite has that name)")
        command(b"/play link", b"No play link has been issued")
        assert_only_play_admin_requests(requests)
        paths = [path for path, _ in requests]
        if paths.count("/api/v1/play/invites") != 2 or revokes.served != 4:
            raise AssertionError(f"the TUI did not issue and revoke through the play API: {paths!r}")
        if revoke_methods != ["DELETE"] * 4:
            raise AssertionError(f"play revokes used the wrong HTTP methods: {revoke_methods!r}")
        # One Esc leaves the chat for the keeper's detail, not for the list, and
        # how many it takes depends on the turn state: the harness counts.
        h.escape_to_keeper_detail(process, master, output, name=b"alpha")
        os.write(master, b"q")

    h.run_terminal_scenario(
        executable,
        description="TUI issues, recalls, lists and revokes a shared DOS play link",
        interact=interact,
        http_fixtures={
            "/api/v1/play/invites": h.RequestHttpResponse(invites),
            "/api/v1/play/invites/guest1": h.MethodHttpResponse(revoke),
        },
        http_requests=requests,
    )
    print("tui play invites: PASS")


if __name__ == "__main__":
    run(sys.argv[1])
