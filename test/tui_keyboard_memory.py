from __future__ import annotations

import os
import re
import subprocess
import time

from tui_keyboard_harness import (
    CSI_RE,
    FRAME_END,
    FULL_REDRAW,
    HttpFixtures,
    HttpResponse,
    Interaction,
    SequencedHttpResponse,
    composer_showing,
    drain_until_quiet,
    escape_to_keeper_detail,
    find_needle,
    frame_containing,
    frame_row_of,
    overview_event_http_fixtures,
    palette_go,
    read_available,
    resize_and_wait,
    run_terminal_scenario,
    screen_row_of,
    screen_rows,
    screen_text,
    select_keeper_row,
    send_and_wait,
    wait_for_fixture_served,
    wait_for_output,
)


def memory_facts_http_fixtures() -> HttpFixtures:
    """The Memory surface's health table plus one keeper's fact listing."""
    fixtures = overview_event_http_fixtures()
    fixtures["/api/v1/dashboard/keeper-memory-health"] = (
        200,
        {
            "schema": "keeper.memory_os.current_health.v7",
            "generated_at": 1787348000.0,
            "keepers": [
                {
                    "keeper_id": "alpha",
                    "revision": 7,
                    "facts": 2,
                    "observed_facts": 2,
                    "derived_facts": 0,
                    "support_invalidations": 0,
                    "snapshot_bytes": 512,
                    "added": 1,
                    "removed": 0,
                    "snapshot_present": True,
                    "updated_at": 1700000000.0,
                    "context_cycle": {
                        "saved": None,
                        "saved_read_error": None,
                        "read_position": None,
                        "read_position_read_error": None,
                        "rewriting_through": None,
                        "prepared": None,
                        "synthesis": None,
                    },
                    "librarian": {
                        "state": "drained",
                        "detail": None,
                        "measured_at": 1787347900.0,
                        "unread_atom_turns": 0,
                        "unread_official_turns": 0,
                        "continuity_unread_atoms": 0,
                        "last_success_at": 1700000000.0,
                        "last_failure_kind": None,
                        "stalled": None,
                    },
                    "librarian_failures": 0,
                    "vision_ingest_errors": 0,
                    "vision_ingest_error_reasons": [],
                    "read_error": None,
                    "source_revision": 2,
                    "source_facts": 1,
                    "source_invalidations": 1,
                    "source_snapshot_bytes": 128,
                    "source_snapshot_present": True,
                    "source_read_error": None,
                    "alerts": [],
                }
            ],
            "totals": {
                "facts": 2,
                "observed_facts": 2,
                "derived_facts": 0,
                "support_invalidations": 0,
                "snapshot_bytes": 512,
                "added": 1,
                "removed": 0,
                "source_facts": 1,
                "source_invalidations": 1,
                "source_snapshot_bytes": 128,
                "librarian_unread_turns": 0,
                "librarian_continuity_unread_atoms": 0,
                "librarian_continuity_unmeasured": 0,
                "librarian_failures": 0,
                "vision_ingest_errors": 0,
                "read_errors": 0,
                "source_read_errors": 0,
            },
            "alert_summary": {
                "total_alerts": 0,
                "warn_alerts": 0,
                "error_alerts": 0,
                "keepers_with_alerts": 0,
                "snapshot_read_error_keepers": 0,
                "source_snapshot_read_error_keepers": 0,
                "librarian_stopped_keepers": 0,
                "librarian_starving_keepers": 0,
            },
        },
    )
    fixtures["/api/v1/keepers/alpha/memory-facts"] = (
        200,
        {
            "keeper": "alpha",
            "dashboard_surface": "/api/v1/keepers/:name/memory-facts",
            "events_read_error": None,
            "ordinary": {
                "present": True,
                "revision": 7,
                "updated_at": 1787348000.0,
                "facts": [
                    {
                        "claim": "the deploy needs assets",
                        "category": "lesson",
                        "origin": "authored",
                        "first_seen": 1787340000.0,
                        "last_seen": 1787347000.0,
                        "memory_id": "mem-1",
                        "events": {
                            "retrieved_count": 3,
                            "retrieved_distinct_days": 2,
                            "last_retrieved_at": 1787347500.0,
                            "retracted_count": 0,
                            "revised_from": [],
                        },
                    },
                    {
                        "claim": "port 8935 is already claimed",
                        "category": "blocker",
                        "origin": "injected",
                        "first_seen": 1787341000.0,
                        "last_seen": 1787346000.0,
                        "memory_id": "mem-2",
                        "events": {
                            "retrieved_count": 0,
                            "retrieved_distinct_days": 0,
                            "last_retrieved_at": None,
                            "retracted_count": 0,
                            "revised_from": [],
                        },
                    },
                ],
            },
            "source_bound": {
                "present": True,
                "revision": 2,
                "updated_at": 1787348000.0,
                "facts": [
                    {
                        "claim": "the config floor is masc.core",
                        "first_seen": 1787342000.0,
                        "path": "docs/config.md",
                        "sha256": "cafe0123beef4567cafe0123beef4567",
                    }
                ],
                "invalidations": [
                    {
                        "source_path": "docs/old.md",
                        "invalidated_at": 1787347500.0,
                        "reason": "source_changed",
                    }
                ],
            },
        },
    )
    return fixtures


