#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

python3 - "$REPO_ROOT" "$@" <<'PY'
import argparse
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path


def parse_args(repo_root: Path) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="scripts/ml_line_cap_audit.sh",
        description="Audit .ml file line caps across repo roots.")
    parser.add_argument("--max-lines", type=int, default=500)
    parser.add_argument(
        "--exceptions-file",
        default=".ci/ml-line-cap-exceptions.txt",
        help="Repo-relative file containing one exception path per line.")
    parser.add_argument(
        "--baseline-file",
        default=".ci/health-baseline.json",
        help="Repo-relative JSON file with fallback baseline counts.")
    parser.add_argument(
        "--baseline-ref",
        default="",
        help="Git ref to compare total manual-over-cap count against.")
    parser.add_argument(
        "--changed-ref",
        default="",
        help="Git ref to compare changed-file violations against.")
    parser.add_argument(
        "--json-out",
        default="",
        help="Write machine-readable JSON output to this path.")
    parser.add_argument(
        "--fail-on-regression",
        action="store_true",
        help="Exit non-zero when manual-over-cap count exceeds the baseline.")
    parser.add_argument(
        "--fail-on-changed-violations",
        action="store_true",
        help="Exit non-zero when changed files remain over the cap.")
    parser.add_argument(
        "--roots",
        nargs="*",
        default=["lib", "bin", "test", "examples"],
        help="Repo-relative roots to scan.")
    args = parser.parse_args(sys.argv[2:])
    args.repo_root = repo_root
    return args


def load_exceptions(base_dir: Path, rel_path: str) -> set[str]:
    path = base_dir / rel_path
    if not path.exists():
        return set()
    values: set[str] = set()
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        values.add(line)
    return values


def scan_tree(base_dir: Path, roots: list[str], exceptions: set[str], max_lines: int) -> dict:
    manual: list[dict] = []
    excepted: list[dict] = []
    counts = {
        "manual_ml_over_500": 0,
        "excepted_ml_over_500": 0,
        "lib_ml_over_500": 0,
        "bin_ml_over_500": 0,
        "test_ml_over_500": 0,
        "examples_ml_over_500": 0,
    }
    skip_dirs = {".git", "_build", ".worktrees", "node_modules", "dist", "coverage", ".next"}

    for root in roots:
        root_path = base_dir / root
        if not root_path.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(root_path):
            dirnames[:] = [d for d in dirnames if d not in skip_dirs]
            for filename in filenames:
                if not filename.endswith(".ml"):
                    continue
                path = Path(dirpath) / filename
                rel_path = path.relative_to(base_dir).as_posix()
                with path.open("rb") as handle:
                    line_count = sum(1 for _ in handle)
                if line_count <= max_lines:
                    continue
                counts[f"{root}_ml_over_500"] += 1
                entry = {"path": rel_path, "lines": line_count, "root": root}
                if rel_path in exceptions:
                    counts["excepted_ml_over_500"] += 1
                    excepted.append(entry)
                else:
                    counts["manual_ml_over_500"] += 1
                    manual.append(entry)

    manual.sort(key=lambda item: (-item["lines"], item["path"]))
    excepted.sort(key=lambda item: (-item["lines"], item["path"]))
    return {"counts": counts, "manual": manual, "excepted": excepted}


def build_tree_from_ref(repo_root: Path, ref: str, archive_paths: list[str]) -> Path:
    tmp_dir = Path(tempfile.mkdtemp(prefix="ml-line-cap-baseline."))
    try:
        archive = subprocess.run(
            ["git", "archive", ref, "--", *archive_paths],
            cwd=repo_root,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE)
    except subprocess.CalledProcessError:
        shutil.rmtree(tmp_dir, ignore_errors=True)
        raise

    tar_path = tmp_dir / "baseline.tar"
    tar_path.write_bytes(archive.stdout)
    with tarfile.open(tar_path) as tar:
        tar.extractall(tmp_dir)
    tar_path.unlink()
    return tmp_dir


def baseline_from_ref(args: argparse.Namespace) -> tuple[dict, str]:
    archive_paths = sorted({*args.roots, ".ci"})
    tmp_dir = build_tree_from_ref(args.repo_root, args.baseline_ref, archive_paths)
    try:
        exceptions = load_exceptions(tmp_dir, args.exceptions_file)
        scanned = scan_tree(tmp_dir, args.roots, exceptions, args.max_lines)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)
    return scanned["counts"], f"git:{args.baseline_ref}"


def baseline_from_file(args: argparse.Namespace) -> tuple[dict, str]:
    baseline_path = args.repo_root / args.baseline_file
    if not baseline_path.exists():
        raise FileNotFoundError(str(baseline_path))
    data = json.loads(baseline_path.read_text())
    counts = data.get("counts", {})
    return {
        "manual_ml_over_500": int(counts.get("manual_ml_over_500", 0)),
        "excepted_ml_over_500": int(counts.get("excepted_ml_over_500", 0)),
        "lib_ml_over_500": int(counts.get("lib_ml_over_500", 0)),
        "bin_ml_over_500": int(counts.get("bin_ml_over_500", 0)),
        "test_ml_over_500": int(counts.get("test_ml_over_500", 0)),
        "examples_ml_over_500": int(counts.get("examples_ml_over_500", 0)),
    }, f"file:{args.baseline_file}"


