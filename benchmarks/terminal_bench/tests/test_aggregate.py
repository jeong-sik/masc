import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import aggregate  # noqa: E402


def make_trial(jobs_dir, rel, **overrides):
    trial = jobs_dir / rel
    trial.mkdir(parents=True)
    data = {
        "task_name": "fix-git",
        "trial_name": "fix-git__Abc123",
        "verifier_result": {"rewards": {"reward": 1}},
        "agent_result": {
            "metadata": {"duration_ms": 1234, "tool_calls": 17,
                         "duplicate_tool_calls": 2, "masc_state": "Succeeded"},
            "n_input_tokens": 100,
            "n_output_tokens": 50,
            "n_cache_tokens": 10,
            "cost_usd": 0.01,
        },
    }
    data.update(overrides)
    (trial / "result.json").write_text(json.dumps(data))
    return trial


def test_aggregate_rows(tmp_path, monkeypatch, capsys):
    jobs = tmp_path / "jobs"
    make_trial(jobs, "arm-b-20260910-1200/fix-git__Abc123")
    make_trial(jobs, "arm-b-20260910-1200/fix-git__Def456",
               trial_name="fix-git__Def456",
               verifier_result={"rewards": {"reward": 0}})
    # job-level result.json (no task_name) must be skipped
    (jobs / "arm-b-20260910-1200" / "result.json").write_text(
        json.dumps({"n_total_trials": 2, "stats": {}}))

    monkeypatch.setattr(sys, "argv", ["aggregate.py", str(jobs)])
    aggregate.main()

    lines = capsys.readouterr().out.strip().splitlines()
    assert len(lines) == 3
    header = lines[0]
    assert header.startswith("job,task,trial,reward,duration_ms,")
    row1 = lines[1].split(",")
    assert row1[:5] == ["arm-b-20260910-1200", "fix-git", "fix-git__Abc123", "1", "1234"]
    assert row1[5:9] == ["100", "50", "10", "0.01"]
    assert row1[9:] == ["17", "2", "Succeeded", ""]
    row2 = lines[2].split(",")
    assert row2[2] == "fix-git__Def456" and row2[3] == "0"


def test_a_malformed_trial_keeps_its_row(tmp_path, monkeypatch, capsys):
    # It used to be dropped. A trial killed mid-write is still a trial, and
    # removing it from the CSV shrinks the arm's denominator, which moves the
    # pass rate up for free.
    jobs = tmp_path / "jobs"
    make_trial(jobs, "arm-b-20260910-1200/fix-git__Abc123")
    bad = jobs / "arm-b-20260910-1200" / "fix-git__Bad999"
    bad.mkdir(parents=True)
    (bad / "result.json").write_text("{not json")

    monkeypatch.setattr(sys, "argv", ["aggregate.py", str(jobs)])
    aggregate.main()

    lines = capsys.readouterr().out.strip().splitlines()
    assert len(lines) == 3
    marked = [line for line in lines if "fix-git__Bad999" in line]
    assert len(marked) == 1
    assert "unparseable" in marked[0]
    assert marked[0].split(",")[3] == "", "a broken trial must not carry a reward"


def test_zero_is_a_measurement_not_a_blank(tmp_path, monkeypatch, capsys):
    # `or ""` rendered 0 as empty, so an agent that emitted nothing — the
    # interesting failure — was indistinguishable from one nobody measured.
    jobs = tmp_path / "jobs"
    make_trial(
        jobs, "arm-b-20260910-1200/fix-git__Zero",
        agent_result={
            "metadata": {"duration_ms": 0, "tool_calls": 0,
                         "duplicate_tool_calls": 0, "masc_state": "Failed"},
            "n_input_tokens": 0, "n_output_tokens": 0,
            "n_cache_tokens": 0, "cost_usd": 0.0,
        },
    )
    monkeypatch.setattr(sys, "argv", ["aggregate.py", str(jobs)])
    aggregate.main()

    row = capsys.readouterr().out.strip().splitlines()[1].split(",")
    assert row[4] == "0"           # duration_ms
    assert row[5:9] == ["0", "0", "0", "0.0"]
    assert row[9:11] == ["0", "0"]


