#!/usr/bin/env python3
"""Interpret exact owner-index modules with explicit Owner/canonicalizer fixtures."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import shutil
import statistics
import subprocess
import time


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def dump(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--baseline-ref", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    relative = "lib/keeper/keeper_owner_projection.ml"
    baseline = subprocess.check_output(
        ["git", "-C", str(args.repo), "show", args.baseline_ref + ":" + relative]
    )
    candidate = (args.repo / relative).read_bytes()
    set_util = (args.repo / "lib/core/set_util.ml").read_bytes()
    map_line = "module StringMap = Map.Make (String)\n"
    assert set_util.decode().count(map_line) == 1
    modules = ["""module Keeper_owner_reducer = struct type projection = int option end
module Keeper_owner = struct
  type t = { state : Keeper_owner_reducer.projection Atomic.t }
  let projection owner = Atomic.get owner.state
end
module Keeper_registry_types = struct
  let canonical_base_path_exn value = value
end
module Set_util = struct
""" + map_line + "end\n"]
    plan = {
        "schema": "masc.owner-projection-index-helper-plan.v1",
        "baseline_ref": args.baseline_ref,
        "scope": "Exact complete inventory modules in OCaml interpreter, injected Owner/projection and identity canonicalizer; not actual Owner actors, production path normalization, native server or Keeper population",
        "fixture_dependencies": {
            "Keeper_owner": "distinct handles holding an Atomic int option projection",
            "Keeper_owner_reducer.projection": "int option",
            "Keeper_registry_types.canonical_base_path_exn": "identity on already canonical fixture keys; actual validation/environment/filesystem costs excluded",
            "Set_util.StringMap": "exact current Map.Make(String) declaration",
        },
        "populations": [2, 30, 300],
        "order_per_population": ["baseline", "candidate", "candidate", "baseline"],
        "phases": ["install", "lookup_sweep", "lookup_miss", "replace", "stale_remove", "current_remove"],
        "sweeps_per_cell": 1000,
        "semantic_seed": [2026, 10, 27],
        "semantic_random_steps": 20000,
        "warmup_or_discard": "none; semantic work precedes measurement; full_major before each phase outside counters/clocks",
        "sources": {},
        "set_util_full_file_sha256": sha(set_util),
        "script_sha256": sha(Path(__file__).read_bytes()),
    }
    for role, raw in [("Baseline", baseline), ("Candidate", candidate)]:
        (args.output / (role.lower() + "-keeper_owner_projection.ml")).write_bytes(raw)
        plan["sources"][role.lower()] = {"full_file_sha256": sha(raw)}
        modules.append("module " + role + " = struct\n" + raw.decode() + "\nend\n")
    harness = r'''
type api =
  { role : string
  ; install : base_path:string -> keeper_name:string -> Keeper_owner.t -> unit
  ; remove : base_path:string -> keeper_name:string -> Keeper_owner.t -> unit
  ; read : base_path:string -> keeper_name:string -> int
  }
let baseline_read ~base_path ~keeper_name =
  match Baseline.lookup ~base_path ~keeper_name with
  | Owner_absent -> -2
  | Owner_projection None -> -1
  | Owner_projection (Some value) -> value
let candidate_read ~base_path ~keeper_name =
  match Candidate.lookup ~base_path ~keeper_name with
  | Owner_absent -> -2
  | Owner_projection None -> -1
  | Owner_projection (Some value) -> value
let baseline =
  { role = "baseline"; install = Baseline.install; remove = Baseline.remove; read = baseline_read }
let candidate =
  { role = "candidate"; install = Candidate.install; remove = Candidate.remove; read = candidate_read }
let roles = [baseline; candidate]
let owner value = Keeper_owner.{ state = Atomic.make value }
let checks = ref 0
let check expected actual =
  incr checks;
  if expected <> actual then
    failwith (Printf.sprintf "semantic check expected %d, actual %d" expected actual)
let () =
  List.iter (fun api ->
    let root = "/fixture/replacement" in
    let other = "/fixture/other-root" in
    let name = "same-name" in
    let first, second = owner (Some 7), owner (Some 7) in
    if first == second || not (first = second) then failwith "identity fixture";
    api.install ~base_path:root ~keeper_name:name first;
    api.install ~base_path:other ~keeper_name:name first;
    api.install ~base_path:root ~keeper_name:name second;
    api.remove ~base_path:root ~keeper_name:name first;
    check 7 (api.read ~base_path:root ~keeper_name:name);
    Atomic.set second.state (Some 11);
    check 11 (api.read ~base_path:root ~keeper_name:name);
    check 7 (api.read ~base_path:other ~keeper_name:name);
    Atomic.set second.state None;
    check (-1) (api.read ~base_path:root ~keeper_name:name);
    api.remove ~base_path:root ~keeper_name:name second;
    check (-2) (api.read ~base_path:root ~keeper_name:name);
    api.remove ~base_path:other ~keeper_name:name second;
    check 7 (api.read ~base_path:other ~keeper_name:name);
    api.remove ~base_path:other ~keeper_name:name first;
    check (-2) (api.read ~base_path:other ~keeper_name:name)) roles;
  let random = Random.State.make [|2026;10;27|] in
  let root = "/fixture/model" in
  let keys = Array.init 32 (Printf.sprintf "model-owner-%d") in
  let handles = Array.init 16 (fun value -> owner (Some value)) in
  let expected = Array.make 32 None in
  for step = 1 to 20000 do
    let key_index = Random.State.int random (Array.length keys) in
    let handle = handles.(Random.State.int random (Array.length handles)) in
    let name = keys.(key_index) in
    (match Random.State.int random 4 with
     | 0 ->
         List.iter (fun api -> api.install ~base_path:root ~keeper_name:name handle) roles;
         expected.(key_index) <- Some handle
     | 1 ->
         List.iter (fun api -> api.remove ~base_path:root ~keeper_name:name handle) roles;
         (match expected.(key_index) with
          | Some current when current == handle -> expected.(key_index) <- None
          | Some _ | None -> ())
     | 2 -> Atomic.set handle.state (if step mod 3 = 0 then None else Some step)
     | _ -> ());
    let observed_key = Random.State.int random (Array.length keys) in
    let value =
      match expected.(observed_key) with
      | None -> -2
      | Some handle -> (match Atomic.get handle.state with None -> -1 | Some n -> n)
    in
    List.iter (fun api ->
      check value (api.read ~base_path:root ~keeper_name:keys.(observed_key))) roles
  done;
  Array.iteri (fun index -> function
    | None -> ()
    | Some handle ->
        List.iter (fun api -> api.remove ~base_path:root ~keeper_name:keys.(index) handle) roles) expected;
  Printf.printf "{\"kind\":\"semantics\",\"checks\":%d,\"random_steps\":20000}\n%!" !checks;
  let measure api population block phase calls expected run =
    Gc.full_major ();
    let before = Gc.allocated_bytes () in
    let started = Mtime_clock.elapsed_ns () in
    let checksum = run () in
    let ended = Mtime_clock.elapsed_ns () in
    let after = Gc.allocated_bytes () in
    if checksum <> expected then failwith ("measurement checksum: " ^ phase);
    let elapsed = Int64.to_float (Int64.sub ended started) /. 1e6 in
    Printf.printf
      "{\"kind\":\"measurement\",\"role\":\"%s\",\"population\":%d,\"block\":%d,\"phase\":\"%s\",\"calls\":%d,\"started_ns\":%Ld,\"ended_ns\":%Ld,\"elapsed_ms\":%.6f,\"allocated_before\":%.0f,\"allocated_after\":%.0f,\"allocated_bytes\":%.0f,\"checksum\":%d}\n%!"
      api.role population block phase calls started ended elapsed before after (after -. before) checksum
  in
  List.iter (fun population ->
    let names = Array.init population (Printf.sprintf "owner-%d") in
    let original = Array.init population (fun value -> owner (Some (value + 1))) in
    let replacements = Array.init population (fun value -> owner (Some (value + 1001))) in
    let root = "/fixture/canonical-owner-root" in
    List.iteri (fun block api ->
      Array.iter (fun name -> check (-2) (api.read ~base_path:root ~keeper_name:name)) names;
      measure api population block "install" population population (fun () ->
        Array.iteri (fun index name -> api.install ~base_path:root ~keeper_name:name original.(index)) names;
        population);
      Array.iteri (fun index name ->
        check (index + 1) (api.read ~base_path:root ~keeper_name:name)) names;
      measure api population block "lookup_sweep" (population * 1000)
        (1000 * population * (population + 1) / 2) (fun () ->
        let sum = ref 0 in
        for _ = 1 to 1000 do
          Array.iter (fun name -> sum := !sum + api.read ~base_path:root ~keeper_name:name) names
        done;
        !sum);
      measure api population block "lookup_miss" (population * 1000) (-2 * population * 1000) (fun () ->
        let sum = ref 0 in
        for _ = 1 to population * 1000 do
          sum := !sum + api.read ~base_path:root ~keeper_name:"missing-owner"
        done;
        !sum);
      measure api population block "replace" population population (fun () ->
        Array.iteri (fun index name -> api.install ~base_path:root ~keeper_name:name replacements.(index)) names;
        population);
      measure api population block "stale_remove" population population (fun () ->
        Array.iteri (fun index name -> api.remove ~base_path:root ~keeper_name:name original.(index)) names;
        population);
      Array.iteri (fun index name ->
        check (index + 1001) (api.read ~base_path:root ~keeper_name:name)) names;
      measure api population block "current_remove" population population (fun () ->
        Array.iteri (fun index name -> api.remove ~base_path:root ~keeper_name:name replacements.(index)) names;
        population);
      Array.iter (fun name -> check (-2) (api.read ~base_path:root ~keeper_name:name)) names)
      [baseline;candidate;candidate;baseline])
    [2;30;300];
  Printf.printf "{\"kind\":\"final_checks\",\"checks\":%d}\n%!" !checks
'''
    probe = args.output / "probe.ml"
    probe.write_text("\n".join(modules) + harness)
    plan["generated_probe_sha256"] = sha(probe.read_bytes())
    mtime = Path(subprocess.check_output(["ocamlfind", "query", "mtime"], text=True).strip())
    clock = Path(subprocess.check_output(["ocamlfind", "query", "mtime.clock.os"], text=True).strip())
    interpreter = Path(shutil.which("ocaml")).resolve()
    libraries = [mtime / "mtime.cma", clock / "mtime_clock.cma"]
    plan["selected_execution_inputs"] = {
        str(p): sha(p.read_bytes()) for p in [interpreter, *libraries]
    }
    plan["actual_interpreter_version"] = subprocess.check_output(
        [str(interpreter), "-version"], text=True
    ).strip()
    command = [
        str(interpreter), "-noinit", "-noprompt", "-I", "+unix", "-I", str(mtime), "-I", str(clock),
        "unix.cma", "mtime.cma", "mtime_clock.cma", str(probe.resolve()),
    ]
    plan["command"] = command
    dump(args.output / "plan.json", plan)
    started_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
    requested_ns = time.perf_counter_ns()
    with (args.output / "stdout.jsonl").open("xb") as out, (args.output / "stderr.txt").open("xb") as err:
        completed = subprocess.run(command, stdout=out, stderr=err)
    returned_ns = time.perf_counter_ns()
    returned_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
    dump(args.output / "execution.json", {
        "command": command, "returncode": completed.returncode,
        "parent_requested_ns": requested_ns, "parent_returned_ns": returned_ns,
        "started_at_utc": started_at, "returned_at_utc": returned_at,
        "stdout_sha256": sha((args.output / "stdout.jsonl").read_bytes()),
        "stderr_sha256": sha((args.output / "stderr.txt").read_bytes()),
    })
    if completed.returncode:
        print(json.dumps({"returncode": completed.returncode, "receipt": str(args.output / "execution.json")}))
        raise SystemExit(completed.returncode)
    rows = [json.loads(line) for line in (args.output / "stdout.jsonl").read_text().splitlines()]
    measurements = [row for row in rows if row["kind"] == "measurement"]
    derived = []
    for population in plan["populations"]:
        for phase in plan["phases"]:
            roles = {}
            for role in ["baseline", "candidate"]:
                selected = [row for row in measurements if row["population"] == population and row["phase"] == phase and row["role"] == role]
                roles[role] = {
                    "cells": len(selected),
                    "calls_per_cell": selected[0]["calls"],
                    "median_elapsed_ms": statistics.median(row["elapsed_ms"] for row in selected),
                    "median_allocated_bytes": statistics.median(row["allocated_bytes"] for row in selected),
                }
            derived.append({"population": population, "phase": phase, "roles": roles})
    summary = {
        "returncode": completed.returncode,
        "started_at_utc": started_at, "returned_at_utc": returned_at,
        "parent_requested_ns": requested_ns, "parent_returned_ns": returned_ns,
        "semantics": [row for row in rows if row["kind"] in ["semantics", "final_checks"]],
        "measurement_rows": len(measurements),
        "derived": derived,
        "scope": plan["scope"],
        "hashes": {p.name: sha(p.read_bytes()) for p in args.output.iterdir() if p.is_file()},
        "source_unchanged": (args.repo / relative).read_bytes() == candidate,
    }
    dump(args.output / "summary.json", summary)
    print(json.dumps({k: summary[k] for k in ["returncode", "semantics", "measurement_rows", "derived"]}))
    raise SystemExit(completed.returncode)


if __name__ == "__main__":
    main()
