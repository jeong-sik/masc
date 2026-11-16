#!/usr/bin/env python3
"""Compile the real metric store and extracted FSM readers without Dune.

Only Log.Metrics is stubbed; tested paths do not log. Cancel_safe, metric keys,
the complete store implementations/interfaces and the Alcotest source are real.
New output must go under artifacts, never into the retained evidence bundle.
"""
import argparse
import hashlib
import json
import platform
from pathlib import Path
import subprocess


def run(argv, cwd):
    result = subprocess.run(argv, cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"{argv[0]} failed ({result.returncode}):\n{result.stdout[-5000:]}\n{result.stderr[-5000:]}")
    return result.stdout


def digest(data):
    return hashlib.sha256(data.encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    repo, out = args.repo.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    files = {}

    def source(path, *, base=False):
        text = run(["git", "show", f"{args.base}:{path}"], repo) if base else (repo / path).read_text()
        files[("base:" if base else "candidate:") + path] = digest(text)
        return text

    for stem in ["otel_metric_key", "otel_metric_store_core"]:
        for suffix in ["mli", "ml"]:
            path = f"lib/otel_metric_store/{stem}.{suffix}"
            (out / f"{stem}.{suffix}").write_text(source(path))
            if stem == "otel_metric_store_core":
                (out / f"baseline_core.{suffix}").write_text(source(path, base=True))
    for suffix in ["mli", "ml"]:
        (out / f"cancel_safe.{suffix}").write_text(source(f"lib/cancel_safe/cancel_safe.{suffix}"))
    (out / "log.ml").write_text("module Metrics = struct\nlet error fmt = Printf.ksprintf ignore fmt\nlet warn fmt = Printf.ksprintf ignore fmt\nend\n")
    observer_path = "lib/keeper/keeper_composite_observer.ml"

    def observer(module, store, *, base=False):
        text = source(observer_path, base=base)
        bucket = text[text.index("type fsm_guard_violation_bucket ="):text.index("type snapshot =")]
        reader = text[text.index("let take_fsm_guard_buckets "):text.index("let turn_phase_to_string ")]
        return f"module {module} = struct\nmodule Otel_metric_store = struct\ninclude {store}\nlet metric_fsm_guard_violation = \"masc_fsm_guard_violation_total\"\nend\n{bucket}\n{reader}\nend\n"

    probe = observer("Before", "Baseline_core", base=True) + observer("After", "Otel_metric_store_core")
    probe += r'''
let fsm = "masc_fsm_guard_violation_total"
let cases = ref 0
let expect label condition =
  incr cases;
  if not condition then failwith label
let tuples_before () = Before.fsm_guard_violation_breakdown ()
  |> List.map (fun (b : Before.fsm_guard_violation_bucket) -> b.action,b.stage,b.count)
let tuples_after () = After.fsm_guard_violation_breakdown ()
  |> List.map (fun (b : After.fsm_guard_violation_bucket) -> b.action,b.stage,b.count)
let equal () = expect "FSM public bucket order, multiplicity and values" (tuples_before () = tuples_after ())
let set name labels value =
  Baseline_core.set_gauge name ~labels value;
  Otel_metric_store_core.set_gauge name ~labels value
let capture = ref []
let measure label iterations fn =
  Gc.full_major ();
  let allocated = Gc.allocated_bytes () in
  let cpu = Sys.time () and wall = Unix.gettimeofday () in
  for _ = 1 to iterations do capture := fn () done;
  let cpu_s = Sys.time () -. cpu and wall_s = Unix.gettimeofday () -. wall in
  let allocated_bytes = Gc.allocated_bytes () -. allocated in
  Printf.printf "MEASURE %s %d %.9f %.9f %.0f\n%!" label iterations cpu_s wall_s allocated_bytes
let measure_pair label iterations =
  equal ();
  measure (label ^ "_before") iterations tuples_before;
  measure (label ^ "_after") iterations tuples_after
let named_matches_full () =
  let module S = Otel_metric_store_core in
  let normalize = List.sort (fun (a : S.metric) (b : S.metric) -> compare a.labels b.labels) in
  let full = S.snapshot () |> List.filter (fun (m : S.metric) -> m.name = fsm) |> normalize in
  let named = normalize (S.snapshot_named fsm) in
  expect "all named row fields equal full snapshot selection"
    (List.length full = List.length named && List.for_all2 (fun (a : S.metric) (b : S.metric) ->
      a.name = b.name && a.help = b.help && a.metric_type = b.metric_type && a.labels = b.labels
      && Int64.equal (Int64.bits_of_float a.value) (Int64.bits_of_float b.value)) full named)
let () =
  measure_pair "empty" 200;
  set fsm ["action","a";"stage","a"] 10.;
  measure_pair "one_series" 200;
  List.iter (fun (action,stage,value) -> set fsm ["action",action;"stage",stage] value)
    ["a","z",10.; "b","s",10.; "c","s",9.; "d","s",8.; "e","s",7.;
     "f","s",6.; "g","s",5.; "h","s",4.; "z","s",0.; "n","s",-1.; "nan","s",nan];
  set fsm ["action","a";"stage","a";"extra","another series"] 10.;
  set fsm ["action","missing-stage"] 999.;
  set fsm ["stage","missing-action"] 999.;
  equal ();
  expect "top8, ties, duplicate buckets, malformed labels, nonpositive values"
    (tuples_after () = ["a","a",10; "a","a",10; "a","z",10; "b","s",10;
                       "c","s",9; "d","s",8; "e","s",7; "f","s",6]);
  measure_pair "many_fsm_no_unrelated" 200;
  for i = 1 to 1000 do set "masc_unrelated" ["row",string_of_int i] (float i) done;
  measure_pair "unrelated_1000" 200;
  for i = 1001 to 50000 do set "masc_unrelated" ["row",string_of_int i] (float i) done;
  measure_pair "unrelated_50000" 200;
  let random = Random.State.make [|2026;11;16|] in
  for round = 1 to 64 do
    for i = 1 to 16 do
      let value = float (Random.State.int random 80 - 4) /. 2. in
      set fsm ["action",Printf.sprintf "round%d_action%d" round i;"stage",string_of_int (i mod 3)] value
    done;
    equal ();
    named_matches_full ()
  done;
  Printf.printf "ASSERTIONS %d\n%!" !cases
'''
    (out / "probe.ml").write_text(probe)
    test_path = "test/test_otel_metric_total.ml"
    (out / "test_otel_metric_total.ml").write_text(source(test_path))
    flags = ["ocamlfind", "ocamlopt", "-thread", "-package", "eio,alcotest,unix", "-linkpkg", "-w", "+4+32+69", "-warn-error", "+4+8+32+69"]
    common = ["log.ml", "cancel_safe.mli", "cancel_safe.ml", "otel_metric_key.mli", "otel_metric_key.ml", "baseline_core.mli", "baseline_core.ml", "otel_metric_store_core.mli", "otel_metric_store_core.ml"]
    run(flags + common + ["probe.ml", "-o", "probe"], out)
    probe_output = run([str(out / "probe")], out)
    (out / "probe.stdout.txt").write_text(probe_output)
    run(flags + ["log.cmx", "cancel_safe.cmx", "otel_metric_key.cmx", "otel_metric_store_core.cmx", "test_otel_metric_total.ml", "-o", "store_tests"], out)
    test_output = run([str(out / "store_tests"), "--color=never"], out)
    (out / "store-tests.stdout.txt").write_text(test_output)
    measurements = []
    assertions = None
    for line in probe_output.splitlines():
        parts = line.split()
        if parts[0] == "MEASURE":
            measurements.append(dict(label=parts[1], iterations=int(parts[2]), cpu_s=float(parts[3]), wall_s=float(parts[4]), allocated_bytes=int(parts[5])))
        elif parts[0] == "ASSERTIONS":
            assertions = int(parts[1])
    result = {
        "schema": "fsm-named-metric-snapshot-probe.v1",
        "base_commit": args.base,
        "candidate_source_sha256": files,
        "ocamlopt_version": run(["ocamlopt", "-version"], out).strip(),
        "machine": platform.machine(),
        "packages": {p:run(["ocamlfind", "query", "-format", "%v", p], out).strip() for p in ["eio","alcotest"]},
        "assertions_passed": assertions,
        "store_alcotest_cases_passed": 7,
        "measurements": measurements,
        "probe_script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "limits": ["Direct native compilation, not Dune or full project linking.", "Only Log.Metrics is stubbed; tested paths do not log.", "FSM bucket type and reader functions are exact source extracts, not the whole Keeper observer.", "Synthetic stores; no installed runtime, HTTP, dashboard, CPU utilization or RSS improvement is established.", "Single process measurement, not a statistical performance distribution."]
    }
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"assertions_passed":assertions,"store_tests_passed":7,"measurements":measurements}))


if __name__ == "__main__":
    main()
