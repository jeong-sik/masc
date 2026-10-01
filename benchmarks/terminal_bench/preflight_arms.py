#!/usr/bin/env python3
"""Bring the MASC server up for each arm of a run the way a trial does.

run_matrix.sh runs this before it downloads the dataset. Without it, a release
that cannot boot a rendered config, a bootstrap that stopped working, or a
keeper_up that answers an error shows up on the first trial of an arm, hours
into the run. After #39020 the renderer and the latest release disagreed for
about 68 hours: the server started and keeper_up answered KeeperUpFailed on
every HTTP lane.

Per arm: render the config, start a clean container of the trial platform,
upload the fetched release binaries, the driver and the config as
MascAgent.install does, and run bootstrap.sh with every keeper of the arm named
in BENCH_KEEPER_POOL (bench-1 to bench-N, the count the arm declares). bootstrap.sh
starts the server, brings each keeper up and sets its approval stance.

No model is called and no credential is used: the provider key is a
placeholder, and GH_TOKEN only decides whether gh is staged. The server logs what
it logs without a key; that is not a failure.

A trial differs in three places. run_episode.sh brings the keepers up itself,
with keeper-instructions.txt and a 90 s limit each, where bootstrap.sh uses its
own pool instructions and 180 s. A task's Skills are rendered into the config
and checked against the catalog. A task's own image, user and PATH replace
the plain image used here. Whether a model answers is not tested.

Exit status: 0 every arm came up, 1 an arm did not (named with its stage),
2 nothing started (bad arguments, dist/ missing).

usage: preflight_arms.py --arms b,c,e --model anthropic/claude-fable-5-1
           [--fallback-models p/m,p/m] [--effort <MascAgent default>]
           [--platform linux/amd64] [--image ubuntu:24.04]
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import inspect
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace

BENCH_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(BENCH_ROOT))
sys.path.insert(0, str(BENCH_ROOT / "configs"))
sys.path.insert(0, str(BENCH_ROOT / "agents"))

from agents.masc_agent import REMOTE, MascAgent  # noqa: E402
from masc_dist import (  # noqa: E402
    PLATFORM_BY_MACHINE,
    UNAME_MARK,
    container_distribution,
)
from agents.masc_sidecar import pool_names  # noqa: E402
from render_configs import ARMS, PROVIDERS, keeper_route, render_arm  # noqa: E402

# Arm a is harbor's own agent for the same model, not MASC (run_matrix.sh).
BASELINE_ARM = "a"
# The image fetch_masc.sh verifies the release binaries in.
DEFAULT_IMAGE = "ubuntu:24.04"
# Terminal-Bench 4.0.0 task images are prebuilt for amd64 (agents/masc_dist.py),
# emulated on Apple Silicon.
DEFAULT_PLATFORM = "linux/amd64"
PLACEHOLDER_KEY = "preflight-placeholder-no-credential"
# What a trial renders with: run_matrix.sh passes no effort, so MascAgent's default applies.
DEFAULT_EFFORT = inspect.signature(MascAgent.__init__).parameters["effort"].default

MACHINE_BY_PLATFORM = {platform: machine for machine, platform in PLATFORM_BY_MACHINE.items()}

# docker run pulls the image when this host has not got it yet.
CONTAINER_START_TIMEOUT_S = 600
# docker cp and a short docker exec.
DOCKER_STEP_TIMEOUT_S = 120
# bootstrap.sh installs packages over the network and then waits up to 60 s for
# MCP, then brings each keeper up. 49 s (arm b, 1 keeper) to 89 s (arm h, 8 keepers)
# were measured on emulated amd64, 2026-10-01.
BOOTSTRAP_TIMEOUT_S = 900
# The container sleeps this long and is then removed on its own (docker run
# --rm), so a preflight killed past its cleanup leaves a container for at most
# this long. The stages above add up to less.
CONTAINER_LIFETIME_S = 3600
FAILURE_TAIL_LINES = 30
SERVER_LOG_TAIL_LINES = 40


class StageFailed(Exception):
    def __init__(self, stage: str, detail: str) -> None:
        super().__init__(f"{stage}: {detail}")
        self.stage = stage
        self.detail = detail


def tail(text: str, lines: int) -> str:
    return "\n".join(text.strip().splitlines()[-lines:])


def docker(stage: str, *args: str, timeout: int) -> subprocess.CompletedProcess[str]:
    try:
        # errors="replace": the output is only read to explain a failure, and
        # one byte that is not UTF-8 must not replace that explanation.
        return subprocess.run(
            ["docker", *args], capture_output=True, text=True, errors="replace",
            timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise StageFailed(stage, f"docker {args[0]} did not finish in {timeout}s") from exc
    except OSError as exc:
        raise StageFailed(stage, f"cannot run docker: {exc}") from exc


def docker_ok(stage: str, *args: str, timeout: int = DOCKER_STEP_TIMEOUT_S) -> None:
    done = docker(stage, *args, timeout=timeout)
    if done.returncode != 0:
        raise StageFailed(
            stage,
            f"docker {args[0]} exited {done.returncode}\n"
            f"{tail(done.stdout + done.stderr, FAILURE_TAIL_LINES)}")


def exit_on_signal(signum: int, frame: object) -> None:
    raise SystemExit(128 + signum)


@contextlib.contextmanager
def termination_runs_cleanup():
    """SIGTERM and SIGHUP end a Python process without running its finally blocks.

    As SystemExit they run: the container is removed and the scratch directories
    go. SIGINT already raises KeyboardInterrupt.
    """
    signals = (signal.SIGTERM, signal.SIGHUP)
    previous = {number: signal.signal(number, exit_on_signal) for number in signals}
    try:
        yield
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


class ConstantMachine:
    """Answers container_distribution's `uname -m` the way a container of that machine would."""

    def __init__(self, machine: str) -> None:
        self.machine = machine

    async def exec_as_root(self, environment, command, env=None, cwd=None, timeout_sec=None):
        return SimpleNamespace(stdout=f"{UNAME_MARK}{self.machine}\n")


