from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import time
import zlib

from tui_keyboard_harness import (
    CSI_RE,
    FRAME_END,
    FRAME_START,
    FULL_REDRAW,
    GatedHttpResponse,
    HttpFixtures,
    HttpResponse,
    Interaction,
    RawHttpResponse,
    SequencedHttpResponse,
    copy_reference,
    drain_until_quiet,
    end_of_needle,
    frame_containing,
    overview_event_http_fixtures,
    palette_go,
    read_available,
    resize_and_wait,
    run_terminal_scenario,
    screen_row_of,
    screen_rows,
    screen_text,
    send_and_wait,
    wait_for_fixture_event,
    wait_for_output,
)

FUSION_RUNS_PATH = "/api/v1/dashboard/fusion-runs"


def fusion_run(
    run_id: str,
    *,
    keeper: str,
    status: str = "completed",
) -> dict[str, object]:
    return {
        "run_id": run_id,
        "keeper": keeper,
        "preset": "trio",
        "topology": "simple",
        "started_at": 1787557669.715736,
        "finished_at": None if status == "running" else 1787557684.715736,
        "status": status,
        "stage": "accepted" if status == "running" else status,
        "progress": {} if status == "running" else None,
    }


# The Registry list fits a run id into a 14-cell column, so what it draws is
# the truncated head with the pane's "…" marker after it. The full id is what
# the detail pane and the copy links carry, and those assertions keep it.
FUSION_TARGET_LISTED = b"fusion-target"


def fusion_runs_response(runs: list[dict[str, object]]) -> HttpResponse:
    return (
        200,
        {
            "generated_at": "2026-08-24T09:00:00Z",
            "count": len(runs),
            "replay": {"status": "not_replayed"},
            "historical_evidence": [],
            "runs": runs,
        },
    )


def fusion_detail_response(run: dict[str, object], judge_reason: str) -> HttpResponse:
    run_id = str(run["run_id"])
    return (
        200,
        {
            "generated_at": "2026-08-24T09:00:01Z",
            "run": run,
            "evidence": {
                "status": "recorded",
                "post": {
                    "id": f"post-{run_id}",
                    "title": f"Fusion evidence for {run_id}",
                    "origin": {
                        "source": "fusion",
                        "fusion_run_id": run_id,
                    },
                    "meta": {
                        "question": "question-proof-501",
                        "panel": [
                            {
                                "model": "panel-first-501",
                                "status": "answered",
                                "answer": "panel-answer-first-501",
                                "input_tokens": 10,
                                "output_tokens": 20,
                            },
                            {
                                "model": "panel-second-501",
                                "status": "failed",
                                "reason_code": "timeout",
                                "reason_detail": "panel-failure-second-501",
                            },
                        ],
                        "judge": {
                            "status": "synthesized",
                            "decision": "answer",
                            "resolved_answer": "judge-resolved-501",
                            "synthesis": judge_reason,
                        },
                        # RFC-0284 judge nodes: a judge-of-judges run's
                        # first-pass lenses and the meta above them. The
                        # canonical single judge stays -- the array is the
                        # additive observation the TUI detail renders.
                        "judges": [
                            {
                                "role": "first",
                                "identity": "ollama_cloud.minimax-m3",
                                "status": "synthesized",
                                "decision": "answer",
                                "resolved_answer": "first-evidence-resolved-501",
                                "synthesis": "first-evidence-synthesis-501",
                                "input_tokens": 30,
                                "output_tokens": 40,
                            },
                            {
                                "role": "first",
                                "identity": "ollama_cloud.deepseek-v4-pro",
                                "status": "failed",
                                "error": "first judge body timed out",
                                "failure_code": "timeout",
                                "input_tokens": 50,
                                "output_tokens": 0,
                                "elapsed_s": None,
                                "timed_out": True,
                            },
                            {
                                "role": "meta",
                                "identity": "meta",
                                "status": "synthesized",
                                "decision": "answer",
                                "resolved_answer": "meta-evidence-resolved-501",
                                "synthesis": "meta-evidence-synthesis-501",
                                "input_tokens": 60,
                                "output_tokens": 70,
                            },
                        ],
                        # Required since #32512: the wire always carries the
                        # tool trace, and an empty ledger says "complete with
                        # nothing observed" without dropping the field.
                        "tool_trace": {
                            "status": "complete",
                            "observed_actors": [],
                            "dropped_events": 0,
                            "gaps": [],
                            "events": [],
                        },
                    },
                },
            },
        },
    )


