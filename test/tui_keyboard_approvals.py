from __future__ import annotations

import json
import os
import re
import select
import subprocess
import tempfile
import time
from collections.abc import Iterator
from contextlib import contextmanager

from tui_keyboard_harness import (
    CSI_RE,
    json_payload_fixture,
    FRAME_END,
    FULL_REDRAW,
    HttpFixtures,
    HttpResponse,
    HttpRequests,
    Interaction,
    approval_selection_snapshot,
    approvals_header,
    copy_reference,
    drain_until_quiet,
    frame_containing,
    overview_event_http_fixtures,
    palette_go,
    read_available,
    resize_and_wait,
    send_and_wait,
    tab_until,
    wait_for_http_request,
    wait_for_output,
)

KEEPER_ASK_ANSWER_PATH = "/api/v1/keepers/ask-answer"


def keeper_asks_response(*, long_question: bool = False) -> HttpResponse:
    return (
        200,
        {
            "keeper": None,
            "open_count": 1,
            "asks": [
                {
                    "keeper": "alpha",
                    "ask_id": "ask-1",
                    "asked_at": 1787557669.0,
                    "context": "the rollout needs a call",
                    "resolution": {"state": "open"},
                    "questions": [
                        {
                            "question_id": "q-1",
                            "header": "Rollout",
                            "prompt": "ship the cold-start change now?",
                            "mode": "single",
                            "free_text": {"allowed": False},
                            "choices": [
                                {"choice_id": "c-yes", "label": "ship it"},
                                {"choice_id": "c-no", "label": "hold"},
                            ],
                        },
                        *([
                            {
                                "question_id": "q-2",
                                "header": "Explanation",
                                "prompt": "Explain the rollout decision",
                                "mode": "single",
                                "free_text": {"allowed": True},
                                "choices": [{
                                    "choice_id": "c-long",
                                    "label": "Consider the deployment consequences. " * 80,
                                }],
                            }
                        ] if long_question else []),
                    ],
                }
            ],
        },
    )


def keeper_ask_answer_interaction(
    fixtures: HttpFixtures, ask_requests: HttpRequests
) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        wait_for_output(process, master_fd, output, b"Health: ", start=0, timeout=10.0)
        cluster_end = output.find(b"Health: ") + len(b"Health: ")
        wait_for_output(
            process, master_fd, output, FRAME_END, start=cluster_end, timeout=3.0
        )
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=40,
            columns=180,
            needle=b"MASC Dashboard",
            final_cursor=b"\x1b[?25l",
        )
        tab_until(process, master_fd, output, b"MASC Keepers")
        palette_go(process, master_fd, output, b"go Approvals", b"Questions waiting on you")

        # Open an approval's detail. The answer flow is drawn by the list, so
        # this is where [a] used to set the mode and change nothing on screen.
        # The detail opens on its own title, "MASC Approval"; the way out is
        # the footer's to say (#35985). The list's title is "MASC Approvals",
        # so the wait rules out the trailing s.
        detail_title = re.compile(rb"MASC Approval(?!s)")
        detail = send_and_wait(process, master_fd, output, b"\r", detail_title)
        if b"Questions waiting on you" in CSI_RE.sub(
            b"", frame_containing(detail, detail_title)
        ):
            raise AssertionError(
                "the detail draws the questions; this scenario no longer tests "
                f"the surface that cannot: {detail!r}"
            )

        answering = send_and_wait(process, master_fd, output, b"a", b"Enter:answer")
        answering_plain = CSI_RE.sub(b"", answering)
        for needle in (b"ship the cold-start change now?", b"ship it", b"hold"):
            if needle not in answering_plain:
                raise AssertionError(
                    f"answering the ask did not draw {needle!r}: {answering!r}"
                )

        # Pick, arm, send. Each step has to be visible: the answer used to be
        # composable and unsendable, because this was the one site in the file
        # waiting for Enter under the name terminals do not send.
        # send_and_wait reads the raw stream and colour sits between the mark
        # and the label, so wait on the mark and check the pairing on the
        # stripped frame.
        picked = send_and_wait(process, master_fd, output, b"1", b"1 (o) ")
        picked_plain = CSI_RE.sub(b"", picked)
        if b"(o) c-yes" not in picked_plain:
            raise AssertionError(f"picking did not mark c-yes: {picked!r}")
        if b"(o) c-no" in picked_plain:
            raise AssertionError(f"picking one choice marked both: {picked!r}")
        send_and_wait(
            process, master_fd, output, b"\r", b"Press Enter again to send"
        )
        os.write(master_fd, b"\r")
        drain_until_quiet(process, master_fd, output)
        sent = [
            body
            for path, body in ask_requests
            if path == KEEPER_ASK_ANSWER_PATH
            and b'"ask_id":"ask-1"' in body
            and b'"c-yes"' in body
        ]
        if not sent:
            raise AssertionError(
                f"the answer never reached the server: {ask_requests!r}"
            )

        os.write(master_fd, b"q")

    return interact


