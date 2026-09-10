import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import aggregate  # noqa: E402


def make_trial(jobs_dir, rel, **overrides):
    trial = jobs_dir / rel
    trial.mkdir(parents=True)
    data = {
        "job_name": "arm-b-20260910-1200",
        "task_name": "fix-git",
        "attempt": 1,
        "verifier_result": {"rewards": {"reward": 1}},
        "agent_context": {
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
    make_trial(jobs, "arm-b-20260910-1200/fix-git/1")
    make_trial(jobs, "arm-b-20260910-1200/fix-git/2",
               verifier_result={"rewards": {"reward": 0}}, attempt=2)

    monkeypatch.setattr(sys, "argv", ["aggregate.py", str(jobs)])
    aggregate.main()

    lines = capsys.readouterr().out.strip().splitlines()
    assert len(lines) == 3
    header = lines[0]
    assert header.startswith("job,task,attempt,reward,duration_ms,")
    row1 = lines[1].split(",")
    assert row1[:5] == ["arm-b-20260910-1200", "fix-git", "1", "1", "1234"]
    assert row1[5:9] == ["100", "50", "10", "0.01"]
    assert row1[9:] == ["17", "2", "Succeeded"]
    row2 = lines[2].split(",")
    assert row2[2] == "2" and row2[3] == "0"


def test_aggregate_skips_malformed_json(tmp_path, monkeypatch, capsys):
    jobs = tmp_path / "jobs"
    make_trial(jobs, "arm-b-20260910-1200/fix-git/1")
    bad = jobs / "arm-b-20260910-1200" / "fix-git" / "2"
    bad.mkdir(parents=True)
    (bad / "result.json").write_text("{not json")

    monkeypatch.setattr(sys, "argv", ["aggregate.py", str(jobs)])
    aggregate.main()

    lines = capsys.readouterr().out.strip().splitlines()
    assert len(lines) == 2