def memory_facts_interaction() -> Interaction:
    """Enter on a Memory health row opens the fact browser: the rows carry
    the server's category and origin spellings, c cycles the filter through
    the loaded categories, and Esc returns to the health table."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        palette_go(process, master_fd, output, b"go Memory", b"MASC Memory")
        # Enter is a no-op until the health snapshot lands. The fixture has
        # two ordinary facts and one source fact, shown in the overview total.
        wait_for_output(
            process, master_fd, output, b"Total 3 facts",
            start=0, timeout=5.0,
        )
        # The title is bold up to the reset, so needles start after it:
        # "<bold> MASC Memory<reset> ▸ alpha (...)".
        send_and_wait(
            process, master_fd, output, b"\r",
            b"\xe2\x96\xb8 alpha",
        )
        # The listing arrives async after the browser opens.
        wait_for_output(
            process, master_fd, output,
            b"the deploy needs assets",
            start=0, timeout=5.0,
        )
        # Badges use uppercase display labels. At this height the selected
        # dropped row is visible; the source row is below the initial window.
        for needle in (
            b"[DROPPED   ]",
            b"docs/old.md",
            b"source_changed",
            b"(2 ord \xc2\xb7 1 src \xc2\xb7 1 drop)",
        ):
            wait_for_output(
                process, master_fd, output, needle, start=0, timeout=5.0
            )
        # Recency sorting opens on the dropped row, so its detail shows first;
        # one step down lands on an ordinary fact and its origin line.
        send_and_wait(process, master_fd, output, b"j", b"Origin:")
        wait_for_output(
            process, master_fd, output, b"authored", start=0, timeout=5.0
        )
        # Visit every category through its filter so each row is visible even
        # when the selected detail panel leaves a short list viewport. The
        # category row is the shared tab strip (#36051): the entry being read
        # is marked with the current-entry glyph directly before its label.
        for category, badge, text in (
            (b"blocker", b"[BLOCKER   ]", b"port 8935 is already claimed"),
            (b"lesson", b"[LESSON    ]", b"the deploy needs assets"),
            (b"source", b"[SOURCE    ]", b"docs/config.md"),
            (b"dropped", b"[DROPPED   ]", b"docs/old.md"),
        ):
            filtered = send_and_wait(
                process, master_fd, output, b"c", b"\xe2\x96\xb8" + category
            )
            plain = CSI_RE.sub(b"", filtered)
            for expected in (badge, text):
                if expected not in plain:
                    raise AssertionError(
                        f"Memory {category!r} filter omitted {expected!r}: {plain!r}"
                    )
        # The fact browser says Total: with a colon; the overview has this
        # fleet total, so it also proves Esc returned to the health table.
        send_and_wait(process, master_fd, output, b"\x1b", b"Total 3 facts")
        os.write(master_fd, b"q")

    return interact


def memory_journal_fixture() -> tuple[int, dict[str, object]]:
    return (
        200,
        {
            "keeper": "alpha",
            "returned": 1,
            "undecodable_lines": 0,
            "entries": [
                {
                    "ok": True,
                    "outcome": "committed",
                    "recorded_at": 1788273295.122265,
                    "revision": 9,
                    "source": {"kind": "librarian", "trace_id": "trace-memory"},
                    "change": {
                        "added": [
                            {
                                "category": "fact",
                                "claim": "the Runtime probe shares one provider endpoint",
                            }
                        ],
                        "removed": [
                            {
                                "category": "constraint",
                                "claim": "probe every model separately",
                            }
                        ],
                        "retained": 3,
                    },
                    "dropped": [
                        {
                            "memory_id": "memory-old-probe-rule",
                            "reason": "superseded by provider grouping",
                        }
                    ],
                }
            ],
        },
    )



def memory_journal_backfill_fixture() -> HttpResponse:
    status, payload = memory_journal_fixture()
    entries = payload["entries"]
    if not isinstance(entries, list):
        raise AssertionError("memory journal fixture entries are not a list")
    entries.insert(
        0,
        {
            "ok": True,
            "outcome": "failed",
            "recorded_at": 1788273280.0,
            "trace_id": "trace-backfilled-probe",
            "kind": "backfilled_probe",
            "detail": "older Journal observation",
            "snapshot_present": True,
        },
    )
    payload["returned"] = 2
    return status, payload


def memory_journal_failing_fixture() -> HttpResponse:
    """The fixture's journal with a pass that failed after its last commit."""
    status, payload = memory_journal_fixture()
    entries = payload["entries"]
    if not isinstance(entries, list):
        raise AssertionError("memory journal fixture entries are not a list")
    entries.append(
        {
            "ok": True,
            "outcome": "failed",
            "recorded_at": 1788273300.0,
            "trace_id": "trace-failing-pass",
            "kind": "exact_execution_failure",
            "detail": "provider returned 503",
            "snapshot_present": True,
        },
    )
    payload["returned"] = len(entries)
    return status, payload