def test_a_missing_measurement_stays_blank(tmp_path, monkeypatch, capsys):
    jobs = tmp_path / "jobs"
    make_trial(jobs, "arm-b-20260910-1200/fix-git__None",
               agent_result={"metadata": {}})
    monkeypatch.setattr(sys, "argv", ["aggregate.py", str(jobs)])
    aggregate.main()
    row = capsys.readouterr().out.strip().splitlines()[1].split(",")
    assert row[4:] == ["", "", "", "", "", "", "", "", ""]


def test_unpriced_keeper_rows_reach_the_table(tmp_path, monkeypatch, capsys):
    # cost_usd is the axis the keeper arm is compared on, and the sidecar adds
    # keeper spend into it. A ledger row it could not price arrives as null and
    # contributes nothing, so the total reads as measured. The count of those
    # rows lived only in metadata.keeper_usage, which this table did not read,
    # and unknown keeper spend was indistinguishable from free.
    jobs = tmp_path / "jobs"
    make_trial(
        jobs, "arm-k-20260913-0900/fix-git__Unpriced",
        trial_name="fix-git__Unpriced",
        agent_result={
            "metadata": {"duration_ms": 10, "tool_calls": 1,
                         "duplicate_tool_calls": 0, "masc_state": "Succeeded",
                         "keeper_usage": {"rows": 5, "cost_usd": 0.02,
                                          "cost_rows_unreported": 2}},
            "n_input_tokens": 1, "n_output_tokens": 1,
            "n_cache_tokens": 0, "cost_usd": 0.02,
        },
    )
    make_trial(
        jobs, "arm-k-20260913-0900/fix-git__Priced",
        trial_name="fix-git__Priced",
        agent_result={
            "metadata": {"duration_ms": 10, "tool_calls": 1,
                         "duplicate_tool_calls": 0, "masc_state": "Succeeded",
                         "keeper_usage": {"rows": 5, "cost_usd": 0.02,
                                          "cost_rows_unreported": 0}},
            "n_input_tokens": 1, "n_output_tokens": 1,
            "n_cache_tokens": 0, "cost_usd": 0.02,
        },
    )
    monkeypatch.setattr(sys, "argv", ["aggregate.py", str(jobs)])
    aggregate.main()

    import csv as _csv
    import io
    rows = list(_csv.reader(io.StringIO(capsys.readouterr().out)))
    assert rows[0][-1] == "keeper_cost_unreported_rows"
    by_trial = {row[2]: row[-1] for row in rows[1:]}
    assert by_trial["fix-git__Unpriced"] == "2"
    # Zero is a measurement here too: this arm priced every keeper row.
    assert by_trial["fix-git__Priced"] == "0"


def test_a_comma_in_a_field_does_not_shift_the_columns(tmp_path, monkeypatch, capsys):
    # Rows were joined by hand, so any comma in task_name or masc_state moved
    # every later column one place left.
    import csv as _csv
    import io

    jobs = tmp_path / "jobs"
    make_trial(jobs, "arm-b-20260910-1200/odd__Abc123",
               task_name="fix,git",
               agent_result={"metadata": {"masc_state": "Failed, no runtime"}})
    monkeypatch.setattr(sys, "argv", ["aggregate.py", str(jobs)])
    aggregate.main()

    rows = list(_csv.reader(io.StringIO(capsys.readouterr().out)))
    assert rows[1][1] == "fix,git"
    # masc_state is second from the end now that the keeper cost count is
    # appended after it.
    assert rows[1][-2] == "Failed, no runtime"
    assert len(rows[1]) == len(rows[0])
