"""Home Ask recovery through applied failed and authoritative successful reads.

Uses the shared Ask wire fixtures and PTY harness. Static checks alone do not
prove these journeys; an executable built with the parent fix is required.
"""
import copy
import json
import os
import re
import sys
import threading

import test_tui_home_decision_cards_pty as cards
import test_tui_home_journey_pty as home
import tui_keyboard_harness as h
import tui_keyboard_approvals as approvals

SOURCE_MODULES = (
    "bin/masc_tui_home.ml", "bin/masc_tui_home.mli",
    "bin/masc_tui_approvals_model.ml", "bin/masc_tui_approvals_model.mli",
    "bin/masc_tui_render_approvals.ml", "bin/masc_tui_render_approvals.mli",
    "bin/masc_tui.ml",
    "bin/masc_tui_types.ml",
    "bin/masc_tui_ask_projection.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_render_prim.ml",
)
ASK_ID = "ask-home-recovery"
CONTEXT = b"home-question-recovery-card"
TEXT = b"retain this unfinished explanation"
RESTORED = b"restored explanation for the same Ask"


def reader_frame(process, fd, output, needle):
    h.resize_and_wait(
        process, fd, output, rows=40, columns=121, needle=needle,
        controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l",
    )
    drawn = h.resize_and_wait(
        process, fd, output, rows=40, columns=120, needle=needle,
        controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l",
    )
    visible = h.screen_text(drawn)
    assert b"MASC Approvals / Questions" in visible, visible
    return visible


def recovery_journey(executable, *, submit):
    fixtures = cards.fixtures_with_held([])
    status, snapshot = copy.deepcopy(approvals.keeper_asks_response(long_question=True))
    ask = snapshot["asks"][0]
    ask.update(ask_id=ASK_ID, context=CONTEXT.decode())
    ask["questions"][1]["choices"][0]["label"] = "explain instead"
    current = [(status, snapshot)]
    lock = threading.Lock()
    requests = []

    def listing():
        with lock:
            return copy.deepcopy(current[0])

    def replace(response):
        with lock:
            current[0] = copy.deepcopy(response)

    fixtures[h.KEEPER_ASKS_PATH] = listing
    fixtures[approvals.KEEPER_ASK_ANSWER_PATH] = (200, {"ok": True})

    def no_posts():
        home.assert_no_decision_posts(requests)

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, CONTEXT, start=0, timeout=10)
        cards.select_home(process, fd, output, CONTEXT, destinations=3)
        h.send_and_wait(process, fd, output, b"\r", b"ship the cold-start change now?")
        h.send_and_wait(process, fd, output, b"1", re.compile(rb"\(o\) (?:\x1b\[[0-9;:]*m)*c-yes"))
        h.send_and_wait(process, fd, output, b"\x1b[C", b"Question 2/2")
        h.send_and_wait(process, fd, output, b"t", b"write: ")
        h.send_and_wait(process, fd, output, TEXT, TEXT)
        no_posts()

        start = len(output)
        replace((503, {"error": "home asks recovery fixture offline"}))
        # A served response is insufficient: wait for the reader's applied
        # error, then inspect a fresh screen, including the unsaved editor.
        h.wait_for_output(process, fd, output, b"Question source unavailable",
                          start=start, timeout=10)
        visible = reader_frame(process, fd, output, TEXT)
        for needle in (b"Question 2/2", b"1 answered", b"write: ", TEXT,
                       b"Question source unavailable"):
            assert needle in visible, visible
        # Save the editor locally, then try twice. Even a complete retained
        # answer must never arm/send while the authoritative read failed.
        h.send_and_wait(process, fd, output, b"\r", TEXT)
        h.send_and_wait(process, fd, output, b"\r",
                        b"Question source unavailable; refresh before answering")
        no_posts()
        os.write(fd, b"\r")
        h.drain_until_quiet(process, fd, output)
        # Repeated refusal may leave exactly the same visible screen.
        assert b"Question source unavailable; refresh before answering" in h.screen_text(bytes(output))
        no_posts()
        h.send_and_wait(process, fd, output, b"\x1b[D", b"Question 1/2")
        visible = reader_frame(process, fd, output, re.compile(rb"\(o\) (?:\x1b\[[0-9;:]*m)*c-yes"))
        assert b"(o) c-yes" in visible and b"(o) c-no" not in visible, visible
        h.send_and_wait(process, fd, output, b"\x1b[C", b"Question 2/2")
        # Return to a partial answer with an unsaved text buffer before the
        # successful refresh. The previous complete answer tested refusal.
        h.send_and_wait(process, fd, output, b"c", b"1 answered")
        h.send_and_wait(process, fd, output, b"t", b"write: ")
        h.send_and_wait(process, fd, output, TEXT, TEXT)

        restored = copy.deepcopy(snapshot)
        restored["asks"][0]["questions"][1]["prompt"] = RESTORED.decode()
        start = len(output)
        replace((200, restored))
        # Changed prompt proves the same-ID successful snapshot was applied.
        h.wait_for_output(process, fd, output, RESTORED, start=start, timeout=10)
        visible = reader_frame(process, fd, output, TEXT)
        assert TEXT in visible and b"write: " in visible, visible
        assert b"1 answered" in visible, visible
        assert b"Question source unavailable" not in visible, visible
        no_posts()

        if submit:
            h.send_and_wait(process, fd, output, b"\r", TEXT)
            h.send_and_wait(process, fd, output, b"\x1b[D", b"Question 1/2")
            visible = reader_frame(process, fd, output, re.compile(rb"\(o\) (?:\x1b\[[0-9;:]*m)*c-yes"))
            assert b"(o) c-yes" in visible, visible
            h.send_and_wait(process, fd, output, b"\r", b"Press enter again to answer alpha")
            no_posts()
            h.send_and_wait(process, fd, output, b"\r", b"Answered alpha:")
            sent = [json.loads(body) for path, body in requests
                    if path == approvals.KEEPER_ASK_ANSWER_PATH]
            assert sent == [{
                "name": "alpha", "ask_id": ASK_ID,
                "answers": [
                    {"question_id": "q-1", "response": {
                        "kind": "chose", "choice_ids": ["c-yes"]}},
                    {"question_id": "q-2", "response": {
                        "kind": "wrote", "text": TEXT.decode()}},
                ],
            }], sent
        else:
            start = len(output)
            replace((200, {"keeper": None, "open_count": 0, "asks": []}))
            h.wait_for_output(process, fd, output, b"No decision is waiting",
                              start=start, timeout=10)
            visible = cards.frame(process, fd, output, "authoritative-empty-ask")
            for removed in (CONTEXT, TEXT, b"MASC Approvals / Questions", b"write: "):
                assert removed not in visible, visible
            assert b"No decision is waiting" in visible, visible
            os.write(fd, b"\r\r")
            h.drain_until_quiet(process, fd, output)
            no_posts()
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description=("Home question failed-read recovery permits explicit retained answer"
                     if submit else "Home question authoritative empty clears retained detail/editor"),
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        prepare_workspace=home.seed_goals, refresh=1.0,
    )
    answer_posts = [(path, body) for path, body in requests
                    if path == approvals.KEEPER_ASK_ANSWER_PATH]
    assert len(answer_posts) == int(submit), answer_posts
    home.assert_no_decision_posts([(path, body) for path, body in requests
                                  if path != approvals.KEEPER_ASK_ANSWER_PATH])


if __name__ == "__main__":
    exe = os.path.abspath(sys.argv[1])
    recovery_journey(exe, submit=True)
    recovery_journey(exe, submit=False)
    print("Home question recovery PTY: PASS (2 scenarios)")
