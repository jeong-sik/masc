"""Home decision cards withdraw when their workspace identity becomes foreign.

Fixture PTY only; depends on the parent workspace-identity dispatch guards.
No owner-store execution or production behavior is established by this suite.
"""
import copy
import json
import os
from pathlib import Path
import sys

import test_tui_home_decision_cards_pty as cards
import test_tui_home_journey_pty as home
import tui_keyboard_harness as h
import tui_keyboard_approvals as approvals


REFUSAL = b"Cannot decide: workspace identity is unverified"
ASK_REFUSAL = b"Cannot answer: workspace identity is unverified; draft retained"


def foreign_decision(executable, kind):
    fixtures = cards.fixtures_with_held([])
    label = f"f-{kind}".encode()
    if kind == "held":
        fixtures[cards.HELD_PATH] = (200, {
            "pending": [cards.held(label.decode(), "foreign held decision")],
        })
    elif kind == "gate":
        gate = copy.deepcopy(approvals.blocked_gate_detail_http_fixtures()[cards.GATE_PATH])
        # The server puts a row in human_required only from an available
        # Require_human summary and sends it with the row (#41464 reads it).
        gate[1]["approval_queue"][0].update(
            id=label.decode(), phase="human_required", tool_name="foreign gate decision",
            summary_status={"status": "available", "summary": {
                "summary_version": 2, "generated_at": 1.0,
                "model_run_id": "run-foreign-gate",
                "context_summary": "foreign gate decision",
                "key_questions": [], "judgment": "require_human",
                "rationale": "the call needs a person"}},
        )
        fixtures[cards.GATE_PATH] = gate
    elif kind == "operator":
        _fixtures, items, _new = h.approval_selection_http_fixtures()
        item = dict(items[0], confirm_token=label.decode(),
                    payload={"reason": "foreign operator decision"})
        fixtures[cards.OPERATOR_PATH] = h.approval_selection_snapshot([item])
    elif kind == "ask":
        ask = copy.deepcopy(approvals.keeper_asks_response())
        ask[1]["asks"][0].update(ask_id=label.decode(), context="foreign ask decision")
        fixtures[h.KEEPER_ASKS_PATH] = ask
    else:
        raise ValueError(kind)
    requests = []
    health = []
    foreign_active = False

    def prepare(base):
        home.seed_goals(base)
        foreign = Path(base, "foreign-server").resolve()
        (foreign / ".masc").mkdir(parents=True)
        assert foreign != Path(base).resolve()
        payload = {
            "status": "ok",
            "paths": {
                "cwd": str(foreign), "effective_base_path": str(foreign),
                "effective_masc_root": str(foreign / ".masc"),
                "effective_has_masc_dir": True,
            },
        }

        def foreign_health():
            effective = foreign if foreign_active else Path(base).resolve()
            health.append(str(effective))
            current = copy.deepcopy(payload)
            current["paths"].update(cwd=str(effective), effective_base_path=str(effective),
                                    effective_masc_root=str(effective / ".masc"))
            # prepare runs after with_workspace_identity and seed_workspace.
            # Raw responses also bypass the HTTP handler's tuple-path rewrite.
            return h.RawHttpResponse(200, json.dumps(current).encode(),
                                     content_type="application/json")

        for path in ("/health", "/health?full=1"):
            fixtures[path] = foreign_health

    def interact(process, fd, _slave, output, base):
        nonlocal foreign_active
        h.wait_for_output(process, fd, output, label, start=0, timeout=10)
        h.resize_and_wait(process, fd, output, rows=40, columns=160,
                          needle=label, final_cursor=b"\x1b[?25l")
        cards.select_home(process, fd, output, label, destinations=3)
        detail = (b"ship the cold-start change now?" if kind == "ask" else
                  b"foreign operator decision" if kind == "operator" else label)
        h.send_and_wait(process, fd, output, b"\r", detail)
        home.assert_no_decision_posts(requests)
        visible_marker = (b"foreign ask decision" if kind == "ask" else
                          b"foreign operator decision" if kind == "operator" else label)
        foreign_active = True
        os.write(fd, b"r")
        assert h.wait_for_fixture_state(process, fd, output,
            lambda: health[-1] != str(Path(base).resolve())
            and visible_marker not in h.screen_text(bytes(output)), timeout=10), \
            "foreign authority did not withdraw the decision row"
        h.drain_until_quiet(process, fd, output)
        plain = h.screen_text(bytes(output))
        assert visible_marker not in plain, "foreign workspace retained an actionable decision card"
        assert health[-1] != str(Path(base).resolve())
        # Old action keys and confirmation cannot dispatch the withdrawn row.
        os.write(fd, b"y\r")
        h.drain_until_quiet(process, fd, output)
        home.assert_no_decision_posts(requests)
        foreign_active = False
        h.send_and_wait(process, fd, output, b"r",
                        visible_marker if kind == "ask" else label)
        assert health[-1] == str(Path(base).resolve())
        home.assert_no_decision_posts(requests)
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable, description=f"Home foreign {kind} refuses explicit decisions without POST",
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        prepare_workspace=prepare,
        # The question view binds no refresh key (1-9, t, s, Enter, Esc), so
        # only a tick shows it the foreign reading. The other views refresh
        # on r and run at the harness cadence.
        **({"refresh": 0.5} if kind == "ask" else {}),
    )
    # Include late dispatch and teardown, allowing only MCP transport setup.
    home.assert_no_decision_posts(requests)


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    for kind in ("held", "gate", "operator", "ask"):
        foreign_decision(executable, kind)
    print("Home identity decision PTY: PASS (4 scenarios)")
