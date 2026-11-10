#!/usr/bin/env python3
"""Run the exact production pure ledger fold, with synthetic authority data.

This is an extracted-module probe, not a Dune build or an integration test.
Only unused random-ID minting is stubbed; the types, wire decoder, and fold
are copied from their source bytes. It does not access runtime data.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
arguments = argparse.ArgumentParser(description=__doc__)
arguments.add_argument("--source", type=Path, default=ROOT / "source")
arguments.add_argument("--output", type=Path, default=ROOT)
arguments.add_argument("--before", default="4b75311e12ce4aeecf51c77fe96f88ec64096510")
options = arguments.parse_args()
SOURCE = options.source.resolve()
OUTPUT = options.output.resolve()
OUTPUT.mkdir(parents=True, exist_ok=True)
BEFORE = options.before
PROBE = r'''
open World_constitution_types
module Store = Store_fold

let article n author text =
  let id = match Article_id.of_string (Printf.sprintf "a-%032x" n) with
    | Ok id -> id | Error e -> failwith e in
  match make ~id ~text ~author ~at:1.0 ~evidence:[] with
  | Ok a -> a | Error e -> failwith (invalid_to_string e)

let original = article 1 "keeper-a" "retired rule"
let stable = article 2 "keeper-a" "unrelated rule"
let collision = article 3 "keeper-a" "old replacement id"
let replacement = article 3 "retired-keeper" "unverified replacement"
let edit = article 1 "retired-keeper" "unverified edit"
let readopted = article 1 "keeper-a" "readopted rule"
let resolve_subject s = String.equal s "keeper-a"
let removed = Removed { id = original.id; by = "retired-operator"; at = 2.0; reason = None }
let replaced by = Replaced { superseded = [original.id]; article = replacement; by; at = 2.0; reason = None }
let encode entries = String.concat "\n" (List.map (fun e -> Yojson.Safe.to_string (World_constitution_wire.entry_to_json e)) entries) ^ "\n"
let cases =
  [ "retired remover", [Added original; Added stable; removed], ["unrelated rule"], 1
  ; "unknown replacement and colliding id", [Added original; Added stable; Added collision; replaced "retired-keeper"], ["unrelated rule"], 1
  ; "unknown same-id edit", [Added original; Added stable; Added edit], ["unrelated rule"], 1
  ; "known mover with unknown author", [Added original; Added stable; Added collision; replaced "keeper-a"], ["unrelated rule"], 1
  ; "later explicit readoption", [Added original; Added stable; removed; Added readopted], ["unrelated rule"; "readopted rule"], 1
  ; "unregistered new norm", [Added stable; Added replacement], ["unrelated rule"], 1
  ; "resolved removal", [Added original; Added stable; Removed {id=original.id; by="keeper-a"; at=2.0; reason=None}], ["unrelated rule"], 0
  ]

let texts (articles : World_constitution_types.t list) = List.map (fun a -> a.text) articles
let () =
  let outcomes = List.map (fun (name, entries, expected, isolated) ->
    let bytes = encode entries in
    let history = Store.parse ~resolve_subject bytes in
    let lean = Store.parse_with ~keep_history:false ~resolve_subject bytes in
    let actual = texts history.articles in
    let pass = actual = expected && texts lean.articles = expected
      && List.length history.entries = List.length entries
      && lean.entries = [] && history.rejected = []
      && List.length history.isolated = isolated in
    `Assoc ["name", `String name; "pass", `Bool pass;
      "actual", `List (List.map (fun s -> `String s) actual);
      "expected", `List (List.map (fun s -> `String s) expected)]) cases in
  let pass = List.for_all (function `Assoc fields -> List.assoc "pass" fields = `Bool true | _ -> false) outcomes in
  print_endline (Yojson.Safe.pretty_to_string (`Assoc ["pass", `Bool pass; "cases", `List outcomes]));
  exit (if pass then 0 else 1)
'''


def read_source(path, before):
    if before:
        return subprocess.check_output(["git", "show", f"{BEFORE}:{path}"], cwd=SOURCE)
    return (SOURCE / path).read_bytes()


receipts = []
for label, before in [("before", True), ("after", False)]:
    target = OUTPUT / f"fold-probe-{label}"
    target.mkdir(exist_ok=True)
    hashes = {}
    for name in ["world_constitution_types", "world_constitution_wire"]:
        for suffix in ["ml", "mli"]:
            path = f"lib/world_constitution/{name}.{suffix}"
            data = read_source(path, before)
            (target / f"{name}.{suffix}").write_bytes(data)
            hashes[path] = hashlib.sha256(data).hexdigest()
    path = "lib/world_constitution/world_constitution_store.ml"
    data = read_source(path, before)
    begin = data.index(b"type line_end =")
    end = data.index(b"let read_contents ~base_path =")
    extracted = data[begin:end]
    (target / "store_fold.ml").write_bytes(extracted)
    hashes[path] = hashlib.sha256(data).hexdigest()
    (target / "random_id.ml").write_text('let prefixed ~prefix:_ ~bytes:_ = invalid_arg "ID minting is outside this probe"\n')
    (target / "probe.ml").write_text(PROBE)
    command = ["ocamlfind", "ocamlc", "-w", "+4+8", "-warn-error", "+4+8", "-package", "yojson,re.pcre,eio", "-linkpkg",
               "random_id.ml", "world_constitution_types.mli", "world_constitution_types.ml",
               "world_constitution_wire.mli", "world_constitution_wire.ml", "store_fold.ml", "probe.ml", "-o", "probe.exe"]
    compiled = subprocess.run(command, cwd=target, text=True, capture_output=True)
    (target / "compile.stdout").write_text(compiled.stdout)
    (target / "compile.stderr").write_text(compiled.stderr)
    receipt = {"label": label, "source_head": BEFORE if before else "worktree candidate", "source_sha256": hashes,
               "fold_slice_sha256": hashlib.sha256(extracted).hexdigest(), "compile_command": command,
               "compile_exit": compiled.returncode}
    if compiled.returncode == 0:
        ran = subprocess.run([str(target / "probe.exe")], cwd=target, text=True, capture_output=True)
        (target / "result.json").write_text(ran.stdout)
        (target / "run.stderr").write_text(ran.stderr)
        receipt.update(run_exit=ran.returncode, result=json.loads(ran.stdout))
    else:
        receipt["compile_error"] = compiled.stderr
    receipts.append(receipt)
result = {"compiler": subprocess.check_output(["ocamlc", "-version"], text=True).strip(),
          "driver_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
          "boundary": "Exact production types/wire and extracted pure fold; unused ID minting stubbed. No Dune, filesystem append/read, Keeper prompt, provider, installation or runtime verification.",
          "receipts": receipts}
(OUTPUT / "fold-probe-receipt.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({"compiler": result["compiler"], "outcomes": [{"label": r["label"], "compile_exit": r["compile_exit"], "run_exit": r.get("run_exit"), "pass": r.get("result", {}).get("pass"), "compile_error": r.get("compile_error")} for r in receipts]}, ensure_ascii=False))
