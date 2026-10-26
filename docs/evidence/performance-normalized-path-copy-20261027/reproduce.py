#!/usr/bin/env python3
"""Interpret exact lexical path helpers; no Dune or native compilation.

Both roles use explicitly supplied HOME-reader and Common.masc_dirname fixtures.
Those dependencies are not the production environment resolver. Exhaustive
equality and fixed ABBA helper rows are separate from a native server result.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import statistics
import subprocess


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def dump(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def extract(raw, first, after):
    text = raw.decode()
    assert text.count(first) == 1 and text.count(after) == 1
    return text[text.index(first):text.index(after)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--baseline-ref", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    relative = "lib/config/env_config_core.ml"
    baseline = subprocess.check_output(
        ["git", "-C", str(args.repo), "show", args.baseline_ref + ":" + relative]
    )
    candidate = (args.repo / relative).read_bytes()
    tests = (args.repo / "test/test_config_dir_resolver.ml").read_bytes()
    test_code = extract(
        tests,
        "let test_normalize_masc_base_path_input_canonicalizes_explicit_path () =",
        "let test_env_override_valid () =",
    )
    modules = [
        """let home_fixture = ref None
let checks = ref 0
let string = ()
let check _ label expected actual =
  incr checks;
  if not (String.equal expected actual) then
    failwith (Printf.sprintf "%s: expected %S, actual %S" label expected actual)
"""
    ]
    plan = {
        "schema": "masc.normalized-path-helper-plan.v1",
        "baseline_ref": args.baseline_ref,
        "scope": "OCaml5.5 interpreter exact extracted helpers, injected HOME/Common dependencies; not a native server or fleet result",
        "fixture_dependencies": {
            "raw_value_opt": "Only HOME is accepted; returns current explicit home_fixture, no actual HOME mutation",
            "Common.masc_dirname": ".masc",
        },
        "differential": {
            "exhaustive_alphabet": ["/", ".", "a", " ", "\u0000"],
            "exhaustive_max_length": 7,
            "random_seed": [2026, 10, 27],
            "random_cases": 20000,
            "random_max_components": 24,
            "long_cases": "1048576 ordinary bytes and 16384 ordinary components",
        },
        "order_per_case": ["baseline", "candidate", "candidate", "baseline"],
        "warmup_or_discard": "none; full_major before every measured block, outside the block",
        "sources": {},
    }
    for role, raw in [("Baseline", baseline), ("Candidate", candidate)]:
        (args.output / (role.lower() + "-env_config_core.ml")).write_bytes(raw)
        trim = extract(raw, "let trim_opt = function", "let strip_trailing_slashes =")
        helpers = extract(raw, "let strip_path_trailing_slashes value =", "let existing_dir path =")
        plan["sources"][role.lower()] = {
            "full_file_sha256": sha(raw),
            "trim_opt_sha256": sha(trim.encode()),
            "path_helpers_sha256": sha(helpers.encode()),
        }
        modules.append(
            "module " + role + """ = struct
module Common = struct let masc_dirname = ".masc" end
let raw_value_opt = function
  | "HOME" -> !home_fixture
  | name -> failwith ("unexpected environment fixture lookup: " ^ name)