def question_reader_interaction(requests: HttpRequests) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        palette_go(process, master_fd, output, b"go Approvals", b"Questions waiting on you")
        send_and_wait(process, master_fd, output, b"a", b"Question 1/2")
        send_and_wait(process, master_fd, output, b"\x1b[C", b"Question 2/2")
        resized = resize_and_wait(
            process, master_fd, output, rows=24, columns=100,
            needle=b"Question 2/2", final_cursor=b"\x1b[?25l",
        )
        progress = re.search(rb"Lines (\d+)-(\d+)/(\d+)", CSI_RE.sub(b"", resized))
        if progress is None or int(progress[2]) >= int(progress[3]):
            raise AssertionError(f"long question did not overflow: {resized!r}")
        paged = send_and_wait(process, master_fd, output, b"\x1b[6~", b"Lines ")
        progress = re.search(rb"Lines (\d+)-(\d+)/(\d+)", CSI_RE.sub(b"", paged))
        if progress is None or int(progress[1]) <= 1:
            raise AssertionError(f"PageDown did not scroll the question: {paged!r}")
        send_and_wait(process, master_fd, output, b"\x1b[D", b"Question 1/2")
        reset = send_and_wait(process, master_fd, output, b"\x1b[C", b"Question 2/2")
        if b"Lines 1-" not in CSI_RE.sub(b"", reset):
            raise AssertionError(f"question navigation kept the previous scroll: {reset!r}")

        # The choices fill the reader, but opening text entry must reveal the
        # editor immediately and keep its caret visible as the text grows.
        send_and_wait(process, master_fd, output, b"t", b"write: ")
        typed = send_and_wait(
            process, master_fd, output,
            b"operator response " * 100 + b"VISIBLE_EDITOR_TAIL",
            b"VISIBLE_EDITOR_TAIL",
        )
        if "▌".encode() not in CSI_RE.sub(b"", frame_containing(typed, b"VISIBLE_EDITOR_TAIL")):
            raise AssertionError(f"the text caret left the visible reader: {typed!r}")
        resize_and_wait(
            process, master_fd, output, rows=22, columns=90,
            needle=b"VISIBLE_EDITOR_TAIL", final_cursor=b"\x1b[?25l",
        )
        send_and_wait(process, master_fd, output, b"\x1b", b"PgUp/PgDn")
        drain_until_quiet(process, master_fd, output)
        if any(path == KEEPER_ASK_ANSWER_PATH for path, _ in requests):
            raise AssertionError(f"browsing or cancelling text sent an answer: {requests!r}")
        os.write(master_fd, b"q")

    return interact


