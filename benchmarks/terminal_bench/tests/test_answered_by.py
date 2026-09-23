"""driver/answered_by.sh: which runtime answered each keeper turn (#37952).

The rows below have the shape keeper_unified_metrics_decision.ml appends to
<keeper>.decisions.jsonl: `event` names the row kind, and a `turn` row carries
provider_context.executed_runtime_id, null when no candidate reported in.
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


def turn(executed):
    return {"event": "turn", "keeper_name": "bench-1",
            "provider_context": {"runtime_id": "bench",
                                 "executed_runtime_id": executed,
                                 "selected_model": None}}


def write_log(path, rows):
    path.write_text("".join(json.dumps(row) + "\n" for row in rows))


def test_turns_are_counted_by_the_runtime_that_answered(tmp_path):
    write_log(tmp_path / "bench-1.decisions.jsonl", [
        turn("kimi_coding.kimi-for-coding"),
        {"event": "tool_exec", "provider_context": None},
        turn("kimi_coding.k3"),
        turn(None),
    ])
    # A rotated segment is part of the same log.
    write_log(tmp_path / "bench-1.decisions.jsonl.1", [turn("kimi_coding.k3")])
    # Another keeper's artifacts are not decision logs.
    (tmp_path / "bench-1.feedback.jsonl").write_text(json.dumps(turn("x.y")) + "\n")
    done = answered_by(tmp_path)
    assert done.returncode == 0, done.stderr
    assert json.loads(done.stdout) == {
        "answered_by": {"kimi_coding.k3": 2, "kimi_coding.kimi-for-coding": 1},
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
    json.dumps({"event": "turn", "provider_context": {"executed_runtime_id": 3}}),
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
    assert "turns_unanswered:($answers.turns_unanswered // null)" in text
