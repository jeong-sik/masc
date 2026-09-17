"""A run is planned from the dataset's own task.toml files.

The fixtures copy real Terminal-Bench 4.0.0 values (measured 2026-09-17 from
`harbor datasets download terminal-bench/terminal-bench@4.0.0`):
live-database-cutover 16 CPU / 16384 MiB, jax-speedrun-gpu 16 / 32768 with one
GPU, atrx-vep-crispr 2 / 4096, and payments-pipeline-fix whose verifier
environment (6 / 12288) is larger than its agent environment (4 / 8192).
"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import dataset_plan  # noqa: E402
from dataset_plan import Capacity, IncompleteDataset, main, plan, read_needs  # noqa: E402

MIB = 1024 * 1024


def write_task(root, short, cpus, memory_mb, gpus=None, verifier=None):
    (root / short).mkdir(parents=True)
    gpu_line = "" if gpus is None else f"gpus = {gpus}\n"
    verifier_block = "" if verifier is None else (
        "\n[verifier.environment]\n"
        f"cpus = {verifier[0]}\nmemory_mb = {verifier[1]}\n")
    (root / short / "task.toml").write_text(
        f'[task]\nname = "terminal-bench/{short}"\n\n'
        "[agent]\ntimeout_sec = 28800.0\n\n"
        f"[environment]\ncpus = {cpus}\nmemory_mb = {memory_mb}\n{gpu_line}"
        f"{verifier_block}")


def dataset(root):
    write_task(root, "atrx-vep-crispr", 2, 4096, gpus=0)
    write_task(root, "jax-speedrun-gpu", 16, 32768, gpus=1)
    write_task(root, "live-database-cutover", 16, 16384, gpus=0)
    write_task(root, "payments-pipeline-fix", 4, 8192, verifier=(6, 12288))
    return root


ROOMY = Capacity(cpus=64, memory_mb=262144, gpus=False)


def test_gpu_tasks_are_excluded_under_the_name_harbor_filters_on(tmp_path):
    from harbor.models.job.config import DatasetConfig
    from harbor.models.task.id import PackageTaskId

    needs = read_needs(dataset(tmp_path))
    result = plan(needs, ROOMY, concurrency=1)
    assert result.excluded_for_gpu == ("terminal-bench/jax-speedrun-gpu",)
    # The same filter `harbor run -d terminal-bench/terminal-bench@4.0.0 -x ...`
    # applies (models/job/config.py _filter_task_ids).
    ids = [PackageTaskId(org="terminal-bench", name=p.name) for p in tmp_path.iterdir()]
    kept = DatasetConfig(name="terminal-bench/terminal-bench", ref="4.0.0",
                         exclude_task_names=list(result.excluded_for_gpu)
                         )._filter_task_ids(ids)
    assert sorted(t.get_name() for t in kept) == sorted(
        n.name for n in needs if n.name != "terminal-bench/jax-speedrun-gpu")


def test_the_larger_of_the_agent_and_verifier_environments_counts(tmp_path):
    needs = {t.name: t for t in read_needs(dataset(tmp_path))}
    payments = needs["terminal-bench/payments-pipeline-fix"]
    assert (payments.cpus, payments.memory_mb) == (6, 12288)


def test_a_task_bigger_than_the_daemon_is_refused_with_its_numbers(tmp_path):
    result = plan(read_needs(dataset(tmp_path)),
                  Capacity(cpus=4, memory_mb=15973, gpus=False), concurrency=1)
    assert result.over_capacity == (
        "terminal-bench/live-database-cutover: cpus 16 > 4, memory_mb 16384 > 15973",
        "terminal-bench/payments-pipeline-fix: cpus 6 > 4",
    )


def test_tasks_that_fit_alone_can_still_overfill_the_daemon_together(tmp_path):
    needs = read_needs(dataset(tmp_path))
    capacity = Capacity(cpus=16, memory_mb=32768, gpus=False)
    assert plan(needs, capacity, concurrency=1).over_capacity == ()
    together = plan(needs, capacity, concurrency=2).over_capacity
    assert together == ("the 2 largest tasks running at once: cpus 22 > 16",)


def test_a_half_downloaded_dataset_is_refused(tmp_path):
    dataset(tmp_path)
    (tmp_path / "wal-recovery-ordering").mkdir()
    with pytest.raises(IncompleteDataset):
        read_needs(tmp_path)
    assert main(["--tasks-dir", str(tmp_path), "--env", "modal"]) == 1


def test_docker_prints_the_exclusions_and_refuses_what_does_not_fit(
        tmp_path, monkeypatch, capsys):
    dataset(tmp_path)
    monkeypatch.setattr(dataset_plan, "docker_capacity",
                        lambda: Capacity(cpus=16, memory_mb=32768, gpus=False))
    assert main(["--tasks-dir", str(tmp_path), "--env", "docker",
                 "--concurrency", "1"]) == 0
    assert capsys.readouterr().out == "terminal-bench/jax-speedrun-gpu\n"
    assert main(["--tasks-dir", str(tmp_path), "--env", "docker",
                 "--concurrency", "2"]) == 1


def test_docker_capacity_reads_cpus_and_mebibytes(monkeypatch):
    class Done:
        stdout = '{"NCPU": 4, "MemTotal": 16748879872}'

    monkeypatch.setattr(dataset_plan.subprocess, "run", lambda *a, **k: Done())
    assert dataset_plan.docker_capacity() == Capacity(
        cpus=4, memory_mb=16748879872 // MIB, gpus=False)
    assert dataset_plan.docker_capacity().memory_mb == 15972


def test_modal_prints_no_exclusions_and_succeeds(tmp_path, capsys):
    dataset(tmp_path)
    assert main(["--tasks-dir", str(tmp_path), "--env", "modal"]) == 0
    assert capsys.readouterr().out == ""
