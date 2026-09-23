"""With zero approvals and one open ask, Approvals stays in the strip."""

import os
import sys

import test_tui_keyboard_input as h

# The regression this scenario stands over: the strip drops its Approvals
# entry when the only pending thing is a keeper's question. is_surface_active
# and the strip badge count approval_items alone (masc_tui_types.ml,
# masc_tui_render_prim.ml); neither saw the asks snapshot the surface already
# fetches (needs_asks). See PR #37060.
SOURCE_MODULES = (
    "bin/masc_tui_types.ml",
    "bin/masc_tui_render_prim.ml",
    "bin/masc_tui_render.ml",
)

CURRENT = b"\xe2\x96\xb8"


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
        # 150 columns: the eleven-entry strip fits whole, so this asserts the
        # entry's presence, never the windowing arithmetic's mercy.
        h.resize_and_wait(process, master_fd, output, rows=38, columns=150,
                          needle=b"MASC Overview", final_cursor=b"\x1b[?25l")
        h.drain_until_quiet(process, master_fd, output)
        # The first paint predates the first periodic refresh, and asks ride
        # the refresh, not the boot. Wait for a frame that carries the entry
        # rather than parsing the boot frame: a strip that keeps its previous
        # scene writes nothing at all, so a needle wait is the only honest
        # wait here (test_tui_keyboard_input.wait_for_fixture_state).
        appeared = h.wait_for_fixture_state(
            process, master_fd, output,
            lambda: b"Approvals\xc2\xb71" in bytes(output),
            timeout=45.0)
        h.drain_until_quiet(process, master_fd, output)
        rows = h.screen_rows(
            bytes(output[: output.rfind(h.FRAME_END) + len(h.FRAME_END)]))
        # The strip is the row carrying the current-entry marker; the title
        # row also says "MASC Overview" but carries no marker.
        strip_row = rows[h.screen_row_of(rows, CURRENT + b"Overview")]
        if not appeared:
            raise AssertionError(
                "zero approvals and one open ask, but no Approvals entry was "
                "drawn within 45s of refreshes; strip reads: "
                + repr(strip_row))
        if b"Approvals" not in strip_row:
            raise AssertionError(
                "zero approvals and one open ask, but the strip has no "
                f"Approvals entry: {strip_row!r}")
        if b"Approvals\xc2\xb71" not in strip_row:
            raise AssertionError(
                "open ask not counted in the Approvals badge, expected "
                "Approvals<middle-dot>1 in: " + repr(strip_row))
        print("strip captured:", strip_row.decode("utf-8", "replace"))
        # Arm the exit; the harness supplies the confirming q itself.
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="An open ask keeps Approvals in the strip",
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
                          needle=b"MASC Overview", final_cursor=b"\x1b[?25l")
        h.drain_until_quiet(process, master_fd, output)
        h.wait_for_fixture_state(
            process, master_fd, output,
            lambda: b"Approvals\xc2\xb71" in bytes(output),
            timeout=45.0)
        h.tab_until(process, master_fd, output, b"MASC Approvals")
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


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("approvals ring pty: PASS")
