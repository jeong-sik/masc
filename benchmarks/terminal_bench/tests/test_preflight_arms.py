"""preflight_arms starts the server for every arm before a run, without a model.

docker is a fake that logs each call and keeps a copy of what was uploaded, so
these tests hold what the script sends to a container: the platform, the
binaries of that platform, the rendered config, the keeper the bootstrap is told
to bring up, and that the real provider key is never among the arguments.
"""
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

import pytest

BENCH = Path(__file__).resolve().parents[1]
for subdirectory in ("agents", "configs", ""):
    sys.path.insert(0, str(BENCH / subdirectory))

import masc_dist  # noqa: E402
import preflight_arms  # noqa: E402
from render_configs import BENCH_LANE  # noqa: E402

REAL_BENCH = BENCH
SOURCE_COMMIT = "b" * 40
REAL_KEY = "sk-real-key-that-must-not-reach-docker"
MODEL = "anthropic/claude-fable-5-1"
FALLBACK_MODEL = "anthropic/claude-sonnet-5"
HEAD_ROUTE = "claude.claude-fable-5-1"

FAKE_DOCKER = r'''#!{python}
import json, os, shutil, sys
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
        shutil.copytree(source, keep)
    else:
        shutil.copy2(source, keep)
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps(entry) + "\n")

joined = " ".join(args)
fail_arm = os.environ.get("FAKE_BOOTSTRAP_FAIL_ARM")
if args[:1] == ["exec"] and "bootstrap.sh" in joined:
    if fail_arm and f"-preflight-{{fail_arm}}-" in joined:
        print("keeper_up answered KeeperUpFailed", file=sys.stderr)
        sys.exit(1)
    print("MASC server ready")
elif args[:1] == ["exec"] and "server.log" in joined:
    print("server.log: runtime.toml refused")
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
        for name in ("masc", "masc-exec-shim"):
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
    for name in ("FAKE_BOOTSTRAP_FAIL_ARM", "FAKE_UPLOAD_FAIL"):
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
        assert env["BENCH_KEEPER_POOL"] == preflight_arms.FIRST_KEEPER
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
