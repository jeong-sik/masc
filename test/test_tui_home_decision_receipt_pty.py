"""Fixture journeys: accepted confirmation is not applied; asks retain drafts.

Receipt wire authority: test_tui_operator_projection.ml confirm_response and
test_confirm_response_status; masc_tui_operator_projection.ml
decode_confirm_envelope. These are fixture observations, not runtime proof.
"""
import base64
import copy
import json
import os
from pathlib import Path
import sys
import threading

import test_tui_home_decision_cards_pty as cards
import test_tui_home_journey_pty as home
import tui_keyboard_harness as h
import tui_keyboard_approvals as approvals
import tui_keyboard_chat as chat


TOKEN = "home-a"
CONFIRM_PATH = "/api/v1/operator/confirm"
CHAT_PATH = "/api/v1/keepers/chat/stream"
DEFERRED = b"Confirmation accepted; action deferred:"


def accepted_but_pending(executable, *, followed_by_held=False):
    fixtures, items, _new = h.approval_selection_http_fixtures()
    item = dict(items[0], confirm_token=TOKEN, trace_id=f"trace-{TOKEN}",
                payload={"reason": "home-receipt-exact-reason"})
    requests = []
    lock = threading.Lock()
    current = [item]
    observations = []
    confirmed = threading.Event()

    def listing():
        with lock:
            rows = copy.deepcopy(current)
            observations.append((confirmed.is_set(), rows))
        return h.approval_selection_snapshot(rows)

    def confirm(body):
        assert json.loads(body) == {"confirm_token": TOKEN, "decision": "confirm"}
        confirmed.set()
        # The source's deferred receipt accepts the decision but keeps its
        # exact request in the authoritative pending list until later apply.
        return 200, {
            "status": "deferred", "trace_id": item["trace_id"],
            "decision": "confirm", "tool_name": item["delegated_tool"],
            "result": {}, "executed_action": copy.deepcopy(item),
        }

    fixtures[cards.OPERATOR_PATH] = listing
    fixtures[CONFIRM_PATH] = h.RequestHttpResponse(confirm)
    held_path = "/api/v1/keepers/tool-approval"
    held_rows = []
    held_item = cards.held("call-after-receipt", "new-held-decision")

    def answer_held(body):
        payload = json.loads(body)
        assert payload["name"] == held_item["keeper"]
        assert payload["tool_call_id"] == "call-after-receipt"
        assert payload["decision"] == "approve"
        assert payload["expected_workspace"] == {
            "base_path": "",
            "masc_root": "",
        }
        held_rows.clear()
        return 200, {"settled": True, "remembered": False}

    if followed_by_held:
        fixtures[cards.HELD_PATH] = lambda: (200, {"pending": copy.deepcopy(held_rows)})
        fixtures[held_path] = h.RequestHttpResponse(answer_held)

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"[home-a]", start=0, timeout=10)
        cards.select_home(process, fd, output, b"[home-a]", destinations=3)
        opened = h.send_and_wait(process, fd, output, b"\r",
                                 b"home-receipt-exact-reason")
        assert b"home-receipt-exact-reason" in h.screen_text(opened)
        home.assert_no_decision_posts(requests)
        h.send_and_wait(process, fd, output, b"y", b"Press y again: namespace_pause")
        home.assert_no_decision_posts(requests)
        accepted = h.send_and_wait(process, fd, output, b"y", DEFERRED)
        assert confirmed.is_set(), "second y did not confirm the exact request"

        def fresh_pending():
            with lock:
                return any(after and rows == [item] for after, rows in observations)

        assert h.wait_for_fixture_state(process, fd, output, fresh_pending, timeout=5), (
            "no fresh post-confirm list retained the exact request", observations)
        assert b"Confirmed:" not in h.screen_text(accepted), accepted
        h.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
        visible = cards.frame(process, fd, output, "accepted-still-pending")
        assert b"[home-a]" in visible and b"namespace_pause" in visible, visible
        assert b"Approvals and questions: 1 need you" in visible, visible
        assert DEFERRED in visible, visible
        assert b"Confirmed:" not in visible and b"No decision is waiting" not in visible
        cards.assert_selected(output, b"[home-a]")
        # Reopen the retained Home identity; navigating cannot replay the POST.
        h.send_and_wait(process, fd, output, b"\r", b"home-receipt-exact-reason")
        h.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
        if followed_by_held:
            # Navigation and operator arming retain the old receipt. Only
            # dispatching the newer held decision supersedes it.
            h.send_and_wait(process, fd, output, b"\r", b"home-receipt-exact-reason")
            h.send_and_wait(process, fd, output, b"y", b"Press y again: namespace_pause")
            h.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
            assert DEFERRED in cards.frame(process, fd, output, "receipt-after-arming")
            held_rows.append(held_item)
            h.send_and_wait(process, fd, output, b"r", b"new-held-decision")
            cards.select_home(process, fd, output, b"new-held-decision", destinations=4)
            h.send_and_wait(process, fd, output, b"\r", b"call-after-receipt")
            home.assert_no_decision_posts([(path, body) for path, body in requests
                                          if path != CONFIRM_PATH])
            h.send_and_wait(process, fd, output, b"y", b"allowed ")
            h.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
            visible = cards.frame(process, fd, output, "receipt-superseded-by-held")
            assert DEFERRED not in visible and b"Last decision receipt" not in visible, visible
            assert sum(path == held_path for path, _ in requests) == 1, requests
            os.write(fd, b"q")
            return
        with lock:
            current.clear()
            before = len(observations)
        h.send_and_wait(process, fd, output, b"r", b"No decision is waiting")

        def fresh_empty():
            with lock:
                return any(after and not rows for after, rows in observations[before:])

        assert h.wait_for_fixture_state(process, fd, output, fresh_empty, timeout=5)
        visible = cards.frame(process, fd, output, "later-source-removal")
        assert b"No decision is waiting" in visible and b"[home-a]" not in visible, visible
        # The removed selection cannot fall through to another authority or
        # replay the accepted action, even with explicit confirmation keys.
        os.write(fd, b"\ryy")
        h.drain_until_quiet(process, fd, output)
        assert sum(path == CONFIRM_PATH for path, _body in requests) == 1, requests
        fixtures[cards.OPERATOR_PATH] = (503, {"error": "confirm source offline"})
        h.send_and_wait(process, fd, output, b"r", b"confirm queue not fully read")
        visible = cards.frame(process, fd, output, "removed-request-source-unavailable")
        assert b"No decision is waiting" not in visible and b"[home-a]" not in visible, visible
        os.write(fd, b"\ryy")
        h.drain_until_quiet(process, fd, output)
        assert sum(path == CONFIRM_PATH for path, _body in requests) == 1, requests
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable, description="Home accepted confirmation stays pending until source removal",
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        prepare_workspace=home.seed_goals, refresh=60.0,
    )
    confirmations = [(path, body) for path, body in requests if path == CONFIRM_PATH]
    assert len(confirmations) == 1, confirmations
    assert json.loads(confirmations[0][1]) == {"confirm_token": TOKEN, "decision": "confirm"}
    home.assert_no_decision_posts([(path, body) for path, body in requests
                                  if path not in (CONFIRM_PATH, held_path)])
    assert sum(path == held_path for path, _ in requests) == int(followed_by_held), requests