def gate_mode_picker_interaction(requests: HttpRequests) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        palette_go(process, master_fd, output, b"go Approvals", b"MASC Approvals")
        mode_paths = {
            "/api/v1/dashboard/gate/mode",
            "/api/v1/dashboard/gate/external-mode",
        }

        def mode_requests() -> list[tuple[str, object]]:
            return [(path, json.loads(body)) for path, body in requests if path in mode_paths]

        send_and_wait(process, master_fd, output, b"w", b"Ask me for each decision")
        send_and_wait(process, master_fd, output, b"\x1b[B", b"Let Auto Judge decide")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Approvals")
        drain_until_quiet(process, master_fd, output)
        if mode_requests():
            raise AssertionError(f"opening, moving or cancelling changed Gate mode: {requests!r}")

        send_and_wait(process, master_fd, output, b"w", b"Ask me for each decision")
        send_and_wait(process, master_fd, output, b"\x1b[B", b"Let Auto Judge decide")
        drain_until_quiet(process, master_fd, output)
        if mode_requests():
            raise AssertionError(f"Gate mode changed before Enter: {requests!r}")
        send_and_wait(process, master_fd, output, b"\r", b"MASC Approvals")
        drain_until_quiet(process, master_fd, output)
        expected = [("/api/v1/dashboard/gate/mode", {"mode": "auto_judge"})]
        if mode_requests() != expected:
            raise AssertionError(f"Enter did not apply only the selected Workspace mode: {requests!r}")

        send_and_wait(process, master_fd, output, b"e", b"Ask me for each decision")
        drain_until_quiet(process, master_fd, output)
        if mode_requests() != expected:
            raise AssertionError(f"opening Outside services changed a mode: {requests!r}")
        send_and_wait(process, master_fd, output, b"\r", b"MASC Approvals")
        drain_until_quiet(process, master_fd, output)
        expected.append(("/api/v1/dashboard/gate/external-mode", {"mode": "manual"}))
        if mode_requests() != expected:
            raise AssertionError(f"Outside services choice used the wrong lane or mode: {requests!r}")
        # [ and ] walk the ask cursor on this surface, and the walk used to
        # take them from the command palette drawn over it: a query with a
        # bracket in it, a task title like [#31874], arrived with the brackets
        # gone and the cursor moved behind the overlay.
        send_and_wait(process, master_fd, output, b":", b"MASC Command palette")
        send_and_wait(
            process,
            master_fd,
            output,
            b"a[b]c",
            # The prompt is styled, then a plain space, then the query.
            re.compile(rb":(?:" + CSI_RE.pattern + rb")* a\[b\]c"),
        )
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Approvals")
        os.write(master_fd, b"q")

    return interact


BLOCKED_GATE_REASON_PREFIX = b"Auto Judge exact attempt quarantined after provider"
BLOCKED_GATE_REASON_TAIL = b"operator must retain this terminal explanation"

# ESC [ 8 m is the conceal: a terminal honouring it stops drawing what comes
# after, so the first words stand for the whole ask. The three constants name
# the three things the screen owes the operator - the body's opening, the part
# the escape would have hidden, and the escape itself.
CONCEAL_ATTACK_CONTENT = "공유합니다 \x1b[8m @everyone https://evil.example/x \x1b[0m"
CONCEAL_ATTACK_VISIBLE = "공유합니다".encode("utf-8")
CONCEAL_ATTACK_TAIL = b"evil.example/x"


def blocked_gate_detail_http_fixtures() -> HttpFixtures:
    fixtures = overview_event_http_fixtures()
    reason = (
        "Auto Judge exact attempt quarantined after provider transport closed "
        "while decoding the structured verdict; operator must retain this "
        "terminal explanation"
    )
    fixtures["/api/v1/dashboard/gate"] = (
        200,
        {
            "approval_queue": [
                {
                    "id": "appr-blocked-detail",
                    "keeper_name": "alpha",
                    "tool_name": "tool_execute",
                    "input_preview": '{"command":"deploy"}',
                    "input_hash": "a" * 64,
                    "sequence": 41,
                    "exact_attempt": {
                        "state": "bound",
                        "status": "quarantined",
                        "quarantine_cause": "cancellation",
                    },
                    "summary_status": {"status": "failed", "reason": reason},
                    "summary_attempt_disposition": {"code": "settled"},
                    # What the server derives from a settled attempt whose
                    # summary failed (phase_of_disposition_and_summary).
                    "phase": "blocked",
                }
            ],
            "approval_queue_state": {"state": "ready"},
            "hitl": {
                "gate_mode": {"mode": "auto_judge"},
                "external_gate_mode": {"mode": "manual"},
            },
            "approval_rules": [],
            "approval_rules_state": {"state": "ready"},
        },
    )
    return fixtures


def blocked_gate_detail_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=40,
            columns=100,
            needle=b"MASC Dashboard",
        )
        palette_go(process, master_fd, output, b"go Approvals", b"MASC Approvals")
        wait_for_output(
            process, master_fd, output, b"AUTO JUDGE BLOCKED", start=0, timeout=5.0
        )
        detail = send_and_wait(
            process, master_fd, output, b"\r", BLOCKED_GATE_REASON_TAIL
        )
        frame = frame_containing(detail, BLOCKED_GATE_REASON_TAIL)
        plain = CSI_RE.sub(b"", frame)
        for needle in (
            b"reason",
            BLOCKED_GATE_REASON_PREFIX,
            BLOCKED_GATE_REASON_TAIL,
            b"this exact attempt cannot be replayed",
        ):
            if needle not in plain:
                raise AssertionError(
                    f"blocked Gate detail omitted {needle!r}: {frame!r}"
                )
        if BLOCKED_GATE_REASON_PREFIX + b"\xe2\x80\xa6" in plain:
            raise AssertionError(f"blocked Gate reason was cell-truncated: {frame!r}")
        os.write(master_fd, b"q")

    return interact