MEMORY_JOURNAL_REQUEST_TS = 1788273291.814646

# The scenario runs a 30-row terminal and the chat pane is shorter than that,
# so this many one-line messages make a transcript taller than the pane. Page-up
# then has something to read back: without them the pane clamps the scroll to
# nothing, says "back at the newest row", and the scroll-pin claim below has
# nothing to measure (#33757).
MEMORY_JOURNAL_FILLER_ROWS = 30

# The filler sits an hour before the turn under test so that turn's own
# civil-hour rail is drawn directly above it and stays on screen with it.
# Filler in the same hour would put that rail at the top of the transcript,
# where the pane's newest window no longer reaches it.
SECONDS_PER_HOUR = 3600.0
MEMORY_JOURNAL_OLDEST_TS = (
    MEMORY_JOURNAL_REQUEST_TS - SECONDS_PER_HOUR - float(MEMORY_JOURNAL_FILLER_ROWS)
)


def memory_journal_filler_rows() -> list[dict[str, object]]:
    """Older conversation, oldest first, one second apart."""
    return [
        {
            "id": f"assistant:filler-{index}",
            "role": "assistant",
            "content": f"older conversation row {index}",
            "ts": MEMORY_JOURNAL_OLDEST_TS + float(index),
            "turn_ref": f"trace-filler#{index}",
            "transcript_slot": {"kind": "terminal_assistant"},
        }
        for index in range(MEMORY_JOURNAL_FILLER_ROWS)
    ]


def memory_journal_chat_fixture() -> HttpResponse:
    # Both conversation rows belong to one direct turn, while the Journal
    # observation lands between their clocks. Keeping the turn physically
    # whole produced the live 23:35:06 -> 23:34:55 regression: causal identity
    # may label the rows, but the shared visible axis must remain monotonic.
    return (
        200,
        memory_journal_filler_rows()
        + [
            {
                "id": "user:before-journal",
                "role": "user",
                "content": "direct turn before Librarian",
                "ts": MEMORY_JOURNAL_REQUEST_TS,
                "delivery_key": {
                    "kind": "operation",
                    "operation_id": "tui-direct-regression",
                },
                "transcript_slot": {"kind": "accepted_user"},
                "speaker_authority": "owner",
                "surface": {"kind": "dashboard"},
            },
            {
                "id": "assistant:after-journal",
                "role": "assistant",
                "content": "direct turn after Librarian",
                "ts": 1788273306.661051,
                "turn_ref": "trace-direct#54",
                "delivery_key": {
                    "kind": "operation",
                    "operation_id": "tui-direct-regression",
                },
                "transcript_slot": {"kind": "terminal_assistant"},
            },
        ],
    )


