"""An open Keeper question remains accessible under Work / Approvals."""

import json
import os
import sys

import test_tui_keyboard_input as h

# The queue and questions are separate readings. With Approvals off the main
# ring, the palette reaches their shared surface and the title still counts
# the open question. See PR #37060 for the original badge regression.
SOURCE_MODULES = (
    "bin/masc_tui_types.ml",
    "bin/masc_tui_render_prim.ml",
    "bin/masc_tui_render.ml",
)

def open_ask_snapshot() -> dict[str, object]:
    """One open question, no approvals anywhere.

    The wire shape follows lib/tui_decode.ml (decode_asks_snapshot and
    friends): the badge counts the rows Masc_tui_ask_projection.open_rows
    keeps (resolution open), not the snapshot's open_count field.
    """
    return {
        "keeper": None,
        "open_count": 1,
        "asks": [
            {
                "keeper": "alpha",
                "ask_id": "ask-pty-1",
                "asked_at": 0.0,
                "context": "waiting on the operator",
                "resolution": {"state": "open"},
                "questions": [
                    {
                        "question_id": "q1",
                        "header": "post or wait",
                        "prompt": "post the comment as is?",
                        "mode": "single",
                        "free_text": None,
                        "choices": [
                            {
                                "choice_id": "post_as_is",
                                "label": "post as is",
                                "description": None,
                            }
                        ],
                    }
                ],
            }
        ],
    }


def run(executable: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    # Zero approvals: the operator summary carries an empty confirm queue and
    # the tool-approval poll answers with the honest empty queue.
    fixtures["/api/v1/operator?view=summary&include_messages=0&include_keepers=0"] = (
        200,
        {
            "pending_confirm_envelope": {
                "items": [],
                "summary": {
                    "actor_filter": "masc-tui",
                    "filter_active": True,
                    "visible_count": 0,
                    "total_count": 0,
                    "hidden_count": 0,
                    "hidden_actors": [],
                    "confirm_required_actions": [],
                },
            }
        },
    )
    fixtures["/api/v1/keepers/tool-approvals"] = (200, {"pending": []})
    # One open ask: the population the two predicates used to miss. The
    # unseen endpoint answers with the snapshot above rather than a 404.
    fixtures["/api/v1/keepers/asks"] = (200, open_ask_snapshot())

    def interact(process, master_fd, _slave_fd, output, _base_path):
        # Approvals is a Work child and has a direct palette destination.
        h.resize_and_wait(process, master_fd, output, rows=38, columns=150,
                          needle=b"MASC Dashboard", final_cursor=b"\x1b[?25l")
        h.palette_go(process, master_fd, output, b"go Approvals", b"MASC Approvals")
        h.wait_for_output(process, master_fd, output,
                          b"Questions waiting on you (1)", start=0, timeout=10)
        # Arm the exit; the harness supplies the confirming q itself.
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="An open ask is visible in Work / Approvals",
        interact=interact,
        http_fixtures=fixtures,
        refresh=2.0,
    )

    # The same fixtures, one screen further in. The queue is empty and a
    # question is waiting, which is the state where the two populations part:
    # the title and the badge count both lists, the queue's own empty note
    # counts only the queue. It used to ask the wider count, so with a
    # question waiting the list drew its empty self -- a cursor mark on a
    # blank row and nothing to say the queue was empty -- where the same
    # screen with no question at all said so.
    def empty_queue_says_so(process, master_fd, _slave_fd, output, _base_path):
        h.resize_and_wait(process, master_fd, output, rows=38, columns=150,
                          needle=b"MASC Dashboard", final_cursor=b"\x1b[?25l")
        h.drain_until_quiet(process, master_fd, output)
        h.palette_go(process, master_fd, output, b"go Approvals", b"MASC Approvals")
        h.wait_for_output(process, master_fd, output,
                          b"(no pending approvals)", start=0, timeout=10)
        # And the question it sits above is still drawn, so the note is about
        # the queue rather than about the screen.
        h.wait_for_output(process, master_fd, output,
                          b"Questions waiting on you (1)", start=0, timeout=10)
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="An empty approval queue says so beside a waiting question",
        interact=empty_queue_says_so,
        http_fixtures=fixtures,
        refresh=2.0,
    )

    # The questions poll fails and one held call waits. The title's count has
    # no question in it because none was read, and the title says so rather
    # than let the count pass for "no question is open".
    unread_fixtures = dict(fixtures)
    unread_fixtures["/api/v1/keepers/asks"] = (
        503, {"error": "asks fixture unavailable"})
    unread_fixtures["/api/v1/keepers/tool-approvals"] = (
        200,
        {
            "pending": [
                {
                    "keeper": "alpha",
                    "tool_call_id": "tool-held-beside-unread-asks",
                    "tool": "Bash",
                    "args": json.dumps({"command": "true"}),
                    "question": "Run Bash on true?",
                    "because": None,
                    "asked_at": 1787766400.0,
                    "timeout_sec": 300.0,
                }
            ]
        },
    )

    def unread_questions_say_so(process, master_fd, _slave_fd, output, _base_path):
        h.resize_and_wait(process, master_fd, output, rows=38, columns=150,
                          needle=b"MASC Dashboard", final_cursor=b"\x1b[?25l")
        h.drain_until_quiet(process, master_fd, output)
        h.palette_go(process, master_fd, output, b"go Approvals", b"MASC Approvals")
        h.wait_for_output(process, master_fd, output,
                          b"questions unread", start=0, timeout=10)
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="A failed questions poll is named in the Approvals title",
        interact=unread_questions_say_so,
        http_fixtures=unread_fixtures,
        refresh=2.0,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("approvals ring pty: PASS")