def fusion_http_fixtures() -> tuple[HttpFixtures, GatedHttpResponse]:
    alpha = fusion_run("fusion-alpha-501", keeper="alpha")
    target = fusion_run("fusion-target-501", keeper="beta")
    new = fusion_run("fusion-new-501", keeper="gamma")
    fixtures = overview_event_http_fixtures()
    fixtures["/api/v1/dashboard/planning"] = (
        200,
        {
            "goals": [
                {
                    "id": "goal-ssim-501",
                    "title": "raise SSIM to 0.95",
                    "phase": "executing",
                    "priority": 1,
                    "metric": "SSIM",
                    "target_value": "0.95",
                    "proof": {"state": "unreviewed"},
                }
            ],
            "rollup": {"active": 1, "verifying": 0, "done": 0, "dropped": 0},
            "backlog": {
                "todo": 1,
                "claimed": 0,
                "running": 0,
                "done": 0,
                "cancelled": 0,
            },
            "generated_at": "2026-08-27T00:00:00Z",
        },
    )
    fixtures["/api/v1/dashboard/harness-health"] = (
        200,
        {
            "generated_at": 1787557669.0,
            "recent_verdicts": [
                {
                    "timestamp": 1787557668.0,
                    "task_id": "task-linked-501",
                    "task_title": "linked Harness task",
                    "agent_name": "beta",
                    "gate": "verify",
                    "verdict": "approve",
                    "evaluator_runtime": "glm-coding",
                    "fallback_reason": None,
                    # SHA256(task_title + "\n" + completion_notes). The
                    # recorder writes it on every verdict and the reader takes
                    # it as opaque, but it is required: without it the whole
                    # harness snapshot fails to decode, the surface draws
                    # "(not loaded)" with its column headers and no rows, and
                    # the footer offers no verdict key because there is no row
                    # to open.
                    "notes_hash": "a51844ac8e12b5bf11f1c6db0021521298e5788cd64e4ec9b566dbf36a16fa51",
                }
            ],
            "calibration": {},
        },
    )
    initial_runs = GatedHttpResponse(fusion_runs_response([alpha, target]))
    fixtures[FUSION_RUNS_PATH] = initial_runs
    fixtures[f"{FUSION_RUNS_PATH}/fusion-alpha-501"] = fusion_detail_response(
        alpha, "wrong-alpha-judge-501"
    )
    fixtures[f"{FUSION_RUNS_PATH}/fusion-target-501"] = fusion_detail_response(
        target, "judge-proof-501"
    )
    fixtures[f"{FUSION_RUNS_PATH}/fusion-new-501"] = fusion_detail_response(
        new, "wrong-new-judge-501"
    )
    return fixtures, initial_runs


def seed_goal_linked_task(base_path: str) -> None:
    """Write the task the harness verdict judges, and the goal it serves.

    Tasks come off the local backlog and the goal link lives in its own
    registry -- the task record carries no goal on purpose. Both have to be on
    disk before the TUI starts or the chain has a hole at its middle hop.
    """
    tasks_dir = os.path.join(base_path, ".masc", "tasks")
    os.makedirs(tasks_dir, exist_ok=True)
    with open(os.path.join(tasks_dir, "backlog.json"), "w", encoding="utf-8") as handle:
        json.dump(
            {
                "tasks": [
                    {
                        "id": "task-linked-501",
                        "title": "linked Harness task",
                        "status": "todo",
                        "priority": 1,
                        "created_at": "2026-08-27T00:00:00Z",
                        "updated_at": "2026-08-27T00:00:00Z",
                    }
                ],
                "last_updated": "2026-08-27T00:00:00Z",
                "version": 1,
            },
            handle,
        )
    with open(
        os.path.join(tasks_dir, "goal_task_links.json"), "w", encoding="utf-8"
    ) as handle:
        json.dump({"links": [{"goal_id": "goal-ssim-501", "task_ids": ["task-linked-501"]}]}, handle)


