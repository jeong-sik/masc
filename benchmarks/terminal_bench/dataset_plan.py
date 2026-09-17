"""Which Terminal-Bench tasks a run on this environment can hold, read from the
dataset's own task.toml files.

Two facts about harbor decide this, and neither shows up until a run is hours
in:

- A task that asks for a GPU on an environment without GPU support makes
  harbor raise while creating the trial (environments/base.py
  _validate_gpu_support), outside the per-trial error handling, so the whole
  job stops. Terminal-Bench 4.0.0 has three such tasks and the docker
  environment has no GPU support. They are named and excluded, and the run
  says it is not the full set.
- The docker environment applies each task's `cpus` and `memory_mb` to its
  container. A task that asks for more than the Docker daemon has does not get
  it, and fails or is starved for a reason that has nothing to do with the
  agent. Those are refused before the run starts, with the numbers.

Usage:
  python dataset_plan.py --tasks-dir <dir> --env docker   # reads `docker info`
  python dataset_plan.py --tasks-dir <dir> --env modal    # sized per task: nothing to plan

Prints one excluded task name per line on stdout. Exits 1 when a task the run
would include does not fit the environment.
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


def read_needs(tasks_dir: Path) -> list[TaskNeeds]:
    needs = []
    for task_toml in sorted(tasks_dir.glob("*/task.toml")):
        environment = tomllib.loads(task_toml.read_text()).get("environment", {})
        needs.append(TaskNeeds(
            name=task_toml.parent.name,
            cpus=int(environment.get("cpus", 1)),
            memory_mb=int(environment.get("memory_mb", 0)),
            gpus=int(environment.get("gpus") or 0),
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


def plan(needs: list[TaskNeeds], capacity: Capacity) -> Plan:
    excluded = tuple(t.name for t in needs if t.gpus > 0 and not capacity.gpus)
    over = tuple(
        line for t in needs if t.name not in excluded
        if (line := shortfall(t, capacity)) is not None
    )
    return Plan(excluded_for_gpu=excluded, over_capacity=over)


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
    args = parser.parse_args(argv)
    needs = read_needs(args.tasks_dir)
    if not needs:
        print(f"no task.toml under {args.tasks_dir}", file=sys.stderr)
        return 1
    if args.env == "modal":
        return 0
    capacity = docker_capacity()
    result = plan(needs, capacity)
    for name in result.excluded_for_gpu:
        print(name)
    if result.excluded_for_gpu:
        print(f"{len(result.excluded_for_gpu)} of {len(needs)} tasks need a GPU, "
              f"which the {args.env} environment cannot give; this run is not "
              f"the full set: {', '.join(result.excluded_for_gpu)}", file=sys.stderr)
    if result.over_capacity:
        print(f"the {args.env} environment has {capacity.cpus} CPUs and "
              f"{capacity.memory_mb} MiB; these tasks ask for more:", file=sys.stderr)
        for line in result.over_capacity:
            print(f"  {line}", file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
