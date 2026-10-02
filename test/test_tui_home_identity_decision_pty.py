"""Foreign HTTP Home cards remain readable but cannot dispatch decisions.

Fixture PTY only; depends on the parent workspace-identity dispatch guards.
No owner-store execution or production behavior is established by this suite.
"""
import copy
import json
import os
import re
from pathlib import Path
import sys

import test_tui_home_decision_cards_pty as cards
import test_tui_home_journey_pty as home
import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui_home.ml", "bin/masc_tui_home.mli",
    "bin/masc_tui_approvals_model.ml", "bin/masc_tui_approvals_model.mli",
    "bin/masc_tui_render_approvals.ml", "bin/masc_tui_render_approvals.mli",
    "bin/masc_tui.ml",
    "bin/masc_tui_types.ml",
    "bin/masc_tui_render.ml",
)
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
        gate = copy.deepcopy(h.blocked_gate_detail_http_fixtures()[cards.GATE_PATH])
        gate[1]["approval_queue"][0].update(
            id=label.decode(), phase="human_required", tool_name="foreign gate decision",
        )
        fixtures[cards.GATE_PATH] = gate
    elif kind == "operator":
        _fixtures, items, _new = h.approval_selection_http_fixtures()
        item = dict(items[0], confirm_token=label.decode(),
                    payload={"reason": "foreign operator decision"})
        fixtures[cards.OPERATOR_PATH] = h.approval_selection_snapshot([item])
    elif kind == "ask":
        ask = copy.deepcopy(h.keeper_asks_response())
        ask[1]["asks"][0].update(ask_id=label.decode(), context="foreign ask decision")
        fixtures[h.KEEPER_ASKS_PATH] = ask
    else:
        raise ValueError(kind)
    requests = []
    health = []

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
            health.append(str(foreign))
            # prepare runs after with_workspace_identity and seed_workspace.
            # Raw responses also bypass the HTTP handler's tuple-path rewrite.
            return h.RawHttpResponse(200, json.dumps(payload).encode(),
                                     content_type="application/json")

        for path in ("/health", "/health?full=1"):
            fixtures[path] = foreign_health

    def interact(process, fd, _slave, output, base):
        h.wait_for_output(process, fd, output, b"[workspace mismatch]", start=0, timeout=10)
        h.wait_for_output(process, fd, output, label, start=0, timeout=10)
        assert health and all(path != str(Path(base).resolve()) for path in health)
        h.resize_and_wait(process, fd, output, rows=40, columns=120,
                          needle=label, final_cursor=b"\x1b[?25l")
        cards.select_home(process, fd, output, label, destinations=3)
        detail = b"ship the cold-start change now?" if kind == "ask" else label
        h.send_and_wait(process, fd, output, b"\r", detail)
        home.assert_no_decision_posts(requests)
        if kind == "operator":
            h.send_and_wait(process, fd, output, b"y", b"Press y again:")
            home.assert_no_decision_posts(requests)
            h.send_and_wait(process, fd, output, b"y", REFUSAL)
        elif kind == "ask":
            h.send_and_wait(process, fd, output, b"1", re.compile(rb"\(o\) (?:\x1b\[[0-9;:]*m)*c-yes"))
            h.send_and_wait(process, fd, output, b"\r", ASK_REFUSAL)
            os.write(fd, b"\r")
            h.drain_until_quiet(process, fd, output)
            plain = h.screen_text(bytes(output))
            assert ASK_REFUSAL in plain, plain
            assert b"(o) c-yes" in plain, "refusal lost the selected answer draft"
            assert b"(o) c-no" not in plain, plain
            home.assert_no_decision_posts(requests)
        else:
            h.send_and_wait(process, fd, output, b"y", REFUSAL)
            # A second refusal need not repaint an unchanged warning. Retry
            # still must stop at identity before retry eligibility.
            os.write(fd, b"n" if kind == "held" else b"R")
            h.drain_until_quiet(process, fd, output)
            assert REFUSAL in h.screen_text(bytes(output))
        home.assert_no_decision_posts(requests)
        h.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
        cards.assert_selected(output, label)
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable, description=f"Home foreign {kind} refuses explicit decisions without POST",
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        prepare_workspace=prepare, refresh=60.0,
    )
    # Include late dispatch and teardown, allowing only MCP transport setup.
    home.assert_no_decision_posts(requests)


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    for kind in ("held", "gate", "operator", "ask"):
        foreign_decision(executable, kind)
    print("Home identity decision PTY: PASS (4 scenarios)")
