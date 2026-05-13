(** Tests for [Autoresearch_result_bridge].

    Unit tests for pure functions: score normalization, target-met
    check, verdict mapping, attribution mapping. *)

module Br = Masc_mcp.Autoresearch_result_bridge
module V = Masc_mcp.Verification
module A = Masc_mcp.Attribution
module AR = Masc_mcp.Autoresearch

let make_state ?(lower_is_better = false) ?(target_score = None)
    ?(baseline = 0.0) () : AR.loop_state =
  {
    loop_id = "loop-test";
    author = None;
    goal = "test goal";
    metric_fn = "dummy";
    model_model = "test-model";
    target_file = "test.py";
    target_score;
    status = AR.Running;
    error_message = None;
    current_cycle = 1;
    baseline;
    best_score = baseline;
    best_cycle = 0;
    queued_hypothesis = None;
    history = [];
    total_keeps = 0;
    total_discards = 0;
    insights = [];
    start_time = 0.0;
    updated_at = 0.0;
    cycle_timeout_s = 60.0;
    max_cycles = 10;
    workdir = "/tmp/test";
    source_workdir = "/tmp/test";
    program_note = None;
    warnings = [];
    patience = 3;
    consecutive_discards = 0;
    build_verify_fn = None;
    lower_is_better;
  }

let make_record ?(decision = AR.Keep) ?(score_before = 0.5)
    ?(score_after = 0.6) ?(hypothesis = "try X") () : AR.cycle_record =
  {
    cycle = 1;
    hypothesis;
    score_before;
    score_after;
    delta = score_after -. score_before;
    decision;
    commit_hash = None;
    elapsed_ms = 1000;
    model_used = "test-model";
    timestamp = 0.0;
  }

(* --- verdict_of_cycle --- *)

let test_keep_above_target_is_pass () =
  let st = make_state ~target_score:(Some 0.9) ~baseline:0.5 () in
  let rec_ = make_record ~decision:AR.Keep ~score_after:0.95 () in
  match Br.verdict_of_cycle st rec_ with
  | V.Pass -> ()
  | other ->
    Alcotest.fail
      (Printf.sprintf "expected Pass, got %s" (V.show_verdict other))

let test_keep_below_target_is_partial () =
  let st = make_state ~target_score:(Some 0.9) ~baseline:0.5 () in
  let rec_ = make_record ~decision:AR.Keep ~score_after:0.7 () in
  match Br.verdict_of_cycle st rec_ with
  | V.Partial (score, rationale) ->
    Alcotest.(check bool) "score in (0.5, 1.0)" true
      (score > 0.5 && score <= 1.0);
    Alcotest.(check bool) "rationale mentions hypothesis" true
      (Astring.String.is_infix ~affix:"try X" rationale)
  | other ->
    Alcotest.fail
      (Printf.sprintf "expected Partial, got %s" (V.show_verdict other))

let test_keep_no_target_is_partial () =
  (* Without a target, Keep always → Partial (no threshold to meet). *)
  let st = make_state ~baseline:0.5 () in
  let rec_ = make_record ~decision:AR.Keep ~score_after:0.9 () in
  match Br.verdict_of_cycle st rec_ with
  | V.Partial _ -> ()
  | _ -> Alcotest.fail "expected Partial when no target"

let test_discard_is_fail () =
  let st = make_state () in
  let rec_ = make_record ~decision:AR.Discard ~score_after:0.3 () in
  match Br.verdict_of_cycle st rec_ with
  | V.Fail msg ->
    Alcotest.(check bool) "reason mentions Discard" true
      (Astring.String.is_infix ~affix:"Discard" msg)
  | _ -> Alcotest.fail "expected Fail"

let test_lower_is_better_orientation () =
  (* baseline=1.0 (val_bpb), target=0.5, score_after=0.7.
     With lower_is_better, 0.7 < baseline is progress → Partial
     (target 0.5 not yet met). *)
  let st =
    make_state ~lower_is_better:true ~baseline:1.0
      ~target_score:(Some 0.5) ()
  in
  let rec_ =
    make_record ~decision:AR.Keep ~score_before:1.0 ~score_after:0.7 ()
  in
  match Br.verdict_of_cycle st rec_ with
  | V.Partial (score, _) ->
    Alcotest.(check bool) "score above baseline midpoint" true
      (score > 0.5)
  | V.Pass -> Alcotest.fail "0.7 < target=0.5 false in lower_is_better"
  | _ -> Alcotest.fail "expected Partial"

let test_lower_is_better_target_met () =
  let st =
    make_state ~lower_is_better:true ~baseline:1.0
      ~target_score:(Some 0.5) ()
  in
  let rec_ =
    make_record ~decision:AR.Keep ~score_before:0.6 ~score_after:0.4 ()
  in
  match Br.verdict_of_cycle st rec_ with
  | V.Pass -> ()
  | _ -> Alcotest.fail "0.4 <= target=0.5 under lower_is_better → Pass"