def background_ask_keeps_beta_draft(executable):
    fixtures, _items, _new = h.approval_selection_http_fixtures()
    fixtures[cards.OPERATOR_PATH] = h.approval_selection_snapshot([])
    requests = []
    ask_arrives = threading.Event()
    ask = copy.deepcopy(approvals.keeper_asks_response())
    ask[1]["asks"][0].update(ask_id="ask-home-bg", context="background-alpha-question")
    empty = (200, {"keeper": None, "open_count": 0, "asks": []})
    fixtures[h.KEEPER_ASKS_PATH] = lambda: copy.deepcopy(ask if ask_arrives.is_set() else empty)
    fixtures[CHAT_PATH] = h.RequestHttpResponse(chat.keeper_chat_succeeded_response)
    for name in ("alpha", "beta"):
        fixtures[f"/api/v1/keepers/{name}/chat/history"] = (200, [])
    draft = "beta first line\nbeta second line\nbeta final line"
    reference = "https://example.invalid/beta-draft.png"

    def prepare(base):
        home.seed_goals(base)
        chat.seed_image_workspace(base)

    def interact(process, fd, _slave, output, base):
        h.wait_for_output(process, fd, output, b"No decision is waiting", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go keepers", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"beta")
        h.send_and_wait(process, fd, output, b"c", b"Esc:list")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.palette_go(process, fd, output, b"go dashboard", b"Continue with beta")
        cards.select_home(process, fd, output, b"Continue with beta", destinations=2)
        h.send_and_wait(process, fd, output, b"\r", b"Esc:Dashboard")
        image = Path(base, chat.IMAGE_NAME)
        h.send_and_wait(process, fd, output, f"/attach {image}\r".encode(), b"attached ")
        h.send_and_wait(process, fd, output, f"/ref {reference}\r".encode(), b"reference(s)")
        h.write_all(fd, output, b"\x1b[200~" + draft.encode() + b"\x1b[201~")
        h.drain_until_quiet(process, fd, output)
        start = len(output)
        ask_arrives.set()
        h.wait_for_output(process, fd, output,
                          b"\x1b]9;alpha is waiting on a decision\x07", start=start, timeout=10)
        home.assert_no_decision_posts(requests)
        h.send_and_wait(process, fd, output, b"\x1b", b"background-alpha-question")
        visible = cards.frame(process, fd, output, "background-ask-beta-draft")
        assert b"[ask-home-bg]" in visible and b"Continue with beta" in visible, visible
        cards.select_home(process, fd, output, b"Continue with beta", destinations=3)
        h.send_and_wait(process, fd, output, b"\r", b"Esc:Dashboard")
        # Read the entire restored payload at the fixture boundary, including
        # offscreen lines and media. A visible suffix alone cannot prove it.
        h.send_and_wait(process, fd, output, b"\r", b"reply-beta first line")
        sent = [json.loads(body) for path, body in requests if path == CHAT_PATH]
        assert len(sent) == 1, sent
        payload = sent[0]
        assert (payload["name"], payload["message"]) == ("beta", draft), payload
        assert len(payload["attachments"]) == 1, payload
        attachment = payload["attachments"][0]
        assert attachment["name"] == image.name, attachment
        assert base64.b64decode(attachment["data"]) == image.read_bytes(), attachment
        assert {"type": "image", "url": reference} in payload["user_blocks"], payload
        h.send_and_wait(process, fd, output, b"\x1b", b"Continue with beta")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable, description="Home beta full draft survives background alpha ask notification",
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        prepare_workspace=prepare, refresh=1.0,
    )
    home.assert_no_decision_posts([(path, body) for path, body in requests if path != CHAT_PATH])
    assert sum(path == CHAT_PATH for path, _body in requests) == 1, requests


if __name__ == "__main__":
    exe = os.path.abspath(sys.argv[1])
    accepted_but_pending(exe)
    accepted_but_pending(exe, followed_by_held=True)
    background_ask_keeps_beta_draft(exe)
    print("Home decision receipt PTY: PASS (3 scenarios)")