def compute_changed_paths(repo_root: Path, ref: str, roots: list[str]) -> list[str]:
    diff_ref = f"{ref}...HEAD"
    diff = subprocess.run(
        ["git", "diff", "--name-only", diff_ref, "--", *roots],
        cwd=repo_root,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True)
    paths = []
    for raw in diff.stdout.splitlines():
        path = raw.strip()
        if path.endswith(".ml"):
            paths.append(path)
    return sorted(set(paths))


def print_entries(title: str, entries: list[dict]) -> None:
    if not entries:
        print(f"{title}: none")
        return
    print(f"{title}:")
    for entry in entries:
        print(f"  {entry['lines']:5d} {entry['path']}")


def main() -> int:
    args = parse_args(Path(sys.argv[1]).resolve())

    exceptions = load_exceptions(args.repo_root, args.exceptions_file)
    current = scan_tree(args.repo_root, args.roots, exceptions, args.max_lines)

    baseline_counts = None
    baseline_source = ""
    if args.baseline_ref:
        baseline_counts, baseline_source = baseline_from_ref(args)
    elif args.baseline_file:
        try:
            baseline_counts, baseline_source = baseline_from_file(args)
        except FileNotFoundError:
            baseline_counts = None

    changed_paths: list[str] = []
    changed_manual: list[dict] = []
    if args.changed_ref:
        changed_paths = compute_changed_paths(args.repo_root, args.changed_ref, args.roots)
        manual_by_path = {entry["path"]: entry for entry in current["manual"]}
        changed_manual = [manual_by_path[path] for path in changed_paths if path in manual_by_path]
        changed_manual.sort(key=lambda item: (-item["lines"], item["path"]))

    if baseline_counts is None:
        regression_status = "disabled"
        regression_message = "baseline unavailable"
    else:
        current_manual = current["counts"]["manual_ml_over_500"]
        baseline_manual = baseline_counts["manual_ml_over_500"]
        if current_manual > baseline_manual:
            regression_status = "fail"
            regression_message = (
                f"manual_ml_over_500 {baseline_manual}->{current_manual}"
            )
        else:
            regression_status = "pass"
            regression_message = f"manual_ml_over_500 {baseline_manual}->{current_manual}"

    changed_status = "disabled"
    changed_message = "changed ref unavailable"
    if args.changed_ref:
        if changed_manual:
            changed_status = "fail"
            changed_message = (
                f"{len(changed_manual)} changed manual .ml file(s) still exceed {args.max_lines} lines"
            )
        else:
            changed_status = "pass"
            changed_message = "no changed manual .ml files exceed the cap"

    payload = {
        "generated_at": subprocess.run(
            ["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"],
            check=True,
            stdout=subprocess.PIPE,
            text=True).stdout.strip(),
        "max_lines": args.max_lines,
        "roots": args.roots,
        "exceptions_file": args.exceptions_file,
        "counts": current["counts"],
        "baseline": {
            "source": baseline_source,
            "counts": baseline_counts,
            "status": regression_status,
            "message": regression_message,
        },
        "changed": {
            "ref": args.changed_ref or None,
            "paths": changed_paths,
            "manual_over_limit": changed_manual,
            "status": changed_status,
            "message": changed_message,
        },
        "violations": {
            "manual_over_limit": current["manual"],
            "excepted_over_limit": current["excepted"],
        },
    }

    print("=== .ml Line Cap Audit ===")
    print(f"Roots: {' '.join(args.roots)}")
    print(f"Max lines: {args.max_lines}")
    print(f"Exceptions file: {args.exceptions_file}")
    print(
        "Counts: "
        f"manual={current['counts']['manual_ml_over_500']} "
        f"excepted={current['counts']['excepted_ml_over_500']} "
        f"lib={current['counts']['lib_ml_over_500']} "
        f"bin={current['counts']['bin_ml_over_500']} "
        f"test={current['counts']['test_ml_over_500']} "
        f"examples={current['counts']['examples_ml_over_500']}"
    )
    print(f"Regression: {regression_status} ({regression_message})")
    print(f"Changed: {changed_status} ({changed_message})")
    print_entries("Changed manual violations", changed_manual)

    if args.json_out:
        json_path = args.repo_root / args.json_out
        json_path.parent.mkdir(parents=True, exist_ok=True)
        json_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")

    exit_code = 0
    if args.fail_on_regression and regression_status == "fail":
        exit_code = 1
    if args.fail_on_changed_violations and changed_status == "fail":
        exit_code = 1
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
PY
