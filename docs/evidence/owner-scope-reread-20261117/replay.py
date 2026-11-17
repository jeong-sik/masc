#!/usr/bin/env python3
"""Replay complete Owner/Store sources with an existing native dependency graph.

Does not run Dune, start MASC, or obtain/build dependencies. See README.md.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


HERE = Path(__file__).resolve().parent
BASE = "ea0b8d1fd284fad784557373fd82e8565a774b10"
OWNER = "lib/lane_addon/lane_addon_tool_request_owner"
STORE = "lib/lane_addon/lane_addon_store"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def change(source, old, new):
    if source.count(old) != 1:
        raise ValueError(f"source anchor is not unique: {old!r}")
    return source.replace(old, new, 1)


def instrument_owner(source, candidate):
    source = change(source,
        "let check_body_digest ~request_digest bytes =\n" if candidate else
        "let check_body ~request_digest bytes =\n",
        ("let check_body_digest ~request_digest bytes =\n" if candidate else
         "let check_body ~request_digest bytes =\n") + "  Metrics.bump Metrics.hashes;\n")
    source = change(source, "  let* json = try Ok (Yojson.Safe.from_string bytes)",
        "  Metrics.bump Metrics.parses;\n  let* json = try Ok (Yojson.Safe.from_string bytes)")
    return change(source,
        "| Some original when same_identity record (listed original) -> Ok original",
        "| Some original when same_identity record (listed original) -> Metrics.note_request original.request; Ok original")


def instrument_store(source):
    source = change(source, "let load_tool_request t ~scope ~request_id ~name_body =\n",
        "let load_tool_request t ~scope ~request_id ~name_body =\n  Metrics.bump Metrics.reads;\n  !Metrics.sample ();\n")
    return change(source, "      let* body = tool_request_body t ~scope ~request_digest in\n",
        "      let* body = tool_request_body t ~scope ~request_digest in\n      Option.iter Metrics.note body;\n")


def run(argv, directory, label):
    result = subprocess.run(argv, cwd=directory, text=True, capture_output=True)
    (directory / (label + ".stderr")).write_text(result.stderr)
    if result.returncode:
        raise RuntimeError(f"{label} failed ({result.returncode}): {result.stderr}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--compile-prefix", required=True, type=Path,
        help="JSON argv: matching ocamlopt and the existing -I/flags prefix")
    parser.add_argument("--link-command", required=True, type=Path,
        help="JSON argv: captured native link command, ending in the five fixture cmx files")
    args = parser.parse_args()
    repo, out = args.repo.resolve(), args.out.resolve()
    if "artifacts" not in out.parts:
        parser.error("new output must be under an artifacts/ directory")
    out.mkdir(parents=True, exist_ok=False)
    manifest = json.loads((HERE / "manifest.json").read_text())
    sources = {}
    for suffix in (".mli", ".ml"):
        for name in (STORE, OWNER):
            path = name + suffix
            sources[path] = (repo / path).read_text()
            if sha(sources[path].encode()) != manifest["candidate_sources"][path]:
                raise ValueError("candidate source differs: " + path)
    before = {}
    for suffix in (".mli", ".ml"):
        path = OWNER + suffix
        before[suffix] = subprocess.check_output(
            ["git", "show", BASE + ":" + path], cwd=repo, text=True)
        if sha(before[suffix].encode()) != manifest["baseline_sources"][path]:
            raise ValueError("baseline source differs: " + path)
    prefix = json.loads(args.compile_prefix.read_text())
    prefix = prefix[:1] + ["-I", str(out)] + prefix[1:]
    derived = []
    for unit, source, candidate in (("store_scope_test", STORE, False),
            ("owner_before", OWNER, False), ("owner_scope_test", OWNER, True)):
        for suffix in (".mli", ".ml"):
            raw = before[suffix] if unit == "owner_before" else sources[source + suffix]
            text = raw
            if suffix == ".ml":
                text = instrument_store(text) if unit == "store_scope_test" else instrument_owner(text, candidate)
            text = "open Masc\n" + ("" if unit == "store_scope_test" else
                "module Lane_addon_store = Store_scope_test\n") + text
            target = out / (unit + suffix)
            target.write_text(text)
            derived.append({"unit": target.name, "whole_source_sha256": sha(raw.encode()),
                "derived_sha256": sha(text.encode())})
    for unit, public in (("metrics", "metrics.ml"), ("test_scope", "cases.ml")):
        (out / (unit + ".ml")).write_bytes((HERE / public).read_bytes())
    for name in ("metrics.ml", "store_scope_test.mli", "store_scope_test.ml",
            "owner_before.mli", "owner_before.ml", "owner_scope_test.mli",
            "owner_scope_test.ml", "test_scope.ml"):
        run(prefix + ["-c", name], out, name)
    link = json.loads(args.link_command.read_text())
    units = ["metrics", "store_scope_test", "owner_before", "owner_scope_test", "test_scope"]
    if [Path(x).stem for x in link[-5:]] != units:
        raise ValueError("link command must end in the documented five fixture units")
    link = link[:-5] + [str(out / (name + ".cmx")) for name in units]
    binary = out / "test_scope.exe"
    link[link.index("-o") + 1] = str(binary)
    run(link, out, "link")
    env = os.environ.copy()
    env.pop("MASC_TEST_ALLOW_HOME_BASE_PATH", None)
    with tempfile.TemporaryDirectory(prefix="masc-owner-scope-proof-") as directory:
        Path(directory, "owned-marker").write_text("synthetic fixture\n")
        env["MASC_BASE_PATH"] = directory
        result = subprocess.run([str(binary)], cwd=directory, env=env,
            text=True, capture_output=True, timeout=45)
    (out / "run.stdout").write_text(result.stdout)
    (out / "run.stderr").write_text(result.stderr)
    result.check_returncode()
    observed = json.loads(result.stdout)
    (out / "observed.json").write_text(json.dumps(observed, indent=2) + "\n")
    (out / "derived-sources.json").write_text(json.dumps(derived, indent=2) + "\n")
    print(json.dumps({"assertions": observed["assertions"], "output": str(out)}))


if __name__ == "__main__":
    main()
