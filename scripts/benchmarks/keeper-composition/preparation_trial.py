#!/usr/bin/env python3
"""Opt-in synthetic, matched Keeper explicit-cycle preparation harness.

The driver owns Runtime/SDK/tools. This coordinator never interprets or executes
model tool calls. It preallocates the full denominator before fixture setup.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import time


def save(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".writing")
    with temporary.open("w", encoding="utf-8") as output:
        json.dump(value, output, ensure_ascii=False, indent=2, allow_nan=False)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(path)


def load(path: Path) -> dict:
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError(f"duplicate JSON field: {key}")
            value[key] = item
        return value
    with path.open(encoding="utf-8") as source:
        return json.load(source, object_pairs_hook=unique,
                         parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))


def digest(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def validate(experiment: dict) -> None:
    if set(experiment) != {"schema_version", "case", "pairs", "runtime", "synthetic_outcome"}:
        raise ValueError("closed experiment fields required")
    if experiment["schema_version"] != 1 or experiment["case"] != "upstream_inline":
        raise ValueError("only schema 1 upstream_inline is implemented")
    if type(experiment["pairs"]) is not int or experiment["pairs"] <= 0:
        raise ValueError("pairs must be an explicit positive integer")
    runtime = experiment["runtime"]
    if set(runtime) != {"mode", "model_id", "max_context_tokens", "max_output_tokens"}:
        raise ValueError("explicit closed synthetic model capabilities required")
    if runtime["mode"] != "synthetic_streaming":
        raise ValueError("real/paid Runtime execution is not authorized or implemented")
    model = runtime["model_id"]
    if not isinstance(model, str) or not model or model != model.strip():
        raise ValueError("model_id must be explicit and nonblank")
    for name in ("max_context_tokens", "max_output_tokens"):
        if type(runtime[name]) is not int or runtime[name] <= 0:
            raise ValueError(f"{name} must be an explicit positive capability")
    if experiment["synthetic_outcome"] not in ("success", "provider_refusal"):
        raise ValueError("synthetic_outcome must be success or provider_refusal")


def inventory(root: Path) -> dict:
    """No symlink traversal or secret-bearing external configuration imports."""
    root_mode = root.stat()
    directories = {".": {"device": root_mode.st_dev, "inode": root_mode.st_ino,
                          "uid": root_mode.st_uid, "permissions": stat.S_IMODE(root_mode.st_mode)}}
    files = {}
    for directory, names, filenames in os.walk(root, followlinks=False):
        for name in names:
            path = Path(directory) / name
            mode = path.lstat()
            if not stat.S_ISDIR(mode.st_mode):
                raise ValueError(f"non-directory fixture entry: {path.relative_to(root)}")
            directories[str(path.relative_to(root))] = {"device": mode.st_dev, "inode": mode.st_ino,
                                                             "uid": mode.st_uid, "permissions": stat.S_IMODE(mode.st_mode)}
        for name in filenames:
            path = Path(directory) / name
            mode = path.lstat()
            if not stat.S_ISREG(mode.st_mode) or mode.st_nlink != 1:
                raise ValueError(f"non-private regular fixture input: {path.relative_to(root)}")
            files[str(path.relative_to(root))] = {"bytes": mode.st_size, "sha256": digest(path)}
    return {"directories": directories, "files": files}


def restore(base: Path, snapshot: Path, frozen: dict, pair_root: Path) -> None:
    # base is allocated by this process under one brand-new experiment. Keep
    # original directory inodes: owned-job backend authority freezes them.
    if base != pair_root / "base" or snapshot != pair_root / "snapshot":
        raise ValueError("restore escaped the experiment-owned pair")
    for name, identity in frozen["directories"].items():
        path = base if name == "." else base / name
        mode = path.lstat()
        if not stat.S_ISDIR(mode.st_mode) or (mode.st_dev, mode.st_ino) != (identity["device"], identity["inode"]):
            raise ValueError("original fixture directory identity changed: " + name)
    for directory, names, filenames in os.walk(base, topdown=False, followlinks=False):
        for name in filenames:
            path = Path(directory) / name
            relative = str(path.relative_to(base))
            if relative not in frozen["files"]:
                path.unlink()
        for name in names:
            path = Path(directory) / name
            relative = str(path.relative_to(base))
            if relative not in frozen["directories"]:
                if path.is_symlink():
                    path.unlink()
                else:
                    path.rmdir()  # contents were removed above; no broad rmtree
    for name, expected in frozen["files"].items():
        source, target = snapshot / name, base / name
        if digest(source) != expected["sha256"]:
            raise ValueError("frozen snapshot changed: " + name)
        if target.is_symlink() or (target.exists() and not stat.S_ISREG(target.lstat().st_mode)):
            raise ValueError("fixture file became non-regular: " + name)
        shutil.copyfile(source, target, follow_symlinks=False)
        shutil.copystat(source, target, follow_symlinks=False)
    actual = inventory(base)
    if actual != frozen:
        raise ValueError("restored common fixture differs from frozen input")


def invoke(driver: Path, experiment_path: Path, prompts: Path, base: Path,
           receipt: Path, mode: str, strategy: str | None = None) -> int:
    command = [str(driver), "--mode", mode, "--base", str(base),
               "--experiment", str(experiment_path), "--receipt", str(receipt),
               "--prompt-root", str(prompts)]
    if strategy is not None:
        command += ["--strategy", strategy]
    # No timeout/retry or Python-side tool scheduler. A killed process retains
    # its preallocated unfinished receipt. No HTTP headers are captured here.
    return subprocess.run(command, check=False).returncode


def run(args) -> None:
    experiment = load(args.experiment)
    validate(experiment)
    if len(args.source_head) != 40 or any(c not in "0123456789abcdef" for c in args.source_head):
        raise ValueError("--source-head requires an explicit 40-character commit identity")
    driver, prompts, output = args.driver.resolve(strict=True), args.prompts.resolve(strict=True), args.output.resolve()
    if not driver.is_file() or not os.access(driver, os.X_OK):
        raise ValueError("--driver must be an explicitly built executable")
    if not (prompts / "keeper.md").is_file():
        raise ValueError("--prompts must contain the frozen keeper.md")
    output.mkdir(mode=0o700)  # refuses an existing/live output root
    experiment_path = output / "experiment.json"
    save(experiment_path, experiment)
    attempts = []
    for pair in range(experiment["pairs"]):
        order = ("direct", "exact_skill") if pair % 2 == 0 else ("exact_skill", "direct")
        for arm in order:
            directory = output / f"pair-{pair:04d}" / arm
            directory.mkdir(parents=True, mode=0o700)
            path = directory / "attempt.json"
            save(path, {"schema_version": 1, "outcome": "unfinished", "strategy": arm,
                        "pair": pair, "reason": "preallocated_before_fixture_setup"})
            attempts.append({"pair": pair, "strategy": arm, "path": str(path.relative_to(output))})
    frozen_prompts = output / "prompts"
    frozen_prompts.mkdir(mode=0o700)
    # Prompt_registry scans only direct *.md entries. Copy precisely those
    # source documents, never arbitrary credential/config directories.
    for source in prompts.iterdir():
        if source.suffix == ".md":
            if not stat.S_ISREG(source.lstat().st_mode):
                raise ValueError("prompt source must be a regular file: " + source.name)
            shutil.copy2(source, frozen_prompts / source.name)
    prompts = frozen_prompts
    prompt_files = {path.name: digest(path) for path in prompts.iterdir()}
    manifest = {"schema_version": 1, "scope": "synthetic_isolated_keeper_explicit_cycle_preparation",
                "source_head_supplied": args.source_head, "source_head_is_build_proof": False,
                "driver_sha256": digest(driver), "keeper_prompt_sha256": digest(prompts / "keeper.md"),
                "experiment_sha256": digest(experiment_path), "expected_attempts": attempts,
                "prompt_files": prompt_files,
                "claims": {"real_model": False, "speedup": False, "fleet_latency": False,
                           "synthetic_docker_cli": True, "same_canonical_fixture_base": True}}
    save(output / "manifest.json", manifest)
    for pair in range(experiment["pairs"]):
        pair_root = output / f"pair-{pair:04d}"
        base, snapshot = pair_root / "base", pair_root / "snapshot"
        setup_receipt = pair_root / "setup.json"
        save(setup_receipt, {"outcome": "unfinished", "reason": "before_setup"})
        if invoke(driver, experiment_path, prompts, base, setup_receipt, "setup") != 0:
            continue  # both declared attempts remain unfinished, never omitted
        frozen = inventory(base)
        save(pair_root / "common-inputs.json", frozen)
        shutil.copytree(base, snapshot, symlinks=False)
        for attempt in (value for value in attempts if value["pair"] == pair):
            receipt = output / attempt["path"]
            try:
                restore(base, snapshot, frozen, pair_root)
                code = invoke(driver, experiment_path, prompts, base, receipt, "run", attempt["strategy"])
                save(receipt.parent / "process.json", {"returncode": code, "observed_epoch": time.time()})
            except (OSError, ValueError) as error:
                value = load(receipt)
                value.update(outcome="unfinished", reason="fixture_or_driver_unavailable", detail=str(error))
                save(receipt, value)
    results = [load(output / attempt["path"]) for attempt in attempts]
    for pair in range(experiment["pairs"]):
        paired = [result for attempt, result in zip(attempts, results) if attempt["pair"] == pair]
        completed = [result for result in paired if result["outcome"] == "correct"]
        if len(completed) == 2:
            for key in ("fixture_sha256", "skill_reference", "input", "runtime", "first_offered_tools_sha256"):
                if completed[0][key] != completed[1][key]:
                    for attempt, result in zip(attempts, results):
                        if attempt["pair"] == pair:
                            result.update(outcome="explicit_failure", error="matched input mismatch: " + key)
                            save(output / attempt["path"], result)
    counts = {name: sum(result["outcome"] == name for result in results)
              for name in ("correct", "explicit_failure", "unfinished")}
    if sum(counts.values()) != len(attempts):
        raise ValueError("unknown outcome cannot disappear from denominator")
    fixtures = [result.get("fixture_sha256") for result in results if result["outcome"] == "correct"]
    save(output / "summary.json", {"expected": len(attempts), "outcomes": counts,
         "strategy_compliant": sum(result.get("strategy_compliant") is True for result in results),
         "attempts": results, "synthetic_only": True, "latency_percentiles": None,
         "speedup": None, "reason": "functional protocol samples, no real model performance evidence",
         "fixture_hashes": fixtures})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", type=Path, required=True)
    parser.add_argument("--source-head", required=True)
    parser.add_argument("--experiment", type=Path, required=True)
    parser.add_argument("--prompts", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        run(args)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