def preflight_arm(
    agent: MascAgent,
    binaries: list[Path],
    bench_root: Path,
    platform: str,
    image: str,
) -> tuple[str, float]:
    """Raises StageFailed when the arm does not come up; returns the keeper route and the seconds it took."""
    name = f"masc-bench-preflight-{agent.arm}-{os.getpid()}"
    provider = agent.runtime_id.split(".", 1)[0]
    key_env = PROVIDERS[provider]["api_key_env"]
    config_dir: Path | None = None
    started = time.monotonic()
    try:
        try:
            config_dir = render_arm(
                agent.arm, agent.runtime_id, agent.effort,
                fallback_runtime_ids=agent.fallback_runtime_ids)
            route = keeper_route(agent.arm, agent.runtime_id, agent.fallback_runtime_ids)
        except (OSError, ValueError, KeyError) as exc:
            raise StageFailed("render", str(exc)) from exc
        docker_ok("container", "run", "-d", "--rm", "--name", name, "--platform", platform,
                  image, "sleep", str(CONTAINER_LIFETIME_S), timeout=CONTAINER_START_TIMEOUT_S)
        docker_ok("upload", "exec", name, "mkdir", "-p", f"{REMOTE}/bin")
        for binary in binaries:
            docker_ok("upload", "cp", str(binary), f"{name}:{REMOTE}/bin/{binary.name}")
        docker_ok("upload", "cp", str(bench_root / "driver"), f"{name}:{REMOTE}/driver")
        docker_ok("upload", "cp", str(config_dir), f"{name}:{REMOTE}/config")
        docker_ok("upload", "exec", name, "sh", "-c",
                  f"chmod +x {REMOTE}/bin/* {REMOTE}/driver/*.sh")
        done = docker(
            "bootstrap", "exec",
            "-e", f"{key_env}={PLACEHOLDER_KEY}",
            "-e", f"BENCH_RUNTIME_ID={route}",
            "-e", f"BENCH_KEEPER_POOL={','.join(pool_names(agent.arm))}",
            name, "bash", f"{REMOTE}/driver/bootstrap.sh",
            timeout=BOOTSTRAP_TIMEOUT_S)
        if done.returncode != 0:
            # bootstrap.sh prints its own server.log tail only when the server
            # never answered; a keeper_up refusal is in the log as well.
            log = docker("bootstrap", "exec", name, "tail", "-n", str(SERVER_LOG_TAIL_LINES),
                         f"{REMOTE}/server.log", timeout=DOCKER_STEP_TIMEOUT_S)
            raise StageFailed(
                "bootstrap",
                f"bootstrap.sh exited {done.returncode}\n"
                f"{tail(done.stdout + done.stderr, FAILURE_TAIL_LINES)}\n"
                f"--- {REMOTE}/server.log\n{tail(log.stdout + log.stderr, SERVER_LOG_TAIL_LINES)}")
        return route, time.monotonic() - started
    finally:
        # Best effort: it must not replace the failure that brought it here.
        try:
            removed = docker("cleanup", "rm", "-f", name, timeout=DOCKER_STEP_TIMEOUT_S)
            if removed.returncode != 0:
                print(f"preflight arm={agent.arm}: container {name} was not removed: "
                      f"{tail(removed.stdout + removed.stderr, FAILURE_TAIL_LINES)}",
                      file=sys.stderr, flush=True)
        except StageFailed as exc:
            print(f"preflight arm={agent.arm}: container {name} was not removed: {exc.detail}",
                  file=sys.stderr, flush=True)
        if config_dir is not None:
            shutil.rmtree(config_dir, ignore_errors=True)