# The whole-input pane is the same screen a concealing escape aims at: a
# value carrying ESC [ 8 m would hide the ask behind its first words and
# show only what the attacker wants shown. The pane draws input values
# through terminal_safe_text, which keeps newline (0x0A) and replaces the
# rest of C0/C1 with spaces, so the escape must arrive as visible text,
# never as its byte.
def concealed_input_http_fixtures() -> HttpFixtures:
    fixtures = blocked_gate_detail_http_fixtures()
    gate = json_payload_fixture(fixtures, "/api/v1/dashboard/gate")
    approval_queue = gate["approval_queue"]
    assert isinstance(approval_queue, list) and isinstance(approval_queue[0], dict)
    row = approval_queue[0]
    row["input"] = {
        "connector": "discord",
        "content": CONCEAL_ATTACK_CONTENT,
    }
    row["tool_name"] = "connector_post"
    row["input_preview"] = '{"connector":"discord","content'
    return fixtures


def concealed_input_detail_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=40,
            columns=100,
            needle=b"MASC Dashboard",
        )
        palette_go(process, master_fd, output, b"go Approvals", b"MASC Approvals")
        # The row names the operation the producer sent, verbatim: the decoder
        # passes [tool_name] through for every operation but identity_call.
        wait_for_output(
            process, master_fd, output, b"connector_post", start=0, timeout=5.0
        )
        # The queue row's preview stops before the body, so these bytes can
        # only come from the detail pane this scenario is about.
        detail = send_and_wait(
            process, master_fd, output, b"\r", CONCEAL_ATTACK_VISIBLE
        )
        frame = frame_containing(detail, CONCEAL_ATTACK_VISIBLE)
        plain = CSI_RE.sub(b"", frame)
        # The pane labels the value it drew, key by key.
        if b"content" not in plain:
            raise AssertionError(f"conceal input key missing from detail: {frame!r}")
        # The body rides whole: the ask's first words are on the screen.
        if CONCEAL_ATTACK_VISIBLE not in plain:
            raise AssertionError(
                f"conceal input body missing from detail: {frame!r}"
            )
        # ...and so does the part the escape was placed to hide.
        if CONCEAL_ATTACK_TAIL not in plain:
            raise AssertionError(
                f"conceal input tail missing from detail: {frame!r}"
            )
        # Asked of the raw frame, not of [plain]: CSI_RE strips exactly the
        # sequence under test, so this assertion could never fail if it read
        # the stripped copy. No renderer here emits SGR 8 (grep: 0 hits), so
        # any occurrence came from the value.
        if b"\x1b[8m" in frame:
            raise AssertionError(
                "the detail pane drew a raw ESC: the input value reached the"
                f" terminal unsanitized: {frame!r}"
            )
        os.write(master_fd, b"q")

    return interact


# A held Keeper tool call asks "Run <tool> on <subject>?", and the subject is
# the command the model wrote. ESC [ 1 A ESC [ 2 K in it moves the cursor up
# a row and clears it, so the detail the operator reads before pressing y
# could be rewritten by the ask itself. The question is the field under test;
# the args carry a marker past the list row's cut, so only the detail pane can
# draw it and the frame that holds it is the detail's.
ESCAPED_QUESTION_INJECTED = b"ok\x1b[1A\x1b[2Krm"
ESCAPED_QUESTION_TAIL = b"rm -rf /tmp/forged?"
ESCAPED_QUESTION_VISIBLE = b"ok\\x1B[1A\\x1B[2Krm"
ESCAPED_QUESTION_DETAIL_MARKER = b"detail-only-marker"


