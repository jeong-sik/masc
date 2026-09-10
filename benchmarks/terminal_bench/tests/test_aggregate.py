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
    assert row1[9:] == ["17", "2", "Succeeded"]
    row2 = lines[2].split(",")
    assert row2[2] == "fix-git__Def456" and row2[3] == "0"


def test_aggregate_skips_malformed_json(tmp_path, monkeypatch, capsys):
    jobs = tmp_path / "jobs"
    make_trial(jobs, "arm-b-20260910-1200/fix-git__Abc123")
    bad = jobs / "arm-b-20260910-1200" / "fix-git__Bad999"
    bad.mkdir(parents=True)
    (bad / "result.json").write_text("{not json")

    monkeypatch.setattr(sys, "argv", ["aggregate.py", str(jobs)])
    aggregate.main()

    lines = capsys.readouterr().out.strip().splitlines()
    assert len(lines) == 2
