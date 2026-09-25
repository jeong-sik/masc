"""A paused bracketed paste stays one chat draft until its closing marker."""
import json
import os
import sys
import tempfile
import threading
import time
from pathlib import Path

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_paste.ml",
    "bin/masc_tui_paste.mli",
)


def run(executable: str) -> None:
    requests: h.HttpRequests = []

    def interact(process, master_fd, _slave_fd, output, _base_path):
        h.wait_for_output(process, master_fd, output, h.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, master_fd, output, b"alpha")
        h.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")

        os.write(master_fd, h.PASTE_START + b"first line")
        # The old reader treated an idle half-second as the end marker. The
        # next pasted CR then became Return and submitted a fragment.
        h.wait_for_output(process, master_fd, output, b"Paste in progress",
                          start=0, timeout=5.0)
        h.send_and_wait(
            process, master_fd, output,
            b"\rsecond line" + h.PASTE_END,
            b"second line",
        )
        if any(path.endswith("/chat/stream") for path, _ in requests):
            raise AssertionError(f"paste sent before Enter: {requests!r}")

        os.write(master_fd, b"\r")
        body = h.wait_for_http_request(
            process, master_fd, output, requests,
            path="/api/v1/keepers/chat/stream",
        )
        message = json.loads(body).get("message")
        if message != "first line\nsecond line":
            raise AssertionError(f"paste was split or changed: {message!r}")
        h.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="A paused bracketed paste stays one draft",
        interact=interact,
        http_fixtures={
            "/api/v1/keepers/chat/stream":
                (503, {"error": "stop after the paste request capture"}),
        },
        http_requests=requests,
    )

    split_requests: h.HttpRequests = []

    def split_marker_interact(process, master_fd, _slave_fd, output, _base_path):
        h.wait_for_output(process, master_fd, output, h.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, master_fd, output, b"alpha")
        h.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")

        os.write(master_fd, b"\x1b[2")
        time.sleep(0.8)
        os.write(master_fd, b"00~first\rsecond" + h.PASTE_END)
        h.wait_for_output(process, master_fd, output, b"second", start=0, timeout=5.0)
        if any(path.endswith("/chat/stream") for path, _ in split_requests):
            raise AssertionError("split start marker sent a paste fragment")
        os.write(master_fd, b"\r")
        body = h.wait_for_http_request(
            process, master_fd, output, split_requests,
            path="/api/v1/keepers/chat/stream",
        )
        message = json.loads(body).get("message")
        if message != "first\nsecond":
            raise AssertionError(f"split start marker changed the draft: {message!r}")
        h.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="A delayed bracketed paste start still makes one draft",
        interact=split_marker_interact,
        http_fixtures={
            "/api/v1/keepers/chat/stream":
                (503, {"error": "stop after the paste request capture"}),
        },
        http_requests=split_requests,
    )

    truncated_csi_requests: h.HttpRequests = []

    def truncated_csi_interact(process, master_fd, _slave_fd, output, _base_path):
        h.wait_for_output(process, master_fd, output, h.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, master_fd, output, b"alpha")
        h.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")

        # This harness never answers the startup graphics query, so the
        # terminal probe stays in front of the key stream, as it does on any
        # terminal without Kitty graphics. The probe holds this head as a
        # possible paste start; the notice and the Ctrl-C cancel must see
        # that hold, not only the reader's own CSI parameters.
        h.send_and_wait(process, master_fd, output, b"\x1b[200",
                        b"Terminal sequence incomplete")
        h.send_and_wait(process, master_fd, output, b"\x03",
                        b"Incomplete terminal sequence cancelled")
        h.send_and_wait(process, master_fd, output, b"recovered",
                        h.composer_showing(b"recovered"))
        os.write(master_fd, b"\r")
        body = h.wait_for_http_request(
            process, master_fd, output, truncated_csi_requests,
            path="/api/v1/keepers/chat/stream",
        )
        if json.loads(body).get("message") != "recovered":
            raise AssertionError("truncated CSI consumed later chat input")
        h.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Ctrl-C cancels a truncated paste start marker",
        interact=truncated_csi_interact,
        http_fixtures={
            "/api/v1/keepers/chat/stream":
                (503, {"error": "stop after the paste request capture"}),
        },
        http_requests=truncated_csi_requests,
    )

    interrupted_requests: h.HttpRequests = []

    def interrupted_interact(process, master_fd, _slave_fd, output, _base_path):
        h.wait_for_output(process, master_fd, output, h.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, master_fd, output, b"alpha")
        h.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")

        os.write(master_fd, h.PASTE_START + b"first\rsecond")
        # A lost closing marker must not trap all later keys in paste mode.
        # The first Ctrl-C waits for a closing marker. The second restores the
        # draft after a quiet read; the third unlocks input when no marker came.
        h.wait_for_output(process, master_fd, output, b"Paste in progress",
                          start=0, timeout=5.0)
        h.send_and_wait(
            process, master_fd, output, b"\x03", b"Paste end awaited",
        )
        h.wait_for_output(process, master_fd, output, b"Paste quiet",
                          start=0, timeout=5.0)
        h.send_and_wait(
            process, master_fd, output, b"\x03",
            b"Incomplete paste restored",
        )
        h.wait_for_output(process, master_fd, output, b"Paste tail quiet",
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"\x03",
                        b"Paste input unlocked")
        h.send_and_wait(process, master_fd, output, b"\r",
                        b"Recovered draft protected")
        if any(path.endswith("/chat/stream") for path, _ in interrupted_requests):
            raise AssertionError("incomplete paste sent before Enter")

        h.send_and_wait(process, master_fd, output, b"\x07",
                        b"Recovered draft confirmed")
        os.write(master_fd, b"\r")
        body = h.wait_for_http_request(
            process, master_fd, output, interrupted_requests,
            path="/api/v1/keepers/chat/stream",
        )
        message = json.loads(body).get("message")
        if message != "first\nsecond":
            raise AssertionError(f"incomplete paste was lost or split: {message!r}")
        h.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Ctrl-C recovers an incomplete bracketed paste as draft",
        interact=interrupted_interact,
        http_fixtures={
            "/api/v1/keepers/chat/stream":
                (503, {"error": "stop after the paste request capture"}),
        },
        http_requests=interrupted_requests,
    )

    prior_draft_requests: h.HttpRequests = []

    def prior_draft_interact(process, master_fd, _slave_fd, output, _base_path):
        h.wait_for_output(process, master_fd, output, h.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, master_fd, output, b"alpha")
        h.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        h.send_and_wait(process, master_fd, output, b"prior draft",
                        h.composer_showing(b"prior draft"))
        os.write(master_fd, h.PASTE_START)
        h.wait_for_output(process, master_fd, output, b"Paste in progress",
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"\x03", b"Paste end awaited")
        h.wait_for_output(process, master_fd, output, b"Paste quiet",
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"\x03",
                        b"Incomplete paste restored")
        h.wait_for_output(process, master_fd, output, b"Paste tail quiet",
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"\x03",
                        b"Paste input unlocked")
        h.send_and_wait(process, master_fd, output, b"\r",
                        b"Recovered draft protected")
        if any(path.endswith("/chat/stream") for path, _ in prior_draft_requests):
            raise AssertionError("a late CR sent the preexisting draft")
        h.send_and_wait(process, master_fd, output, b"\x15",
                        h.composer_showing(b""))
        h.send_and_wait(process, master_fd, output, b"new draft",
                        h.composer_showing(b"new draft"))
        os.write(master_fd, b"\r")
        body = h.wait_for_http_request(
            process, master_fd, output, prior_draft_requests,
            path="/api/v1/keepers/chat/stream",
        )
        if json.loads(body).get("message") != "new draft":
            raise AssertionError("discard did not release the preexisting draft")
        h.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Empty paste recovery protects a preexisting draft",
        interact=prior_draft_interact,
        http_fixtures={
            "/api/v1/keepers/chat/stream":
                (503, {"error": "stop after the paste request capture"}),
        },
        http_requests=prior_draft_requests,
    )

    image_requests: h.HttpRequests = []

    def image_recovery_interact(process, master_fd, _slave_fd, output, base_path):
        h.seed_image_workspace(base_path)
        h.wait_for_output(process, master_fd, output, h.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, master_fd, output, b"alpha")
        h.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        h.send_and_wait(process, master_fd, output, b"image prompt",
                        h.composer_showing(b"image prompt"))
        image_path = str(Path(base_path, h.IMAGE_NAME)).encode()
        os.write(master_fd, h.PASTE_START + image_path)
        h.wait_for_output(process, master_fd, output, b"Paste in progress",
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"\x03", b"Paste end awaited")
        h.wait_for_output(process, master_fd, output, b"Paste quiet",
                          start=0, timeout=5.0)
        # A recovered image path is attached while the same Pasted event is
        # handled, so its "Attached" notice replaces the generic restore
        # notice before the frame is drawn.
        h.send_and_wait(process, master_fd, output, b"\x03",
                        b"Attached shot.png")
        os.write(master_fd, h.PASTE_END)
        h.wait_for_output(process, master_fd, output, b"Paste tail ended",
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"\r",
                        b"Recovered draft protected")
        h.send_and_wait(process, master_fd, output, b"\x15",
                        h.composer_showing(b""))
        h.send_and_wait(process, master_fd, output, b"text only",
                        h.composer_showing(b"text only"))
        os.write(master_fd, b"\r")
        body = h.wait_for_http_request(
            process, master_fd, output, image_requests,
            path="/api/v1/keepers/chat/stream",
        )
        request = json.loads(body)
        if request.get("message") != "text only" or request.get("attachments"):
            raise AssertionError(f"recovered image survived Ctrl-U: {request!r}")
        h.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Discarding a recovered image also discards its attachment",
        interact=image_recovery_interact,
        http_fixtures={
            "/api/v1/keepers/chat/stream":
                (503, {"error": "stop after the paste request capture"}),
        },
        http_requests=image_requests,
    )

    keeper_requests: h.HttpRequests = []

    def keeper_lock_interact(process, master_fd, _slave_fd, output, _base_path):
        h.wait_for_output(process, master_fd, output, h.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, master_fd, output, b"alpha")
        h.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")

        os.write(master_fd, h.PASTE_START + b"alpha protected")
        h.wait_for_output(process, master_fd, output, b"Paste in progress",
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"\x03", b"Paste end awaited")
        h.wait_for_output(process, master_fd, output, b"Paste quiet",
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"\x03",
                        b"Incomplete paste restored")
        os.write(master_fd, h.PASTE_END)
        h.wait_for_output(process, master_fd, output, b"Paste tail ended",
                          start=0, timeout=5.0)

        h.send_and_wait(process, master_fd, output, b"\x11",
                        b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        h.select_keeper_row(process, master_fd, output, b"beta")
        h.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1mbeta")
        h.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat")
        h.send_and_wait(process, master_fd, output, b"beta safe",
                        h.composer_showing(b"beta safe"))
        os.write(master_fd, b"\r")
        beta_body = h.wait_for_http_request(
            process, master_fd, output, keeper_requests,
            path="/api/v1/keepers/chat/stream",
        )
        if json.loads(beta_body).get("message") != "beta safe":
            raise AssertionError("another Keeper's draft was blocked")
        if any(json.loads(body).get("message") == "alpha protected"
               for path, body in keeper_requests if path.endswith("/chat/stream")):
            raise AssertionError("protected alpha draft was sent")

        h.escape_to_keeper_detail(process, master_fd, output, name=b"beta")
        h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        h.select_keeper_row(process, master_fd, output, b"alpha")
        h.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        h.send_and_wait(process, master_fd, output, b"\r",
                        b"Recovered draft protected")
        h.send_and_wait(process, master_fd, output, b"\x15",
                        h.composer_showing(b""))
        h.send_and_wait(process, master_fd, output, b"alpha new",
                        h.composer_showing(b"alpha new"))
        os.write(master_fd, b"\r")
        deadline = time.monotonic() + 3.0
        while (len([1 for path, _ in keeper_requests
                    if path == "/api/v1/keepers/chat/stream"]) < 2
               and time.monotonic() < deadline):
            h.read_available(master_fd, output)
            time.sleep(0.05)
        bodies = [body for path, body in keeper_requests
                  if path == "/api/v1/keepers/chat/stream"]
        if len(bodies) != 2:
            raise AssertionError(f"expected beta and alpha sends: {keeper_requests!r}")
        alpha_body = bodies[-1]
        if json.loads(alpha_body).get("message") != "alpha new":
            raise AssertionError("Ctrl-U did not release the discarded draft")
        h.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Recovered draft lock follows its Keeper and clears on discard",
        interact=keeper_lock_interact,
        http_fixtures={
            "/api/v1/keepers/chat/stream":
                (503, {"error": "stop after the paste request capture"}),
        },
        http_requests=keeper_requests,
    )

    board_requests: h.HttpRequests = []

    def board_recovery_interact(process, master_fd, _slave_fd, output, _base_path):
        h.wait_for_output(process, master_fd, output, h.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, master_fd, output, b"alpha")
        h.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        h.send_and_wait(process, master_fd, output, b"\x11",
                        b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.palette_go(process, master_fd, output, b"go board", b"MASC Board")
        h.send_and_wait(process, master_fd, output, b"w", b"type to write")
        os.write(master_fd, h.PASTE_START + b"board only")
        h.wait_for_output(process, master_fd, output, b"Paste in progress",
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"\x03", b"Paste end awaited")
        h.wait_for_output(process, master_fd, output, b"Paste quiet",
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"\x03",
                        b"Incomplete paste restored")
        os.write(master_fd, h.PASTE_END)
        h.wait_for_output(process, master_fd, output, b"Paste tail ended",
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"\x1b", b"d:discard")
        h.send_and_wait(process, master_fd, output, b"d", b"MASC Board")
        h.send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, master_fd, output, b"alpha")
        h.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        h.send_and_wait(process, master_fd, output, b"chat safe",
                        h.composer_showing(b"chat safe"))
        os.write(master_fd, b"\r")
        body = h.wait_for_http_request(
            process, master_fd, output, board_requests,
            path="/api/v1/keepers/chat/stream",
        )
        if json.loads(body).get("message") != "chat safe":
            raise AssertionError("Board paste recovery locked an unrelated chat")
        h.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Board paste recovery does not lock a previous Keeper",
        interact=board_recovery_interact,
        http_fixtures={
            "/api/v1/keepers/chat/stream":
                (503, {"error": "stop after the paste request capture"}),
        },
        http_requests=board_requests,
    )

    late_tail_requests: h.HttpRequests = []

    def late_tail_interact(process, master_fd, _slave_fd, output, _base_path):
        h.wait_for_output(process, master_fd, output, h.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, master_fd, output, b"alpha")
        h.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")

        os.write(master_fd, h.PASTE_START + b"first\x1b[20")
        h.wait_for_output(process, master_fd, output, b"Paste in progress",
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"\x03", b"Paste end awaited")
        h.wait_for_output(process, master_fd, output, b"Paste quiet",
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"\x03",
                        b"Incomplete paste restored")
        # The original decoder has already matched ESC[20. The delayed 1~
        # must close the recovery guard. Bytes after the marker are keys
        # again, so the CR that must stay unsent is sent on its own below.
        h.send_and_wait(process, master_fd, output, b"1~", b"Paste tail ended")
        h.send_and_wait(process, master_fd, output, b"\r",
                        b"Recovered draft protected")
        if any(path.endswith("/chat/stream") for path, _ in late_tail_requests):
            raise AssertionError("late paste newline sent the recovered draft")
        h.send_and_wait(process, master_fd, output, b"\x07",
                        b"Recovered draft confirmed")
        os.write(master_fd, b"\r")
        body = h.wait_for_http_request(
            process, master_fd, output, late_tail_requests,
            path="/api/v1/keepers/chat/stream",
        )
        message = json.loads(body).get("message")
        if message != "first":
            raise AssertionError(f"recovered draft retained marker bytes: {message!r}")
        h.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Late marker suffix and CR cannot send a recovered draft",
        interact=late_tail_interact,
        http_fixtures={
            "/api/v1/keepers/chat/stream":
                (503, {"error": "stop after the paste request capture"}),
        },
        http_requests=late_tail_requests,
    )

    def continuous_interact(process, master_fd, _slave_fd, output, _base_path):
        h.wait_for_output(process, master_fd, output, h.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, master_fd, output, b"alpha")
        h.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        os.write(master_fd, h.PASTE_START + b"continuous")
        h.wait_for_output(process, master_fd, output, b"Paste in progress",
                          start=0, timeout=5.0)
        stop = threading.Event()

        def feed():
            while not stop.is_set():
                os.write(master_fd, b"more")
                time.sleep(0.08)

        producer = threading.Thread(target=feed, daemon=True)
        producer.start()
        try:
            time.sleep(0.2)
            h.send_and_wait(
                process, master_fd, output, b"\x03",
                b"Paste end awaited",
            )
        finally:
            stop.set()
            producer.join(timeout=2.0)
        start = len(output)
        os.write(master_fd, b"\rrest" + h.PASTE_END)
        h.wait_for_output(process, master_fd, output, b"rest", start=start,
                          timeout=5.0)
        if any(path.endswith("/chat/stream") for path, _ in continuous_requests):
            raise AssertionError("remaining paste newline was treated as Enter")
        h.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    continuous_requests: h.HttpRequests = []

    h.run_terminal_scenario(
        executable,
        description="Ctrl-C recovers while paste bytes keep arriving",
        interact=continuous_interact,
        http_requests=continuous_requests,
    )

    def editor_interact(process, master_fd, _slave_fd, output, _base_path):
        h.wait_for_output(process, master_fd, output, h.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        h.palette_go(process, master_fd, output, b"go board", b"MASC Board")
        h.send_and_wait(process, master_fd, output, b"w", b"MASC Board")
        start = len(output)
        h.send_and_wait(process, master_fd, output, b"\x05",
                        b"Board draft updated from editor")
        if h.BRACKETED_PASTE_ON not in output[start:]:
            raise AssertionError("bracketed paste was not reenabled after $EDITOR")
        h.send_and_wait(process, master_fd, output, b"\x1b", b"d:discard")
        h.send_and_wait(process, master_fd, output, b"d", b"MASC Board")
        os.write(master_fd, b"q")

    with tempfile.TemporaryDirectory(prefix="masc-tui-paste-editor-") as directory:
        editor = Path(directory, "editor.sh")
        editor.write_text(
            "#!/bin/sh\n"
            "printf '%s' 'draft from editor' > \"$1\"\n"
            "printf '\\033[?2004l'\n"
        )
        editor.chmod(0o755)
        h.run_terminal_scenario(
            executable,
            description="Bracketed paste is reenabled after an editor returns",
            interact=editor_interact,
            extra_env={"EDITOR": str(editor)},
        )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("paused bracketed paste: PASS")
