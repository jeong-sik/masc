"""Board detail names the answer source when completion persistence failed."""

from __future__ import annotations

import copy
import os
import sys
from typing import Any, cast

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
    "lib/tui_decode.ml",
)


def run(executable: str, status: str, persistence_state: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[h.KEEPER_LANES_PATH] = h.keeper_lanes_response([])
    fixtures[h.STANDALONE_LANES_PATH] = h.standalone_lanes_response()
    run_id = "jev-" + status
    detail = cast(dict[str, Any], copy.deepcopy(h.hitl_lane_run_detail_response()[1]))
    run_record = cast(dict[str, Any], detail["run"])
    run_record.update(
        {
            "run_id": run_id,
            "lane": "board_attention_exact",
            "subject_id": "board-candidate-1",
            "actor": "keeper-a",
            "status": status,
            "selected_slot": None,
            "intended_status": "succeeded",
            "persistence_error": "completion append did not settle",
            "persistence_state": persistence_state,
            "input": {
                "kind": "exact",
                "payload": {"candidate_id": "board-candidate-1"},
            },
            "output": {
                "verdict": {
                    "decision": "relevant",
                    "rationale": "the Board post needs attention",
                },
                "slot_id": "jev-latest",
                "source": {
                    "kind": "vendor_system_one",
                    "endpoint": "https://jev.invalid/v1/judge",
                    "model": "jev-latest",
                    "request_body_sha256": "a" * 64,
                },
                "judged_at": 42.0,
            },
        }
    )
    summary_fields = {
        "run_id",
        "run_kind",
        "lane",
        "subject_id",
        "actor",
        "started_at",
        "status",
        "elapsed_s",
        "selected_slot",
        "intended_status",
        "persistence_error",
        "persistence_state",
    }
    summary = {key: value for key, value in run_record.items() if key in summary_fields}
    fixtures[h.lane_runs_path("board_attention_exact")] = (
        200,
        {"runs": [summary], "has_more": False, "total": 1},
    )
    fixtures["/api/v1/dashboard/exact-lane-runs/" + run_id] = (200, detail)

    def interact(process, master, _slave, output, _base):
        h.palette_go(process, master, output, b"go lanes", b"Board Attention")
        h.send_and_wait(
            process, master, output, b"\r", b"1 loaded / 1 retained \xc2\xb7 end"
        )
        h.send_and_wait(
            process, master, output, b"\r", b"INPUT \xc2\xb7 PROMPT PAYLOAD"
        )
        h.resize_and_wait(
            process,
            master,
            output,
            rows=32,
            columns=180,
            needle=b"NO EXACT-FLOW RECEIPT",
            controls=(h.FULL_REDRAW,),
        )
        h.read_available(master, output)
        screen = h.screen_text(bytes(output))
        assert ("RUN  " + status).encode() in screen, screen
        assert b"ANSWER  VENDOR SYSTEM ONE" in screen, screen
        assert b"jev-latest" in screen, screen
        assert b"NO EXACT-FLOW RECEIPT" in screen, screen
        assert b"SLOT jev-latest" not in screen, screen
        os.write(master, b"q")

    h.run_terminal_scenario(
        executable,
        description="Board answer source: " + status,
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]), "completion_persistence_failed", "not_persisted")
    run(
        os.path.abspath(sys.argv[1]),
        "completion_durability_unknown",
        "durability_unknown",
    )
    print("TUI Board answer source: PASS")
