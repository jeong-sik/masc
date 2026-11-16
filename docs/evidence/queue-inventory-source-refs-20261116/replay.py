#!/usr/bin/env python3
"""Replay the bounded queue-renderer proof using existing OCaml build artifacts."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("repo", "base", "candidate", "build-root", "opam-prefix", "out"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--ppx-driver", help="Existing PPX executable; otherwise discover one supporting enumerate")
    args = parser.parse_args()
    repo, build, opam, out = (Path(value).resolve() for value in
                            (args.repo, args.build_root, args.opam_prefix, args.out))
    if out == repo or repo in out.parents and out.relative_to(repo).parts[0] != "artifacts":
        parser.error("--out must be outside source discovery, for example REPO/artifacts/queue-ref-replay")
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, PATH=str(opam / "bin") + os.pathsep + os.environ.get("PATH", ""),
               GIT_NO_LAZY_FETCH="1")

    def run(command, *, check=True):
        result = subprocess.run(list(map(str, command)), cwd=out, env=env,
                                text=True, capture_output=True)
        if check and result.returncode:
            raise RuntimeError("command failed: " + str(command[0]) + "\n" + result.stderr[-6000:])
        return result

    def git(*arguments):
        return run(["git", "-C", repo, *arguments]).stdout

    def source(ref, path):
        return git("show", ref + ":" + path)

    base, candidate = (git("rev-parse", ref + "^{commit}").strip()
                       for ref in (args.base, args.candidate))
    compiler = opam / "bin/ocamlc"
    version = run([compiler, "-version"]).stdout.strip()
    if version != "5.5.2":
        raise RuntimeError("expected OCaml 5.5.2, found " + version)

    # These are observations of source copies, not proof of native archive provenance.
    copy_matches = {}
    for path in ("lib/keeper_runtime/keeper_event_queue.ml",
                 "packages/agent_core/lib/digest/agent_core_sha256.ml"):
        copied = build / path
        copy_matches[path] = copied.is_file() and copied.read_bytes() == source(base, path).encode()
    if not all(copy_matches.values()):
        raise RuntimeError("existing encoder/SHA source copies must match --base; no build is attempted")

    def production_path(path):
        relative = path.relative_to(build)
        return (relative.parts[0] in ("lib", "packages", "proto", "ppx_tla")
                and not any(part in ("test", "tests", "bin") for part in relative.parts))

    # Find CMIs and native objects only; never invoke Dune or compile project modules.
    cmi_dirs = {path.parent for path in build.rglob("*.cmi") if production_path(path)}
    cmi_dirs.update(path.parent for path in (opam / "lib").rglob("*.cmi"))
    cmi_dirs = {path for path in cmi_dirs
                if not (path.name == "public_cmi" and (path.parent / "byte").is_dir())}
    includes = [argument for path in sorted(cmi_dirs) for argument in ("-I", str(path))]
    prefix = [compiler, "-no-alias-deps", "-open", "Masc", *includes,
              "-w", "+4+8+32+69", "-warn-error", "+4+8+32+69"]
    enum = out / "enum_probe.ml"
    enum.write_text("type t = A | B [@@deriving enumerate]\nlet _ : t list = all_of_t\n")
    drivers = [Path(args.ppx_driver).resolve()] if args.ppx_driver else sorted((build / ".ppx").glob("*/ppx.exe"))
    driver = None
    for current in drivers:
        result = run([*prefix, "-ppx", shlex.join([str(current), "--as-ppx"]), "-stop-after", "typing", "-c", enum], check=False)
        if result.returncode == 0:
            driver = current
            break
    if driver is None:
        raise RuntimeError("no existing PPX driver supporting enumerate; provide --ppx-driver")
    ppx = ["-ppx", shlex.join([str(driver), "--as-ppx"])]

    path = "lib/server_keeper_waiting_inventory.ml"
    before, after = source(base, path), source(candidate, path)
    interface = source(candidate, "lib/server_keeper_waiting_inventory.mli")
    contract = out / "full_contract.ml"
    contract.write_text("module Candidate : sig\n" + interface + "\nend = struct\n" + after + "\nend\n")
    typed = run([*prefix, *ppx, "-stop-after", "typing", "-c", contract], check=False)
    (out / "typing.stdout").write_text(typed.stdout)
    (out / "typing.stderr").write_text(typed.stderr)
    metadata = {"base": base, "candidate": candidate, "compiler": version,
                "implementation_sha256": hashlib.sha256(after.encode()).hexdigest(),
                "interface_sha256": hashlib.sha256(interface.encode()).hexdigest(),
                "typing_exit": typed.returncode, "fatal_warnings": [4, 8, 32, 69],
                "prebuilt_source_copy_matches": copy_matches,
                "archive_build_provenance": "not established by matching source copies"}
    (out / "typing.json").write_text(json.dumps(metadata, indent=2) + "\n")
    if typed.returncode:
        raise RuntimeError("full implementation/signature typing failed; see typing.stderr")

    state_path = "lib/keeper_runtime/keeper_event_queue_state_core.ml"
    state = source(base, state_path)
    digest = state.split("let source_snapshot_ref source =", 1)[1].split(";;", 1)[0]
    other_digest = source(candidate, state_path).split("let source_snapshot_ref source =", 1)[1].split(";;", 1)[0]
    if digest != other_digest:
        raise RuntimeError("source-ref implementation changed; this replay assumes step 1 only")
    pending = state.split("type pending_selection =", 1)[1].split("\ntype t =", 1)[0]
    probe = ("module Original_state = Keeper_event_queue_state\nmodule Counter = struct\n"
             "let calls = ref 0\nlet source_snapshot_ref source = incr calls;" + digest + "\nend\n"
             "module Source_state = struct\ntype pending_selection = Original_state.pending_selection =" + pending +
             "\nlet source_snapshot_ref = Counter.source_snapshot_ref\nend\n")
    for name, body in (("Before", before), ("After", after)):
        probe += ("module " + name + " = struct\nmodule Keeper_event_queue_state = Source_state\n" +
                  body.split("let read_error_row", 1)[0] + "\nend\n")
    probe += Path(__file__).with_name("cases.ml").read_text()
    tests = source(base, "test/test_tool_misc_coverage.ml")
    tests = ("let json_int_member key =" + tests.split("let json_int_member key =", 1)[1]
             .split("\nlet () =\n  Alcotest.run", 1)[0])
    probe += ("\nmodule Server_keeper_waiting_inventory = struct\ninclude After\nmodule For_testing = After\nend\n"
              "let existing_tests = ref []\nlet test name f = f (); existing_tests := name :: !existing_tests\n" + tests +
              "\nlet () = Printf.printf \"%s\\n\" (Yojson.Safe.pretty_to_string (probe_result (List.rev !existing_tests)))\n")
    probe_path = out / "row_projection_probe.ml"
    probe_path.write_text(probe)

    objects = {}
    for path in sorted(build.rglob("*.cmx")):
        if production_path(path):
            objects.setdefault(path.stem.lower(), path)
    graph = {}

    def archive(path):
        directory = path.parent.parent
        result = directory.parent / (directory.name.removeprefix(".").removesuffix(".objs") + ".cmxa")
        if not result.is_file():
            raise RuntimeError("missing existing archive: " + str(result))
        return result

    def visit(name):
        key = name.lower()
        if key in graph or key not in objects:
            return
        text = run([opam / "bin/ocamlobjinfo", "-no-approx", "-no-code", objects[key]]).stdout
        section = text.split("Implementations imported:\n", 1)[1].split("Clambda unit", 1)[0]
        deps = re.findall(r"\s+(?:[0-9a-f]{32}|-{32})\s+(\S+)", section)
        graph[key] = (archive(objects[key]), deps)
        for dependency in deps:
            visit(dependency)

    for name in ("Keeper_event_queue", "Masc_domain", "Json_util", "Agent_core_sha256"):
        if name.lower() not in objects:
            raise RuntimeError("missing existing native object: " + name)
        visit(name)
    dependencies = {item[0]: set() for item in graph.values()}
    for library, deps in graph.values():
        for dependency in deps:
            item = graph.get(dependency.lower())
            if item is not None and item[0] != library:
                dependencies[library].add(item[0])
    libraries, active = [], set()

    def order(library):
        if library in libraries:
            return
        if library in active:
            raise RuntimeError("archive dependency cycle: " + str(library))
        active.add(library)
        for dependency in sorted(dependencies[library]):
            order(dependency)
        active.remove(library)
        libraries.append(library)

    for library in sorted(dependencies):
        order(library)
    packages = ("digestif.c,yojson,ptime,re,eio_main,mcp_protocol.eio,mirage-crypto-rng.unix,"
                "uuidm,otoml,ppx_deriving_yojson.runtime,ppx_deriving.runtime")
    executable = out / "row_projection_probe.exe"
    command = [opam / "bin/ocamlfind", "ocamlopt", "-thread", "-package", packages, "-linkpkg",
               *prefix[1:], *ppx]
    for directory in sorted({library.parent for library in libraries}):
        command += ["-I", directory]
    command += [*libraries, probe_path, "-o", executable]
    linked = run(command, check=False)
    (out / "link.stdout").write_text(linked.stdout)
    (out / "link.stderr").write_text(linked.stderr)
    if linked.returncode:
        raise RuntimeError("standalone probe link failed; see link.stderr (project modules were not rebuilt)")
    result = run([executable], check=False)
    (out / "probe.stderr").write_text(result.stderr)
    if result.returncode:
        raise RuntimeError("standalone probe failed: " + result.stderr[-3000:])
    parsed = json.loads(result.stdout)
    (out / "results.json").write_text(json.dumps(parsed, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"cases": len(parsed["cases"]), "assertions": parsed["assertions"],
                      "existing_grouping_tests": len(parsed["existing_grouping_tests"]),
                      "typing_exit": typed.returncode}))


if __name__ == "__main__":
    main()
