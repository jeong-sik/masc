"""A /collab command leaves a share card with links and a QR in the chat pane."""
import os
import sys
import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs
# a suite when a pull request changes a path the suite names.
SOURCE_MODULES = (
    "bin/masc_tui_collab_text.ml",
    "bin/masc_tui_command.ml",
    "bin/masc_tui_loader.ml",
    "bin/masc_tui_http.ml",
    "bin/masc_tui.ml",
)

HOST_ANSWER = {
    "ok": True,
    "keeper": "alpha",
    "room_id": "pendar",
    "view_link": "masc-collab://view-sees-only",
    "control_link": "masc-collab://control-steers",
    "web_link": "https://relay.test:8443/r/pendar#view-sees-only-the-room-key",
    "control_web_link": "https://relay.test:8443/r/pendar#control-steers-with-token",
    "base_url": "https://relay.test:8443",
    "resumed": False,
}

STOP_ANSWER = {"ok": True, "keeper": "alpha", "stopped": 1}

# Half-block QR rows draw these; a card without any drew no QR.
QR_BLOCKS = (b"\xe2\x96\x88", b"\xe2\x96\x80", b"\xe2\x96\x84")


def run(executable: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])
    fixtures["/api/v1/keepers/alpha/memory-journal?limit=20"] = (
        200,
        {"keeper": "alpha", "entries": []},
    )
    fixtures["/api/v1/collab/host"] = (200, HOST_ANSWER)
    fixtures["/api/v1/collab/stop"] = (200, STOP_ANSWER)
    requests: h.HttpRequests = []

    def interact(process, master_fd, _slave_fd, output, _base_path):
        h.resize_and_wait(process, master_fd, output, rows=60, columns=140,
                          needle=b"MASC Overview")
        h.send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, master_fd, output, b"alpha")
        h.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        h.send_and_wait(process, master_fd, output, b"/collab",
                        h.composer_showing(b"/collab"))
        h.send_and_wait(process, master_fd, output, b"\r", b"sharing alpha")
        h.wait_for_output(process, master_fd, output, b"scan to join in a browser:",
                          start=0, timeout=10)
        plain = h.screen_text(bytes(output))
        # The chat pane wraps long rows, so the full URL never sits on one
        # row; the room path fragment is the longest contiguous piece.
        for expected in (b"view (browser):", b"control (browser):",
                         b"relay.test:8443/r/pendar"):
            if expected not in plain:
                raise AssertionError(f"share card omitted {expected!r}")
        if not any(block in plain for block in QR_BLOCKS):
            raise AssertionError("share card drew no QR block rows")
        posts = [body for path, body in requests if path == "/api/v1/collab/host"]
        if not posts or b'"alpha"' not in posts[0]:
            raise AssertionError(f"/collab never posted its keeper: {requests!r}")
        h.send_and_wait(process, master_fd, output, b"/collab stop",
                        h.composer_showing(b"/collab stop"))
        h.send_and_wait(process, master_fd, output, b"\r", b"stopped sharing alpha")
        h.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="/collab leaves a share card with links and a QR",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("collab share card: PASS")
