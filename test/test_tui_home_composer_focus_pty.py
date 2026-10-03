"""Mouse entry to Home releases a surface composer and retains its full draft.

Fixture PTY behavior only: navigation must precede an explicit chat send.
"""
import base64
import json
import os
from pathlib import Path
import sys

import test_tui_home_decision_cards_pty as cards
import test_tui_home_journey_pty as home
import test_tui_keyboard_input as h


CHAT_PATH = "/api/v1/keepers/chat/stream"


def mouse_home_retains_composer(executable):
    fixtures, _items, _new = h.approval_selection_http_fixtures()
    fixtures[cards.OPERATOR_PATH] = h.approval_selection_snapshot([])
    fixtures[CHAT_PATH] = h.RequestHttpResponse(h.keeper_chat_succeeded_response)
    fixtures["/api/v1/keepers/beta/chat/history"] = (200, [])
    requests = []
    draft = b"beta-mouse-home-unsent"
    reference = "https://example.invalid/beta-mouse-home.png"
    destination = b"Continue with beta"

    def prepare(base):
        home.seed_goals(base)
        h.seed_image_workspace(base)

    def interact(process, fd, _slave, output, base):
        h.wait_for_output(process, fd, output, b"No decision is waiting",
                          start=0, timeout=10)
        h.palette_go(process, fd, output, b"go keepers", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"beta")
        # Establish a named Home continuation, then compose on the list
        # surface rather than in the chat view's separate key dispatcher.
        h.send_and_wait(process, fd, output, b"c", b"Esc:list")
        image = Path(base, h.IMAGE_NAME)
        h.send_and_wait(process, fd, output, f"/attach {image}\r".encode(), b"attached ")
        h.send_and_wait(process, fd, output, f"/ref {reference}\r".encode(), b"reference(s)")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.send_and_wait(process, fd, output, b"i", h.COMPOSER_FOCUSED)
        h.send_and_wait(process, fd, output, draft, draft)
        h.drain_until_quiet(process, fd, output)
        assert b"MASC Keepers" in h.screen_text(bytes(output))
        home.assert_no_decision_posts(requests)

        # The helper reads the tab's actual terminal cells before emitting
        # SGR press/release; no keyboard escape can release focus first.
        h.press_label_on_screen(process, fd, output, b"Dashboard",
                                row=1, needle=destination)
        h.drain_until_quiet(process, fd, output)
        visible = h.screen_text(bytes(output))
        assert draft not in visible, visible
        assert b"(i to write)" not in visible, visible
        home.assert_no_decision_posts(requests)
        home.select_destination(process, fd, output, destination)
        cards.assert_selected(output, destination)
        # Refresh must keep Home navigation focus. It must not become a
        # character appended to the saved draft or reopen the composer.
        h.send_and_wait(process, fd, output, b"r", b"Enter:open")
        h.drain_until_quiet(process, fd, output)
        cards.assert_selected(output, destination)
        assert draft not in h.screen_text(bytes(output))
        home.assert_no_decision_posts(requests)

        # This Enter opens the selected Home destination; it does not send
        # the formerly focused composer's retained message.
        h.send_and_wait(process, fd, output, b"\r", b"Esc:Dashboard")
        h.drain_until_quiet(process, fd, output)
        restored = h.screen_text(bytes(output))
        assert "Keepers ▸ beta ▸ chat".encode() in restored, restored
        assert draft in restored, restored
        home.assert_no_decision_posts(requests)

        # Only the next, explicitly issued chat Enter may send. Read the
        # entire payload at the HTTP boundary, including retained media.
        h.send_and_wait(process, fd, output, b"\r", b"reply-" + draft)
        sent = [json.loads(body) for path, body in requests if path == CHAT_PATH]
        assert len(sent) == 1, sent
        payload = sent[0]
        assert (payload["name"], payload["message"]) == ("beta", draft.decode()), payload
        assert len(payload["attachments"]) == 1, payload
        attachment = payload["attachments"][0]
        assert attachment["name"] == image.name, attachment
        assert base64.b64decode(attachment["data"]) == image.read_bytes(), attachment
        assert {"type": "image", "url": reference} in payload["user_blocks"], payload
        h.send_and_wait(process, fd, output, b"\x1b", destination)
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable, description="Mouse Dashboard entry blurs and saves beta surface composer",
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        prepare_workspace=prepare, terminal_cols=120,
    )
    home.assert_no_decision_posts([(path, body) for path, body in requests if path != CHAT_PATH])
    assert sum(path == CHAT_PATH for path, _body in requests) == 1, requests


if __name__ == "__main__":
    mouse_home_retains_composer(os.path.abspath(sys.argv[1]))
    print("Home composer focus PTY: PASS (1 scenario)")
