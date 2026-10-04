"""A paused bracketed paste stays one chat draft until its closing marker."""
import json
import os
import sys
import tempfile
import threading
import time
from pathlib import Path

import tui_keyboard_chat as _keyboard_chat
import tui_keyboard_harness as _keyboard_harness




def run(executable: str) -> None:
    requests: _keyboard_harness.HttpRequests = []

    def interact(process, master_fd, _slave_fd, output, _base_path):
        _keyboard_harness.wait_for_output(process, master_fd, output, _keyboard_chat.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        _keyboard_harness.select_keeper_row(process, master_fd, output, b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")

        os.write(master_fd, _keyboard_chat.PASTE_START + b"first line")
        # The old reader treated an idle half-second as the end marker. The
        # next pasted CR then became Return and submitted a fragment.
        _keyboard_harness.wait_for_output(process, master_fd, output, b"Paste in progress",
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(
            process, master_fd, output,
            b"\rsecond line" + _keyboard_chat.PASTE_END,
            b"second line",
        )
        if any(path.endswith("/chat/stream") for path, _ in requests):
            raise AssertionError(f"paste sent before Enter: {requests!r}")

        os.write(master_fd, b"\r")
        body = _keyboard_harness.wait_for_http_request(
            process, master_fd, output, requests,
            path="/api/v1/keepers/chat/stream",
        )
        message = json.loads(body).get("message")
        if message != "first line\nsecond line":
            raise AssertionError(f"paste was split or changed: {message!r}")
        _keyboard_harness.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="A paused bracketed paste stays one draft",
        interact=interact,
        http_fixtures={
            "/api/v1/keepers/chat/stream":
                (503, {"error": "stop after the paste request capture"}),
        },
        http_requests=requests,
    )

    split_requests: _keyboard_harness.HttpRequests = []

    def split_marker_interact(process, master_fd, _slave_fd, output, _base_path):
        _keyboard_harness.wait_for_output(process, master_fd, output, _keyboard_chat.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        _keyboard_harness.select_keeper_row(process, master_fd, output, b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")

        os.write(master_fd, b"\x1b[2")
        time.sleep(0.8)
        os.write(master_fd, b"00~first\rsecond" + _keyboard_chat.PASTE_END)
        _keyboard_harness.wait_for_output(process, master_fd, output, b"second", start=0, timeout=5.0)
        if any(path.endswith("/chat/stream") for path, _ in split_requests):
            raise AssertionError("split start marker sent a paste fragment")
        os.write(master_fd, b"\r")
        body = _keyboard_harness.wait_for_http_request(
            process, master_fd, output, split_requests,
            path="/api/v1/keepers/chat/stream",
        )
        message = json.loads(body).get("message")
        if message != "first\nsecond":
            raise AssertionError(f"split start marker changed the draft: {message!r}")
        _keyboard_harness.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="A delayed bracketed paste start still makes one draft",
        interact=split_marker_interact,
        http_fixtures={
            "/api/v1/keepers/chat/stream":
                (503, {"error": "stop after the paste request capture"}),
        },
        http_requests=split_requests,
    )

    truncated_csi_requests: _keyboard_harness.HttpRequests = []

    def truncated_csi_interact(process, master_fd, _slave_fd, output, _base_path):
        _keyboard_harness.wait_for_output(process, master_fd, output, _keyboard_chat.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        _keyboard_harness.select_keeper_row(process, master_fd, output, b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")

        # This harness never answers the startup graphics query, so the
        # terminal probe stays in front of the key stream, as it does on any
        # terminal without Kitty graphics. The probe holds this head as a
        # possible paste start; the notice and the Ctrl-C cancel must see
        # that hold, not only the reader's own CSI parameters.
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b[200",
                        b"Terminal sequence incomplete")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x03",
                        b"Incomplete terminal sequence cancelled")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"recovered",
                        _keyboard_harness.composer_showing(b"recovered"))
        os.write(master_fd, b"\r")
        body = _keyboard_harness.wait_for_http_request(
            process, master_fd, output, truncated_csi_requests,
            path="/api/v1/keepers/chat/stream",
        )
        if json.loads(body).get("message") != "recovered":
            raise AssertionError("truncated CSI consumed later chat input")
        _keyboard_harness.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Ctrl-C cancels a truncated paste start marker",
        interact=truncated_csi_interact,
        http_fixtures={
            "/api/v1/keepers/chat/stream":
                (503, {"error": "stop after the paste request capture"}),
        },
        http_requests=truncated_csi_requests,
    )

    interrupted_requests: _keyboard_harness.HttpRequests = []

    def interrupted_interact(process, master_fd, _slave_fd, output, _base_path):
        _keyboard_harness.wait_for_output(process, master_fd, output, _keyboard_chat.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        _keyboard_harness.select_keeper_row(process, master_fd, output, b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")

        os.write(master_fd, _keyboard_chat.PASTE_START + b"first\rsecond")
        # A lost closing marker must not trap all later keys in paste mode.
        # The first Ctrl-C waits for a closing marker. The second restores the
        # draft after a quiet read; the third unlocks input when no marker came.
        _keyboard_harness.wait_for_output(process, master_fd, output, b"Paste in progress",
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(
            process, master_fd, output, b"\x03", b"Paste end awaited",
        )
        _keyboard_harness.wait_for_output(process, master_fd, output, b"Paste quiet",
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(
            process, master_fd, output, b"\x03",
            b"Incomplete paste restored",
        )
        _keyboard_harness.wait_for_output(process, master_fd, output, b"Paste tail quiet",
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x03",
                        b"Paste input unlocked")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\r",
                        b"Recovered draft protected")
        if any(path.endswith("/chat/stream") for path, _ in interrupted_requests):
            raise AssertionError("incomplete paste sent before Enter")

        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x07",
                        b"Recovered draft confirmed")
        os.write(master_fd, b"\r")
        body = _keyboard_harness.wait_for_http_request(
            process, master_fd, output, interrupted_requests,
            path="/api/v1/keepers/chat/stream",
        )
        message = json.loads(body).get("message")
        if message != "first\nsecond":
            raise AssertionError(f"incomplete paste was lost or split: {message!r}")
        _keyboard_harness.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Ctrl-C recovers an incomplete bracketed paste as draft",
        interact=interrupted_interact,
        http_fixtures={
            "/api/v1/keepers/chat/stream":
                (503, {"error": "stop after the paste request capture"}),
        },
        http_requests=interrupted_requests,
    )

    prior_draft_requests: _keyboard_harness.HttpRequests = []

    def prior_draft_interact(process, master_fd, _slave_fd, output, _base_path):
        _keyboard_harness.wait_for_output(process, master_fd, output, _keyboard_chat.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        _keyboard_harness.select_keeper_row(process, master_fd, output, b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"prior draft",
                        _keyboard_harness.composer_showing(b"prior draft"))
        os.write(master_fd, _keyboard_chat.PASTE_START)
        _keyboard_harness.wait_for_output(process, master_fd, output, b"Paste in progress",
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x03", b"Paste end awaited")
        _keyboard_harness.wait_for_output(process, master_fd, output, b"Paste quiet",
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x03",
                        b"Incomplete paste restored")
        _keyboard_harness.wait_for_output(process, master_fd, output, b"Paste tail quiet",
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x03",
                        b"Paste input unlocked")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\r",
                        b"Recovered draft protected")
        if any(path.endswith("/chat/stream") for path, _ in prior_draft_requests):
            raise AssertionError("a late CR sent the preexisting draft")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x15",
                        _keyboard_harness.composer_showing(b""))
        _keyboard_harness.send_and_wait(process, master_fd, output, b"new draft",
                        _keyboard_harness.composer_showing(b"new draft"))
        os.write(master_fd, b"\r")
        body = _keyboard_harness.wait_for_http_request(
            process, master_fd, output, prior_draft_requests,
            path="/api/v1/keepers/chat/stream",
        )
        if json.loads(body).get("message") != "new draft":
            raise AssertionError("discard did not release the preexisting draft")
        _keyboard_harness.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Empty paste recovery protects a preexisting draft",
        interact=prior_draft_interact,
        http_fixtures={
            "/api/v1/keepers/chat/stream":
                (503, {"error": "stop after the paste request capture"}),
        },
        http_requests=prior_draft_requests,
    )

    image_requests: _keyboard_harness.HttpRequests = []

    def image_recovery_interact(process, master_fd, _slave_fd, output, base_path):
        _keyboard_chat.seed_image_workspace(base_path)
        _keyboard_harness.wait_for_output(process, master_fd, output, _keyboard_chat.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        _keyboard_harness.select_keeper_row(process, master_fd, output, b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"image prompt",
                        _keyboard_harness.composer_showing(b"image prompt"))
        image_path = str(Path(base_path, _keyboard_chat.IMAGE_NAME)).encode()
        os.write(master_fd, _keyboard_chat.PASTE_START + image_path)
        _keyboard_harness.wait_for_output(process, master_fd, output, b"Paste in progress",
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x03", b"Paste end awaited")
        _keyboard_harness.wait_for_output(process, master_fd, output, b"Paste quiet",
                          start=0, timeout=5.0)
        # A recovered image path is attached while the same Pasted event is
        # handled, so its "Attached" notice replaces the generic restore
        # notice before the frame is drawn.
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x03",
                        b"Attached shot.png")
        os.write(master_fd, _keyboard_chat.PASTE_END)
        _keyboard_harness.wait_for_output(process, master_fd, output, b"Paste tail ended",
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\r",
                        b"Recovered draft protected")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x15",
                        _keyboard_harness.composer_showing(b""))
        _keyboard_harness.send_and_wait(process, master_fd, output, b"text only",
                        _keyboard_harness.composer_showing(b"text only"))
        os.write(master_fd, b"\r")
        body = _keyboard_harness.wait_for_http_request(
            process, master_fd, output, image_requests,
            path="/api/v1/keepers/chat/stream",
        )
        request = json.loads(body)
        if request.get("message") != "text only" or request.get("attachments"):
            raise AssertionError(f"recovered image survived Ctrl-U: {request!r}")
        _keyboard_harness.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Discarding a recovered image also discards its attachment",
        interact=image_recovery_interact,
        http_fixtures={
            "/api/v1/keepers/chat/stream":
                (503, {"error": "stop after the paste request capture"}),
        },
        http_requests=image_requests,
    )

    keeper_requests: _keyboard_harness.HttpRequests = []

    def keeper_lock_interact(process, master_fd, _slave_fd, output, _base_path):
        _keyboard_harness.wait_for_output(process, master_fd, output, _keyboard_chat.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        _keyboard_harness.select_keeper_row(process, master_fd, output, b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")

        os.write(master_fd, _keyboard_chat.PASTE_START + b"alpha protected")
        _keyboard_harness.wait_for_output(process, master_fd, output, b"Paste in progress",
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x03", b"Paste end awaited")
        _keyboard_harness.wait_for_output(process, master_fd, output, b"Paste quiet",
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x03",
                        b"Incomplete paste restored")
        os.write(master_fd, _keyboard_chat.PASTE_END)
        _keyboard_harness.wait_for_output(process, master_fd, output, b"Paste tail ended",
                          start=0, timeout=5.0)

        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x11",
                        b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        _keyboard_harness.select_keeper_row(process, master_fd, output, b"beta")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1mbeta")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"beta safe",
                        _keyboard_harness.composer_showing(b"beta safe"))
        os.write(master_fd, b"\r")
        beta_body = _keyboard_harness.wait_for_http_request(
            process, master_fd, output, keeper_requests,
            path="/api/v1/keepers/chat/stream",
        )
        if json.loads(beta_body).get("message") != "beta safe":
            raise AssertionError("another Keeper's draft was blocked")
        if any(json.loads(body).get("message") == "alpha protected"
               for path, body in keeper_requests if path.endswith("/chat/stream")):
            raise AssertionError("protected alpha draft was sent")

        _keyboard_harness.escape_to_keeper_detail(process, master_fd, output, name=b"beta")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        _keyboard_harness.select_keeper_row(process, master_fd, output, b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\r",
                        b"Recovered draft protected")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x15",
                        _keyboard_harness.composer_showing(b""))
        _keyboard_harness.send_and_wait(process, master_fd, output, b"alpha new",
                        _keyboard_harness.composer_showing(b"alpha new"))
        os.write(master_fd, b"\r")
        # The fixture answers 503, which the TUI treats as an unverified
        # outcome: it re-POSTs the same request_id every half second to
        # reconcile (the server refuses a second turn for one id). So beta's
        # request repeats, and a count of chat/stream requests says nothing
        # about alpha. Wait for a request addressed to alpha instead.
        def chat_sends(name):
            return [json.loads(body) for path, body in list(keeper_requests)
                    if path == "/api/v1/keepers/chat/stream"
                    and json.loads(body).get("name") == name]

        deadline = time.monotonic() + 3.0
        while not chat_sends("alpha") and time.monotonic() < deadline:
            _keyboard_harness.read_available(master_fd, output)
            time.sleep(0.05)
        alpha_messages = {send.get("message") for send in chat_sends("alpha")}
        if alpha_messages != {"alpha new"}:
            raise AssertionError(
                f"Ctrl-U did not release the discarded draft: {keeper_requests!r}")
        if {send.get("message") for send in chat_sends("beta")} != {"beta safe"}:
            raise AssertionError(f"beta sent something else: {keeper_requests!r}")
        _keyboard_harness.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Recovered draft lock follows its Keeper and clears on discard",
        interact=keeper_lock_interact,
        http_fixtures={
            "/api/v1/keepers/chat/stream":
                (503, {"error": "stop after the paste request capture"}),
        },
        http_requests=keeper_requests,
    )

    board_requests: _keyboard_harness.HttpRequests = []

    def board_recovery_interact(process, master_fd, _slave_fd, output, _base_path):
        _keyboard_harness.wait_for_output(process, master_fd, output, _keyboard_chat.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        _keyboard_harness.select_keeper_row(process, master_fd, output, b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x11",
                        b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        _keyboard_harness.palette_go(process, master_fd, output, b"go board", b"MASC Board")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"w", b"type to write")
        os.write(master_fd, _keyboard_chat.PASTE_START + b"board only")
        _keyboard_harness.wait_for_output(process, master_fd, output, b"Paste in progress",
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x03", b"Paste end awaited")
        _keyboard_harness.wait_for_output(process, master_fd, output, b"Paste quiet",
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x03",
                        b"Incomplete paste restored")
        os.write(master_fd, _keyboard_chat.PASTE_END)
        _keyboard_harness.wait_for_output(process, master_fd, output, b"Paste tail ended",
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b", b"d:discard")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"d", b"MASC Board")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        _keyboard_harness.select_keeper_row(process, master_fd, output, b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"chat safe",
                        _keyboard_harness.composer_showing(b"chat safe"))
        os.write(master_fd, b"\r")
        body = _keyboard_harness.wait_for_http_request(
            process, master_fd, output, board_requests,
            path="/api/v1/keepers/chat/stream",
        )
        if json.loads(body).get("message") != "chat safe":
            raise AssertionError("Board paste recovery locked an unrelated chat")
        _keyboard_harness.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Board paste recovery does not lock a previous Keeper",
        interact=board_recovery_interact,
        http_fixtures={
            "/api/v1/keepers/chat/stream":
                (503, {"error": "stop after the paste request capture"}),
        },
        http_requests=board_requests,
    )

    late_tail_requests: _keyboard_harness.HttpRequests = []

    def late_tail_interact(process, master_fd, _slave_fd, output, _base_path):
        _keyboard_harness.wait_for_output(process, master_fd, output, _keyboard_chat.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        _keyboard_harness.select_keeper_row(process, master_fd, output, b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")

        os.write(master_fd, _keyboard_chat.PASTE_START + b"first\x1b[20")
        _keyboard_harness.wait_for_output(process, master_fd, output, b"Paste in progress",
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x03", b"Paste end awaited")
        _keyboard_harness.wait_for_output(process, master_fd, output, b"Paste quiet",
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x03",
                        b"Incomplete paste restored")
        # The original decoder has already matched ESC[20. The delayed 1~
        # must close the recovery guard. Bytes after the marker are keys
        # again, so the CR that must stay unsent is sent on its own below.
        _keyboard_harness.send_and_wait(process, master_fd, output, b"1~", b"Paste tail ended")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\r",
                        b"Recovered draft protected")
        if any(path.endswith("/chat/stream") for path, _ in late_tail_requests):
            raise AssertionError("late paste newline sent the recovered draft")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x07",
                        b"Recovered draft confirmed")
        os.write(master_fd, b"\r")
        body = _keyboard_harness.wait_for_http_request(
            process, master_fd, output, late_tail_requests,
            path="/api/v1/keepers/chat/stream",
        )
        message = json.loads(body).get("message")
        if message != "first":
            raise AssertionError(f"recovered draft retained marker bytes: {message!r}")
        _keyboard_harness.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    _keyboard_harness.run_terminal_scenario(
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
        _keyboard_harness.wait_for_output(process, master_fd, output, _keyboard_chat.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        _keyboard_harness.select_keeper_row(process, master_fd, output, b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        os.write(master_fd, _keyboard_chat.PASTE_START + b"continuous")
        _keyboard_harness.wait_for_output(process, master_fd, output, b"Paste in progress",
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
            _keyboard_harness.send_and_wait(
                process, master_fd, output, b"\x03",
                b"Paste end awaited",
            )
        finally:
            stop.set()
            producer.join(timeout=2.0)
        start = len(output)
        os.write(master_fd, b"\rrest" + _keyboard_chat.PASTE_END)
        _keyboard_harness.wait_for_output(process, master_fd, output, b"rest", start=start,
                          timeout=5.0)
        if any(path.endswith("/chat/stream") for path, _ in continuous_requests):
            raise AssertionError("remaining paste newline was treated as Enter")
        _keyboard_harness.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    continuous_requests: _keyboard_harness.HttpRequests = []

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Ctrl-C recovers while paste bytes keep arriving",
        interact=continuous_interact,
        http_requests=continuous_requests,
    )

    def editor_interact(process, master_fd, _slave_fd, output, _base_path):
        _keyboard_harness.wait_for_output(process, master_fd, output, _keyboard_chat.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        _keyboard_harness.palette_go(process, master_fd, output, b"go board", b"MASC Board")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"w", b"MASC Board")
        start = len(output)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x05",
                        b"Board draft updated from editor")
        if _keyboard_chat.BRACKETED_PASTE_ON not in output[start:]:
            raise AssertionError("bracketed paste was not reenabled after $EDITOR")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b", b"d:discard")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"d", b"MASC Board")
        os.write(master_fd, b"q")

    with tempfile.TemporaryDirectory(prefix="masc-tui-paste-editor-") as directory:
        editor = Path(directory, "editor.sh")
        editor.write_text(
            "#!/bin/sh\n"
            "printf '%s' 'draft from editor' > \"$1\"\n"
            "printf '\\033[?2004l'\n"
        )
        editor.chmod(0o755)
        _keyboard_harness.run_terminal_scenario(
            executable,
            description="Bracketed paste is reenabled after an editor returns",
            interact=editor_interact,
            extra_env={"EDITOR": str(editor)},
        )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("paused bracketed paste: PASS")
