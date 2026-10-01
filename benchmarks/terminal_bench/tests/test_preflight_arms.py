"""preflight_arms starts the server for every arm before a run, without a model.

docker is a fake that logs each call and keeps a copy of what was uploaded, so
these tests hold what the script sends to a container: the platform, the
binaries of that platform, the rendered config, the keepers the bootstrap is told
to bring up, and that the real provider key is never among the arguments.
"""
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest

BENCH = Path(__file__).resolve().parents[1]
for subdirectory in ("agents", "configs", ""):
    sys.path.insert(0, str(BENCH / subdirectory))

import masc_dist  # noqa: E402
import preflight_arms  # noqa: E402
from masc_agent import MascAgent  # noqa: E402
from render_configs import BENCH_LANE  # noqa: E402

REAL_BENCH = BENCH
SOURCE_COMMIT = "b" * 40
REAL_KEY = "sk-real-key-that-must-not-reach-docker"
REAL_GH_TOKEN = "ghp_real-token-that-must-not-reach-docker"
MODEL = "anthropic/claude-fable-5-1"
FALLBACK_MODEL = "anthropic/claude-sonnet-5"
HEAD_ROUTE = "claude.claude-fable-5-1"

FAKE_DOCKER = r'''#!{python}
import json, os, shutil, sys, time
from pathlib import Path

args = sys.argv[1:]
root = Path(os.environ["FAKE_DOCKER_DIR"])
entry = {{"argv": args}}
if args[:1] == ["cp"] and args[1].startswith("/"):
    source = Path(args[1])
    destination = args[2].split(":", 1)[1]
    keep = root / "copied" / args[2].split(":", 1)[0] / destination.lstrip("/")
    keep.parent.mkdir(parents=True, exist_ok=True)
    if source.is_dir():
        shutil.copytree(source, keep, dirs_exist_ok=True)
    else:
        shutil.copy2(source, keep)
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps(entry) + "\n")

joined = " ".join(args)
fail_arm = os.environ.get("FAKE_BOOTSTRAP_FAIL_ARM")
if args[:1] == ["info"] and os.environ.get("FAKE_DOCKER_HANG"):
    time.sleep(30)
if args[:1] == ["exec"] and "bootstrap.sh" in joined:
    if os.environ.get("FAKE_BOOTSTRAP_HANG"):
        time.sleep(60)
    if fail_arm and f"-preflight-{{fail_arm}}-" in joined:
        message = b"keeper_up answered KeeperUpFailed"
        if os.environ.get("FAKE_BOOTSTRAP_BAD_BYTES"):
            message += b" \xff\xfe"
        sys.stderr.buffer.write(message + b"\n")
        sys.exit(1)
    print("MASC server ready")
elif args[:1] == ["exec"] and "server.log" in joined:
    print("server.log: runtime.toml refused")
elif args[:1] == ["rm"] and os.environ.get("FAKE_RM_FAIL"):
    print("Cannot connect to the Docker daemon", file=sys.stderr)
    sys.exit(1)
elif args[:1] == ["cp"] and os.environ.get("FAKE_UPLOAD_FAIL") and args[2].endswith("/config"):
    print("no space left on device", file=sys.stderr)
    sys.exit(1)
'''


def make_bench_root(tmp_path: Path) -> Path:
    root = tmp_path / "bench"
    shutil.copytree(REAL_BENCH / "driver", root / "driver")
    floor = (REAL_BENCH / "image" / "min_masc_version").read_text().strip()
    architectures = {}
    for directory, machine, platform in (
        ("linux-x64", "x86_64", "linux/amd64"),
        ("linux-arm64", "aarch64", "linux/arm64"),
    ):
        (root / "dist" / directory).mkdir(parents=True)
        hashes = {}
        for name in ("masc", "masc-exec-shim", "gh"):
            body = f"fixture {directory} {name}\n".encode()
            (root / "dist" / directory / name).write_bytes(body)
            hashes[name] = hashlib.sha256(body).hexdigest()
        architectures[directory] = {"machine": machine, "platform": platform, "binaries": hashes}
    (root / "dist" / masc_dist.MANIFEST_FILE).write_text(json.dumps({
        "schema": masc_dist.MANIFEST_SCHEMA,
        "release_version": floor,
        "source_commit": SOURCE_COMMIT,
        "architectures": architectures,
    }))
    return root


