"""The Attention panel's age column is drawn when some item has an age."""
import os
import sys
import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs a
# suite when a pull request changes a path the suite names.
SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
)

BRIEFING = "/api/v1/dashboard/briefing"
BADGE = b"[warn]"
SUMMARY = b"sangsu has external attention"
# What a row reads as when the column is not there: the badge, one space, and
# the summary.
BADGE_THEN_SUMMARY = BADGE + b" " + SUMMARY
DASH = b"\xe2\x80\x94"


def briefing(stamped: bool) -> h.HttpResponse:
    """Two items the panel keeps: their target keeper is not on the roster
    this fixture serves, so no Team row carries them away."""
    first = {
        "kind": "keeper_attention",
        "severity": "warning",
        "summary": "sangsu has external attention from discord",
        "target_type": "keeper",
        "target_id": "sangsu",
    }
    second = dict(first, summary="analyst needs operator attention")
    if stamped:
        # The one producer that stamps its evidence: a tool-host failure.
        first = dict(first, evidence={"log_ts": "2026-09-23T00:00:00Z"})
    return (
        200,
        {
            "summary": {
                "workspace_health": "ok",
                "cluster": "cluster-a",
                "project": "project-a",
            },
            "generated_at": "2026-09-23T00:00:00Z",
            "incidents": [],
            "attention_queue": [first, second],
            "attention_items": [],
            "agent_briefs": [],
            "keeper_briefs": [],
            "keepers_unread": [],
        },
    )


def summary_offset(executable: str, stamped: bool) -> bytes:
    """The attention row carrying the first item, as the panel drew it."""
    fixtures = h.overview_event_http_fixtures()
    fixtures[BRIEFING] = briefing(stamped)
    measured = {}

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, SUMMARY, start=0, timeout=10)
        # A width the scenario did not open at, so the resize redraws and the
        # frame this reads is a whole one.
        drawn = h.resize_and_wait(process, fd, output, rows=30, columns=150,
                                  needle=SUMMARY, controls=(h.FULL_REDRAW,))
        rows = h.screen_rows(drawn)
        index = h.screen_row_of(rows, SUMMARY)
        if index < 0:
            raise AssertionError("the attention panel drew no row")
        row = rows[index]
        if BADGE not in row:
            raise AssertionError(f"the row carries no badge: {row!r}")
        measured["row"] = row.rstrip()
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description=f"attention age column, stamped={stamped}",
        interact=interact, http_fixtures=fixtures)
    return measured["row"]


def run(executable: str) -> None:
    # No item has an age: the summary follows the badge, and no row carries
    # the dash that stood for an age nobody stamped.
    bare = summary_offset(executable, stamped=False)
    if BADGE_THEN_SUMMARY not in bare:
        raise AssertionError(
            f"a panel with no ages still keeps the column: {bare!r}")
    if DASH in bare:
        raise AssertionError(f"an item with no age still drew a dash: {bare!r}")

    # One item is stamped: the column is back, for the whole panel, so the
    # summary no longer sits against its badge.
    stamped = summary_offset(executable, stamped=True)
    if BADGE_THEN_SUMMARY in stamped:
        raise AssertionError(
            f"a stamped item drew no age column: {stamped!r}")


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("the attention age column follows its ages: PASS")
