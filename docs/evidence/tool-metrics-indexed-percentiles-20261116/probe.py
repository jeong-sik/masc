#!/usr/bin/env python3
"""Real Tool_metrics source; Result/Dispatch/Log boundaries are fixtures."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import re
import subprocess


def run(argv, cwd):
    r = subprocess.run(argv, cwd=cwd, capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(f"{argv[0]} failed ({r.returncode}):\n{r.stdout[-4000:]}\n{r.stderr[-4000:]}")
    return r.stdout


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--repo", type=Path, required=True)
    p.add_argument("--base", required=True)
    p.add_argument("--out", type=Path, required=True)
    args = p.parse_args()
    repo, out = args.repo.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    hashes = {}

    def source(path, base=False):
        text = run(["git", "show", f"{args.base}:{path}"], repo) if base else (repo/path).read_text()
        hashes[("base:" if base else "candidate:")+path] = hashlib.sha256(text.encode()).hexdigest()
        return text

    metric_path = "lib/tool_surface/tool_metrics.ml"
    baseline = source(metric_path, True)
    (out/"baseline_metrics.ml").write_text(baseline)
    historical_commit = run(["git", "rev-parse", "b91ce999cd4d1ae04354be4193f14f46de33b5a1^"], repo).strip()
    historical = run(["git", "show", f"{historical_commit}:{metric_path}"], repo)
    hashes["historical:"+metric_path] = hashlib.sha256(historical.encode()).hexdigest()
    (out/"historical_metrics.ml").write_text(historical)
    fused_function = '''let percentiles { counts; total } =
  if total = 0 then 0.0, 0.0, 0.0
  else
    let index p =
      let idx = Float.to_int (Float.round (Stdlib.Float.of_int (total - 1) *. p)) in
      max 0 (min (total - 1) idx)
    in
    let p50_index = index 0.50 and p95_index = index 0.95 and p99_index = index 0.99 in
    let last_index = max p50_index (max p95_index p99_index) in
    let rec walk consumed p50 p95 p99 seq =
      match seq () with
      | Seq.Nil -> p50, p95, p99
      | Seq.Cons ((value, multiplicity), rest) ->
        let next = consumed + multiplicity in
        let p50 = if consumed <= p50_index && p50_index < next then value else p50 in
        let p95 = if consumed <= p95_index && p95_index < next then value else p95 in
        let p99 = if consumed <= p99_index && p99_index < next then value else p99 in
        if last_index < next then p50, p95, p99
        else walk next p50 p95 p99 rest
    in
    walk 0 0.0 0.0 0.0 (Duration_counts.to_seq counts)

'''
    fused = baseline[:baseline.index("let durations_nth ")] + fused_function + baseline[baseline.index("(** Per-tool accumulator."):]
    start, end = fused.index("let percentile "), fused.index("let compute_stats ")
    fused = fused[:start] + fused[end:]
    fused = fused.replace("  { tool_name\n  ; call_count", "  let p50_ms, p95_ms, p99_ms = percentiles acc.durations in\n  { tool_name\n  ; call_count")
    for name, value in [("p50", "0.50"), ("p95", "0.95"), ("p99", "0.99")]:
        fused = fused.replace(f"; {name}_ms = percentile acc.durations {value}", f"; {name}_ms")
    hashes["experiment:fused_prefix"] = hashlib.sha256(fused.encode()).hexdigest()
    (out/"fused_metrics.ml").write_text(fused)
    candidate = source(metric_path)
    (out/"candidate_metrics.ml").write_text(candidate)
    (out/"tool_metrics.ml").write_text(candidate)
    (out/"tool_metrics.mli").write_text(source("lib/tool_surface/tool_metrics.mli"))
    for ext in ["ml","mli"]:
        (out/f"set_util.{ext}").write_text(source(f"lib/core/set_util.{ext}"))
    fixtures = {
        "log.ml": "module Metrics = struct let warn fmt = Printf.ksprintf ignore fmt end\n",
        "dispatch_outcome.ml": "type t = Handled | No_handler\n",
        "tool_result.ml": r'''
type failure_class = Runtime_failure
type effect_disposition = Effect_outcome_unknown
type data_source = Explicit_data of Yojson.Safe.t
type output = { retained_artifacts:unit list; content_blocks:unit option;
  tool_name:string; data:Yojson.Safe.t; metadata:unit option; duration_ms:float }
type failure = { class_:failure_class; effect_disposition:effect_disposition;
  message:string; data_source:data_source; metadata:unit option; tool_name:string; duration_ms:float }
type result = Completed of output | Deferred of output | Failed of failure
''',
        "tool_dispatch.ml": "let register_dispatch_observer (_ : Dispatch_outcome.t -> Tool_result.result option -> unit) = ()\n"
    }
    for name,text in fixtures.items():
        (out/name).write_text(text)
    probe = r'''
module B = Baseline_metrics
module C = Candidate_metrics
module F = Fused_metrics
module H = Historical_metrics
let assertions = ref 0
let expect name yes = incr assertions; if not yes then failwith name
let bits = Int64.bits_of_float
let b_row (s:B.tool_stats) = (s.tool_name,s.call_count,s.success_count,s.deferred_count,s.failure_count,
  bits s.p50_ms,bits s.p95_ms,bits s.p99_ms,bits s.mean_ms)
let c_row (s:C.tool_stats) = (s.tool_name,s.call_count,s.success_count,s.deferred_count,s.failure_count,
  bits s.p50_ms,bits s.p95_ms,bits s.p99_ms,bits s.mean_ms)
let f_row (s:F.tool_stats) = (s.tool_name,s.call_count,s.success_count,s.deferred_count,s.failure_count,
  bits s.p50_ms,bits s.p95_ms,bits s.p99_ms,bits s.mean_ms)
let compare () =
  expect "all fields, float bits and exact all_stats ordering"
    (List.map b_row (B.all_stats ()) = List.map c_row (C.all_stats ()));
  expect "fused experiment equals current outputs" (List.map b_row (B.all_stats ()) = List.map f_row (F.all_stats ()));
  List.iter (fun name -> expect "stats_for has identical values"
    (Option.map b_row (B.stats_for name) = Option.map c_row (C.stats_for name))) ["target";"other";"missing"]
let load values =
  let a = B.replace_samples (fun add -> List.iteri (fun i duration_ms ->
    add {B.tool_name="target"; disposition=(match i mod 3 with 0->Completed|1->Deferred|_->Failed);duration_ms}) values; Ok ()) in
  let b = C.replace_samples (fun add -> List.iteri (fun i duration_ms ->
    add {C.tool_name="target"; disposition=(match i mod 3 with 0->Completed|1->Deferred|_->Failed);duration_ms}) values; Ok ()) in
  ignore (F.replace_samples (fun add -> List.iteri (fun i duration_ms ->
    add {F.tool_name="target"; disposition=(match i mod 3 with 0->Completed|1->Deferred|_->Failed);duration_ms}) values; Ok ()));
  ignore (H.replace_samples (fun add -> List.iteri (fun i duration_ms ->
    add {H.tool_name="target"; disposition=(match i mod 3 with 0->Completed|1->Deferred|_->Failed);duration_ms}) values; Ok ()));
  expect "replacement result" (a=b)
let verify_cache () =
  let before=B.all_stats () and after=C.all_stats () in
  expect "baseline cache identity" (before==B.all_stats ());
  expect "candidate cache identity" (after==C.all_stats ())
let record name duration_ms = Tool_result.Completed
  {retained_artifacts=[]; content_blocks=None; tool_name=name; data=`Null; metadata=None; duration_ms}
let measure label count fn =
  Gc.full_major ();
  let allocated=Gc.allocated_bytes () in
  let cpu=Sys.time () and wall=Unix.gettimeofday () in
  for _=1 to count do ignore (Sys.opaque_identity (fn ())) done;
  let cpu_s=Sys.time ()-.cpu and wall_s=Unix.gettimeofday ()-.wall in
  let bytes=Gc.allocated_bytes ()-.allocated in
  Printf.printf "MEASURE %s %d %.9f %.9f %.0f\n%!" label count cpu_s wall_s bytes
let benchmark label values repetitions =
  load values; compare (); verify_cache ();
  measure (label^"_stats_for_before") repetitions (fun ()->B.stats_for "target");
  measure (label^"_stats_for_after") repetitions (fun ()->C.stats_for "target");
  measure (label^"_stats_for_fused") repetitions (fun ()->F.stats_for "target");
  measure (label^"_stats_for_historical") repetitions (fun ()->H.stats_for "target");
  measure (label^"_warm_all_before") repetitions B.all_stats;
  measure (label^"_warm_all_after") repetitions C.all_stats
let check_tree values =
  let tree=ref C.Duration_tree.empty and oracle=ref B.durations_empty in
  let verify () =
    let rec inspect lower upper = function
      | C.Duration_tree.Empty -> 0,0
      | C.Duration_tree.Node n ->
        expect "positive multiplicity" (n.multiplicity>0);
        expect "strict lower Float.compare ordering" (Option.fold ~none:true ~some:(fun x->Float.compare x n.value<0) lower);
        expect "strict upper Float.compare ordering" (Option.fold ~none:true ~some:(fun x->Float.compare n.value x<0) upper);
        let lh,lc=inspect lower (Some n.value) n.left
        and rh,rc=inspect (Some n.value) upper n.right in
        expect "height recurrence and AVL balance" (n.height=1+max lh rh && abs(lh-rh)<=2);
        expect "subtree cardinality recurrence" (n.cardinality=lc+n.multiplicity+rc);
        n.height,n.cardinality
    in
    let _,count=inspect None None !tree in
    expect "total cardinality" (count= !oracle.B.total);
    let index=ref 0 in
    B.Duration_counts.iter (fun value multiplicity ->
      for _=1 to multiplicity do
        expect "nth exact current map representative bits"
          (Option.map bits (C.Duration_tree.nth !index !tree)=Some(bits value));
        incr index
      done) !oracle.B.counts
  in
  List.iteri (fun i value ->
    tree:=C.Duration_tree.add value !tree;
    oracle:=B.durations_add value !oracle;
    if i<64 || (i+1) land i=0 then verify ()) values;
  verify ()
let benchmark_writes label values =
  let b ()=B.replace_samples (fun add -> List.iter (fun duration_ms -> add {B.tool_name="target";disposition=Completed;duration_ms}) values;Ok ())
  and c ()=C.replace_samples (fun add -> List.iter (fun duration_ms -> add {C.tool_name="target";disposition=Completed;duration_ms}) values;Ok ())
  and f ()=F.replace_samples (fun add -> List.iter (fun duration_ms -> add {F.tool_name="target";disposition=Completed;duration_ms}) values;Ok ())
  and h ()=H.replace_samples (fun add -> List.iter (fun duration_ms -> add {H.tool_name="target";disposition=Completed;duration_ms}) values;Ok ()) in
  measure (label^"_replace_before") 3 b;
  measure (label^"_replace_after") 3 c;
  measure (label^"_replace_fused") 3 f;
  measure (label^"_replace_historical") 3 h;
  compare ()
let () =
  expect "empty private quantiles remain zero"
    ((B.percentile B.durations_empty 0.50,B.percentile B.durations_empty 0.95,B.percentile B.durations_empty 0.99)
     = (C.percentile C.Duration_tree.empty 0.50,C.percentile C.Duration_tree.empty 0.95,C.percentile C.Duration_tree.empty 0.99));
  List.iter (fun values -> load values; compare (); verify_cache ())
    [[];[1.];[1.;2.];[1.;1.;9.;9.];[-3.;-2.;-1.];[nan];[infinity];[neg_infinity];
     [-0.];[0.];[-0.;0.;-0.];[nan;neg_infinity;0.;infinity];
     [Int64.float_of_bits 0x7ff8000000000001L;Int64.float_of_bits 0x7ff8000000000002L;1.];
     [Int64.float_of_bits 0x7ff8000000000002L;Int64.float_of_bits 0x7ff8000000000001L;1.];
     [0.;-0.];[-0.;0.]];
  load [0.;-0.];
  expect "incoming signed-zero representative preserved"
    (Option.map (fun (s:C.tool_stats)->bits s.p50_ms) (C.stats_for "target")=Some(bits (-0.)));
  expect "historical first-key policy is deliberately not restored"
    (Option.map (fun (s:H.tool_stats)->bits s.p50_ms) (H.stats_for "target")=Some(bits 0.));
  let first_nan=Int64.float_of_bits 0x7ff8000000000001L
  and last_nan=Int64.float_of_bits 0x7ff8000000000002L in
  load [first_nan;last_nan];
  expect "incoming NaN payload representative preserved"
    (Option.map (fun (s:C.tool_stats)->bits s.p50_ms) (C.stats_for "target")=Some(bits last_nan));
  expect "historical first NaN payload deliberately not restored"
    (Option.map (fun (s:H.tool_stats)->bits s.p50_ms) (H.stats_for "target")=Some(bits first_nan));
  let random=Random.State.make [|2026;11;16;99|] in
  let monotone=List.init 50000 Float.of_int in
  List.iter check_tree
    [monotone;List.rev monotone;
     List.init 50000 (fun i->Float.of_int (if i mod 2=0 then i/2 else 50000-i/2));
     List.init 20000 (fun _->Float.of_int (Random.State.int random 100000));
     List.init 50000 (fun i->Float.of_int (i mod 7));
     [0.;-0.;nan;Int64.float_of_bits 0x7ff8000000000001L;neg_infinity;infinity;0.;nan]];
  for round=1 to 300 do
    let values=List.init (Random.State.int random 512) (fun _ ->
      match Random.State.int random 16 with
      | 0 -> nan | 1 -> infinity | 2 -> neg_infinity | 3 -> -0.
      | _ -> Float.of_int (Random.State.int random 1000-500) /. 10.) in
    load values; compare ();
    let old_b=B.all_stats () and old_c=C.all_stats () in
    let error_b=B.replace_samples (fun add -> add {B.tool_name="partial";disposition=Completed;duration_ms=3.}; Error "refused") in
    let error_c=C.replace_samples (fun add -> add {C.tool_name="partial";disposition=Completed;duration_ms=3.}; Error "refused") in
    expect "failed replacement returns same error" (error_b=error_c);
    expect "failed replacement preserves baseline cache" (old_b==B.all_stats ());
    expect "failed replacement preserves candidate cache" (old_c==C.all_stats ());
    B.record (record "other" (Float.of_int round)); C.record (record "other" (Float.of_int round)); F.record (record "other" (Float.of_int round));
    expect "record invalidates baseline cache" (old_b!=B.all_stats ());
    expect "record invalidates candidate cache" (old_c!=C.all_stats ());
    compare ()
  done;
  benchmark "one" [1.] 2000;
  benchmark "duplicates" (List.init 100000 (fun i->Float.of_int (i mod 3))) 2000;
  let mass=List.init 100000 (fun _->0.) in
  let tail=List.init 500 (fun i->Float.of_int (i+1)) in
  benchmark "rare_tail" (mass@tail) 2000;
  benchmark "middle_mass" (-1.::mass@tail) 2000;
  benchmark "high_mass" (List.map Float.neg tail@mass) 2000;
  benchmark "unique100k" (List.init 100000 Float.of_int) 20;
  let unrelated=record "other" 1. in
  measure "global_invalidation_before" 20 (fun ()->B.record unrelated; B.all_stats ());
  measure "global_invalidation_after" 20 (fun ()->C.record unrelated; C.all_stats ());
  measure "global_invalidation_fused" 20 (fun ()->F.record unrelated; F.all_stats ());
  measure "global_invalidation_historical" 20 (fun ()->H.record unrelated; H.all_stats ());
  compare ();
  let before_counts=ref (B.Duration_counts.singleton 0. 1000000)
  and after_tree=ref C.Duration_tree.empty in
  for _=1 to 1000000 do after_tree:=C.Duration_tree.add 0. !after_tree done;
  for i=1 to 5000 do
    before_counts:=B.Duration_counts.add (Float.of_int i) 1 !before_counts;
    after_tree:=C.Duration_tree.add (Float.of_int i) !after_tree
  done;
  let before_durations:B.durations={counts= !before_counts;total=1005000} in
  let before ()=B.percentile before_durations 0.50,B.percentile before_durations 0.95,B.percentile before_durations 0.99
  and after ()=C.percentile !after_tree 0.50,C.percentile !after_tree 0.95,C.percentile !after_tree 0.99 in
  expect "dominant minimum plus5000 rare keys" (before ()=after ());
  measure "dominant_min_private_before" 2000 before;
  measure "dominant_min_private_after" 2000 after;
  benchmark_writes "ascending100k" (List.init 100000 Float.of_int);
  benchmark_writes "random100k" (List.init 100000 (fun _->Float.of_int (Random.State.int random 1000000)));
  benchmark_writes "duplicates100k" (List.init 100000 (fun i->Float.of_int (i mod 3)));
  let writes=List.init 20000 (fun i->record "target" (Float.of_int i)) in
  measure "record20k_before" 1 (fun ()->List.iter B.record writes);
  measure "record20k_after" 1 (fun ()->List.iter C.record writes);
  measure "record20k_fused" 1 (fun ()->List.iter F.record writes);
  measure "record20k_historical" 1 (fun ()->List.iter H.record writes);
  compare ();
  B.clear ();C.clear ();F.clear ();compare ();
  Printf.printf "ASSERTIONS %d\n%!" !assertions
'''
    (out/"probe.ml").write_text(probe)
    test_path="test/test_tool_metrics.ml"
    (out/"test_tool_metrics.ml").write_text(source(test_path))
    flags=["ocamlfind","ocamlopt","-thread","-package","yojson,alcotest,unix","-linkpkg","-w","+4+32+69","-warn-error","+4+8+32+69"]
    common=["set_util.mli","set_util.ml","log.ml","dispatch_outcome.ml","tool_result.ml","tool_dispatch.ml"]
    run(flags+common+["baseline_metrics.ml","candidate_metrics.ml","fused_metrics.ml","historical_metrics.ml","probe.ml","-o","probe"],out)
    output=run([str(out/"probe")],out)
    (out/"probe.stdout.txt").write_text(output)
    run(flags+["set_util.cmx","log.cmx","dispatch_outcome.cmx","tool_result.cmx","tool_dispatch.cmx","tool_metrics.mli","tool_metrics.ml","test_tool_metrics.ml","-o","tests"],out)
    test_output=run([str(out/"tests"),"--color=never"],out)
    (out/"tests.stdout.txt").write_text(test_output)
    match=re.search(r"(\d+) tests run",test_output)
    if not match: raise RuntimeError("Alcotest count missing")
    measurements=[];assertions=None
    for line in output.splitlines():
        parts=line.split()
        if parts[0]=="ASSERTIONS":assertions=int(parts[1])
        if parts[0]=="MEASURE":measurements.append(dict(label=parts[1],iterations=int(parts[2]),cpu_s=float(parts[3]),wall_s=float(parts[4]),allocated_bytes=int(parts[5])))
    result=dict(schema="tool-metrics-indexed-percentiles-probe.v1",base_commit=args.base,historical_commit=historical_commit,source_sha256=hashes,compiler_version=run(["ocamlopt","-version"],out).strip(),machine=platform.machine(),assertions_passed=assertions,unchanged_existing_alcotest_cases_passed=int(match[1]),measurements=measurements,probe_script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),limits=["Complete baseline/candidate/historical Tool_metrics implementations are compiled directly. The fused-prefix experiment derives from baseline with the function included in this script. Private helpers are visible in inferred probe-only interfaces for the empty/invariant cases.","The unchanged existing test source runs against the actual candidate public interface and implementation.","Set_util is real; Tool_result/Tool_dispatch/Dispatch_outcome/Log are explicit fixtures. Actual dependency CMI typing is separate evidence.","Historical measurements demonstrate indexed selection costs; the old equal-key representative intentionally differs from current Map semantics for signed-zero/NaN payloads.","No Dune, full project link, HTTP, runtime or provider execution.","One-process synthetic measurements; no production CPU/RSS improvement is established."])
    (out/"result.json").write_text(json.dumps(result,indent=2)+"\n")
    print(json.dumps({"assertions_passed":assertions,"existing_tests_passed":int(match[1]),"measurements":measurements}))


if __name__=="__main__":main()
