"""run_matrix.sh starts the arms' servers before it downloads the dataset or runs an arm.

uv and docker are stubs. uv logs its arguments, one JSON list per call, and for
preflight_arms.py exits with the status the test asks for. docker answers
`docker info` with the status the test asks for. What is held here is the order
of the calls, the exact arguments the preflight gets, and when it runs, not the
text of the script.
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

BENCH = Path(__file__).resolve().parents[1]
STUB_UV = f"""#!{sys.executable}
import json, os, sys
with open(os.environ["FAKE_UV_LOG"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
if any("preflight_arms.py" in argument for argument in sys.argv):
    sys.exit(int(os.environ.get("FAKE_PREFLIGHT_EXIT", "0")))
"""
STUB_DOCKER = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"
exit "${FAKE_DOCKER_INFO_EXIT:-0}"
"""


def run_matrix(tmp_path: Path, *args: str, **env: str) -> tuple[subprocess.CompletedProcess[str], list[list[str]], list[str]]:
    """The finished run, the uv calls as argument lists, and the docker calls."""
    root = tmp_path / "bench"
    root.mkdir()
    shutil.copy(BENCH / "run_matrix.sh", root / "run_matrix.sh")
    (root / "results" / "datasets" / "terminal-bench-4.0.0").mkdir(parents=True)
    (root / "results" / "jobs").mkdir(parents=True)
    commands = tmp_path / "commands"
    commands.mkdir()
    for name, body in (("uv", STUB_UV), ("docker", STUB_DOCKER)):
        stub = commands / name
        stub.write_text(body)
        stub.chmod(0o755)
    uv_log = tmp_path / "uv.log"
    docker_log = tmp_path / "docker.log"
    environment = {
        **{k: v for k, v in os.environ.items() if not k.startswith(("BENCH_", "FAKE_"))},
        "PATH": f"{commands}{os.pathsep}{os.environ['PATH']}",
        "FAKE_UV_LOG": str(uv_log),
        "FAKE_DOCKER_LOG": str(docker_log),
        **env,
    }
    done = subprocess.run(
        ["bash", str(root / "run_matrix.sh"), *args],
        cwd=root, env=environment, capture_output=True, text=True)
    uv_calls = [json.loads(line) for line in uv_log.read_text().splitlines()] if uv_log.exists() else []
    docker_calls = docker_log.read_text().splitlines() if docker_log.exists() else []
    return done, uv_calls, docker_calls


def index_of(calls: list[list[str]], needle: str) -> int:
    return next(i for i, argv in enumerate(calls) if needle in " ".join(argv))


def preflight_calls(calls: list[list[str]]) -> list[list[str]]:
    return [argv for argv in calls if any("preflight_arms.py" in argument for argument in argv)]


def test_the_preflight_runs_first_and_is_told_the_arms_and_models(tmp_path):
    done, calls, _ = run_matrix(tmp_path, "a,b,l", "1",
                                BENCH_MODEL="anthropic/claude-fable-5-1",
                                BENCH_FALLBACK_MODELS="anthropic/claude-sonnet-5")
    assert done.returncode == 0, done.stderr
    assert calls[0] == ["run", "python", "preflight_arms.py",
                        "--arms", "a,b,l",
                        "--model", "anthropic/claude-fable-5-1",
                        "--fallback-models", "anthropic/claude-sonnet-5"]
    assert index_of(calls, "preflight_arms.py") < index_of(calls, "harbor datasets download")
    assert index_of(calls, "harbor datasets download") < index_of(calls, "harbor run")


def test_no_fallback_models_still_reaches_the_preflight_as_an_empty_argument(tmp_path):
    done, calls, _ = run_matrix(tmp_path, "b", "1")
    assert done.returncode == 0, done.stderr
    assert calls[0][-2:] == ["--fallback-models", ""]


def test_a_refused_preflight_stops_the_run_before_the_download(tmp_path):
    done, calls, _ = run_matrix(tmp_path, "b", FAKE_PREFLIGHT_EXIT="1")
    assert done.returncode != 0
    assert len(calls) == 1 and "preflight_arms.py" in " ".join(calls[0])
    assert not any("harbor" in " ".join(argv) for argv in calls)


def test_the_failover_arm_without_fallbacks_stops_before_the_preflight(tmp_path):
    done, calls, _ = run_matrix(tmp_path, "l")
    assert done.returncode == 2
    assert "BENCH_FALLBACK_MODELS" in done.stderr
    assert calls == []


def test_a_docker_run_does_not_ask_the_daemon_first(tmp_path):
    done, calls, docker_calls = run_matrix(tmp_path, "b", "1", BENCH_ENV="docker")
    assert done.returncode == 0, done.stderr
    assert len(preflight_calls(calls)) == 1
    assert docker_calls == []


def test_a_modal_run_runs_the_preflight_when_a_docker_daemon_answers(tmp_path):
    done, calls, docker_calls = run_matrix(tmp_path, "b", "1", BENCH_ENV="modal")
    assert done.returncode == 0, done.stderr
    assert docker_calls == ["info"]
    assert len(preflight_calls(calls)) == 1
    assert index_of(calls, "preflight_arms.py") < index_of(calls, "harbor datasets download")


def test_a_modal_run_without_a_docker_daemon_says_it_skipped_the_preflight(tmp_path):
    done, calls, docker_calls = run_matrix(
        tmp_path, "b", "1", BENCH_ENV="modal", FAKE_DOCKER_INFO_EXIT="1")
    assert done.returncode == 0, done.stderr
    assert docker_calls == ["info"]
    assert "preflight skipped: BENCH_ENV=modal and no docker daemon answers" in done.stderr
    assert preflight_calls(calls) == []
    assert any("harbor run" in " ".join(argv) for argv in calls)
