"""driver/tool_outcomes.sh: what the keeper's tool calls came to, per tool.

The rows below have the shape keeper_tool_call_log.ml appends to
.masc/tool_calls/<yyyy-mm>/<dd>.jsonl: record_kind names the row kind, and a
call's outcome is its disposition, or its wire_outcome when it has none.
"""
import json
import subprocess
from pathlib import Path

HELPER = Path(__file__).resolve().parents[1] / "driver" / "tool_outcomes.sh"
COLLECT = Path(__file__).resolve().parents[1] / "driver" / "collect_result.sh"


def outcomes(tool_calls_dir):
    return subprocess.run(
        ["bash", "-c", 'set -euo pipefail; source "$1" && bench_tool_outcomes_json "$2"',
         "_", str(HELPER), str(tool_calls_dir)],
        capture_output=True, text=True)


def call(tool, disposition="succeeded", output="ok", result_bytes=10, **extra):
    row = {"record_kind": "tool_call", "tool": tool, "disposition": disposition,
           "output": output, "result_bytes": result_bytes}
    row.update(extra)
    return row


def write_day(root, day, rows):
    path = root / "2026-09" / f"{day}.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row) + "\n" for row in rows))


def test_calls_and_failures_are_counted_per_tool(tmp_path):
    write_day(tmp_path, "23", [
        call("Execute"),
        call("Execute", disposition="failed", output="Path blocked: /app\nretry elsewhere"),
        call("Execute", disposition="failed", output="Path blocked: /app\nretry elsewhere"),
        call("Read", disposition="failed", output={"error": "path_outside_sandbox"}),
    ])
    write_day(tmp_path, "24", [call("Read", result_bytes=5)])
    result = outcomes(tmp_path)
    assert result.returncode == 0, result.stderr
    data = json.loads(result.stdout)
    assert data["tool_calls"] == 5
    assert data["failed_tool_calls"] == 3
    execute, read = data["by_tool"]
    assert execute == {"tool": "Execute", "calls": 3, "failed": 2, "result_bytes": 30,
                       "top_failure": "Path blocked: /app / retry elsewhere"}
    assert read["failed"] == 1 and read["calls"] == 2 and read["result_bytes"] == 15
    assert read["top_failure"] == '{"error":"path_outside_sandbox"}'


def test_rows_that_are_not_calls_are_not_counted(tmp_path):
    # A composition's steps are tool_call rows of their own; its
    # composition_run row summarizes them, so counting it would count the run
    # twice. A vision_candidate end row is a lifecycle marker, not a call.
    write_day(tmp_path, "24", [
        call("Execute"),
        call("Read", disposition="failed"),
        {"record_kind": "composition_run", "tool": "keeper_composition_run_summary",
         "wire_outcome": "error"},
        {"record_kind": "lifecycle_event", "tool": "vision_candidate", "wire_outcome": "error"},
    ])
    data = json.loads(outcomes(tmp_path).stdout)
    assert (data["tool_calls"], data["failed_tool_calls"]) == (2, 1)
    assert [row["tool"] for row in data["by_tool"]] == ["Read", "Execute"]


def test_the_failure_rule_is_the_repositorys(tmp_path):
    # disposition first; wire_outcome only without one; "unknown" is not a
    # failure.
    write_day(tmp_path, "24", [
        {"record_kind": "tool_call", "tool": "A", "wire_outcome": "error", "output": "boom"},
        {"record_kind": "tool_call", "tool": "B", "wire_outcome": "unknown"},
        {"record_kind": "tool_call", "tool": "C", "disposition": "succeeded", "wire_outcome": "error"},
    ])
    data = json.loads(outcomes(tmp_path).stdout)
    failed = {row["tool"]: row["failed"] for row in data["by_tool"]}
    assert failed == {"A": 1, "B": 0, "C": 0}


def test_tools_are_ordered_by_failures_then_calls_then_name(tmp_path):
    write_day(tmp_path, "24", [
        call("Read"), call("Read"), call("Grep"), call("Edit"),
        call("Write", disposition="failed"),
    ])
    names = [row["tool"] for row in json.loads(outcomes(tmp_path).stdout)["by_tool"]]
    assert names == ["Write", "Read", "Edit", "Grep"]


def test_an_episode_that_recorded_nothing_is_null_not_zero(tmp_path):
    assert outcomes(tmp_path / "absent").stdout.strip() == "null"
    (tmp_path / "empty").mkdir()
    assert outcomes(tmp_path / "empty").stdout.strip() == "null"


def test_a_row_it_cannot_read_fails_rather_than_being_left_out(tmp_path):
    path = tmp_path / "2026-09" / "24.jsonl"
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps(call("Execute")) + "\n{not json\n")
    assert outcomes(tmp_path).returncode != 0
    write_day(tmp_path, "24", [{"record_kind": "tool_call", "tool": "Execute"}])
    assert outcomes(tmp_path).returncode != 0


def test_a_row_the_writer_would_not_write_fails(tmp_path):
    # keeper_tool_call_log.ml writes record_kind and tool on every row, so a
    # row without them, or with a kind it does not write, is broken.
    broken = [
        {k: v for k, v in call("Execute").items() if k != "record_kind"},
        call("Execute", record_kind="tool_result"),
        {k: v for k, v in call("Execute").items() if k != "tool"},
    ]
    for row in broken:
        write_day(tmp_path, "24", [call("Read"), row])
        result = outcomes(tmp_path)
        assert result.returncode != 0, row


def test_collect_result_reports_the_outcomes():
    text = COLLECT.read_text()
    assert 'source "$BENCH/driver/tool_outcomes.sh"' in text
    assert 'bench_tool_outcomes_json "$tool_log_dir"' in text
    assert "tool_calls:($outcomes.tool_calls // null)" in text
    assert "failed_tool_calls:($outcomes.failed_tool_calls // null)" in text
    assert "tool_outcomes:($outcomes.by_tool // null)" in text