(* --- attribution_of_cycle --- *)

let test_attribution_keep_pass_outcome () =
  let st = make_state ~target_score:(Some 0.9) ~baseline:0.5 () in
  let rec_ = make_record ~decision:AR.Keep ~score_after:0.95 () in
  let attr = Br.attribution_of_cycle st rec_ in
  Alcotest.(check string) "gate" "autoresearch" attr.gate;
  Alcotest.(check bool) "origin=NonDet" true (attr.origin = A.NonDet);
  Alcotest.(check bool) "outcome=Passed" true
    (match attr.outcome with A.Passed -> true | _ -> false)

let test_attribution_keep_partial () =
  let st = make_state ~target_score:(Some 0.9) ~baseline:0.5 () in
  let rec_ = make_record ~decision:AR.Keep ~score_after:0.7 () in
  let attr = Br.attribution_of_cycle st rec_ in
  match attr.outcome with
  | A.Partial_pass { score; rationale } ->
    Alcotest.(check bool) "score normalized in (0, 1]" true
      (score > 0.0 && score <= 1.0);
    Alcotest.(check bool) "rationale mentions cycle" true
      (Astring.String.is_infix ~affix:"cycle" rationale)
  | _ -> Alcotest.fail "expected Partial_pass"

let test_attribution_discard_policy_failed () =
  let st = make_state () in
  let rec_ = make_record ~decision:AR.Discard ~hypothesis:"bad idea" () in
  let attr = Br.attribution_of_cycle st rec_ in
  Alcotest.(check bool) "origin=NonDet (even on discard)" true
    (attr.origin = A.NonDet);
  match attr.outcome with
  | A.Policy_failed { reason } ->
    Alcotest.(check bool) "reason mentions Discard" true
      (Astring.String.is_infix ~affix:"Discard" reason)
  | _ -> Alcotest.fail "expected Policy_failed"

let test_attribution_evidence_has_loop_identity () =
  let st = make_state ~target_score:(Some 0.9) ~baseline:0.5 () in
  let rec_ = make_record ~decision:AR.Keep ~score_after:0.95 () in
  let attr = Br.attribution_of_cycle st rec_ in
  match attr.evidence with
  | `Assoc fields ->
    Alcotest.(check (option string)) "loop_id"
      (Some "loop-test")
      (match List.assoc_opt "loop_id" fields with
       | Some (`String s) -> Some s
       | _ -> None);
    Alcotest.(check (option int)) "cycle" (Some 1)
      (match List.assoc_opt "cycle" fields with
       | Some (`Int n) -> Some n
       | _ -> None);
    Alcotest.(check bool) "model_used redacted" true
      (match List.assoc_opt "model_used" fields with
       | Some `Null -> true
       | _ -> false);
    Alcotest.(check bool) "has rationale for Passed" true
      (List.mem_assoc "rationale" fields)
  | _ -> Alcotest.fail "evidence must be object"

let test_partial_has_rationale_on_outcome_not_evidence () =
  (* For Partial_pass, rationale lives on the outcome record, not
     inside evidence. *)
  let st = make_state ~target_score:(Some 0.9) ~baseline:0.5 () in
  let rec_ = make_record ~decision:AR.Keep ~score_after:0.7 () in
  let attr = Br.attribution_of_cycle st rec_ in
  match attr.outcome with
  | A.Partial_pass { rationale; _ } ->
    Alcotest.(check bool) "rationale on outcome" true
      (String.length rationale > 0)
  | _ -> Alcotest.fail "expected Partial_pass"

let () =
  Alcotest.run "Autoresearch_result_bridge"
    [
      ( "verdict_of_cycle",
        [
          Alcotest.test_case "Keep + above target → Pass" `Quick
            test_keep_above_target_is_pass;
          Alcotest.test_case "Keep + below target → Partial" `Quick
            test_keep_below_target_is_partial;
          Alcotest.test_case "Keep + no target → Partial" `Quick
            test_keep_no_target_is_partial;
          Alcotest.test_case "Discard → Fail" `Quick test_discard_is_fail;
          Alcotest.test_case "lower_is_better orientation" `Quick
            test_lower_is_better_orientation;
          Alcotest.test_case "lower_is_better target met" `Quick
            test_lower_is_better_target_met;
        ] );
      ( "attribution_of_cycle",
        [
          Alcotest.test_case "Keep + target met → Passed" `Quick
            test_attribution_keep_pass_outcome;
          Alcotest.test_case "Keep + below target → Partial_pass" `Quick
            test_attribution_keep_partial;
          Alcotest.test_case "Discard → Policy_failed" `Quick
            test_attribution_discard_policy_failed;
          Alcotest.test_case "evidence has loop_id and cycle" `Quick
            test_attribution_evidence_has_loop_identity;
          Alcotest.test_case "Partial_pass rationale on outcome" `Quick
            test_partial_has_rationale_on_outcome_not_evidence;
        ] );
    ]