def fusion_list_detail_interaction(
    fixtures: HttpFixtures,
    initial_runs: GatedHttpResponse,
) -> Interaction:
    """Select by run id across reorder, then read the four-stage flow."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        # Task Verdicts belongs to Planning; Tab cycles top-level families,
        # whereas v selects the three Planning tabs without skipping coverage.
        palette_go(process, master_fd, output, b"go Work", b"MASC Work")
        send_and_wait(process, master_fd, output, b"v", b"Task Review")
        send_and_wait(process, master_fd, output, b"v", b"automatic Gate rulings")
        # One full repaint, because the pane redraws only the rows that change
        # and the column headers are written once. The assertions below are
        # about the whole list, so they need the whole list in one frame.
        #
        # The wait ends on the verdict row, not on a column header. The
        # headers are drawn before the harness snapshot arrives, under
        # "(not loaded)", and the copy below reads the selected row: pressed
        # between the two, Y had no row to copy. Measured on this scenario
        # alone, 3 of 43 runs pressed Y about 20 ms before the snapshot and
        # timed out; a second Y in the same session copied. glm-coding is the
        # row's evaluator cell and nothing else on this screen draws it.
        harness_plain = CSI_RE.sub(
            b"",
            resize_and_wait(
                process,
                master_fd,
                output,
                rows=30,
                columns=220,
                needle=b"glm-coding",
                controls=(FULL_REDRAW,),
            ),
        )
        # The column row is upper case. Spelled in title case, "Verdict" was
        # still found -- in the tab label "Task Verdicts" one row above -- so
        # only two of these three ever said anything about the list.
        for needle in (b"GATE", b"VERDICT", b"EVALUATOR"):
            if needle not in harness_plain:
                raise AssertionError(
                    f"Harness list omitted {needle!r}: {harness_plain!r}"
                )
        # The verdict key used to be asserted here. The key strip is drawn on
        # its own row and only when it changes, so it is not in the frame the
        # list rows arrive in and often not in the repaint either -- the check
        # was reading a region this frame does not carry. The Enter below opens
        # the verdict, which proves the key works rather than that it is
        # spelled on screen.
        copy_reference(
            process,
            master_fd,
            output,
            b"masc://overview/tasks/task-linked-501",
        )
        verdict_start = len(output)
        send_and_wait(process, master_fd, output, b"\r", b"EVALUATOR VERDICT")
        # The heading precedes asynchronous task/goal enrichment. Inspect one
        # completed screen after both the linked goal and footer are present.
        observed = (b"masc://planning/goal-ssim-501", b"Left / Esc:back")
        for needle in observed:
            wait_for_output(process, master_fd, output, needle,
                            start=verdict_start, timeout=10.0)
        settled_at = max(end_of_needle(output, needle, verdict_start)
                         for needle in observed)
        wait_for_output(process, master_fd, output, FRAME_END,
                        start=settled_at, timeout=10.0)
        verdict_plain = screen_text(bytes(output[:output.rfind(FRAME_END) + len(FRAME_END)]))
        # The verdict names a task; the task names its goals; a goal declares
        # the metric it is measured by. All three were present and none of them
        # met on a screen, so a verdict said "approve" without saying what it
        # was approving towards.
        for needle in (
            b"linked Harness task",
            b"Agent",
            b"beta",
            b"approve",
            b"glm-coding",
            b"Fallback",
            b"masc://planning/goal-ssim-501",
            # #35734 spells hint keys the way the key table does: "Left", not
            # "left"; and with the table's spaces, which is the spelling the
            # footer's pin reads. The label is the table's own ("back") now
            # that this footer is read from the table rather than written out
            # in the renderer, where it read "list".
            b"Left / Esc:back",
            # #36652: the hand-written row left these two out. [ / ] is
            # answered here and only here, and the pair that answers a ruling
            # was missing from the one screen that exists for reading a ruling
            # in full. The pair is pinned, so a narrow footer keeps it.
            b"[ / ]:previous / next",
            b"y / x:agree / overrule",
        ):
            if needle not in verdict_plain:
                raise AssertionError(
                    f"Harness detail omitted {needle!r}: {verdict_plain!r}"
                )
        # The verdict names a task, the task names its goals, and a goal
        # declares its metric. All three were present before and none of them
        # met on a screen. Whichever way the chain resolves, the detail has to
        # say so rather than drawing nothing -- "not linked" and "not in this
        # backlog" are different facts and both are answers.
        if not any(
            marker in verdict_plain
            for marker in (b"TOWARDS", b"Towards")
        ):
            raise AssertionError(
                f"the verdict says nothing about what it aims at: {verdict_plain!r}"
            )
        # Back on the list, whose tab label carries the count. The word came
        # off when the count was split into page and ledger: it reads "(1)"
        # here and "(8 of 4197)" against a server with a backlog.
        send_and_wait(
            process, master_fd, output, b"\x1b[D", b"\xe2\x96\xb8Task Verdicts (1)"
        )
        read_available(master_fd, output)
        start = len(output)
        palette_go(process, master_fd, output, b"go Fusion", b"MASC Fusion")
        if not wait_for_fixture_event(
            process, master_fd, output, initial_runs.requested, timeout=10.0
        ):
            raise AssertionError("Fusion did not request its Registry list")
        # Several periodic ticks pass while the first read is held. The TUI
        # must keep that one request authoritative instead of continually
        # superseding it with a newer generation that will also be held.
        time.sleep(0.2)
        if initial_runs.calls != 1:
            raise AssertionError(
                "Fusion stacked Registry reads while one was in flight: "
                f"{initial_runs.calls} calls"
            )
        initial_runs.release.set()
        wait_for_output(
            process,
            master_fd,
            output,
            FUSION_TARGET_LISTED,
            start=start,
            timeout=3.0,
        )
        target_end = output.find(FUSION_TARGET_LISTED, start) + len(
            FUSION_TARGET_LISTED
        )
        wait_for_output(
            process,
            master_fd,
            output,
            FRAME_END,
            start=target_end,
            timeout=3.0,
        )
        frame_end = output.find(FRAME_END, target_end) + len(FRAME_END)
        loaded = bytes(output[start:frame_end])
        plain = CSI_RE.sub(b"", loaded)
        for column in (
            b"STARTED",
            b"AGE",
            b"STATE",
            b"KEEPER",
            b"PRESET",
            # No TOPOLOGY column: the header row is STARTED AGE STATE KEEPER
            # PRESET RUN, and the keeper column took the width the run id used
            # to sit whole in.
            b"RUN",
            # The selected run's own state under the list; the static
            # "Flow: Question → …" that opened this row is gone.
            b"evidence retained",
        ):
            if column not in plain:
                raise AssertionError(
                    f"Fusion did not draw the {column!r} source column: {plain!r}"
                )
        # The default Activity pane reserves 56 columns: a 200-column
        # terminal gives this footer 144 cells. Status yields before hints,
        # then copy/search yield before pinned exits. A wider frame must still
        # show those controls; check both states on the actual footer row.
        # [ / ] steps the open run and the dispatcher answers it only with a
        # detail open, so the run list does not offer it -- the open run's own
        # footer does.
        footer_head = (
            b"j/k:move  PgUp/PgDn:page  "
            b"K:calling Keeper  B:Board evidence  Home/End:top/bottom  "
            b"Enter:open"
        )
        exits = (b"Esc:back", b"q:quit")
        secondary = (b"Y:copy", b"/:find", b"n / N:next / previous match")
        # 144 cells fit all but the longest of the three once [ / ] left this
        # row: the key answers only with a run open, and the cell it was
        # holding is a cell a usable key can have. The order is what this
        # pins -- the search pair yields before copy, and both before the
        # exits -- not how many survive at one width.
        at_200 = (b"Y:copy", b"/:find")
        for columns, required, omitted in (
                (200, exits + at_200, (b"n / N:next / previous match",)),
                (280, exits + secondary, ())):
            resize_and_wait(
                process, master_fd, output, rows=30, columns=columns,
                needle=b"MASC Fusion", controls=(FULL_REDRAW,),
            )
            # The title and footer can arrive in different frames.
            drain_until_quiet(process, master_fd, output)
            drawn_rows = screen_rows(bytes(output))
            footer_row = screen_row_of(drawn_rows, footer_head)
            if footer_row < 0:
                raise AssertionError(
                    f"Fusion footer at {columns} columns lost navigation: {drawn_rows!r}"
                )
            footer = drawn_rows[footer_row]
            for control in required:
                if control not in footer:
                    raise AssertionError(
                        f"Fusion footer at {columns} columns omitted {control!r}: {footer!r}"
                    )
            for control in omitted:
                if control in footer:
                    raise AssertionError(
                        f"Fusion footer at {columns} columns retained dropped control {control!r}: {footer!r}"
                    )
        resize_and_wait(
            process, master_fd, output, rows=30, columns=120,
            needle=b"MASC Fusion", controls=(FULL_REDRAW,),
        )
        drain_until_quiet(process, master_fd, output)
        # Nothing is running in this fixture, and the title says so by not
        # saying it: it used to end "· 0 run", a pair that names no run and
        # reads as a third total beside the two counts before it.
        title_rows = screen_rows(bytes(output))
        title = title_rows.get(screen_row_of(title_rows, b"MASC Fusion"), b"")
        if b"0 run" in title or b"running" in title:
            raise AssertionError(
                f"the Fusion title counted runs that are not running: {title!r}"
            )
        if b"runs" not in title or b"done" not in title:
            raise AssertionError(f"the Fusion title lost its counts: {title!r}")

        selected = send_and_wait(
            process, master_fd, output, b"j", FUSION_TARGET_LISTED
        )
        if re.search(rb">[^\r\n]*fusion-target", CSI_RE.sub(b"", selected)) is None:
            raise AssertionError(f"Fusion did not select the target run: {selected!r}")

        target = fusion_run("fusion-target-501", keeper="beta")
        new = fusion_run("fusion-new-501", keeper="gamma")
        alpha = fusion_run("fusion-alpha-501", keeper="alpha")
        fixtures[FUSION_RUNS_PATH] = fusion_runs_response([target, new, alpha])
        refreshed = send_and_wait(process, master_fd, output, b"r", b"fusion-new-501")
        if (
            re.search(rb">[^\r\n]*fusion-target", CSI_RE.sub(b"", refreshed))
            is None
        ):
            raise AssertionError(
                f"Fusion refresh moved selection off its run id: {refreshed!r}"
            )

        # The detail no longer repeats the list's Flow row: its pipeline row
        # names the same four stops with the run's state on them.
        detail = send_and_wait(
            process, master_fd, output, b"\r", b"Pipeline:"
        )
        detail_plain = CSI_RE.sub(b"", detail)
        question_index = detail_plain.find(b"1  QUESTION")
        first_panel_index = detail_plain.find(b"2  PANEL RESPONSES")
        if question_index < 0 or first_panel_index < question_index:
            raise AssertionError(
                f"Fusion detail did not start with question then panel: {detail_plain!r}"
            )
        for needle in (
            b"masc://fusion/fusion-target-501",
            b"masc://keepers/beta",
            b"1  QUESTION",
            b"2  PANEL RESPONSES",
            b"PgUp/PgDn:page",
        ):
            if needle not in detail_plain:
                raise AssertionError(
                    f"Fusion detail omitted the {needle!r} summary: {detail_plain!r}"
                )
        copy_reference(
            process,
            master_fd,
            output,
            b"masc://fusion/fusion-target-501",
        )
        send_and_wait(
            process, master_fd, output, b"\x1b[6~", b"panel-failure-second-501"
        )
        # The page lands over several frames -- the responses, then the judge
        # section under them -- so the frame the first row arrives in does not
        # hold the rest. Wait for the frames to stop and read the screen.
        drain_until_quiet(process, master_fd, output)
        panel_plain = screen_text(bytes(output))
        # Which page a row lands on follows the RUN block's height above it,
        # and that block is not this scenario's subject: the panel summary
        # sits at the foot of the first page when the block is short and at
        # the head of the second when it is tall. Read both.
        two_pages = detail_plain + panel_plain
        for needle in (
            b"panel-answer-first-501",
            b"panel-failure-second-501",
            b"1 answered / 1 failed",
            b"10 input / 20 output tokens",
        ):
            if needle not in two_pages:
                raise AssertionError(
                    f"Fusion panel page omitted {needle!r}: {panel_plain!r}"
                )
        for needle in (
            b"3  JUDGE",
            b"judge-proof-501",
            # The topology was a sentence ("Judge topology: judge-of-judges")
            # and is now the row that draws it: the lens counts, then the
            # shape they add up to.
            "first ×2".encode(),
            "meta ×1".encode(),
            b"judge-of-judges",
            b"First 1 [synthesized] ollama_cloud.minimax-m3",
            b"First 2 [failed] ollama_cloud.deepseek-v4-pro",
        ):
            if needle not in panel_plain:
                raise AssertionError(
                    f"Fusion detail lost its judge section or lenses "
                    f"({needle!r}): {panel_plain!r}"
                )
        # The lens cards grew the detail past one page: the flow now ends on
        # the page after the panel one.
        tail = send_and_wait(
            process, master_fd, output, b"\x1b[6~", b"5  EVIDENCE RECORDED"
        )
        tail_plain = CSI_RE.sub(b"", tail)
        for needle in (
            b"4  TOOL EXECUTIONS",
            b"5  EVIDENCE RECORDED",
            b"masc://board/post-fusion-target-501",
        ):
            if needle not in tail_plain:
                raise AssertionError(
                    f"Fusion flow did not end with Tool then Evidence: {tail_plain!r}"
                )
        if (
            b"wrong-alpha-judge-501" in detail_plain
            or b"wrong-new-judge-501" in detail_plain
        ):
            raise AssertionError(
                f"Fusion opened the numeric cursor, not the run id: {detail_plain!r}"
            )

        send_and_wait(process, master_fd, output, b"\x1b", b"fusion-new-501")
        os.write(master_fd, b"q")

    return interact


def fusion_live_reload_http_fixtures() -> tuple[HttpFixtures, GatedHttpResponse, SequencedHttpResponse]:
    """The feed initialize is held at the gate so the frame lands while the
    operator is already on the Fusion surface.

    Releasing the gate is what makes the causality readable: with the cadence
    at its 60-second default, the only things that can fetch the run list are
    the surface entry and the status frame the stream then pushes. The list
    answer changes between the two fetches -- the second run appears -- so the
    reload draws a row that was not on the first screen.
    """
    alpha = fusion_run("fusion-alpha-601", keeper="alpha", status="running")
    target = fusion_run("fusion-target-601", keeper="beta")
    fixtures = overview_event_http_fixtures()
    mcp_initialize = GatedHttpResponse(
        RawHttpResponse(
            200,
            json.dumps({"jsonrpc": "2.0", "id": 1, "result": {}}).encode(),
            content_type="application/json",
            headers=(("Mcp-Session-Id", "mcp_fixture_session"),),
        )
    )
    fixtures["/mcp"] = mcp_initialize
    fixtures["/mcp?sse_kind=observer"] = RawHttpResponse(
        200,
        (
            b'event: message\n'
            b'data: {"type":"fusion_run_status","run":{"run_id":"fusion-target-601",'
            b'"keeper":"beta","preset":"trio","topology":"simple",'
            b'"started_at":1787557669.7,"finished_at":1787557684.7,"status":"completed"}}\n\n'
        ),
        content_type="text/event-stream",
    )
    run_list = SequencedHttpResponse(
        [
            fusion_runs_response([alpha]),
            fusion_runs_response([alpha, target]),
        ]
    )
    fixtures[FUSION_RUNS_PATH] = run_list
    return fixtures, mcp_initialize, run_list


def fusion_live_reload_interaction(
    run_list: SequencedHttpResponse, mcp_initialize: GatedHttpResponse
) -> Interaction:
    """Tab lands on Fusion (the ring stop this scenario exists to prove), one
    status frame on the observer feed refetches the list, and the new run
    draws. Exactly two list loads in total -- the entry and the trigger."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        def list_loads() -> int:
            # HttpRequests records POST bodies; this list is fetched by GET.
            return run_list.served

        landed = palette_go(process, master_fd, output, b"go Fusion", b"fusion-alpha")
        if list_loads() != 1:
            raise AssertionError(
                f"surface entry alone should load the list once, saw {list_loads()}"
            )
        mcp_initialize.release.set()
        wait_for_output(
            process,
            master_fd,
            output,
            b"fusion-target",
            start=len(landed),
            timeout=10.0,
        )
        if list_loads() != 2:
            raise AssertionError(
                f"the status frame should reload the list exactly once, "
                f"saw {list_loads()} loads"
            )
        os.write(master_fd, b"q")

    return interact