def escaped_question_http_fixtures() -> HttpFixtures:
    fixtures = overview_event_http_fixtures()
    command = "echo " + "x" * 120 + " " + ESCAPED_QUESTION_DETAIL_MARKER.decode()
    fixtures["/api/v1/keepers/tool-approvals"] = (
        200,
        {
            "pending": [
                {
                    "keeper": "alpha",
                    "tool_call_id": "tool-escaped-question",
                    "tool": "Bash",
                    "args": json.dumps({"command": command}),
                    "question": "Run Bash on echo "
                    + ESCAPED_QUESTION_INJECTED.decode()
                    + " -rf /tmp/forged?",
                    "because": None,
                    "asked_at": 1787766400.0,
                    "timeout_sec": 300.0,
                }
            ]
        },
    )
    return fixtures


def escaped_question_detail_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=40,
            columns=100,
            needle=b"MASC Dashboard",
        )
        palette_go(process, master_fd, output, b"go Approvals", b"MASC Approvals")
        wait_for_output(
            process, master_fd, output, b"tool-escaped-question", start=0, timeout=5.0
        )
        detail = send_and_wait(
            process, master_fd, output, b"\r", ESCAPED_QUESTION_DETAIL_MARKER
        )
        frame = frame_containing(detail, ESCAPED_QUESTION_DETAIL_MARKER)
        plain = CSI_RE.sub(b"", frame)
        # Asked of the raw frame: CSI_RE strips exactly the bytes under test.
        if ESCAPED_QUESTION_INJECTED in frame:
            raise AssertionError(
                "the approval detail drew the question's escapes raw, so the"
                f" ask could rewrite the rows above it: {frame!r}"
            )
        # The escape is drawn as text where it sat, so the operator sees one
        # was tried instead of a blank that reads as spacing.
        if ESCAPED_QUESTION_VISIBLE not in plain:
            raise AssertionError(
                f"the question's escapes are not drawn visibly: {frame!r}"
            )
        # The words the escape surrounded are still on the pane.
        if ESCAPED_QUESTION_TAIL not in plain:
            raise AssertionError(
                f"the question's tail is missing from the detail: {frame!r}"
            )
        os.write(master_fd, b"q")

    return interact


def approval_selection_identity_interaction(
    fixtures: HttpFixtures,
    initial_items: list[dict[str, object]],
    approval_new: dict[str, object],
) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        wait_for_output(process, master_fd, output, b"Health: ", start=0, timeout=10.0)
        cluster_end = output.find(b"Health: ") + len(b"Health: ")
        wait_for_output(
            process,
            master_fd,
            output,
            FRAME_END,
            start=cluster_end,
            timeout=3.0,
        )
        tab_until(process, master_fd, output, b"MASC Keepers")
        # The operator queue can answer before the held-call/Question/Gate
        # polls. Wait for the complete reading before checking its breakdown.
        ready_header = re.compile(
            rb"MASC Approvals(?:\x1b\[[0-9;]*m)* \("
            rb"(?:\x1b\[[0-9;]*m)*3 op(?:\x1b\[[0-9;]*m)*\)"
        )
        landed = palette_go(process, master_fd, output, b"go Approvals", ready_header)
        # Three operator entries, no held call, no Gate row: the title names
        # the one kind that has rows and says no zero for the two that do not.
        landed_plain = CSI_RE.sub(b"", frame_containing(landed, ready_header))
        if b"MASC Approvals (3 op)" not in landed_plain or b"0 held" in landed_plain:
            raise AssertionError(
                f"Approvals title did not read its count by kind: {landed_plain!r}"
            )
        selected = send_and_wait(process, master_fd, output, b"j", b"keeper_probe")
        selected_plain = CSI_RE.sub(b"", selected)
        if not re.search(
            rb">\s+masc-tui\s+keeper_probe\s+keeper\s+beta", selected_plain
        ):
            raise AssertionError(f"fixture did not select approval B: {selected!r}")

        # An ask names what it is asking about, so the row under the cursor is
        # followable. The kind is read from the typed target, not matched as
        # text: this one targets keeper beta.
        copy_reference(process, master_fd, output, b"masc://keepers/beta")

        fixtures[
            "/api/v1/operator?view=summary&include_messages=0&include_keepers=0"
        ] = approval_selection_snapshot([approval_new, *initial_items])
        refreshed = send_and_wait(
            process,
            master_fd,
            output,
            b"r",
            approvals_header(4),
        )
        refreshed_frame = frame_containing(
            refreshed,
            approvals_header(4),
        )
        refreshed_plain = CSI_RE.sub(b"", refreshed_frame)
        if not re.search(
            rb">\s+masc-tui\s+keeper_probe\s+keeper\s+beta",
            refreshed_plain,
        ):
            raise AssertionError(
                f"approval refresh changed the selected token: {refreshed!r}"
            )

        armed = send_and_wait(process, master_fd, output, b"y", b"Press y again:")
        expected_arm = b"Press y again: keeper_probe on keeper (masc_keeper_status)"
        if expected_arm not in armed:
            raise AssertionError(f"approval refresh armed the wrong token: {armed!r}")
        os.write(master_fd, b"q")

    return interact


