"""Compile the actual ledger suite with only declared libraries directly visible.

Requires compatible prebuilt dependencies. New output under artifacts only;
no Dune, provider or server operations. The old broad experiment recipe remains
unchanged and does not itself verify dependency declarations.
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
    args = parser.parse_args()
    repo, build, opam, out = [p.resolve() for p in
                              [args.repo, args.build_repo, args.opam_prefix, args.out]]
    if "artifacts" not in out.parts:
        parser.error("--out must be a new directory under artifacts")
    out.mkdir(parents=True, exist_ok=False)
    manifest = json.loads((HERE / "dependency-visibility.json").read_text())
    original = json.loads((HERE / "provenance.json").read_text())
    wanted = dict(original["candidate_sources"], **manifest["source_sha256"])
    for path, digest in wanted.items():
        if hashlib.sha256((repo / path).read_bytes()).hexdigest() != digest:
            raise RuntimeError("source differs from the frozen candidate: " + path)
    replacements = {"@OUT@": str(out), "@BUILD_REPO@": str(build), "@OPAM@": str(opam)}

    def expand(value):
        for old, new in replacements.items():
            value = value.replace(old, new)
        return value

    recipes = json.loads((HERE / "native-recipes.json").read_text())
    core = [expand(value) for value in recipes["compile_prefix"]]
    hidden = ["-H" if value == "-I" else value for value in core[1:]]
    direct = [expand(value) for value in manifest["direct_include_dirs"]]
    receipts = []

    def test_prefix(dirs):
        return [core[0], "-I", str(out)] + [value for path in dirs
               for value in ["-I", path]] + hidden

    def run(label, argv, env=None, expect_unbound=False):
        started = time.monotonic()
        proc = subprocess.run(argv, cwd=out, env=env, capture_output=True, text=True)
        for stream in ["stdout", "stderr"]:
            (out / (label + "." + stream)).write_text(getattr(proc, stream))
        receipts.append({"label": label, "argv": argv, "exit_code": proc.returncode,
                         "elapsed_seconds": time.monotonic() - started})
        (out / "commands.json").write_text(json.dumps(receipts, indent=2) + "\n")
        if expect_unbound:
            if proc.returncode == 0 or "Unbound module Unix" not in proc.stderr:
                raise RuntimeError("expected original Unix visibility failure: " + proc.stderr[-2000:])
        elif proc.returncode:
            raise RuntimeError(label + ": " + proc.stderr[-2000:])
        return proc.stdout

    for ext in ["mli", "ml"]:
        source = (repo / ("lib/workspace_memory/workspace_memory_ledger." + ext)).read_text()
        (out / ("ledger_after." + ext)).write_text("open Masc\n" + source)
        run("ledger-" + ext, core + ["-c", "ledger_after." + ext])
    source = (repo / "test/test_workspace_memory_ledger.ml").read_text()
    old = "module Ledger = Masc.Workspace_memory_ledger"
    if source.count(old) != 1:
        raise RuntimeError("maintained suite namespace changed")
    (out / "test_visibility.ml").write_text((HERE / "suite-prelude.ml").read_text()
        + source.replace(old, "module Ledger = Ledger_after", 1))
    (out / "test_visibility.mli").write_text("")
    visible = test_prefix(direct)
    run("empty-test-interface", visible + ["-c", "test_visibility.mli"])
    without_unix = [path for path in direct if path != str(opam / "lib/ocaml/unix")]
    run("hidden-unix-refused", test_prefix(without_unix) + ["-c", "test_visibility.ml"],
        expect_unbound=True)
    run("declared-unix-compiles", visible + ["-c", "test_visibility.ml"])
    executable = out / "test_visibility.exe"
    run("link", [expand(value) for value in recipes["link_prefix"]]
        + ["-o", str(executable), str(out / "ledger_after.cmx"), str(out / "test_visibility.cmx")])
    with tempfile.TemporaryDirectory(prefix="masc-ledger-owned-") as root:
        Path(root, "owned-fixture-marker").write_text("synthetic fixture only\n")
        env = dict(os.environ, MASC_BASE_PATH=root, TMPDIR=root)
        env.pop("MASC_TEST_ALLOW_HOME_BASE_PATH", None)
        run("native", [str(executable)], env)
    print(json.dumps({"expected_failure": "Unbound module Unix", "maintained_tests": 19,
                      "scope": "declared dependency visibility; compatible prebuilt dependencies"}))


if __name__ == "__main__":
    main()
