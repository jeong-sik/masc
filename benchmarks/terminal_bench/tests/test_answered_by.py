"""driver/answered_by.sh: which runtime answered each keeper turn (#37952).

The rows below have the shape keeper_unified_metrics_decision.ml appends to
<keeper>.decisions.jsonl: `event` names the row kind, `outcome` is what the turn
ended as, and provider_context.executed_runtime_id is the candidate that
answered or, on an error, the last one dispatched (null when none was).
"""
import json
import subprocess
from pathlib import Path

import pytest

HELPER = Path(__file__).resolve().parents[1] / "driver" / "answered_by.sh"
COLLECT = Path(__file__).resolve().parents[1] / "driver" / "collect_result.sh"


def answered_by(keepers_dir):
    return subprocess.run(
        ["bash", "-c", 'set -euo pipefail; source "$1" && bench_answered_by_json "$2"',
         "_", str(HELPER), str(keepers_dir)],
        capture_output=True, text=True)


def turn(executed, outcome="success"):
    return {"event": "turn", "keeper_name": "bench-1", "outcome": outcome,
            "provider_context": {"runtime_id": "bench",
                                 "executed_runtime_id": executed,
                                 "selected_model": None}}


def write_log(path, rows):
    path.write_text("".join(json.dumps(row) + "\n" for row in rows))


def test_turns_are_counted_by_the_runtime_that_answered(tmp_path):
    write_log(tmp_path / "bench-1.decisions.jsonl", [
        turn("kimi_coding.kimi-for-coding"),
        {"event": "tool_exec", "provider_context": None},
        turn("kimi_coding.k3", outcome="checkpoint"),
        turn(None, outcome="error"),
        # Failed on the candidate the walk reached last: it did not answer.
        turn("kimi_coding.k3", outcome="error"),
    ])
    # A rotated segment is part of the same log.
    write_log(tmp_path / "bench-1.decisions.jsonl.1",
              [turn("kimi_coding.k3", outcome="input_required")])
    # Another keeper's artifacts are not decision logs.
    (tmp_path / "bench-1.feedback.jsonl").write_text(json.dumps(turn("x.y")) + "\n")
    done = answered_by(tmp_path)
    assert done.returncode == 0, done.stderr
    assert json.loads(done.stdout) == {
        "answered_by": {"kimi_coding.k3": 2, "kimi_coding.kimi-for-coding": 1},
        "failed_on": {"kimi_coding.k3": 1},
        "turns_unanswered": 1,
    }


@pytest.mark.parametrize("make_dir", [False, True])
def test_an_episode_without_a_decision_log_is_unmeasured_not_zero(tmp_path, make_dir):
    keepers = tmp_path / "keepers"
    if make_dir:
        keepers.mkdir()
    done = answered_by(keepers)
    assert done.returncode == 0, done.stderr
    assert json.loads(done.stdout) is None


@pytest.mark.parametrize("bad_row", [
    "{not json",
    json.dumps({"event": "turn"}),
    json.dumps({"event": "turn", "outcome": "success",
                "provider_context": {"executed_runtime_id": 3}}),
    # The key is missing, not null: that is not "no candidate dispatched".
    json.dumps({"event": "turn", "outcome": "error", "provider_context": {}}),
    json.dumps({"event": "turn", "outcome": "success",
                "provider_context": {"executed_runtime_id": None}}),
    json.dumps({"event": "turn", "outcome": "stalled",
                "provider_context": {"executed_runtime_id": "kimi_coding.k3"}}),
])
def test_a_row_it_cannot_read_fails_rather_than_leaving_it_out(tmp_path, bad_row):
    (tmp_path / "bench-1.decisions.jsonl").write_text(
        json.dumps(turn("kimi_coding.k3")) + "\n" + bad_row + "\n")
    done = answered_by(tmp_path)
    assert done.returncode != 0
    assert done.stdout.strip() == ""


def test_collect_result_records_both_fields_from_the_helper():
    # collect_result.sh itself needs a running server; what is held here is
    # that it reads the helper and writes both fields into result.json.
    text = COLLECT.read_text()
    assert 'source "$BENCH/driver/answered_by.sh"' in text
    assert "bench_answered_by_json \"$MASC_BASE_PATH/.masc/keepers\"" in text
    assert "answered_by:($answers.answered_by // null)" in text
    assert "failed_on:($answers.failed_on // null)" in text
    assert "turns_unanswered:($answers.turns_unanswered // null)" in text