VERIFICATION_VERDICT_PATH = "/api/v1/verification/verdict"


# The TUI asks for one view and one page, so the stub answers that exact
# query. Spelled once here because three scenarios key their fixtures on it.
VERIFICATION_QUEUE_PATH = (
    "/api/v1/verification/requests?view=awaiting&limit=200&offset=0"
)


def verification_snapshot(
    rows: list[dict[str, object]],
    *,
    total: int | None = None,
    offset: int = 0,
    truncated: bool = False,
    view: str = "awaiting",
) -> dict[str, object]:
    """The projection the TUI decodes.

    Every field is required on the reader's side: a snapshot that does not say
    which list it holds cannot be drawn honestly, because the same row count
    means "nothing is waiting" in the queue and "the newest page" in the
    history.
    """
    return {
        "requests": rows,
        "total": len(rows) if total is None else total,
        "view": view,
        "offset": offset,
        "returned": len(rows),
        "truncated": truncated,
        "awaiting_unresolved_total": 0,
        "awaiting_unresolved": [],
        "backlog_error": None,
        "backlog_recovery": None,
    }


def verification_request_row(task_id: str) -> dict[str, object]:
    return {
        "request_id": f"vr-{task_id}",
        "task_id": task_id,
        "task_title": f"finish {task_id}",
        # request_kind, request_summary and next_action are gone from the
        # producer: Verification_protocol wrote them as the fixed literals
        # "normal", "" and "", so three rows of the detail pane said the same
        # thing on every request ever drawn. Nothing reads them now.
        "submitted_by": "keeper-alpha",
        "created_at": "2026-08-25T14:00:00+09:00",
        "required_artifacts": ["diff"],
        "submitted_evidence": ["diff"],
    }


HARNESS_HEALTH_PATH = "/api/v1/dashboard/harness-health"


def harness_health_snapshot() -> dict[str, object]:
    """A ruled ledger, which is what makes Task Verdicts draw its full head.

    With no calibration the ledger block is empty and the head is six rows;
    with one it is nine, and the surface's row arithmetic has to hold for
    both. The block is where that arithmetic went wrong (masc_tui_render.ml,
    render_harness_list).
    """
    return {
        "recent_verdicts": [
            {
                "task_id": "task-901",
                "task_title": "a ruled task",
                "agent_name": "alpha",
                "gate": "structured_tool",
                "verdict": "approve",
                "evaluator_runtime": "claude_code.claude-sonnet-5",
                "timestamp": 1787766400.0,
                "notes_hash": "d0d0",
            }
        ],
        "calibration": {
            "total_verdicts": 12,
            "approve_count": 8,
            "reject_count": 4,
            "labeled_count": 0,
            "gate_distribution": {"fallback": 7, "structured_tool": 5},
        },
        "overview": {"evaluator_status": "healthy"},
    }


def verification_verdict_fixtures() -> HttpFixtures:
    rows = [
        verification_request_row("task-901"),
        verification_request_row("task-902"),
    ]
    return {
        VERIFICATION_QUEUE_PATH: (200, verification_snapshot(rows)),
        HARNESS_HEALTH_PATH: (200, harness_health_snapshot()),
        VERIFICATION_VERDICT_PATH: (
            200,
            {"ok": True, "message": "verdict recorded for task-901", "noop": False},
        ),
    }


@contextmanager
def reject_editor_script() -> Iterator[str]:
    """An $EDITOR that writes the reject reason into the form and exits 0.

    The TUI hands the editor the temp file as its one argument; a real editor
    is a human typing, this one is the same save without the human.
    """
    fd, path = tempfile.mkstemp(prefix="masc-tui-reject-editor-", suffix=".sh")
    try:
        os.write(fd, b'#!/bin/sh\nprintf %s \'{"reason": "needs a repro"}\' > "$1"\n')
        os.close(fd)
        os.chmod(path, 0o755)
        yield path
    finally:
        os.unlink(path)


