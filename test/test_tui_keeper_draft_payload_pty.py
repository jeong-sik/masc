"""Switching recipients preserves complete drafts without leaking their media."""
import base64
import json
import os
from pathlib import Path
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui.ml", "bin/masc_tui_types.ml")


def recipient_bound_draft(executable, *, with_text):
    requests = []
    fixtures = h.overview_event_http_fixtures()
    fixtures["/api/v1/keepers/chat/stream"] = h.RequestHttpResponse(
        h.keeper_chat_succeeded_response
    )
    for name in ("alpha", "beta"):
        fixtures[f"/api/v1/keepers/{name}/chat/history"] = (200, [])

    def interact(process, fd, _slave, output, base):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go keepers", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"c", b"Esc:list")
        image = Path(base, h.IMAGE_NAME)
        reference = "https://example.invalid/alpha-draft.png"
        h.send_and_wait(process, fd, output, f"/attach {image}\r".encode(), b"attached ")
        h.send_and_wait(process, fd, output, f"/ref {reference}\r".encode(), b"reference(s)")
        if with_text:
            h.send_and_wait(process, fd, output, b"alpha-draft", h.composer_showing(b"alpha-draft"))
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"beta")
        h.send_and_wait(process, fd, output, b"c", b"Esc:list")
        h.send_and_wait(process, fd, output, b"beta-only\r", b"reply-beta-only")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"c", b"Esc:list")
        if with_text:
            h.wait_for_output(process, fd, output, h.composer_showing(b"alpha-draft"), start=0, timeout=10)
            message = "alpha-draft"
        else:
            # A media-only draft is retained even before text is composed.
            h.send_and_wait(process, fd, output, b"alpha-after-return", h.composer_showing(b"alpha-after-return"))
            message = "alpha-after-return"
        h.send_and_wait(process, fd, output, b"\r", f"reply-{message}".encode())
        sent = [json.loads(body) for path, body in requests if path == "/api/v1/keepers/chat/stream"]
        assert len(sent) == 2, sent
        beta, alpha = sent
        assert (beta["name"], beta["message"]) == ("beta", "beta-only"), beta
        assert not beta.get("attachments"), beta
        assert all(block["type"] == "text" for block in beta.get("user_blocks", [])), beta
        assert (alpha["name"], alpha["message"]) == ("alpha", message), alpha
        assert len(alpha["attachments"]) == 1, alpha
        attachment = alpha["attachments"][0]
        assert attachment["name"] == image.name, attachment
        assert base64.b64decode(attachment["data"]) == image.read_bytes(), attachment
        assert {"type": "image", "url": reference} in alpha["user_blocks"], alpha
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable, description=f"Keeper draft payload with_text={with_text}",
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        prepare_workspace=h.seed_image_workspace,
    )


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    recipient_bound_draft(executable, with_text=True)
    recipient_bound_draft(executable, with_text=False)
    print("Keeper draft payload PTY: PASS (2 scenarios)")
