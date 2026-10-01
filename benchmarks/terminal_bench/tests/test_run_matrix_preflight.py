"""run_matrix.sh starts the arms' servers before it downloads the dataset or runs an arm.

uv is a stub that logs its arguments and, for preflight_arms.py, exits with the
status the test asks for. What is held here is the order of the calls and what
the preflight is told, not the text of the script.
"""
import os
import shutil
import subprocess
from pathlib import Path

BENCH = Path(__file__).resolve().parents[1]
STUB_UV = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FAKE_UV_LOG"
if [[ "$*" == *preflight_arms.py* ]]; then exit "${FAKE_PREFLIGHT_EXIT:-0}"; fi
exit 0
"""


def run_matrix(tmp_path: Path, *args: str, **env: str) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    root = tmp_path / "bench"
    root.mkdir()
    shutil.copy(BENCH / "run_matrix.sh", root / "run_matrix.sh")
    (root / "results" / "datasets" / "terminal-bench-4.0.0").mkdir(parents=True)
    (root / "results" / "jobs").mkdir(parents=True)
    commands = tmp_path / "commands"
    commands.mkdir()
    uv = commands / "uv"
    uv.write_text(STUB_UV)
    uv.chmod(0o755)
    log = tmp_path / "uv.log"
    environment = {
        **{k: v for k, v in os.environ.items() if not k.startswith("BENCH_")},
        "PATH": f"{commands}{os.pathsep}{os.environ['PATH']}",
        "FAKE_UV_LOG": str(log),
        **env,
    }
    done = subprocess.run(
        ["bash", str(root / "run_matrix.sh"), *args],
        cwd=root, env=environment, capture_output=True, text=True)
    return done, log.read_text().splitlines() if log.exists() else []


def index_of(lines: list[str], needle: str) -> int:
    return next(i for i, line in enumerate(lines) if needle in line)


def test_the_preflight_runs_first_and_is_told_the_arms_and_models(tmp_path):
    done, lines = run_matrix(tmp_path, "a,b,l", "1",
                             BENCH_MODEL="anthropic/claude-fable-5-1",
                             BENCH_FALLBACK_MODELS="anthropic/claude-sonnet-5")
    assert done.returncode == 0, done.stderr
    assert "preflight_arms.py" in lines[0]
    assert "--arms a,b,l" in lines[0]
    assert "--model anthropic/claude-fable-5-1" in lines[0]
    assert "--fallback-models anthropic/claude-sonnet-5" in lines[0]
    assert index_of(lines, "preflight_arms.py") < index_of(lines, "harbor datasets download")
    assert index_of(lines, "harbor datasets download") < index_of(lines, "harbor run")


def test_a_refused_preflight_stops_the_run_before_the_download(tmp_path):
    done, lines = run_matrix(tmp_path, "b", FAKE_PREFLIGHT_EXIT="1")
    assert done.returncode != 0
    assert len(lines) == 1 and "preflight_arms.py" in lines[0]
    assert not any("harbor" in line for line in lines)


def test_the_failover_arm_without_fallbacks_stops_before_the_preflight(tmp_path):
    done, lines = run_matrix(tmp_path, "l")
    assert done.returncode == 2
    assert "BENCH_FALLBACK_MODELS" in done.stderr
    assert lines == []
