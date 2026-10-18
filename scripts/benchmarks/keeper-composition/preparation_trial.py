#!/usr/bin/env python3
"""Opt-in Keeper explicit-cycle preparation harness.

The driver owns Runtime/SDK/tools. This coordinator never interprets or executes
model tool calls. It preallocates the full denominator before fixture setup.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import time
import tomllib


def save(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".writing")
    with temporary.open("w", encoding="utf-8") as output:
        json.dump(value, output, ensure_ascii=False, indent=2, allow_nan=False)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(path)


def decode_json(text: str):
    def finite_float(value):
        number = float(value)
        if not math.isfinite(number):
            raise ValueError("non-finite JSON number")
        return number

    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError(f"duplicate JSON field: {key}")
            value[key] = item
        return value
    return json.loads(text, object_pairs_hook=unique, parse_float=finite_float,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))


def load(path: Path) -> dict:
    return decode_json(path.read_text(encoding="utf-8"))


def digest(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def validate(experiment: dict) -> None:
    if (not isinstance(experiment, dict) or type(experiment.get("schema_version")) is not int
            or experiment["schema_version"] != 1 or experiment.get("case") not in ("upstream_inline", "named_inline")):
        raise ValueError("schema 1 upstream_inline or named_inline required")
    if type(experiment["pairs"]) is not int or experiment["pairs"] <= 0:
        raise ValueError("pairs must be an explicit positive integer")
    runtime = experiment["runtime"]
    if runtime["mode"] == "configured_http":
        if set(experiment) != {"schema_version", "case", "pairs", "runtime"} or set(runtime) != {"mode", "configuration"}:
            raise ValueError("closed configured HTTP experiment fields required")
        # Before persisting any input, refuse credential values. The native
        # Runtime parser owns the actual configuration/protocol contract.
        configuration = tomllib.loads(runtime["configuration"])
        for provider in configuration.get("providers", {}).values():
            credential = provider.get("credentials")
            if credential is not None and (set(credential) != {"type", "key"} or credential["type"] != "env"):
                raise ValueError("experiment credentials must name an existing environment variable")
            if provider.get("headers"):
                raise ValueError("experiment authentication must not persist inline headers")
        return
    if set(experiment) != {"schema_version", "case", "pairs", "runtime", "synthetic_outcome"}:
        raise ValueError("closed synthetic experiment fields required")
    if set(runtime) != {"mode", "model_id", "max_context_tokens", "max_output_tokens"}:
        raise ValueError("explicit closed synthetic model capabilities required")
    if runtime["mode"] != "synthetic_streaming":
        raise ValueError("unsupported preparation Runtime mode")
    model = runtime["model_id"]
    if not isinstance(model, str) or not model or model != model.strip():
        raise ValueError("model_id must be explicit and nonblank")
    for name in ("max_context_tokens", "max_output_tokens"):
        if type(runtime[name]) is not int or runtime[name] <= 0:
            raise ValueError(f"{name} must be an explicit positive capability")
    if experiment["synthetic_outcome"] not in ("success", "provider_refusal", "malformed_final", "fixed_child"):
        raise ValueError("unsupported synthetic outcome")


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


def declared_attempts(pairs: int) -> list[dict]:
    return [{"pair": pair, "strategy": arm,
             "path": f"pair-{pair:04d}/{arm}/attempt.json"}
            for pair in range(pairs)
            for arm in (("direct", "exact_skill") if pair % 2 == 0 else ("exact_skill", "direct"))]


def capture_bytes(root: Path, relative: str):
    path = root
    parts = Path(relative).parts
    for index, part in enumerate(parts):
        if part in (".", "..") or not part or Path(relative).is_absolute():
            raise ValueError("capture path is not relative")
        path = path / part
        mode = path.lstat().st_mode
        expected = stat.S_ISREG if index == len(parts) - 1 else stat.S_ISDIR
        if not expected(mode):
            raise ValueError("capture entry is not a regular file/directory: " + relative)
    raw = path.read_bytes()
    return raw, hashlib.sha256(raw).hexdigest()


def capture_json(root: Path, relative: str):
    raw, digest_value = capture_bytes(root, relative)
    return decode_json(raw.decode("utf-8")), digest_value


def same_json(first, second) -> bool:
    # JSON true and 1 are different input declarations, despite Python equality.
    pending = [(first, second)]
    while pending:
        first, second = pending.pop()
        if type(first) is not type(second):
            return False
        if isinstance(first, dict):
            if first.keys() != second.keys():
                return False
            pending.extend((first[key], second[key]) for key in first)
        elif isinstance(first, list):
            if len(first) != len(second):
                return False
            pending.extend(zip(first, second))
        elif first != second:
            return False
    return True


def report_capture(directory: Path) -> dict:
    """Read a declared capture without invoking a driver or changing evidence."""
    root = directory.resolve(strict=True)
    if not stat.S_ISDIR(root.lstat().st_mode):
        raise ValueError("capture root must be a directory")
    manifest, _ = capture_json(root, "manifest.json")
    experiment, experiment_hash = capture_json(root, "experiment.json")
    validate(experiment)
    attempts = declared_attempts(experiment["pairs"])
    if (not isinstance(manifest, dict) or type(manifest.get("schema_version")) is not int
            or manifest["schema_version"] != 1
            or manifest.get("experiment_sha256") != experiment_hash
            or not same_json(manifest.get("expected_attempts"), attempts)):
        raise ValueError("capture manifest does not bind the complete declared experiment")
    results, by_pair = [], {}
    for attempt in attempts:
        result, receipt_hash, state, error = {}, None, "read", None
        try:
            raw, receipt_hash = capture_bytes(root, attempt["path"])
            result = decode_json(raw.decode("utf-8"))
            if not isinstance(result, dict):
                result = {}
                raise ValueError("attempt receipt must be an object")
            if (type(result.get("schema_version")) is not int or result["schema_version"] != 1
                    or result.get("strategy") != attempt["strategy"]
                    or ("pair" in result and not same_json(result["pair"], attempt["pair"]))
                    or result.get("outcome") not in ("correct", "explicit_failure", "unfinished")):
                raise ValueError("attempt receipt identity or reported outcome is invalid")
            if result["outcome"] == "correct" and result.get("case") != experiment["case"]:
                raise ValueError("correct receipt does not name the declared case")
        except FileNotFoundError:
            state, error = "missing", "attempt receipt unavailable"
        except (OSError, ValueError, RecursionError):
            state, error = "invalid", "attempt receipt cannot be admitted"
        result = dict(result)
        result.update(reported_outcome=result.get("outcome"), receipt_state=state,
                      receipt_sha256=receipt_hash, declared_attempt=dict(attempt))
        if state != "read":
            result.update(outcome="unfinished", receipt_error=error)
        results.append(result)
        by_pair.setdefault(attempt["pair"], []).append(result)
    matching, comparisons = [], []
    for pair in range(experiment["pairs"]):
        paired = by_pair[pair]
        if not all(result["outcome"] == "correct" for result in paired):
            comparisons.append({"pair": pair, "state": "incomplete", "mismatched_fields": []})
            continue
        first, second = paired
        mismatch = [key for key in ("case", "fixture_sha256", "skill_reference", "input", "runtime",
                                   "first_offered_tools_sha256", "common_instruction_sha256")
                    if key not in first or key not in second or not same_json(first[key], second[key])]
        comparisons.append({"pair": pair, "state": "mismatch" if mismatch else "matched",
                            "mismatched_fields": mismatch})
        if mismatch:
            for result in paired:
                result.update(outcome="explicit_failure", comparison_errors=mismatch)
        else:
            matching.append({"pair": pair, "first_offered_inventory_reported":
                             all(result["first_offered_tools_sha256"] is not None for result in paired)})
    counts = {name: sum(result["outcome"] == name for result in results)
              for name in ("correct", "explicit_failure", "unfinished")}
    synthetic = experiment["runtime"]["mode"] == "synthetic_streaming"
    return {"case": experiment["case"], "expected": len(attempts), "outcomes": counts,
            "strategy_compliant": sum(result.get("strategy_compliant") is True for result in results),
            "strategy_compliant_scope": "receipt_reported",
            "attempts": results, "synthetic_only": synthetic, "latency_percentiles": None,
            "speedup": None, "matching": matching, "pair_comparisons": comparisons,
            "receipt_states": {state: sum(result["receipt_state"] == state for result in results)
                               for state in ("read", "missing", "invalid")},
            "comparison_scope": "receipt_reported_common_inputs_only",
            "execution_verified": False, "source_build_verified": False,
            "reason": ("functional protocol samples, no real model performance evidence" if synthetic else
                       "reported input agreement does not verify execution or response-reported model identity"),
            "fixture_hashes": [result.get("fixture_sha256") for result in results if result["outcome"] == "correct"]}


def run(args) -> None:
    experiment = load(args.experiment)
    validate(experiment)
    synthetic = experiment["runtime"]["mode"] == "synthetic_streaming"
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
    attempts = declared_attempts(experiment["pairs"])
    for attempt in attempts:
        path = output / attempt["path"]
        path.parent.mkdir(parents=True, mode=0o700)
        save(path, {"schema_version": 1, "outcome": "unfinished", "strategy": attempt["strategy"],
                    "pair": attempt["pair"], "reason": "preallocated_before_fixture_setup"})
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
    manifest = {"schema_version": 1, "scope": ("synthetic_isolated_keeper_explicit_cycle_preparation" if synthetic
                                              else "configured_http_isolated_keeper_explicit_cycle_preparation"),
                "source_head_supplied": args.source_head, "source_head_is_build_proof": False,
                "driver_sha256": digest(driver), "keeper_prompt_sha256": digest(prompts / "keeper.md"),
                "experiment_sha256": digest(experiment_path), "expected_attempts": attempts,
                "prompt_files": prompt_files,
                "claims": {"real_model": False if synthetic else None, "speedup": False, "fleet_latency": False,
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
                save(receipt.parent / "process.json", {"returncode": None,
                     "observation": "fixture_or_driver_unavailable", "detail": str(error)})
    save(output / "summary.json", report_capture(output))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report-from", type=Path, help="read an existing capture; print JSON without execution or writes")
    parser.add_argument("--driver", type=Path)
    parser.add_argument("--source-head")
    parser.add_argument("--experiment", type=Path)
    parser.add_argument("--prompts", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        run_arguments = (args.driver, args.source_head, args.experiment, args.prompts, args.output)
        if args.report_from is not None:
            if any(value is not None for value in run_arguments):
                parser.error("--report-from cannot be combined with run arguments")
            print(json.dumps(report_capture(args.report_from), indent=2, ensure_ascii=False, allow_nan=False))
            return 0
        if any(value is None for value in run_arguments):
            parser.error("run requires --driver, --source-head, --experiment, --prompts and --output")
        run(args)
    except (OSError, ValueError, KeyError, TypeError, RecursionError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
