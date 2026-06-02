(* test/test_heuristic_metrics_diagnostics.ml

   Covers Heuristic_metrics_diagnostics.analyze semantics.
   Related: #7718 reopen (instrumentation theatre regression — 51 records
   all [("post_tool_use_failure", 1.0, 0.0, true)]). *)

open Masc_mcp
module D = Heuristic_metrics_diagnostics

let fail msg = failwith msg
let assert_true msg b = if not b then fail msg
let assert_false msg b = if b then fail msg

let assert_eq_int ~msg expected got =
  if expected <> got then
    fail (Printf.sprintf "%s: expected=%d got=%d" msg expected got)

let assert_list_equal ~msg expected got =
  let e = List.sort String.compare expected in
  let g = List.sort String.compare got in
  if e <> g then
    fail
      (Printf.sprintf "%s: expected=[%s] got=[%s]" msg
         (String.concat ";" e) (String.concat ";" g))

let record ?(ts = 1.0) ~site ~raw ~thr ~trig () : Yojson.Safe.t =
  `Assoc
    [
      "module", `String "test";
      "site", `String site;
      "raw_value", `Float raw;
      "threshold", `Float thr;
      "triggered", `Bool trig;
      "timestamp", `Float ts;
    ]

let repeat n f = List.init n f

(* --- Parsing robustness ----------------------------------------- *)

let test_ignores_malformed_records () =
  let records : Yojson.Safe.t list =
    [
      `Assoc [ "site", `String "ok"; "raw_value", `Float 0.5;
               "threshold", `Float 0.3; "triggered", `Bool true;
               "timestamp", `Float 1.0 ];
      `Null;
      `Assoc [ "site", `String "missing_threshold"; "raw_value", `Float 0.5;
               "triggered", `Bool true ];
      `Assoc [ "site", `String "bad_types"; "raw_value", `String "oops";
               "threshold", `Float 0.3; "triggered", `Bool true ];
    ]
  in
  let r = D.analyze records in
  assert_eq_int ~msg:"only the well-formed record is counted"
    1 r.total_records;
  (match r.sites with
   | [ s ] -> assert_true "good site name parsed" (s.site = "ok")
   | other ->
       fail
         (Printf.sprintf "expected one site, got %d" (List.length other)))

(* --- #7718 regression reproduction ------------------------------ *)

let test_degenerate_site_flagged () =
  (* 51 copies of the exact tuple from #7718 reopen evidence. *)
  let records =
    repeat 51 (fun i ->
      record ~ts:(float_of_int i)
        ~site:"post_tool_use_failure" ~raw:1.0 ~thr:0.0 ~trig:true ())
  in
  let r = D.analyze records in
  assert_eq_int ~msg:"51 records observed" 51 r.total_records;
  (match r.sites with
   | [ s ] ->
     assert_eq_int ~msg:"single site count" 51 s.count;
     assert_eq_int ~msg:"exactly one unique tuple" 1 s.unique_tuples;
     assert_eq_int ~msg:"all triggered=true" 51 s.triggered_true_count
   | _ -> fail "expected one site");
  assert_list_equal ~msg:"post_tool_use_failure flagged degenerate"
    [ "post_tool_use_failure" ] r.degenerate_sites;
  assert_list_equal ~msg:"one-sided (100% triggered=true)"
    [ "post_tool_use_failure" ] r.one_sided_sites

let test_below_min_records_not_flagged () =
  (* Identical-tuple stream but only degenerate_min_records - 1 records:
     intentionally treated as insufficient data. *)
  let n = D.degenerate_min_records - 1 in
  let records =
    repeat n (fun i ->
      record ~ts:(float_of_int i) ~site:"tiny" ~raw:1.0 ~thr:0.0 ~trig:true ())
  in
  let r = D.analyze records in
  assert_false "below-threshold site NOT flagged degenerate"
    (List.mem "tiny" r.degenerate_sites);
  assert_false "below-threshold site NOT flagged one-sided"
    (List.mem "tiny" r.one_sided_sites)

let test_variance_prevents_flag () =
  (* Same site, but raw_value varies — healthy signal. *)
  let records =
    List.init 30 (fun i ->
      record ~ts:(float_of_int i)
        ~site:"healthy"
        ~raw:(float_of_int i /. 100.0)
        ~thr:0.5
        ~trig:(i mod 2 = 0)
        ())
  in
  let r = D.analyze records in
  assert_false "varying site NOT degenerate"
    (List.mem "healthy" r.degenerate_sites);
  assert_false "varying site NOT one-sided"
    (List.mem "healthy" r.one_sided_sites);
  (match r.sites with
   | [ s ] ->
     assert_true "multiple unique tuples" (s.unique_tuples > 1);
     assert_true "triggered counts split" (s.triggered_true_count > 0 && s.triggered_false_count > 0)
   | _ -> fail "expected one site")

(* --- Mixed-site report ----------------------------------------- *)

let test_mixed_workload () =
  let degenerate =
    repeat 25 (fun i ->
      record ~ts:(float_of_int i)
        ~site:"theatre" ~raw:1.0 ~thr:0.0 ~trig:true ())
  in
  let healthy =
    List.init 25 (fun i ->
      record ~ts:(100.0 +. float_of_int i)
        ~site:"real"
        ~raw:(float_of_int i /. 100.0)
        ~thr:0.5
        ~trig:(i mod 3 = 0)
        ())
  in
  let cold =
    repeat 3 (fun _ ->
      record ~site:"cold" ~raw:0.1 ~thr:0.9 ~trig:false ())
  in
  let r = D.analyze (degenerate @ healthy @ cold) in
  assert_eq_int ~msg:"total records" 53 r.total_records;
  assert_list_equal ~msg:"only theatre flagged degenerate"
    [ "theatre" ] r.degenerate_sites;
  assert_list_equal ~msg:"only theatre one-sided"
    [ "theatre" ] r.one_sided_sites

let test_all_triggered_false_flagged () =
  (* Unreachable-branch case: site always records triggered=false but
     raw/threshold differ → variance > 1 so not degenerate, but is
     one-sided. *)
  let records =
    List.init 25 (fun i ->
      record ~ts:(float_of_int i)
        ~site:"unreachable"
        ~raw:(float_of_int i /. 100.0)
        ~thr:1.0
        ~trig:false
        ())
  in
  let r = D.analyze records in
  assert_false "not degenerate (variance present)"
    (List.mem "unreachable" r.degenerate_sites);
  assert_list_equal ~msg:"one-sided (all triggered=false)"
    [ "unreachable" ] r.one_sided_sites

(* --- Timestamp + pretty ---------------------------------------- *)

let test_latest_timestamp_is_max () =
  let records =
    [
      record ~ts:3.0 ~site:"s" ~raw:1.0 ~thr:0.5 ~trig:true ();
      record ~ts:1.0 ~site:"s" ~raw:1.0 ~thr:0.5 ~trig:true ();
      record ~ts:5.0 ~site:"s" ~raw:1.0 ~thr:0.5 ~trig:true ();
      record ~ts:2.0 ~site:"s" ~raw:1.0 ~thr:0.5 ~trig:true ();
    ]
  in
  let r = D.analyze records in
  match r.sites with
  | [ s ] -> (
      match s.latest_timestamp with
      | Some 5.0 -> ()
      | Some f ->
          fail (Printf.sprintf "latest_timestamp should be 5.0, got %.3f" f)
      | None -> fail "expected latest_timestamp")
  | _ -> fail "expected one site"

let contains_substring s sub =
  let ls = String.length s and lsub = String.length sub in
  if lsub = 0 then true
  else if lsub > ls then false
  else
    let last = ls - lsub in
    let rec loop i =
      if i > last then false
      else if String.sub s i lsub = sub then true
      else loop (i + 1)
    in
    loop 0

let test_pretty_summary_contains_header () =
  let records =
    repeat 25 (fun _ ->
      record ~site:"x" ~raw:1.0 ~thr:0.0 ~trig:true ())
  in
  let r = D.analyze records in
  let s = D.pretty_summary r in
  assert_true "header line present"
    (contains_substring s "heuristic_metrics diagnostics:");
  assert_true "degenerate count surfaces"
    (contains_substring s "degenerate=1");
  assert_true "site line present"
    (contains_substring s "site=x")

let () =
  test_ignores_malformed_records ();
  test_degenerate_site_flagged ();
  test_below_min_records_not_flagged ();
  test_variance_prevents_flag ();
  test_mixed_workload ();
  test_all_triggered_false_flagged ();
  test_latest_timestamp_is_max ();
  test_pretty_summary_contains_header ();
  print_endline "test_heuristic_metrics_diagnostics: OK"
