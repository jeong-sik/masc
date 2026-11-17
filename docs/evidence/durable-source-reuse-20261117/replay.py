"""Replay this bounded source experiment against compatible prebuilt dependencies.

No Dune, dependency rebuild, server access or provider call. New output only.
The recorded native recipes require an OCaml 5.5.2 installation and the compatible
prebuilt _build tree; they are not an independent clean-build recipe.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
BASE = "a5eae5da05442ea52f67e3fd44705293b7392e7c"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True, help="candidate source checkout")
    parser.add_argument("--build-repo", type=Path, required=True, help="compatible prebuilt tree")
    parser.add_argument("--opam-prefix", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True, help="new directory under artifacts")
    parser.add_argument("--consumer", type=Path, help="optional upper-layer evidence directory")
    args = parser.parse_args()
    repo, build, opam, out = (p.resolve() for p in
                              (args.repo, args.build_repo, args.opam_prefix, args.out))
    if "artifacts" not in out.parts:
        parser.error("--out must be a new directory under artifacts")
    out.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, GIT_NO_LAZY_FETCH="1")
    receipts = []
    source_hashes = {}
    expected = json.loads((HERE / "replay-provenance.json").read_text())

    def digest(value):
        return hashlib.sha256(value).hexdigest()

    for filename, wanted in expected["fixture_files"].items():
        if digest((HERE / filename).read_bytes()) != wanted:
            raise RuntimeError("fixture differs from retained observation: " + filename)

    def source(path, candidate=False):
        value = (repo / path).read_bytes() if candidate else subprocess.check_output(
            ["git", "show", BASE + ":" + path], cwd=repo, env=env)
        key = ("candidate:" if candidate else "baseline:") + path
        source_hashes[key] = digest(value)
        wanted = expected["candidate_sources" if candidate else "baseline_sources"][path]
        if source_hashes[key] != wanted:
            raise RuntimeError("source differs from recorded experiment: " + key)
        return value.decode()

    recipe = json.loads((HERE / "native-recipes.json").read_text())
    substitutions = {"@OUT@": str(out), "@BUILD_REPO@": str(build), "@OPAM@": str(opam)}

    def expand(value):
        for old, new in substitutions.items():
            value = value.replace(old, new)
        return value

    prefix = [expand(value) for value in recipe["compile_prefix"]]
    link_prefix = [expand(value) for value in recipe["link_prefix"]]

    def run(argv, label, run_env=env):
        started = time.monotonic()
        proc = subprocess.run(argv, cwd=out, env=run_env, capture_output=True, text=True)
        (out / (label + ".stdout")).write_text(proc.stdout)
        (out / (label + ".stderr")).write_text(proc.stderr)
        receipts.append({"label": label, "argv": argv, "exit_code": proc.returncode,
                         "elapsed_seconds": time.monotonic() - started})
        (out / "commands.json").write_text(json.dumps(receipts, indent=2) + "\n")
        if proc.returncode:
            raise RuntimeError(label + ": " + proc.stderr[-3000:])

    def compile_unit(unit, text, ext="ml"):
        (out / (unit + "." + ext)).write_text(text)
        run(prefix + ["-c", unit + "." + ext], unit + "-" + ext)

    modules = [
        ("source_under_test", "lib/keeper/keeper_librarian_durable_capture", "", True),
        ("runtime_under_test", "lib/keeper/keeper_librarian_runtime", "", True),
        ("owner_under_test", "lib/lane_addon/lane_addon_tool_request_owner", "", True),
        ("question_under_test", "lib/keeper/keeper_librarian_durable_question",
         "module Keeper_librarian_runtime = Runtime_under_test\n", False),
    ]
    units = []
    for unit, stem, aliases, has_mli in modules:
        for ext in (["mli", "ml"] if has_mli else ["ml"]):
            compile_unit(unit, "open Masc\n" + aliases + source(stem + "." + ext), ext)
        units.append(unit)
    aliases = ("module Keeper_librarian_durable_question = Question_under_test\n"
               "module Keeper_librarian_durable_capture = Source_under_test\n"
               "module Keeper_librarian_runtime = Runtime_under_test\n"
               "module Lane_addon_tool_request_owner = Owner_under_test\n")
    for unit, candidate in [("request_before", False), ("request_after", True)]:
        for ext in ["mli", "ml"]:
            text = source("lib/keeper/keeper_librarian_durable_request." + ext, candidate)
            compile_unit(unit, "open Masc\n" + aliases + text, ext)
        units.append(unit)
    for unit in ["fixture", "reuse_helpers"]:
        compile_unit(unit, (HERE / (unit + ".ml")).read_text())
        units.append(unit)

    def execute(unit, extra_units):
        executable = out / (unit + ".exe")
        argv = list(link_prefix)
        argv[argv.index("-o") + 1] = str(executable)
        argv += [str(out / (name + ".cmx")) for name in units + extra_units + [unit]]
        run(argv, unit + "-link")
        with tempfile.TemporaryDirectory(prefix="masc-source-reuse-") as root:
            Path(root, "owned-fixture-marker").write_text("synthetic fixture only\n")
            run_env = dict(env, MASC_BASE_PATH=root)
            run_env.pop("MASC_TEST_ALLOW_HOME_BASE_PATH", None)
            run([str(executable)], unit + "-run", run_env)
        result = json.loads((out / (unit + "-run.stdout")).read_text())
        (out / (unit + "-result.json")).write_text(json.dumps(result, indent=2) + "\n")

    for unit in ["test_source_reuse", "test_additional"]:
        compile_unit(unit, (HERE / (unit + ".ml")).read_text())
        execute(unit, [])
    if args.consumer:
        consumer = args.consumer.resolve()
        upper = json.loads((consumer / "replay-provenance.json").read_text())
        if digest((consumer / "test_consumer.ml").read_bytes()) != upper["test_consumer_sha256"]:
            raise RuntimeError("consumer fixture differs from retained observation")
        for path, wanted in upper["candidate_sources"].items():
            if digest((repo / path).read_bytes()) != wanted:
                raise RuntimeError("upper candidate source differs: " + path)
        for filename, wanted in upper["function_body_files"].items():
            raw = (consumer / filename).read_bytes()
            if digest(raw) != wanted:
                raise RuntimeError("upper fixture body differs: " + filename)
            baseline = filename == "batch_before.ml"
            path = "lib/keeper/keeper_librarian_durable_owner.ml"
            original = subprocess.check_output(["git", "show", BASE + ":" + path],
                                              cwd=repo, env=env).decode() if baseline else (repo / path).read_text()
            body = raw.decode().split("module Request = Request_", 1)[1].split("\n", 1)[1]
            if body not in original:
                raise RuntimeError("consumer body is not verbatim production source")
        for unit in ["batch_before", "batch_after", "test_consumer"]:
            compile_unit(unit, (consumer / (unit + ".ml")).read_text())
        execute("test_consumer", ["batch_before", "batch_after"])
    (out / "source-hashes.json").write_text(json.dumps(source_hashes, indent=2) + "\n")
    print(out)


if __name__ == "__main__":
    main()
