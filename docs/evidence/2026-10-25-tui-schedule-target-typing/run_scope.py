#!/usr/bin/env python3
"""Reproduce warning 4 using actual TUI types, predicate and target expression."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

SOURCE = "bin/masc_tui_types.ml"


def checked(argv, cwd):
    return subprocess.run(argv, cwd=cwd, capture_output=True, text=True, check=True).stdout


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".")
    parser.add_argument("--before-ref", required=True)
    parser.add_argument("--after-ref", required=True)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    root = Path(checked(["git", "rev-parse", "--show-toplevel"], args.repo).strip())
    refs = {name: checked(["git", "rev-parse", "--verify", "--end-of-options", ref + "^{commit}"], root).strip()
            for name, ref in [("before", args.before_ref), ("after", args.after_ref)]}
    extractor = Path(__file__).with_name("extract_scope.ml").read_bytes()
    result = {"recorded_at": datetime.now(timezone.utc).isoformat(), "refs": refs,
              "ocaml_version": checked(["ocamlc", "-version"], root).strip(),
              "extractor_sha256": digest(extractor),
              "runner_sha256": digest(Path(__file__).read_bytes()), "checks": {}}
    with tempfile.TemporaryDirectory(prefix="masc-tui-fragile-") as folder:
        work = Path(folder)
        (work / "extract_scope.ml").write_bytes(extractor)
        checked(["ocamlc", "-I", "+compiler-libs", "ocamlcommon.cma", "extract_scope.ml", "-o", "extract_scope"], work)
        for name, ref in refs.items():
            source = subprocess.check_output(["git", "show", ref + ":" + SOURCE], cwd=root)
            path = work / (name + "_source.ml")
            path.write_bytes(source)
            scope = checked(["./extract_scope", path.name], work).encode()
            scope_name = name + "_scope.ml"
            (work / scope_name).write_bytes(scope)
            argv = ["ocamlc", "-w", "+4+8", "-warn-error", "+4+8", "-stop-after", "typing", scope_name]
            compile_result = subprocess.run(argv, cwd=work, capture_output=True, text=True)
            result["checks"][name] = {
                "source_path": SOURCE, "source_sha256": digest(source), "scope_sha256": digest(scope),
                "command": argv, "exit": compile_result.returncode,
                "stdout": compile_result.stdout, "stderr": compile_result.stderr}
    before, after = result["checks"]["before"], result["checks"]["after"]
    result["reported_failure_reproduced"] = (
        before["exit"] != 0 and "warning 4 [fragile-match]" in before["stderr"]
        and "type surface" in before["stderr"] and "type keeper_mode" in before["stderr"])
    result["fixed_fragment_types"] = after["exit"] == 0
    result["scope"] = (
        "Actual keeper_mode/surface declarations, view_is_chat binding and schedule target expression; "
        "two minimal record shapes supply field types and the selected-Keeper predicate is a function parameter. "
        "Only this fragment is typechecked. No full TUI module/build, state-transition test, Dune, CI or UI execution.")
    result["verdict"] = "PASS" if result["reported_failure_reproduced"] and result["fixed_fragment_types"] else "FAIL"
    encoded = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.receipt:
        with args.receipt.open("x", encoding="utf-8") as channel:
            channel.write(encoded)
    else:
        print(encoded, end="")
    print("before", before["exit"], "after", after["exit"], "verdict", result["verdict"])
    return 0 if result["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