@pytest.fixture
def fake_docker(tmp_path, monkeypatch):
    commands = tmp_path / "commands"
    commands.mkdir()
    script = commands / "docker"
    script.write_text(FAKE_DOCKER.format(python=sys.executable))
    script.chmod(0o755)
    state = tmp_path / "docker-state"
    state.mkdir()
    monkeypatch.setenv("PATH", f"{commands}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("FAKE_DOCKER_DIR", str(state))
    monkeypatch.setenv("ANTHROPIC_API_KEY", REAL_KEY)
    for name in ("FAKE_BOOTSTRAP_FAIL_ARM", "FAKE_UPLOAD_FAIL", "FAKE_DOCKER_HANG",
                 "FAKE_BOOTSTRAP_HANG", "FAKE_BOOTSTRAP_BAD_BYTES", "FAKE_RM_FAIL", "GH_TOKEN"):
        monkeypatch.delenv(name, raising=False)
    return state


def calls(state: Path) -> list[list[str]]:
    log = state / "calls.jsonl"
    if not log.exists():
        return []
    return [json.loads(line)["argv"] for line in log.read_text().splitlines()]


def bootstraps(state: Path) -> dict[str, list[str]]:
    """Container name -> the docker exec that ran bootstrap.sh in it."""
    found = {}
    for argv in calls(state):
        if argv[:1] == ["exec"] and any(a.endswith("bootstrap.sh") for a in argv):
            name = argv[argv.index("bash") - 1]
            found[name] = argv
    return found


def env_of(argv: list[str]) -> dict[str, str]:
    pairs = (argv[i + 1] for i, a in enumerate(argv) if a == "-e")
    return dict(p.split("=", 1) for p in pairs)


def run(tmp_path, *argv):
    return preflight_arms.main(list(argv), bench_root=make_bench_root(tmp_path))


def test_every_arm_comes_up_and_the_real_key_stays_out(tmp_path, fake_docker, capsys):
    assert run(tmp_path, "--arms", "b,e", "--model", MODEL) == 0
    ran = bootstraps(fake_docker)
    assert sorted(ran) == [
        f"masc-bench-preflight-b-{os.getpid()}", f"masc-bench-preflight-e-{os.getpid()}"]
    for argv in ran.values():
        env = env_of(argv)
        assert env["BENCH_RUNTIME_ID"] == HEAD_ROUTE
        assert env["BENCH_KEEPER_POOL"] == "bench-1"
        assert env["ANTHROPIC_API_KEY"] == preflight_arms.PLACEHOLDER_KEY
    assert REAL_KEY not in json.dumps(calls(fake_docker))
    out = capsys.readouterr().out
    assert "preflight arm=b ok" in out and "preflight arm=e ok" in out


def test_each_container_gets_the_platform_the_rendered_config_and_the_driver(tmp_path, fake_docker):
    assert run(tmp_path, "--arms", "e", "--model", MODEL) == 0
    run_call = next(argv for argv in calls(fake_docker) if argv[:1] == ["run"])
    assert run_call[run_call.index("--platform") + 1] == "linux/amd64"
    assert preflight_arms.DEFAULT_IMAGE in run_call
    name = f"masc-bench-preflight-e-{os.getpid()}"
    copied = fake_docker / "copied" / name / "opt" / "masc-bench"
    runtime_toml = (copied / "config" / "runtime.toml").read_text()
    assert f'default = "{HEAD_ROUTE}"' in runtime_toml
    assert (copied / "config" / "keepers" / "bench-1.toml").is_file()
    assert (copied / "driver" / "bootstrap.sh").is_file()
    assert (copied / "bin" / "masc").read_text() == "fixture linux-x64 masc\n"
    assert (copied / "bin" / "masc-exec-shim").read_text() == "fixture linux-x64 masc-exec-shim\n"


def test_the_platform_picks_the_binaries_built_for_it(tmp_path, fake_docker):
    assert run(tmp_path, "--arms", "b", "--model", MODEL, "--platform", "linux/arm64") == 0
    name = f"masc-bench-preflight-b-{os.getpid()}"
    masc = fake_docker / "copied" / name / "opt" / "masc-bench" / "bin" / "masc"
    assert masc.read_text() == "fixture linux-arm64 masc\n"


def test_a_failing_arm_is_named_with_its_stage_and_the_others_still_run(tmp_path, fake_docker, capsys, monkeypatch):
    monkeypatch.setenv("FAKE_BOOTSTRAP_FAIL_ARM", "e")
    assert run(tmp_path, "--arms", "b,e,f", "--model", MODEL) == 1
    captured = capsys.readouterr()
    assert "preflight arm=b ok" in captured.out and "preflight arm=f ok" in captured.out
    assert "preflight arm=e FAILED at bootstrap" in captured.err
    assert "KeeperUpFailed" in captured.err
    assert "server.log: runtime.toml refused" in captured.err
    assert "1 of 3 arm(s) did not come up" in captured.err
    removed = {argv[-1] for argv in calls(fake_docker) if argv[:2] == ["rm", "-f"]}
    assert removed == {f"masc-bench-preflight-{arm}-{os.getpid()}" for arm in "bef"}


def test_an_upload_failure_names_its_stage_and_still_removes_the_container(tmp_path, fake_docker, capsys, monkeypatch):
    monkeypatch.setenv("FAKE_UPLOAD_FAIL", "1")
    assert run(tmp_path, "--arms", "b", "--model", MODEL) == 1
    assert "preflight arm=b FAILED at upload" in capsys.readouterr().err
    assert ["rm", "-f", f"masc-bench-preflight-b-{os.getpid()}"] in calls(fake_docker)
    assert bootstraps(fake_docker) == {}


def test_the_baseline_arm_starts_nothing(tmp_path, fake_docker, capsys):
    assert run(tmp_path, "--arms", "a", "--model", MODEL) == 0
    assert calls(fake_docker) == []
    assert "no MASC arm" in capsys.readouterr().out


def test_a_missing_dist_stops_before_docker(tmp_path, fake_docker, capsys):
    empty = tmp_path / "empty"
    shutil.copytree(REAL_BENCH / "driver", empty / "driver")
    assert preflight_arms.main(["--arms", "b", "--model", MODEL], bench_root=empty) == 2
    assert "image/fetch_masc.sh" in capsys.readouterr().err
    assert calls(fake_docker) == []


def test_the_failover_arm_is_routed_through_the_lane_and_the_others_get_no_fallback(tmp_path, fake_docker):
    assert run(tmp_path, "--arms", "b,l", "--model", MODEL, "--fallback-models", FALLBACK_MODEL) == 0
    ran = bootstraps(fake_docker)
    assert env_of(ran[f"masc-bench-preflight-l-{os.getpid()}"])["BENCH_RUNTIME_ID"] == BENCH_LANE
    assert env_of(ran[f"masc-bench-preflight-b-{os.getpid()}"])["BENCH_RUNTIME_ID"] == HEAD_ROUTE


def test_the_failover_arm_without_a_fallback_is_refused_before_docker(tmp_path, fake_docker, capsys):
    assert run(tmp_path, "--arms", "l", "--model", MODEL) == 2
    assert "needs at least one fallback model" in capsys.readouterr().err
    assert calls(fake_docker) == []


def test_an_unknown_arm_is_refused_before_docker(tmp_path, fake_docker, capsys):
    assert run(tmp_path, "--arms", "b,zz", "--model", MODEL) == 2
    assert "unknown arm ['zz']" in capsys.readouterr().err
    assert calls(fake_docker) == []


def test_without_docker_the_container_stage_fails_and_says_why(tmp_path, monkeypatch, capsys):
    nowhere = tmp_path / "no-docker-here"
    nowhere.mkdir()
    monkeypatch.setenv("PATH", str(nowhere))
    assert run(tmp_path, "--arms", "b", "--model", MODEL) == 1
    err = capsys.readouterr().err
    assert "preflight arm=b FAILED at container" in err
    assert "cannot run docker" in err


def trial_env(arm: str, tmp_path: Path) -> dict[str, str]:
    """The environment a trial's install hands the container for this arm."""
    agent = preflight_arms.build_agent(
        arm, MODEL, preflight_arms.DEFAULT_EFFORT, "", tmp_path / f"trial-logs-{arm}")
    return agent._container_env()


@pytest.mark.parametrize("arm", ["b", "f", "h"])
def test_the_bootstrap_brings_up_every_keeper_the_arm_runs_in_a_trial(tmp_path, fake_docker, arm):
    count = int(trial_env(arm, tmp_path)["KEEPER_COUNT"])
    assert (count > 1) == (arm in ("f", "h"))
    assert run(tmp_path, "--arms", arm, "--model", MODEL) == 0
    name = f"masc-bench-preflight-{arm}-{os.getpid()}"
    pool = env_of(bootstraps(fake_docker)[name])["BENCH_KEEPER_POOL"].split(",")
    assert pool == [f"bench-{i}" for i in range(1, count + 1)]
    keepers = fake_docker / "copied" / name / "opt" / "masc-bench" / "config" / "keepers"
    assert all((keepers / f"{keeper}.toml").is_file() for keeper in pool)


@pytest.mark.parametrize("model,key_env", [
    (MODEL, "ANTHROPIC_API_KEY"),
    ("claude_code/claude-sonnet-5", "CLAUDE_CODE_OAUTH_TOKEN"),
    ("kimi_coding/kimi-for-coding", "KIMI_API_KEY"),
])
def test_the_placeholder_goes_to_the_variable_the_providers_key_lives_in(
        tmp_path, fake_docker, model, key_env):
    # Arm e: the arms that turn parallel tool calls off cannot run on claude_code.
    assert run(tmp_path, "--arms", "e", "--model", model) == 0
    env = env_of(bootstraps(fake_docker)[f"masc-bench-preflight-e-{os.getpid()}"])
    assert env[key_env] == preflight_arms.PLACEHOLDER_KEY
    assert sorted(name for name in env if name.endswith(("_KEY", "_TOKEN"))) == [key_env]


def test_the_container_is_prepared_like_a_trials_and_expires_on_its_own(tmp_path, fake_docker):
    assert run(tmp_path, "--arms", "b", "--model", MODEL) == 0
    name = f"masc-bench-preflight-b-{os.getpid()}"
    argvs = calls(fake_docker)
    run_call = next(argv for argv in argvs if argv[:1] == ["run"])
    assert "-d" in run_call and "--rm" in run_call
    assert run_call[-2:] == ["sleep", str(preflight_arms.CONTAINER_LIFETIME_S)]
    assert preflight_arms.REMOTE == "/opt/masc-bench"
    assert ["exec", name, "mkdir", "-p", "/opt/masc-bench/bin"] in argvs
    chmod = next(argv[-1] for argv in argvs
                 if argv[:2] == ["exec", name] and "chmod +x" in argv[-1])
    assert "/opt/masc-bench/bin/*" in chmod and "/opt/masc-bench/driver/*.sh" in chmod


def test_the_platform_reaches_docker_run_whatever_it_is(tmp_path, fake_docker):
    assert run(tmp_path, "--arms", "b", "--model", MODEL, "--platform", "linux/arm64") == 0
    run_call = next(argv for argv in calls(fake_docker) if argv[:1] == ["run"])
    assert run_call[run_call.index("--platform") + 1] == "linux/arm64"


def test_a_hung_docker_command_fails_its_stage_instead_of_waiting(fake_docker, monkeypatch):
    monkeypatch.setenv("FAKE_DOCKER_HANG", "1")
    started = time.monotonic()
    with pytest.raises(preflight_arms.StageFailed, match="did not finish in 1s") as raised:
        preflight_arms.docker("probe", "info", timeout=1)
    assert raised.value.stage == "probe"
    assert time.monotonic() - started < 20


def rendered_configs(monkeypatch) -> list[Path]:
    """Records every directory render_arm returns, to see afterwards whether it is gone."""
    made: list[Path] = []
    real = preflight_arms.render_arm

    def spy(*args, **kwargs):
        path = real(*args, **kwargs)
        made.append(Path(path))
        return path

    monkeypatch.setattr(preflight_arms, "render_arm", spy)
    return made


def test_the_rendered_config_is_removed_whether_the_arm_comes_up_or_not(tmp_path, fake_docker, monkeypatch):
    made = rendered_configs(monkeypatch)
    monkeypatch.setenv("FAKE_BOOTSTRAP_FAIL_ARM", "e")
    assert run(tmp_path, "--arms", "b,e", "--model", MODEL) == 1
    assert len(made) == 2
    assert not any(path.exists() for path in made)


def test_the_effort_is_the_one_a_trial_renders_with_unless_asked(tmp_path, fake_docker, monkeypatch):
    efforts: list[str] = []
    real = preflight_arms.render_arm

    def spy(arm, runtime_id, effort, **kwargs):
        efforts.append(effort)
        return real(arm, runtime_id, effort, **kwargs)

    monkeypatch.setattr(preflight_arms, "render_arm", spy)
    root = make_bench_root(tmp_path)
    assert preflight_arms.main(["--arms", "b", "--model", MODEL], bench_root=root) == 0
    trial_effort = MascAgent(tmp_path / "logs", model_name=MODEL, arm="b").effort
    assert efforts == [trial_effort]
    asked = "low" if trial_effort != "low" else "high"
    assert preflight_arms.main(
        ["--arms", "b", "--model", MODEL, "--effort", asked], bench_root=root) == 0
    assert efforts[-1] == asked


def test_a_config_that_cannot_be_rendered_stops_at_render_without_a_container(
        tmp_path, fake_docker, monkeypatch, capsys):
    def refuse(*args, **kwargs):
        raise ValueError("no such binding")

    monkeypatch.setattr(preflight_arms, "render_arm", refuse)
    assert run(tmp_path, "--arms", "b", "--model", MODEL) == 1
    err = capsys.readouterr().err
    assert "preflight arm=b FAILED at render" in err and "no such binding" in err
    assert not any(argv[:1] == ["run"] for argv in calls(fake_docker))


def test_an_unreadable_dist_is_refused_before_docker(tmp_path, fake_docker, monkeypatch, capsys):
    async def unreadable(*args, **kwargs):
        raise PermissionError("dist/linux-x64/masc")

    monkeypatch.setattr(preflight_arms, "container_distribution", unreadable)
    assert run(tmp_path, "--arms", "b", "--model", MODEL) == 2
    assert "dist/linux-x64/masc" in capsys.readouterr().err
    assert calls(fake_docker) == []


def staged_gh(state: Path) -> Path:
    return (state / "copied" / f"masc-bench-preflight-b-{os.getpid()}"
            / "opt" / "masc-bench" / "bin" / "gh")


def test_gh_is_staged_when_a_trial_would_stage_it_and_the_token_stays_out(tmp_path, fake_docker, monkeypatch):
    monkeypatch.setenv("GH_TOKEN", REAL_GH_TOKEN)
    assert trial_env("b", tmp_path)["GH_TOKEN"] == REAL_GH_TOKEN
    assert run(tmp_path, "--arms", "b", "--model", MODEL) == 0
    assert staged_gh(fake_docker).read_text() == "fixture linux-x64 gh\n"
    assert REAL_GH_TOKEN not in json.dumps(calls(fake_docker))


def test_gh_is_left_out_without_a_token(tmp_path, fake_docker):
    assert "GH_TOKEN" not in trial_env("b", tmp_path)
    assert run(tmp_path, "--arms", "b", "--model", MODEL) == 0
    assert not staged_gh(fake_docker).exists()


def test_arms_are_split_the_way_run_matrix_splits_them(tmp_path, fake_docker):
    assert run(tmp_path, "--arms", "b, e", "--model", MODEL) == 0
    assert sorted(bootstraps(fake_docker)) == [
        f"masc-bench-preflight-b-{os.getpid()}", f"masc-bench-preflight-e-{os.getpid()}"]


def test_output_that_is_not_utf8_does_not_hide_the_failure(tmp_path, fake_docker, capsys, monkeypatch):
    monkeypatch.setenv("FAKE_BOOTSTRAP_FAIL_ARM", "b")
    monkeypatch.setenv("FAKE_BOOTSTRAP_BAD_BYTES", "1")
    assert run(tmp_path, "--arms", "b,e", "--model", MODEL) == 1
    captured = capsys.readouterr()
    assert "preflight arm=b FAILED at bootstrap" in captured.err
    assert "KeeperUpFailed" in captured.err
    assert "preflight arm=e ok" in captured.out


def test_a_container_that_could_not_be_removed_is_reported(tmp_path, fake_docker, capsys, monkeypatch):
    monkeypatch.setenv("FAKE_RM_FAIL", "1")
    assert run(tmp_path, "--arms", "b", "--model", MODEL) == 0
    err = capsys.readouterr().err
    assert f"container masc-bench-preflight-b-{os.getpid()} was not removed" in err
    assert "Cannot connect to the Docker daemon" in err


RUNNER = """
import sys
from pathlib import Path
bench = {bench!r}
sys.path[:0] = [bench, bench + "/agents", bench + "/configs"]
import preflight_arms
sys.exit(preflight_arms.main(["--arms", "b", "--model", {model!r}], bench_root=Path({root!r})))
"""


def wait_until(condition, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.05)
    raise AssertionError(f"not reached within {seconds}s")


@pytest.mark.parametrize("terminate", [signal.SIGTERM, signal.SIGHUP])
def test_a_terminated_preflight_removes_its_container_and_its_files(
        tmp_path, fake_docker, monkeypatch, terminate):
    monkeypatch.setenv("FAKE_BOOTSTRAP_HANG", "1")
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    rendered = BENCH / "configs" / "out"
    before = set(rendered.iterdir()) if rendered.exists() else set()
    code = RUNNER.format(bench=str(BENCH), model=MODEL, root=str(make_bench_root(tmp_path)))
    child = subprocess.Popen(
        [sys.executable, "-c", code], env={**os.environ, "TMPDIR": str(scratch)},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        wait_until(lambda: any(argv[:1] == ["exec"] and any(a.endswith("bootstrap.sh") for a in argv)
                               for argv in calls(fake_docker)))
        child.send_signal(terminate)
        child.communicate(timeout=60)
    finally:
        if child.poll() is None:
            child.kill()
            child.communicate()
    assert child.returncode == 128 + terminate
    assert ["rm", "-f", f"masc-bench-preflight-b-{child.pid}"] in calls(fake_docker)
    assert list(scratch.iterdir()) == []
    assert (set(rendered.iterdir()) if rendered.exists() else set()) == before