def verification_verdict_interaction(requests: HttpRequests) -> Interaction:
    """Enter explains what the request asks for and which evidence exists.
    Then `a` arms and only the second `a` sends the approve; `x` collects a
    reason through $EDITOR and sends the reject. The verdict assertions read
    the recorded POST bodies -- the wire, not the paint -- and the frame
    between the two presses proves the first one sent nothing.
    """

    def verdict_bodies() -> list[bytes]:
        return [
            body
            for request_path, body in requests
            if request_path == VERIFICATION_VERDICT_PATH
        ]

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC Work")
        send_and_wait(process, master_fd, output, b"v", b"Task Review")
        wait_for_output(
            process, master_fd, output, b"task-901", start=0, timeout=3.0
        )
        detail = send_and_wait(
            process,
            master_fd,
            output,
            b"\r",
            b"HOW TO READ THIS",
        )
        detail_plain = CSI_RE.sub(b"", detail)
        for needle in (
            b"vr-task-901",
            b"finish task-901",
            b"Submitted by",
            b"REQUIRED ARTIFACTS (1)",
            b"SUBMITTED EVIDENCE (1)",
            b"diff",
            b"Left / Esc:back",
        ):
            if needle not in detail_plain:
                raise AssertionError(
                    f"Verification detail omitted {needle!r}: {detail_plain!r}"
                )
        send_and_wait(process, master_fd, output, b"\x1b", b"task-901")
        send_and_wait(
            process,
            master_fd,
            output,
            b"a",
            b"armed: approve task-901 -- same key again to send",
        )
        if verdict_bodies():
            raise AssertionError("the first press already sent the verdict")
        os.write(master_fd, b"a")
        approve_body = wait_for_http_request(
            process, master_fd, output, requests, path=VERIFICATION_VERDICT_PATH
        )
        approve_payload = json.loads(approve_body)
        # The verdict names the submission the row showed, so the server can
        # refuse it when the Task has moved on to another one.
        if approve_payload != {
            "task_id": "task-901",
            "verification_id": "vr-task-901",
            "verdict": "approve",
        }:
            raise AssertionError(f"approve body: {approve_payload!r}")
        # Let the approve completion and its queue reload settle before the
        # editor temporarily gives up the alternate screen. Otherwise the
        # redraw from that reload can race the terminal handoff and leave the
        # editor wait with no frame to drain.
        drain_until_quiet(process, master_fd, output)
        # Reject on the same row: the $EDITOR stub saves the reason form, so
        # the second verdict body carries it.
        read_available(master_fd, output)
        reject_start = len(output)
        os.write(master_fd, b"x")
        deadline = time.monotonic() + 10.0
        while len(verdict_bodies()) < 2:
            read_available(master_fd, output)
            if process.poll() is not None:
                raise AssertionError("TUI exited before the reject verdict")
            if time.monotonic() > deadline:
                raise AssertionError(
                    f"reject verdict never posted: {bytes(output[reject_start:])!r}"
                )
            select.select([master_fd], [], [], 0.05)
        reject_payload = json.loads(verdict_bodies()[1])
        if reject_payload != {
            "task_id": "task-901",
            "verification_id": "vr-task-901",
            "verdict": "reject",
            "reason": "needs a repro",
        }:
            raise AssertionError(f"reject body: {reject_payload!r}")
        # The verdict events live in the TUI session block on Usage / Telemetry, so the
        # visible trace is asserted there, not on the Verification frame. The
        # block lists the newest line last; a tall frame keeps every retained
        # line on screen, and the resize redraws the whole frame.
        tab_until(process, master_fd, output, b"MASC Dashboard")
        send_and_wait(process, master_fd, output, b"m", b"MASC Usage")
        send_and_wait(process, master_fd, output, b"p", b"TUI session")
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=50,
            columns=100,
            needle=b"TUI session",
            controls=(FULL_REDRAW,),
        )
        wait_for_output(
            process,
            master_fd,
            output,
            b"rejecting task-901",
            start=reject_start,
            timeout=3.0,
        )
        # The block trims long rows, so the completion needle stops before
        # the width does.
        wait_for_output(
            process,
            master_fd,
            output,
            b"Verification: verdict recorded",
            start=reject_start,
            timeout=3.0,
        )
        os.write(master_fd, b"q")

    return interact
