"""Which Terminal-Bench tasks a run on this environment can hold, read from the
dataset's own task.toml files.

Two facts about harbor decide this, and neither shows up until a run is hours
in:

- A task that asks for a GPU on an environment without GPU support makes
  harbor raise while creating the trial (environments/base.py
  _validate_gpu_support). Trial.create is outside the per-trial error handling
  and the job runs trials in a TaskGroup, so the whole job stops. Terminal-Bench
  4.0.0 has three such tasks and the docker environment has no GPU support.
  They are printed for `harbor run -x` under the name harbor filters on
  (`[task].name`, e.g. terminal-bench/jax-speedrun-gpu), and the run says it is
  not the full set.
- The docker environment sets each task container's `cpus` and `memory_mb` as
  limits, with no reservation. A task declares those as what it needs, so a run
  is refused when the daemon cannot give them: when one task asks for more than
  the daemon has, or when the tasks that can run at once (the largest
  `concurrency` of them) ask for more together. The agent and verifier
  environments of one trial do not overlap, so each task counts the larger of
  the two.

Usage:
  python dataset_plan.py --tasks-dir <dir> --env docker --concurrency N
  python dataset_plan.py --tasks-dir <dir> --env modal    # sized per task: nothing to plan

Prints one excluded task name per line on stdout. Exits 1 when the run would
not fit the environment, or when the dataset directory is incomplete.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path

MIB = 1024 * 1024


@dataclass(frozen=True, slots=True)
class TaskNeeds:
    name: str
    cpus: int
    memory_mb: int
    gpus: int


@dataclass(frozen=True, slots=True)
class Capacity:
    cpus: int
    memory_mb: int
    gpus: bool


@dataclass(frozen=True, slots=True)
class Plan:
    excluded_for_gpu: tuple[str, ...]
    over_capacity: tuple[str, ...]


class IncompleteDataset(Exception):
    pass


def environment_needs(table: dict) -> tuple[int, int, int]:
    return (int(table.get("cpus") or 1), int(table.get("memory_mb") or 0),
            int(table.get("gpus") or 0))


def read_needs(tasks_dir: Path) -> list[TaskNeeds]:
    """Every task directory must carry a task.toml with a [task] name: a
    download stopped half way leaves directories without one, and planning over
    the rest would pass a run that then fetches the whole dataset."""
    needs = []
    for task_dir in sorted(p for p in tasks_dir.iterdir() if p.is_dir()):
        task_toml = task_dir / "task.toml"
        if not task_toml.is_file():
            raise IncompleteDataset(f"{task_dir} has no task.toml")
        config = tomllib.loads(task_toml.read_text())
        name = (config.get("task") or {}).get("name")
        if not name:
            raise IncompleteDataset(f"{task_toml} has no [task] name")
        agent_env = config.get("environment") or {}
        verifier_env = (config.get("verifier") or {}).get("environment") or agent_env
        agent, verifier = environment_needs(agent_env), environment_needs(verifier_env)
        needs.append(TaskNeeds(
            name=name,
            cpus=max(agent[0], verifier[0]),
            memory_mb=max(agent[1], verifier[1]),
            gpus=max(agent[2], verifier[2]),
        ))
    return needs


def shortfall(task: TaskNeeds, capacity: Capacity) -> str | None:
    """What `task` asks for beyond `capacity`, or None when it fits."""
    parts = []
    if task.cpus > capacity.cpus:
        parts.append(f"cpus {task.cpus} > {capacity.cpus}")
    if task.memory_mb > capacity.memory_mb:
        parts.append(f"memory_mb {task.memory_mb} > {capacity.memory_mb}")
    return f"{task.name}: {', '.join(parts)}" if parts else None


def concurrent_shortfall(included: list[TaskNeeds], capacity: Capacity,
                         concurrency: int) -> str | None:
    """The largest `concurrency` tasks can be running at the same moment."""
    width = min(concurrency, len(included))
    cpus = sum(sorted((t.cpus for t in included), reverse=True)[:width])
    memory_mb = sum(sorted((t.memory_mb for t in included), reverse=True)[:width])
    parts = []
    if cpus > capacity.cpus:
        parts.append(f"cpus {cpus} > {capacity.cpus}")
    if memory_mb > capacity.memory_mb:
        parts.append(f"memory_mb {memory_mb} > {capacity.memory_mb}")
    if not parts:
        return None
    return f"the {width} largest tasks running at once: {', '.join(parts)}"


def plan(needs: list[TaskNeeds], capacity: Capacity, concurrency: int) -> Plan:
    excluded = tuple(t.name for t in needs if t.gpus > 0 and not capacity.gpus)
    included = [t for t in needs if t.name not in excluded]
    over = [line for t in included if (line := shortfall(t, capacity)) is not None]
    if not over:
        together = concurrent_shortfall(included, capacity, concurrency)
        if together is not None:
            over.append(together)
    return Plan(excluded_for_gpu=excluded, over_capacity=tuple(over))


def docker_capacity() -> Capacity:
    info = json.loads(subprocess.run(
        ["docker", "info", "--format", "{{json .}}"],
        check=True, capture_output=True, text=True).stdout)
    # harbor's docker environment reports no GPU support (docker.py
    # capabilities), whatever the daemon has.
    return Capacity(cpus=int(info["NCPU"]), memory_mb=int(info["MemTotal"]) // MIB,
                    gpus=False)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tasks-dir", type=Path, required=True)
    parser.add_argument("--env", choices=("docker", "modal"), required=True)
    parser.add_argument("--concurrency", type=int, default=1)
    args = parser.parse_args(argv)
    try:
        needs = read_needs(args.tasks_dir)
    except IncompleteDataset as exc:
        print(f"incomplete dataset: {exc}; download it again", file=sys.stderr)
        return 1
    if not needs:
        print(f"no tasks under {args.tasks_dir}", file=sys.stderr)
        return 1
    if args.env == "modal":
        return 0
    capacity = docker_capacity()
    result = plan(needs, capacity, args.concurrency)
    for name in result.excluded_for_gpu:
        print(name)
    if result.excluded_for_gpu:
        print(f"{len(result.excluded_for_gpu)} of {len(needs)} tasks need a GPU, "
              f"which the {args.env} environment cannot give; this run is not "
              f"the full set: {', '.join(result.excluded_for_gpu)}", file=sys.stderr)
    if result.over_capacity:
        print(f"the {args.env} environment has {capacity.cpus} CPUs and "
              f"{capacity.memory_mb} MiB, and the run at concurrency "
              f"{args.concurrency} asks for more:", file=sys.stderr)
        for line in result.over_capacity:
            print(f"  {line}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
