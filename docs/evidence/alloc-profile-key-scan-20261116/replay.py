#!/usr/bin/env python3
"""Compile only the isolated exact-source key fixture; output goes to artifacts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
MANIFEST = json.loads((HERE / "source-manifest.json").read_text())


def digest(data):
    return hashlib.sha256(data).hexdigest()


def source_at(ref, path):
    env = os.environ.copy()
    env["GIT_NO_LAZY_FETCH"] = "1"
    return subprocess.check_output(["git", "-C", str(ROOT), "show", f"{ref}:{path}"], env=env)


def fragments(source):
    text = source.decode()
    key_start = text.index("let key_of_callstack callstack =")
    key_end = text.index("let block_of (allocation")
    helpers = text[text.index("let skipped_frame_name_prefixes ="):key_start]
    constants = "\n".join(next(line for line in text.splitlines()
                                 if line.startswith("let " + name + " ="))
                          for name in ["callstack_frames", "unattributed_marker"]) + "\n"
    return constants + helpers, text[key_start:key_end], helpers


def summaries(results):
    groups = []
    for group in results["benchmarks"]:
        iterations = group["iterations_per_variant_per_round"]
        item = {"group": group["group"], "capture": group["capture"],
                "iterations": iterations, "rounds": len(group["rounds"])}
        for variant in ["original", "candidate"]:
            cpu = [row[variant]["cpu_seconds"] / iterations * 1e6 for row in group["rounds"]]
            allocated = [row[variant]["allocated_bytes"] / iterations for row in group["rounds"]]
            item[variant] = {"median_cpu_us": statistics.median(cpu),
                             "cpu_us_range": [min(cpu), max(cpu)],
                             "median_allocated_bytes": statistics.median(allocated)}
        for row in group["rounds"]:
            if row["original"]["checksum"] != row["candidate"]["checksum"]:
                raise SystemExit("Benchmark output checksums disagree")
        groups.append(item)
    return groups


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ocamlopt", default=shutil.which("ocamlopt"))
    parser.add_argument("--ocamlfind")
    parser.add_argument("--candidate-ref", help="Read the candidate source from this local Git ref")
    parser.add_argument("--output", type=Path, help="New directory, outside retained evidence")
    args = parser.parse_args()
    if not args.ocamlopt:
        raise SystemExit("OCaml 5.5.2 is required; select its compiler with --ocamlopt")
    compiler = str(Path(args.ocamlopt).resolve())
    version = subprocess.check_output([compiler, "-version"], text=True).strip()
    if version != "5.5.2":
        raise SystemExit(f"Expected OCaml 5.5.2, found {version}")
    findlib = args.ocamlfind or str(Path(compiler).with_name("ocamlfind"))
    yojson = Path(subprocess.check_output([findlib, "query", "yojson"], text=True).strip())
    path = MANIFEST["source_path"]
    baseline = source_at(MANIFEST["baseline_ref"], path)
    candidate = source_at(args.candidate_ref, path) if args.candidate_ref else (ROOT / path).read_bytes()
    mli_path = str(Path(path).with_suffix(".mli"))
    public_mli = source_at(args.candidate_ref, mli_path) if args.candidate_ref else (ROOT / mli_path).read_bytes()
    for data, key in [(baseline, "baseline_whole_ml_sha256"),
                      (candidate, "candidate_whole_ml_sha256"),
                      (public_mli, "unchanged_public_mli_sha256")]:
        if digest(data) != MANIFEST[key]:
            raise SystemExit(f"Exact source binding differs: {key}")
    shared, original_key, helpers = fragments(baseline)
    candidate_shared, candidate_key, candidate_helpers = fragments(candidate)
    if shared != candidate_shared or helpers != candidate_helpers:
        raise SystemExit("Classifier, formatter, or constants changed")
    for text, key in [(original_key, "baseline_key_span_sha256"),
                      (candidate_key, "candidate_key_span_sha256"),
                      (helpers, "shared_helpers_sha256")]:
        if digest(text.encode()) != MANIFEST[key]:
            raise SystemExit(f"Extracted source binding differs: {key}")
    helper_bytes = {}
    for name, expected in MANIFEST["helpers"].items():
        helper_bytes[name] = (HERE / name).read_bytes()
        if digest(helper_bytes[name]) != expected:
            raise SystemExit(f"Recorded helper changed: {name}")
    output = (args.output or ROOT / "artifacts/alloc-profile-key-scan-20261116" / uuid.uuid4().hex).resolve()
    if output == HERE or HERE in output.parents:
        raise SystemExit("New output must be outside retained evidence")
    output.mkdir(parents=True, exist_ok=False)
    (output / "shared.ml").write_text(shared)
    (output / "original.ml").write_text("open Shared\n" + original_key)
    (output / "candidate.ml").write_text("open Shared\n" + candidate_key)
    for name, data in helper_bytes.items():
        (output / name).write_bytes(data)
    warnings = ["-w", "+4+8+32+69", "-warn-error", "+4+8+32+69"]
    commands = [
        [compiler, "-opaque", *warnings, "-c", "no_debug_capture.ml"],
        [compiler, "-g", "-O2", "-inline", "100", *warnings,
         "-I", str(yojson), str(yojson / "yojson.cmxa"), "shared.ml", "original.ml",
         "candidate.ml", "stdlib__Key_scan_fixture.ml", "no_debug_capture.cmx", "cases.ml",
         "-o", "test_alloc_key_scan.exe"],
    ]
    (output / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
    for index, command in enumerate(commands):
        result = subprocess.run(command, cwd=output, capture_output=True, text=True, timeout=30)
        (output / f"compile-{index}.stdout").write_text(result.stdout)
        (output / f"compile-{index}.stderr").write_text(result.stderr)
        if result.returncode:
            raise SystemExit(f"Compile {index} failed; see {output}")
    env = os.environ.copy()
    env.pop("MASC_TEST_ALLOW_HOME_BASE_PATH", None)
    with tempfile.TemporaryDirectory(prefix="alloc-key-scan-bootstrap-") as bootstrap:
        env["MASC_BASE_PATH"] = bootstrap
        result = subprocess.run([str(output / "test_alloc_key_scan.exe")], cwd=bootstrap, env=env,
                                capture_output=True, text=True, timeout=55)
    (output / "native-results.json").write_text(result.stdout)
    (output / "run.stderr").write_text(result.stderr)
    if result.returncode:
        raise SystemExit(f"Fixture failed ({result.returncode}); see {output}")
    results = json.loads(result.stdout)
    receipt = {"source_binding": MANIFEST, "compiler_version": version,
               "fatal_warnings": [4, 8, 32, 69], "exit_code": result.returncode,
               "scope": "isolated exact-source key functions, real native backtraces/GC; no product runtime",
               "results": results, "summary": summaries(results)}
    (output / "observed.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Output: {output}")
    print(f"Byte-equality captures: {results['oracle_raw_captures']}; assertions: {results['assertions']}")


if __name__ == "__main__":
    main()