def autonomous_turn_history_interaction() -> Interaction:
    """The chat pane draws what an autonomous turn did, not a blank line."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        pane_start = len(output)
        send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        # The transcript is fetched on a background fiber once the pane opens,
        # so the rows land in a later frame than the header.
        wait_for_output(
            process,
            master_fd,
            output,
            b"masc_task_history",
            start=pane_start,
            timeout=5.0,
        )
        # Two calls, each with its own detail rows, do not fit the runner's
        # default 30 rows: the block reaches the first call's identity line
        # and the second is below the fold, so this read used to miss it and
        # report a name that was on screen a few rows further down.
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=60,
            columns=100,
            needle=b"masc_task_history",
            controls=(FULL_REDRAW,),
        )
        pane = bytes(output[pane_start:])
        plain_pane = CSI_RE.sub(b"", pane)
        for needle, what in (
            # Not "content withheld" any more. That wording read as someone
            # holding the text back and sent readers looking for a way to see
            # it; there is none, and the count is the whole fact. The renderer
            # says so in its own words at masc_tui_keeper_chat_history.ml.
            ("2 reasoning steps \u00b7 text not recorded".encode(),
             "the unrecorded reasoning count"),
            ("\u2713 masc_task_history \u00b7 32ms".encode(), "the returned call"),
            ("\u2717 tool_execute \u00b7 1200ms".encode(), "the failed call"),
            # No lane word on the work lanes any more: the mark already says
            # which lane the row is, so the badge is the glyph and its
            # padding and nothing else. What pins the thinking row is its
            # mark against the first words of the withheld-note body, with
            # whatever padding the badge puts between -- never the mark
            # alone, which the body's own " · " separators also carry.
            (re.compile("\u00b7\\s+2 reasoning steps".encode()),
             "the thinking lane"),
            # The block header row carries the badge, the quoted rail and
            # the first call's status on one stripped row, so the mark is
            # pinned against them the way the thinking lane is pinned
            # against its body -- never the bare mark alone.
            (re.compile("\u25a0\\s+\u2502\\s+\u2717".encode()),
             "the tool block mark"),
        ):
            if find_needle(plain_pane, needle) < 0:
                raise AssertionError(
                    f"Autonomous turn history did not draw {what}: {pane!r}"
                )
        # The lane words are gone for good: a revert that puts TOOLS or
        # THINKING back on a badge must fail here, not pass silently.
        for word in (b"TOOLS", b"THINKING"):
            if word in plain_pane:
                raise AssertionError(f"the lane word {word} is back: {pane!r}")
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        os.write(master_fd, b"q")

    return interact


def memory_journal_timeline_interaction(
    memory: SequencedHttpResponse,
) -> Interaction:
    def assert_monotonic_direct_turn(drawn: bytes) -> None:
        """Every claim here is about the screen, so it reads the screen.

        The pane resends only the rows that changed, so the frame that
        expands the Journal entry does not carry the request row above it or
        the hour rail above that -- both were written once, when they first
        appeared, and nothing has changed them since."""
        rows = screen_rows(drawn)
        plain = screen_text(drawn)
        hour = time.strftime(
            "%Y-%m-%d · %H:00", time.localtime(MEMORY_JOURNAL_REQUEST_TS)
        ).encode()
        styled_rail = re.compile(
            rb"\x1b\[(?:2|90)m"
            + "┄┄ ".encode()
            + re.escape(hour)
        )
        if styled_rail.search(drawn) is None:
            raise AssertionError(
                "Civil-hour rail did not recede (dim/gray) "
                f"for {hour!r}: {drawn!r}"
            )
        bold_rail = re.compile(
            rb"\x1b\[[0-9;]*m\x1b\[1m"
            + "┄┄ ".encode()
            + re.escape(hour)
        )
        if bold_rail.search(drawn) is not None:
            raise AssertionError(
                f"Civil-hour rail still held the bold slot for {hour!r}: {drawn!r}"
            )
        # The renderer groups by civil hour (checked above) and does not
        # also draw a per-message HH:MM:SS clock in the resting chat body
        # (no such formatting exists in bin/masc_tui_render.ml). The three
        # exact-second clock checks below are a fossil from a design that
        # predates hour-grouping; only content ordering still applies.
        ordered = (
            hour,
            b"direct turn before Librarian",
            b"Librarian \xc2\xb7 revision 9",
            b"direct turn after Librarian",
        )
        positions = [screen_row_of(rows, needle) for needle in ordered]
        if any(position < 0 for position in positions) or positions != sorted(
            positions
        ):
            raise AssertionError(
                "The direct-turn request, Journal entry, and reply did not "
                f"share one monotonic axis: {dict(zip(ordered, positions))!r}"
            )
        for pattern, label in (
            (re.compile("▶\\s+YOU".encode()), "direct turn start"),
            # The reply resumes after the Journal row under a heading of its
            # own: the keeper's mark and the rule. No name -- the breadcrumb
            # already says whose chat this is -- and no request id.
            (re.compile("●\\s+─".encode()), "post-Journal continuation"),
        ):
            if find_needle(plain, pattern) < 0:
                raise AssertionError(f"Missing {label} label: {plain!r}")
        # The conversation badge reverses only the speaker name. The mark's
        # color and weight end before it, and the badge resets before the rule.
        badge = b"\x1b[7mYOU\x1b[0m"
        if badge not in drawn:
            raise AssertionError(f"Direct causal label lost its bounded reverse badge: {drawn!r}")
        if "▶".encode() + b"\x1b[0m " + badge not in drawn:
            raise AssertionError(f"Direct causal mark style leaked into the speaker badge: {drawn!r}")

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        start = len(output)
        send_and_wait(
            process,
            master_fd,
            output,
            b"m",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )
        # This scenario verifies the complete timestamp axis. Chat itself now
        # rests in the clock-free reading layout, so opt into full metadata.
        #
        # One press, not two. The header names only the two densities away
        # from the resting one: Origin_bare draws "metadata:off", Origin_row
        # draws "metadata:full", and Origin_inline -- the default this pane
        # opens in -- draws nothing, because a label saying you are where you
        # started is not news. So "metadata:inline" is not a string this
        # header can produce, and waiting for it starved.
        send_and_wait(process, master_fd, output, b"\x06", b"metadata:full")
        # At rest the journal draws only its one-line summary: the header
        # with source, revision, and counts. The change fence under it is a
        # keypress away.
        wait_for_output(
            process,
            master_fd,
            output,
            b"Librarian \xc2\xb7 revision 9",
            start=start,
            timeout=5.0,
        )
        last_row_end = output.find(
            b"Librarian \xc2\xb7 revision 9", start
        ) + len(b"Librarian \xc2\xb7 revision 9")
        wait_for_output(
            process,
            master_fd,
            output,
            FRAME_END,
            start=last_row_end,
            timeout=3.0,
        )
        frame_end = output.find(FRAME_END, last_row_end) + len(FRAME_END)
        resting = frame_containing(
            bytes(output[start:frame_end]),
            b"Librarian \xc2\xb7 revision 9",
        )
        plain_resting = CSI_RE.sub(b"", resting)
        assert_monotonic_direct_turn(bytes(output))
        # The key that opens the summary is the footer's Ctrl-N:journal; the
        # row itself names no key.
        summary_rows = [
            text
            for text in screen_rows(bytes(output)).values()
            if b"Librarian \xc2\xb7 revision 9" in text
        ]
        if not summary_rows or any(b"Ctrl-N" in row for row in summary_rows):
            raise AssertionError(
                f"Journal summary row named a key the footer names: {summary_rows!r}"
            )
        # What the key does is the footer's line, which is on screen with
        # this row; saying it again per row is what the row stopped doing.
        if b"Ctrl-N: journal detail" in plain_resting:
            raise AssertionError(
                f"Journal summary spelled the footer's own words: {resting!r}"
            )
        if re.search("\u25c8\\s+JOURNAL".encode(), plain_resting) is None:
            raise AssertionError(
                f"Memory timeline did not draw its distinct Journal marker: {resting!r}"
            )
        if "\u250a".encode() not in plain_resting:
            raise AssertionError(
                f"Memory timeline did not draw its parallel dotted rail: {resting!r}"
            )
        for fence_only in (
            b"one provider endpoint",
            b"superseded by provider grouping",
        ):
            if fence_only in resting:
                raise AssertionError(
                    f"Summary mode drew the change fence {fence_only!r}: {resting!r}"
                )

        # /memory steps the lane from summary to full, where the change
        # fence draws in whole.
        send_and_wait(process, master_fd, output, b"/memory", composer_showing(b"/memory"))
        full_start = len(output)
        send_and_wait(process, master_fd, output, b"\r", b"journal:full")
        wait_for_output(
            process,
            master_fd,
            output,
            b"superseded by provider grouping",
            start=full_start,
            timeout=5.0,
        )
        last_row_end = output.find(
            b"superseded by provider grouping", full_start
        ) + len(b"superseded by provider grouping")
        wait_for_output(
            process,
            master_fd,
            output,
            FRAME_END,
            start=last_row_end,
            timeout=3.0,
        )
        frame_end = output.find(FRAME_END, last_row_end) + len(FRAME_END)
        visible = frame_containing(
            bytes(output[full_start:frame_end]),
            b"superseded by provider grouping",
        )
        plain_visible = CSI_RE.sub(b"", visible)
        assert_monotonic_direct_turn(bytes(output))
        # Read off the screen, not this frame: expanding the entry rewrote
        # the rows under its header, and the header itself did not change,
        # so the pane had no reason to send it again.
        if re.search("◈\\s+JOURNAL".encode(), screen_text(bytes(output))) is None:
            raise AssertionError(
                "Memory timeline did not draw its distinct Journal marker: "
                f"{screen_text(bytes(output))!r}"
            )
        if "\u250a".encode() not in plain_visible:
            raise AssertionError(
                f"Memory timeline did not draw its parallel dotted rail: {visible!r}"
            )
        # Each fact is its sign, its category in a column padded to the
        # revision's widest, and the claim. The sign and the category carry
        # their own colours, so SGR lands between the pieces; a flat byte
        # needle spanning a boundary cannot match a coloured one.
        tag = rb"(?:\x1b\[[0-9;]*m)*"
        for needle in (
            re.compile(
                rb"\+" + tag + rb" " + tag + rb"fact" + tag + rb" +" + tag
                + rb"the Runtime probe shares"
            ),
            b"one provider endpoint",
            re.compile(
                "\u2212".encode() + tag + rb" " + tag + rb"constraint" + tag
                + rb" +" + tag + rb"probe"
            ),
            b"every model separately",
            re.compile(rb"drop" + tag + rb" +" + tag + rb"memory-old-probe-rule"),
            b"superseded by provider grouping",
        ):
            if find_needle(visible, needle) < 0:
                raise AssertionError(f"Memory timeline did not draw {needle!r}: {visible!r}")

        # The changed facts are drawn from typed lines, never through
        # markdown, so a leading + cannot be read as a list item. The renderer
        # once escaped that + instead, and nothing consumed the escape, so
        # every changed fact reached the pane behind a literal backslash.
        # Asserted on the drawn bytes because that is where it showed.
        for escaped in (b"\\+ ", b"\\- "):
            if escaped in visible:
                raise AssertionError(
                    f"Memory timeline drew an unconsumed escape {escaped!r}: {visible!r}"
                )

        # A wheel notch reads back, and it is the shallow way to do it: a
        # page would carry the pinned row below off the newest window, and
        # this block is about where that row sits, not about how far the
        # pane can travel. A single row per press was the arrow key's old
        # behaviour and is gone.
        #
        # The status row names its row count only while an older page
        # exists, so the needle is the part that marks reading back in
        # either wording.
        reading_back = b"Ctrl-E returns to the newest"
        # The producer's older journal rows have to land before the pane is
        # read back, because a pane that is read back does not ask for them:
        # the tick reloads the transcript only at the newest row, and the
        # journal comes down that same load (bin/masc_tui.ml, the msg_scroll
        # guard on launch_keeper_history_load). What the pin below is about
        # is where the row sits once they are in.
        memory.responses.append(memory_journal_backfill_fixture())
        served_before_backfill = memory.served
        wait_for_fixture_served(
            process,
            master_fd,
            output,
            memory,
            after=served_before_backfill,
            description="Journal producer backfill",
            timeout=5.0,
        )
        drain_until_quiet(process, master_fd, output)
        scrolled = send_and_wait(
            process, master_fd, output, b"\x1b[<64;5;5M", reading_back
        )
        scrolled_frame = frame_containing(scrolled, reading_back)
        anchor = b"Librarian \xc2\xb7 revision 9"
        if anchor not in CSI_RE.sub(b"", scrolled_frame):
            raise AssertionError(
                f"Scroll setup did not keep the intended Journal anchor: {scrolled_frame!r}"
            )
        anchor_row_before = frame_row_of(scrolled_frame, anchor)
        status_row_before = frame_row_of(scrolled_frame, reading_back)
        anchor_offset_before = anchor_row_before - status_row_before
        refreshed_frame = resize_and_wait(
            process,
            master_fd,
            output,
            rows=31,
            columns=100,
            needle=reading_back,
            controls=(FULL_REDRAW,),
        )
        if anchor not in CSI_RE.sub(b"", refreshed_frame):
            raise AssertionError(
                "A redraw moved the pinned row out of the read-back window: "
                f"{refreshed_frame!r}"
            )
        anchor_row_after = frame_row_of(refreshed_frame, anchor)
        status_row_after = frame_row_of(refreshed_frame, reading_back)
        anchor_offset_after = anchor_row_after - status_row_after
        if anchor_offset_after != anchor_offset_before:
            raise AssertionError(
                "A redraw changed the pinned row's footer-relative slot: "
                f"before={anchor_offset_before} after={anchor_offset_after} "
                f"frame={refreshed_frame!r}"
            )
        send_and_wait(
            process,
            master_fd,
            output,
            b"\x05",
            b"direct turn after Librarian",
        )

        # Ctrl-N walks the same cycle without the composer: full -> hidden.
        # Each check reads only the frame that drew the new mode. The bytes
        # send_and_wait returns start at the key press, so a refresh frame the
        # loop drew before it read the key -- still in the previous mode --
        # can sit in front of it: under the full keyboard suite the hidden
        # check once found the row in the frame before "journal:off".
        hidden = frame_containing(
            send_and_wait(process, master_fd, output, b"\x0e", b"journal:off"),
            b"journal:off",
        )
        if b"Librarian \xc2\xb7 revision 9" in hidden:
            raise AssertionError(f"Hidden Memory timeline still drew its row: {hidden!r}")

        # ... and hidden -> summary, the resting default.
        restored = frame_containing(
            send_and_wait(
                process,
                master_fd,
                output,
                b"\x0e",
                b"Librarian \xc2\xb7 revision 9",
            ),
            b"Librarian \xc2\xb7 revision 9",
        )
        if b"journal:off" in restored:
            raise AssertionError(f"Restored Memory timeline stayed off: {restored!r}")
        if b"superseded by provider grouping" in restored:
            raise AssertionError(
                f"Summary mode drew the change fence after restore: {restored!r}"
            )

        # A chat pane too narrow for the composer still owes the display
        # toggles a working gate. Twelve columns keeps the frame painted
        # (the global compact fallback is row-driven and owns every key on
        # its screen), draws only the "needs a larger terminal" notice, and
        # makes keeper_message_input_supported false — the regime where the
        # gate decides. Ctrl-R/Ctrl-D always passed it while Ctrl-F and then
        # Ctrl-N (#32367) were swallowed, because the gate admitted keys one
        # by one instead of the display-toggle set. The toggles land on the
        # notice screen and prove themselves on the way back up.
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=31,
            columns=12,
            needle=b"Keeper ch\xe2\x80\xa6",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        # FIONREAD only observes the kernel queue: the TUI can read both
        # toggles into its input buffer before dispatching either. Resizing
        # at that point invalidates the old frame and correctly suppresses
        # input until the new one is painted. Ctrl-T's emitted mouse mode
        # acknowledges dispatch after the preceding keys, even when their
        # changed header is hidden by this narrow notice. Restore tracking
        # before widening; the journal assertion below still proves Ctrl-N.
        read_available(master_fd, output)
        tracking_ack_start = len(output)
        os.write(master_fd, b"\x0e\x06\x14\x14")
        wait_for_output(
            process,
            master_fd,
            output,
            b"\x1b[?1006;1000h",
            start=tracking_ack_start,
            timeout=3.0,
        )
        try:
            widened = resize_and_wait(
                process,
                master_fd,
                output,
                rows=31,
                columns=100,
                needle=b"journal:full",
                controls=(FULL_REDRAW,),
            )
        except AssertionError:
            # The raw byte dump this would otherwise carry runs to a hundred
            # kilobytes and is cut by the CI log before it says anything. The
            # screen is the part that answers what the toggles did.
            raise AssertionError(
                "Widening back never showed journal:full. Screen:\n"
                + screen_text(bytes(output)).decode("utf8", "replace")
            ) from None
        if b"journal:full" not in CSI_RE.sub(b"", widened):
            raise AssertionError(
                "A display toggle pressed on the narrow-pane notice screen "
                f"was swallowed by the composer gate: {widened!r}"
            )

        # A pass that failed after the last commit is a state of the keeper's
        # memory: the header names the run, from the producer's typed outcome
        # through to the pane, and summary mode draws no row for it.
        memory.responses.append(memory_journal_failing_fixture())
        served_before_failure = memory.served
        failing_from = len(output)
        wait_for_fixture_served(
            process,
            master_fd,
            output,
            memory,
            after=served_before_failure,
            description="Journal with a failed pass",
            timeout=5.0,
        )
        failing_header = b"Librarian failing \xc3\x971 since"
        wait_for_output(
            process, master_fd, output, failing_header, start=failing_from, timeout=5.0
        )
        # journal:full -> off -> summary.
        send_and_wait(process, master_fd, output, b"\x0e", b"journal:off")
        send_and_wait(process, master_fd, output, b"\x0e", b"Librarian \xc2\xb7 revision 9")
        drain_until_quiet(process, master_fd, output)
        rows = screen_rows(bytes(output[: output.rfind(FRAME_END) + len(FRAME_END)]))
        naming = [row for row, text in rows.items() if failing_header in text]
        failed_rows = [row for row, text in rows.items() if b"Librarian failed" in text]
        if len(naming) != 1 or failed_rows:
            raise AssertionError(
                "A failing Librarian is the header item alone in summary mode "
                f"(header rows {naming}, failure rows {failed_rows}): "
                + screen_text(bytes(output)).decode("utf8", "replace")
            )
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        os.write(master_fd, b"q")

    return interact


def run_memory_journal_regression(executable: str) -> None:
    memory_journal_sequence = SequencedHttpResponse([memory_journal_fixture()])
    run_terminal_scenario(
        executable,
        description="Keeper Memory journal timeline",
        interact=memory_journal_timeline_interaction(memory_journal_sequence),
        http_fixtures={
            "/api/v1/keepers/alpha/chat/history": memory_journal_chat_fixture(),
            # Reading back asks for the page behind the oldest row it holds,
            # matched independent of its timestamp. Without an answer the pane
            # draws the load error instead of the reading-back status row,
            # and the scroll-pin claim below has nothing to measure against.
            "/api/v1/keepers/alpha/chat/history/page": (
                200, {"messages": [], "has_more": False, "next_before": None}
            ),
            "/api/v1/keepers/alpha/memory-journal?limit=20": memory_journal_sequence,
        },
        refresh=0.5,
    )
