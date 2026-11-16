#!/usr/bin/env python3
"""Run source-extracted path-kind fixtures and type the complete candidate module."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("repo", "base", "candidate", "build-root", "opam-prefix", "out"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--iterations", type=int, default=5000)
    args = parser.parse_args()
    repo, build, opam, out = (Path(value).resolve() for value in
                             (args.repo, args.build_root, args.opam_prefix, args.out))
    if args.iterations <= 0:
        parser.error("--iterations must be positive")
    if out == repo or (repo in out.parents and out.relative_to(repo).parts[0] != "artifacts"):
        parser.error("--out must be outside source discovery, such as REPO/artifacts/kind-replay")
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, PATH=str(opam / "bin") + os.pathsep + os.environ.get("PATH", ""),
               GIT_NO_LAZY_FETCH="1")

    def run(command, check=True):
        result = subprocess.run(list(map(str, command)), cwd=out, env=env,
                                text=True, capture_output=True)
        if check and result.returncode:
            raise RuntimeError(str(command[0]) + " failed:\n" + result.stderr[-6000:])
        return result

    def git(*arguments):
        return run(["git", "-C", repo, *arguments]).stdout

    def source(ref, path):
        if ref == "WORKTREE":
            return (repo / path).read_text()
        return git("show", ref + ":" + path)

    def extract(text, start, stop):
        return start + text.split(start, 1)[1].split(stop, 1)[0]

    base = git("rev-parse", args.base + "^{commit}").strip()
    candidate = ("WORKTREE" if args.candidate == "WORKTREE" else
                 git("rev-parse", args.candidate + "^{commit}").strip())
    compiler = opam / "bin/ocamlc"
    version = run([compiler, "-version"]).stdout.strip()
    if version != "5.5.2":
        raise RuntimeError("expected OCaml 5.5.2, found " + version)
    path = "lib/fs_compat/fs_compat_owned_file.ml"
    before, after = source(base, path), source(candidate, path)
    mli = source(candidate, "lib/fs_compat/fs_compat_owned_file.mli")
    if mli != source(base, "lib/fs_compat/fs_compat_owned_file.mli"):
        raise RuntimeError("public signature changed; this replay expects a private adapter change")
    fallback_before = before.split("let exact_path_kind", 1)[1].split("(fun fs ->", 1)[0]
    fallback_after = after.split("let exact_path_kind", 1)[1].split("(fun fs ->", 1)[0]
    if fallback_before != fallback_after:
        raise RuntimeError("fallback source changed; this replay expects the exact original Unix branch")
    cmi_dirs = {p.parent for top in ("lib", "packages", "proto")
                for p in (build / top).rglob("*.cmi")
                if not any(part in ("test", "tests", "bin") for part in p.relative_to(build).parts)}
    cmi_dirs = {p for p in cmi_dirs if not (p.name == "public_cmi" and (p.parent / "byte").is_dir())}
    if not cmi_dirs:
        raise RuntimeError("existing project CMIs are required; no build fallback")
    includes = [item for p in sorted(cmi_dirs) for item in ("-I", str(p))]
    warnings = ["-w", "+4+8+32+69", "-warn-error", "+4+8+32+69"]
    contract = out / "full_contract.ml"
    contract.write_text("module Candidate : sig\n" + mli + "\nend = struct\n" + after + "\nend\n")
    start = time.monotonic()
    typed = run([opam / "bin/ocamlfind", "ocamlc", "-thread", "-package", "eio_main,yojson",
                 "-no-alias-deps", "-open", "Fs_compat__", *includes, *warnings,
                 "-stop-after", "typing", "-c", contract], check=False)
    (out / "typing.stdout").write_text(typed.stdout)
    (out / "typing.stderr").write_text(typed.stderr)
    metadata = {"base": base, "candidate": candidate, "compiler": version,
                "production_sha256": hashlib.sha256(after.encode()).hexdigest(),
                "interface_sha256": hashlib.sha256(mli.encode()).hexdigest(),
                "implementation_lines": len(after.splitlines()), "interface_lines": len(mli.splitlines()),
                "typing_exit": typed.returncode, "typing_seconds": time.monotonic() - start,
                "fatal_warnings": [4, 8, 32, 69], "prebuilt_project_cmi_directories": len(cmi_dirs),
                "typing_scope": "complete actual ML/MLI ascription against existing dependency CMIs",
                "unix_fallback_source_unchanged": True,
                "cases_sha256": hashlib.sha256(Path(__file__).with_name("cases.ml").read_bytes()).hexdigest(),
                "replay_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    (out / "typing.json").write_text(json.dumps(metadata, indent=2) + "\n")
    if typed.returncode:
        raise RuntimeError("actual full module typing failed; see typing.stderr")

    io = source(base, "lib/fs_compat/fs_compat_base_io.ml")
    if source(candidate, "lib/fs_compat/fs_compat_base_io.ml") != io:
        raise RuntimeError("base I/O source changed; this replay expects only the kind adapter")
    execution = source(base, "lib/fs_compat/execution_context.ml")
    if execution != source(candidate, "lib/fs_compat/execution_context.ml"):
        raise RuntimeError("execution-context source changed")
    probe = "module Execution_context = struct\n" + execution + "\nend\nmodule Ports = struct\n"
    probe += extract(io, "let global_fs :", "(** Check if Eio fs")
    probe += extract(io, "let with_io ~path f =", ";;") + ";;\n"
    probe += extract(io, "let with_fs_or_fallback ~path ~fallback f =", ";;") + ";;\nend\n"
    for name, body in (("Before", before), ("After", after)):
        probe += "module " + name + " = struct\ninclude Ports\n"
        probe += extract(body, "type exact_path_kind =", "let path_kind") + "\nend\n"

    queue_path = "lib/keeper_runtime/keeper_event_queue_persistence.ml"
    queue = source(base, queue_path)
    if source(candidate, queue_path) != queue:
        raise RuntimeError("discovery source changed; this replay expects an unchanged caller")
    schema = source(base, "lib/keeper_runtime/keeper_event_queue_schema.ml")
    quarantine = source(base, "lib/keeper_runtime/keeper_event_queue_quarantine.ml")
    # Only these non-I/O ports are synthetic. The path-kind adapter, directory
    # inspection, directory listing, presence probes and error collection are real.
    for name, implementation in (("Discovery_before", "Before"), ("Discovery_after", "After")):
        probe += "module " + name + " = struct\nmodule Fs_compat = struct\ninclude " + implementation
        probe += "\ntype path_kind = Missing | Directory | Other\nend\n"
        probe += "module Owner_lock = struct let canonical_base_path path = Ok path end\n"
        probe += "let owner_error_to_string value = value\n"
        probe += "module Common = struct let keepers_runtime_dir_of_base ~base_path = base_path end\n"
        probe += "module Keeper_id = struct module Keeper_name = struct\nlet of_string name = Ok name\nlet to_string name = name\nend end\n"
        probe += extract(schema, "let snapshot_filename =", "\n") + "\n"
        probe += extract(schema, "let transition_wal_filename =", "\n") + "\n"
        probe += "module Quarantine = struct\n" + extract(quarantine, "let filename =", "\n") + "\n"
        probe += extract(quarantine, "let path ~snapshot =", "\n") + "\nend\n"
        probe += extract(queue, "let inspect_path_kind", "let durable_state_exists_unlocked")
        probe += extract(queue, "type durable_state_discovery =", "\nlet discover_keeper_names")
        probe += extract(queue, "let discover_keeper_names_with_durable_state", ";;") + ";;\nend\n"

    probe += Path(__file__).with_name("cases.ml").read_text()
    # Execute the exact new native test body with only its temp-directory owner
    # and fs-selection helpers supplied by this standalone harness.
    test = source(candidate, "test/test_fs_compat.ml")
    probe += "\nmodule Native_test = struct\nopen Alcotest\nmodule Fs_compat = After\n"
    probe += "let with_tmp_dir = with_root\n"
    probe += extract(test, "let with_optional_read_fs fs test () =", ";;") + ";;\n"
    probe += extract(test, "let test_missing_path_kind_avoids_discarded_context", ";;") + ";;\nend\n"
    probe += "\nlet () = run ~iterations:" + str(args.iterations) + " Native_test.test_missing_path_kind_avoids_discarded_context\n"
    target = out / "probe.ml"
    target.write_text(probe)
    executable = out / "probe.exe"
    linked = run([opam / "bin/ocamlfind", "ocamlopt", "-g", "-thread", "-package",
                  "eio_main,yojson,alcotest", "-linkpkg", *warnings, target, "-o", executable], check=False)
    (out / "compile.stdout").write_text(linked.stdout)
    (out / "compile.stderr").write_text(linked.stderr)
    if linked.returncode:
        raise RuntimeError("standalone compile failed; see compile.stderr")
    result = run([executable], check=False)
    (out / "probe.stderr").write_text(result.stderr)
    if result.returncode:
        raise RuntimeError("standalone fixture failed:\n" + result.stderr[-6000:])
    parsed = json.loads(result.stdout)
    parsed["source"] = metadata
    (out / "results.json").write_text(json.dumps(parsed, indent=2) + "\n")
    print(json.dumps({"checks": parsed["checks"], "cases": len(parsed["cases"]),
                      "typing_exit": typed.returncode, "results": str(out / "results.json")}))


if __name__ == "__main__":
    main()