"""
            + trim + helpers + "\nend\n"
        )
        modules.append(
            "module " + role + "_cases = struct\nmodule Env_config_core = " + role
            + "\n" + test_code + "\nend\n"
        )
    (args.output / "candidate-test_config_dir_resolver.ml").write_bytes(tests)
    plan["added_and_existing_case_source_sha256"] = sha(test_code.encode())
    harness = r'''
let compare path =
  check string "lexical differential"
    (Baseline.normalize_path_lexically path) (Candidate.normalize_path_lexically path);
  check string "base-input differential"
    (Baseline.normalize_masc_base_path_input path)
    (Candidate.normalize_masc_base_path_input path)
let () =
  Baseline_cases.test_normalize_masc_base_path_input_canonicalizes_explicit_path ();
  Baseline_cases.test_normalize_path_lexically_normal_paths ();
  Baseline_cases.test_normalize_path_lexically_special_components ();
  Baseline_cases.test_normalize_masc_base_path_input_strips_one_masc_component ();
  Candidate_cases.test_normalize_masc_base_path_input_canonicalizes_explicit_path ();
  Candidate_cases.test_normalize_path_lexically_normal_paths ();
  Candidate_cases.test_normalize_path_lexically_special_components ();
  Candidate_cases.test_normalize_masc_base_path_input_strips_one_masc_component ();
  let actual_cases = !checks in
  let alphabet = [| '/'; '.'; 'a'; ' '; '\000' |] in
  let rec enumerate remaining prefix =
    compare prefix;
    if remaining > 0 then
      Array.iter (fun byte ->
        enumerate (remaining - 1) (prefix ^ String.make 1 byte)) alphabet
  in
  enumerate 7 "";
  let random = Random.State.make [| 2026; 10; 27 |] in
  let components =
    [| ""; "."; ".."; "ordinary"; "..."; ".hidden"; "..suffix";
       "white space"; "설정"; "alpha\\beta"; "\000"; ".masc" |]
  in
  for _ = 1 to 20000 do
    let count = Random.State.int random 25 in
    let parts = List.init count (fun _ ->
      components.(Random.State.int random (Array.length components))) in
    let path = String.concat "/" parts in
    compare (if Random.State.bool random then "/" ^ path else path)
  done;
  compare (String.make 1048576 'a');
  compare (String.concat "/" (List.init 16384 (fun _ -> "component")));
  List.iter (fun home ->
    home_fixture := home;
    List.iter compare [ "~/"; "~/alpha"; "~/alpha/../beta"; "~/./.masc";
                        " ~/설정//..suffix/ "; "~/../.."; "~/../../.masc" ])
    [None; Some ""; Some "  "; Some "/"; Some "/fixture/home";
     Some " /alpha/./beta/..// "; Some "relative/home"];
  home_fixture := None;
  Printf.printf "{\"kind\":\"semantics\",\"actual_test_case_checks\":%d,\"all_checks\":%d}\n%!"
    actual_cases !checks;
  let owner_root = "/fixture/owned-base/.masc/config/keepers/scale-owner-299" in
  let cases =
    [ "root", "/", 50000;
      "short_relative", "alpha", 50000;
      "relative_components", "alpha/beta/gamma", 50000;
      "normal_owner_path", owner_root, 50000;
      "trimmed_owner_path", " \t" ^ owner_root ^ "\n", 50000;
      "late_special_component", owner_root ^ "/..", 50000;
      "early_special_component", "//" ^ owner_root, 50000;
      "long_normal_component", "/" ^ String.make 4096 'a', 1000 ]
  in
  let roles =
    [ "baseline", Baseline.normalize_path_lexically;
      "candidate", Candidate.normalize_path_lexically ]
  in
  List.iter (fun (case, path, calls) ->
    let expected = Baseline.normalize_path_lexically path in
    List.iteri (fun block role ->
      let normalize = List.assoc role roles in
      let checksum = ref 0 in
      Gc.full_major ();
      let before = Gc.allocated_bytes () in
      let started = Mtime_clock.elapsed_ns () in
      for _ = 1 to calls do
        let result = Sys.opaque_identity (normalize (Sys.opaque_identity path)) in
        checksum := !checksum + String.length result
      done;
      let elapsed = Int64.to_float (Int64.sub (Mtime_clock.elapsed_ns ()) started) /. 1e6 in
      let allocated = Gc.allocated_bytes () -. before in
      if !checksum <> calls * String.length expected then failwith "measurement checksum";
      Printf.printf
        "{\"kind\":\"measurement\",\"role\":\"%s\",\"case\":\"%s\",\"calls\":%d,\"block\":%d,\"elapsed_ms\":%.6f,\"allocated_bytes\":%.0f,\"checksum\":%d}\n%!"
        role case calls block elapsed allocated !checksum)
      [ "baseline"; "candidate"; "candidate"; "baseline" ]) cases
'''
    generated = ("\n".join(modules) + harness).encode()
    probe = args.output / "probe.ml"
    probe.write_bytes(generated)
    plan["generated_probe_sha256"] = sha(generated)
    plan["script_sha256"] = sha(Path(__file__).read_bytes())
    mtime = subprocess.check_output(["ocamlfind", "query", "mtime"], text=True).strip()
    clock = subprocess.check_output(["ocamlfind", "query", "mtime.clock.os"], text=True).strip()
    command = [
        "ocaml", "-noinit", "-noprompt", "-I", "+unix", "-I", mtime, "-I", clock,
        "unix.cma", "mtime.cma", "mtime_clock.cma", str(probe.resolve()),
    ]
    plan["command"] = command
    plan["interpreter"] = subprocess.check_output(["ocamlc", "-version"], text=True).strip()
    dump(args.output / "plan.json", plan)
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    with (args.output / "stdout.jsonl").open("xb") as out, (args.output / "stderr.txt").open("xb") as err:
        completed = subprocess.run(command, stdout=out, stderr=err)
    returned = datetime.datetime.now(datetime.timezone.utc).isoformat()
    rows = [json.loads(line) for line in (args.output / "stdout.jsonl").read_text().splitlines()]
    measurements = [row for row in rows if row["kind"] == "measurement"]
    case_summaries = {}
    for case in dict.fromkeys(row["case"] for row in measurements):
        roles = {}
        for role in ["baseline", "candidate"]:
            selected = [row for row in measurements if row["case"] == case and row["role"] == role]
            roles[role] = {
                "cells": len(selected),
                "calls_per_cell": selected[0]["calls"],
                "median_elapsed_ms": statistics.median(row["elapsed_ms"] for row in selected),
                "median_allocated_bytes": statistics.median(row["allocated_bytes"] for row in selected),
            }
        case_summaries[case] = roles
    summary = {
        "returncode": completed.returncode,
        "started_at_utc": started,
        "returned_at_utc": returned,
        "semantics": [row for row in rows if row["kind"] == "semantics"],
        "measurements": len(measurements),
        "cases": case_summaries,
        "scope": plan["scope"],
        "hashes": {
            path.name: sha(path.read_bytes()) for path in args.output.iterdir() if path.is_file()
        },
        "candidate_source_still_matches": (args.repo / relative).read_bytes() == candidate,
    }
    dump(args.output / "summary.json", summary)
    print(json.dumps({key: summary[key] for key in ["returncode", "semantics", "measurements", "cases"]}))
    raise SystemExit(completed.returncode)


if __name__ == "__main__":
    main()
