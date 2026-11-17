"""Replay only these leaf modules against compatible prebuilt OCaml 5.5.2 dependencies.

Writes a new artifacts directory. No Dune, server, provider or dependency rebuild.
Optional --consumer compiles the complete HTTP consumer without executing it.
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["repo", "build-repo", "opam-prefix", "out"]:
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--consumer", action="store_true")
    args = parser.parse_args()
    repo, build, opam, out = [p.resolve() for p in
                              [args.repo, args.build_repo, args.opam_prefix, args.out]]
    if "artifacts" not in out.parts:
        parser.error("--out must be a new directory under artifacts")
    out.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, GIT_NO_LAZY_FETCH="1")
    provenance = json.loads((HERE / "provenance.json").read_text())
    digest = lambda value: hashlib.sha256(value).hexdigest()
    for filename, wanted in provenance["retained_captures"].items():
        if digest((HERE / filename).read_bytes()) != wanted:
            raise RuntimeError("retained capture changed: " + filename)
    substitutions = {"@OUT@": str(out), "@BUILD_REPO@": str(build), "@OPAM@": str(opam)}

    def expand(value):
        for old, new in substitutions.items():
            value = value.replace(old, new)
        return value

    recipes = json.loads((HERE / "native-recipes.json").read_text())
    compile_prefix = [expand(v) for v in recipes["compile_prefix"]]
    link_prefix = [expand(v) for v in recipes["link_prefix"]]
    receipts, sources = [], {}

    def run(label, argv, run_env=env):
        start = time.monotonic()
        proc = subprocess.run(argv, cwd=out, env=run_env, capture_output=True, text=True)
        for stream in ["stdout", "stderr"]:
            (out / (label + "." + stream)).write_text(getattr(proc, stream))
        receipts.append({"label": label, "argv": argv, "exit_code": proc.returncode,
                         "elapsed_seconds": time.monotonic() - start})
        (out / "commands.json").write_text(json.dumps(receipts, indent=2) + "\n")
        if proc.returncode:
            raise RuntimeError(label + ": " + proc.stderr[-3000:])
        return proc.stdout

    def source(path, candidate):
        value = (repo / path).read_bytes() if candidate else subprocess.check_output(
            ["git", "show", provenance["baseline"] + ":" + path], cwd=repo, env=env)
        sources[("candidate:" if candidate else "baseline:") + path] = digest(value)
        wanted = provenance["candidate_sources" if candidate else "baseline_sources"][path]
        if digest(value) != wanted:
            raise RuntimeError("source differs from recorded experiment: " + path)
        return value.decode()

    def compile_unit(unit, text, ext="ml"):
        (out / (unit + "." + ext)).write_text(text)
        run(unit + "-" + ext, compile_prefix + ["-c", unit + "." + ext])

    for unit, candidate in [("ledger_before", False), ("ledger_after", True)]:
        for ext in ["mli", "ml"]:
            compile_unit(unit, "open Masc\n" + source(
                "lib/workspace_memory/workspace_memory_ledger." + ext, candidate), ext)
    compile_unit("test_preflight", (HERE / "fixture.ml").read_text())
    executable = out / "test_preflight.exe"
    run("fixture-link", link_prefix + ["-o", str(executable)] +
        [str(out / (name + ".cmx")) for name in
         ["ledger_before", "ledger_after", "test_preflight"]])

    def execute_owned(label, executable):
        with tempfile.TemporaryDirectory(prefix="masc-ledger-owned-") as root:
            Path(root, "owned-fixture-marker").write_text("synthetic fixture only\n")
            run_env = dict(env, MASC_BASE_PATH=root, TMPDIR=root)
            run_env.pop("MASC_TEST_ALLOW_HOME_BASE_PATH", None)
            return run(label, [str(executable)], run_env)

    observed = json.loads(execute_owned("fixture-run", executable))
    (out / "observed.json").write_text(json.dumps(observed, indent=2) + "\n")
    maintained = source("test/test_workspace_memory_ledger.ml", True)
    old = "module Ledger = Masc.Workspace_memory_ledger"
    if maintained.count(old) != 1:
        raise RuntimeError("maintained suite namespace changed")
    compile_unit("test_ledger_suite", (HERE / "suite-prelude.ml").read_text() +
                 maintained.replace(old, "module Ledger = Ledger_after", 1))
    executable = out / "test_ledger_suite.exe"
    run("suite-link", link_prefix + ["-o", str(executable), str(out / "ledger_after.cmx"),
                                    str(out / "test_ledger_suite.cmx")])
    execute_owned("suite-run", executable)
    if args.consumer:
        stem = "lib/server/server_routes_http_routes_dashboard."
        for ext in ["mli", "ml"]:
            text = (repo / (stem + ext)).read_text()
            sources["consumer:" + stem + ext] = digest(text.encode())
            alias = "module Workspace_memory_ledger = Ledger_after\n" if ext == "ml" else ""
            compile_unit("server_consumer", "open Masc\n" + alias + text, ext)
    (out / "source-hashes.json").write_text(json.dumps(sources, indent=2) + "\n")
    print(json.dumps({"commands": len(receipts), "all_exit_zero": True,
                      "assertions": observed["assertions"], "maintained_tests": 19,
                      "consumer_compiled": args.consumer,
                      "scope": "standalone native experiment, compatible prebuilt dependencies"}))


if __name__ == "__main__":
    main()
