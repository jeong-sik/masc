"""A run is planned from the dataset's own task.toml files.

The real Terminal-Bench 4.0.0 numbers are used where they matter: three tasks
ask for one H100 each, and the largest CPU-only task asks for 16 CPUs.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from dataset_plan import Capacity, main, plan, read_needs  # noqa: E402


def write_task(root, name, cpus, memory_mb, gpus=None):
    (root / name).mkdir(parents=True)
    gpu_line = "" if gpus is None else f"gpus = {gpus}\n"
    (root / name / "task.toml").write_text(
        "[agent]\ntimeout_sec = 28800.0\n\n"
        f"[environment]\ncpus = {cpus}\nmemory_mb = {memory_mb}\n{gpu_line}")


def dataset(tmp_path):
    write_task(tmp_path, "atrx-vep-crispr", 2, 4096, gpus=0)
    write_task(tmp_path, "jax-speedrun-gpu", 16, 32768, gpus=1)
    write_task(tmp_path, "vllm-deepseek-streaming", 16, 16384, gpus=0)
    write_task(tmp_path, "cad-model", 4, 8192)
    return read_needs(tmp_path)


def test_gpu_tasks_are_excluded_by_name_where_there_is_no_gpu(tmp_path):
    result = plan(dataset(tmp_path), Capacity(cpus=16, memory_mb=65536, gpus=False))
    assert result.excluded_for_gpu == ("jax-speedrun-gpu",)
    assert result.over_capacity == ()


def test_a_task_bigger_than_the_daemon_is_refused_with_its_numbers(tmp_path):
    result = plan(dataset(tmp_path), Capacity(cpus=4, memory_mb=16384, gpus=False))
    assert result.over_capacity == ("vllm-deepseek-streaming: cpus 16 > 4",)


def test_an_excluded_gpu_task_is_not_also_counted_against_capacity(tmp_path):
    result = plan(dataset(tmp_path), Capacity(cpus=4, memory_mb=8192, gpus=False))
    assert not any(line.startswith("jax-speedrun-gpu") for line in result.over_capacity)
    assert "vllm-deepseek-streaming: cpus 16 > 4, memory_mb 16384 > 8192" in result.over_capacity


def test_modal_prints_no_exclusions_and_succeeds(tmp_path, capsys):
    dataset(tmp_path)
    assert main(["--tasks-dir", str(tmp_path), "--env", "modal"]) == 0
    assert capsys.readouterr().out == ""


def test_an_empty_tasks_dir_is_an_error_not_an_empty_run(tmp_path):
    assert main(["--tasks-dir", str(tmp_path), "--env", "modal"]) == 1