def run_fusion_history_regression(executable: str) -> None:
    """Historical evidence remains inspectable without a retained run or recent Board row."""
    fixtures = overview_event_http_fixtures()
    run = fusion_run("history-701", keeper="not-a-proven-caller")
    post = fusion_detail_response(run, "historical-judge-synthesis-701")[1]["evidence"]["post"]
    post.update(author="board-author-701", body="original-board-body-701")
    # A recorded zero remains a chart observation; a failed panel has no usage.
    post["meta"]["panel"].append({
        "model": "panel-zero-701", "status": "answered",
        "answer": "zero-usage-answer-701", "input_tokens": 0, "output_tokens": 0,
    })
    post["meta"]["observed_usage"] = {"input_tokens": 101, "output_tokens": 202}
    refreshed = json.loads(json.dumps(post))
    refreshed["meta"]["observed_usage"]["input_tokens"] = 303
    wrong_post = json.loads(json.dumps(refreshed))
    wrong_post["origin"]["fusion_run_id"] = "different-run-702"
    response = fusion_runs_response([])
    response[1]["replay"] = {
        "status": "complete", "lines_read": 68,
        "malformed_lines": 34, "dropped_running": 34,
    }
    response[1]["historical_evidence"] = [{
        "run_id": "history-701", "post_id": post["id"],
        "title": post["title"], "created_at": 1787557684.0,
    }]
    second_post = json.loads(json.dumps(post))
    second_post.update(id="post-history-702", title="Second historical Fusion", author="board-author-702")
    second_post["origin"]["fusion_run_id"] = "history-702"
    second_post["meta"]["panel"] = [second_post["meta"]["panel"][1]]
    response[1]["historical_evidence"].append({
        "run_id": "history-702", "post_id": second_post["id"],
        "title": second_post["title"], "created_at": 1787557600.0,
    })
    fixtures[FUSION_RUNS_PATH] = response
    fixtures[f"/api/v1/board/{second_post['id']}"] = (200, second_post)
    fixtures[f"/api/v1/board/{post['id']}"] = SequencedHttpResponse([
        (200, post), (200, refreshed), (200, wrong_post), (200, refreshed),
    ])

    def interact(process, master_fd, slave_fd, output, base_path):
        palette_go(process, master_fd, output, b"go fusion", b"MASC Fusion")
        send_and_wait(process, master_fd, output, b"\r", b"HISTORICAL BOARD EVIDENCE")
        read_available(master_fd, output)
        before_resize = len(output)
        resize_and_wait(
            process, master_fd, output, rows=110, columns=170,
            needle=b"BOARD ORIGINAL", controls=(FULL_REDRAW,),
        )
        redraw = output.find(FULL_REDRAW, before_resize)
        if redraw < 0:
            raise AssertionError("historical inspector resize did not fully redraw")
        wait_for_output(process, master_fd, output, FRAME_END, start=redraw, timeout=3.0)
        end = output.find(FRAME_END, redraw) + len(FRAME_END)
        start = output.rfind(FRAME_START, before_resize, redraw)
        frame = bytes(output[redraw if start < 0 else start:end])
        visible = CSI_RE.sub(b"", frame)
        for marker in (
            b"This Board evidence does not provide execution status or finish time",
            b"Board author: board-author-701", b"Run reference: history-701",
            b"Observed tokens: 101 input / 202 output", b"Observed cost: not recorded",
            b"question-proof-501", b"panel-answer-first-501",
            b"historical-judge-synthesis-701", b"TOOL EXECUTIONS",
            b"original-board-body-701",
            b"measured 2/3 panels: 10 input / 20 output tokens",
            b"Panel 3 [answered] panel-zero-701  (0 in / 0 out)",
        ):
            if marker not in visible:
                raise AssertionError(f"historical inspector missing {marker!r}: {visible!r}")
        if b"not-a-proven-caller" in visible:
            raise AssertionError("historical evidence invented a retained run caller")
        chart = visible.split(b"Model token distribution (measured 2/3 panels):", 1)[1]
        chart = chart.split(b"Panel 1 [answered]", 1)[0]
        for model in (b"panel-first-501", b"panel-zero-701"):
            if model not in chart:
                raise AssertionError(f"recorded panel usage missing from chart: {chart!r}")
        if b"panel-second-501" in chart:
            raise AssertionError(f"unobserved failed-panel usage was charted: {chart!r}")
        failed_card = visible.split(b"Panel 2 [failed]", 1)[1].split(b"Panel 3 [answered]", 1)[0]
        if b"Token usage: not recorded" not in failed_card:
            raise AssertionError(f"failed-panel usage must remain unknown: {failed_card!r}")
        print("FUSION_HISTORY_PTY_FRAME=" + json.dumps({
            "rows": 110, "columns": 170,
            "ansi_zlib_base64": base64.b64encode(zlib.compress(frame)).decode("ascii"),
            "ansi_bytes": len(frame),
        }), flush=True)
        send_and_wait(
            process, master_fd, output, b"r",
            b"Observed tokens: 303 input / 202 output",
        )
        send_and_wait(
            process, master_fd, output, b"r",
            b"historical Fusion Board identity does not match the selected run and post",
        )
        retained = b"Previous Board reading retained"
        resize_and_wait(
            process, master_fd, output, rows=111, columns=170,
            needle=retained, controls=(FULL_REDRAW,),
        )
        retained_at = output.rfind(retained)
        wait_for_output(
            process, master_fd, output, FRAME_END,
            start=retained_at + len(retained), timeout=3,
        )
        frame_end = output.find(FRAME_END, retained_at) + len(FRAME_END)
        stale_visible = screen_text(bytes(output[:frame_end]))
        mismatch = (
            b"historical Fusion Board identity does not match the selected run and post"
        )
        if stale_visible.count(mismatch) != 1 or stale_visible.count(retained) != 1:
            raise AssertionError(
                f"Historical Board lost its error or retained reading: {stale_visible!r}"
            )
        if b"refresh failed" in stale_visible:
            raise AssertionError("Historical Board refresh repeated its error verdict")
        if b"different-run-702" in stale_visible:
            raise AssertionError("mismatched Board origin replaced selected evidence")
        send_and_wait(process, master_fd, output, b"r", b"Observed tokens: 303 input / 202 output")
        all_failed = send_and_wait(
            process, master_fd, output, b"]", b"panel token usage: not recorded",
        )
        all_failed = CSI_RE.sub(b"", frame_containing(all_failed, b"panel token usage: not recorded"))
        if b"Board author: board-author-702" not in all_failed:
            raise AssertionError(f"all-failed summary lost exact Board identity: {all_failed!r}")
        send_and_wait(process, master_fd, output, b"[", b"Board author: board-author-701")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Fusion")
        send_and_wait(process, master_fd, output, b"\r", b"HISTORICAL BOARD EVIDENCE")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Fusion")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Dashboard")
        send_and_wait(process, master_fd, output, b"q", b"q: press again to quit")

    run_terminal_scenario(
        executable, description="historical Fusion evidence inspection and refresh",
        interact=interact, http_fixtures=fixtures,
    )