def build_agent(arm: str, model: str, effort: str, fallback_models: str, logs_dir: Path) -> MascAgent:
    # Only the failover arm takes the fallback models (run_matrix.sh passes
    # them to arm l alone), and MascAgent refuses them on any other arm.
    fallbacks = fallback_models if ARMS[arm]["failover"] else ""
    return MascAgent(logs_dir, model_name=model, arm=arm, effort=effort,
                     fallback_models=fallbacks)


def main(argv: list[str] | None = None, *, bench_root: Path = BENCH_ROOT) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("--arms", required=True, help="comma-separated arms, as run_matrix.sh takes them")
    parser.add_argument("--model", required=True, help="<provider>/<model>, as harbor names it")
    parser.add_argument("--fallback-models", default="", help="comma-separated <provider>/<model> for arm l")
    parser.add_argument("--effort", default=DEFAULT_EFFORT)
    parser.add_argument("--platform", default=DEFAULT_PLATFORM, choices=sorted(MACHINE_BY_PLATFORM))
    parser.add_argument("--image", default=DEFAULT_IMAGE)
    args = parser.parse_args(argv)

    arms = [arm for arm in (part.strip() for part in args.arms.split(",")) if arm and arm != BASELINE_ARM]
    if not arms:
        print("preflight: no MASC arm in the list, nothing to start")
        return 0
    unknown = [arm for arm in arms if arm not in ARMS]
    if unknown:
        print(f"preflight: unknown arm {unknown}; expected one of {sorted(ARMS)}", file=sys.stderr)
        return 2

    with termination_runs_cleanup(), tempfile.TemporaryDirectory(prefix="masc-bench-preflight-") as scratch:
        scratch_dir = Path(scratch)
        try:
            agents = [build_agent(arm, args.model, args.effort, args.fallback_models,
                                  scratch_dir / f"logs-{arm}") for arm in arms]
            distribution = asyncio.run(container_distribution(
                ConstantMachine(MACHINE_BY_PLATFORM[args.platform]),
                SimpleNamespace(default_user=None),
                bench_root, scratch_dir / "dist", with_gh=bool(os.environ.get("GH_TOKEN"))))
        except (OSError, RuntimeError, ValueError) as exc:
            print(f"preflight: {exc}", file=sys.stderr)
            return 2
        print(f"preflight: masc {distribution.identity.release_version} "
              f"({distribution.identity.source_commit[:10]}) on {args.platform}, "
              f"arms {','.join(arms)}", flush=True)

        failed = 0
        for agent in agents:
            try:
                route, seconds = preflight_arm(
                    agent, distribution.binaries, bench_root, args.platform, args.image)
                print(f"preflight arm={agent.arm} ok route={route} platform={args.platform} "
                      f"seconds={seconds:.0f}", flush=True)
            except StageFailed as exc:
                failed += 1
                print(f"preflight arm={agent.arm} FAILED at {exc.stage}\n{exc.detail}", file=sys.stderr, flush=True)
        if failed:
            print(f"preflight: {failed} of {len(agents)} arm(s) did not come up; the run was not started",
                  file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
