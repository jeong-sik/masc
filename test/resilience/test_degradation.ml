(* Cycle 27 / Tier A11 — Resilience.Degradation tests. *)

module D = Resilience.Degradation
module R = Resilience.Recovery

(* ─── Tag mirror + numeric mapping ────────────────────────────── *)

let test_all_level_tags () =
  assert (List.length D.all_level_tags = 4);
  let strs = List.map D.level_tag_to_string D.all_level_tags in
  assert (strs = [ "L1"; "L2"; "L3"; "L4" ])

let test_level_to_tag_round_trip () =
  assert (D.level_to_tag D.L1 = D.Tag_l1);
  assert (D.level_to_tag D.L2 = D.Tag_l2);
  assert (D.level_to_tag D.L3 = D.Tag_l3);
  assert (D.level_to_tag D.L4 = D.Tag_l4)

let test_any_level_to_tag () =
  assert (D.any_level_to_tag (D.Any_level D.L1) = D.Tag_l1);
  assert (D.any_level_to_tag (D.Any_level D.L4) = D.Tag_l4)

let test_level_to_string () =
  assert (D.level_to_string D.L2 = "L2");
  assert (D.level_to_string D.L3 = "L3")

let test_to_int () =
  assert (D.to_int D.L1 = 1);
  assert (D.to_int D.L4 = 4);
  assert (D.any_to_int (D.Any_level D.L3) = 3)

let test_of_int_opt () =
  (match D.of_int_opt 2 with
   | Some (D.Any_level D.L2) -> ()
   | _ -> assert false);
  assert (D.of_int_opt 5 = None);
  assert (D.of_int_opt 0 = None);
  assert (D.of_int_opt (-1) = None)

(* ─── authorize_transition ────────────────────────────────────── *)

let test_authorize_transition_allows_same_or_degradation () =
  assert (
    D.authorize_transition ~from:(D.Any_level D.L1) ~to_:(D.Any_level D.L1)
    = Ok ());
  assert (
    D.authorize_transition ~from:(D.Any_level D.L1) ~to_:(D.Any_level D.L4)
    = Ok ());
  assert (
    D.authorize_transition ~from:(D.Any_level D.L2) ~to_:(D.Any_level D.L3)
    = Ok ())

let test_authorize_transition_rejects_restoration_without_policy () =
  match D.authorize_transition ~from:(D.Any_level D.L4) ~to_:(D.Any_level D.L1) with
  | Error _ -> ()
  | Ok () -> assert false

(* ─── apply_level_to_strategy ─────────────────────────────────── *)

let transient_mode () = R.transient ~detail:"net" ~max_retries:3 ()
let permanent_handoff_mode () =
  R.permanent ~detail:"401" ~fallback:(R.HumanHandoff "rotate key")
let resource_mode () =
  R.resource_exhausted ~resource:`Tokens ~consumed:1.0 ~limit:1.0

let test_l1_returns_canonical_for_transient () =
  match D.apply_level_to_strategy D.L1 (transient_mode ()) with
  | R.Retry _ -> ()
  | _ -> assert false

let test_l1_returns_canonical_for_permanent_handoff () =
  match D.apply_level_to_strategy D.L1 (permanent_handoff_mode ()) with
  | R.Handoff _ -> ()
  | _ -> assert false

let test_l2_downgrades_retry_to_fallback () =
  match D.apply_level_to_strategy D.L2 (transient_mode ()) with
  | R.Fallback { fallback_value; degrade_confidence_by } ->
      assert (fallback_value = "<degraded:L2>");
      assert (Float.abs (degrade_confidence_by -. 0.3) < 1e-9)
  | _ -> assert false

let test_l2_preserves_handoff_for_permanent () =
  match D.apply_level_to_strategy D.L2 (permanent_handoff_mode ()) with
  | R.Handoff _ -> ()
  | _ -> assert false

let test_l3_forces_handoff_regardless () =
  (match D.apply_level_to_strategy D.L3 (transient_mode ()) with
   | R.Handoff _ -> ()
   | _ -> assert false);
  match D.apply_level_to_strategy D.L3 (resource_mode ()) with
  | R.Handoff _ -> ()
  | _ -> assert false

let test_l4_forces_abort_regardless () =
  (match D.apply_level_to_strategy D.L4 (transient_mode ()) with
   | R.Abort _ -> ()
   | _ -> assert false);
  match D.apply_level_to_strategy D.L4 (permanent_handoff_mode ()) with
  | R.Abort _ -> ()
  | _ -> assert false

(* ─── Recovery → Degradation bridge (A11b) ────────────────────── *)

let test_of_recovery_recommended_level_for_degradation_required () =
  let mode = R.degradation_required ~detail:"target=2" ~recommended_level:2 in
  match D.of_recovery_recommended_level mode with
  | Some (D.Any_level level) -> assert (D.to_int level = 2)
  | None -> assert false

let test_of_recovery_recommended_level_returns_none_for_other_modes () =
  assert (D.of_recovery_recommended_level (transient_mode ()) = None);
  assert (D.of_recovery_recommended_level (permanent_handoff_mode ()) = None);
  assert (D.of_recovery_recommended_level (resource_mode ()) = None)

let test_of_recovery_recommended_level_returns_none_for_out_of_range () =
  let mode = R.degradation_required ~detail:"bad" ~recommended_level:0 in
  assert (D.of_recovery_recommended_level mode = None);
  let mode2 = R.degradation_required ~detail:"bad" ~recommended_level:5 in
  assert (D.of_recovery_recommended_level mode2 = None)

let test_strategy_for_error_mode_uses_level_when_present () =
  (* L1 → canonical (Recovery.default_strategy of DegradationRequired
     is Handoff per B6 mapping). Verifying L1 path still returns
     Handoff confirms the mode→level→strategy round-trip. *)
  let mode_l1 = R.degradation_required ~detail:"x" ~recommended_level:1 in
  (match D.strategy_for_error_mode mode_l1 with
   | R.Handoff _ -> ()
   | _ -> assert false);
  (* L4 forces Abort regardless of mode. *)
  let mode_l4 = R.degradation_required ~detail:"x" ~recommended_level:4 in
  match D.strategy_for_error_mode mode_l4 with
  | R.Abort _ -> ()
  | _ -> assert false

let test_strategy_for_error_mode_falls_back_to_default_for_other_modes () =
  (* Transient → Recovery.default_strategy → Retry. *)
  (match D.strategy_for_error_mode (transient_mode ()) with
   | R.Retry _ -> ()
   | _ -> assert false);
  (* Permanent handoff → Handoff via canonical default. *)
  match D.strategy_for_error_mode (permanent_handoff_mode ()) with
  | R.Handoff _ -> ()
  | _ -> assert false

let test_strategy_for_error_mode_falls_back_when_level_out_of_range () =
  (* recommended_level = 99 → of_recovery_recommended_level = None
     → falls back to canonical default (Handoff for DegradationRequired). *)
  let mode = R.degradation_required ~detail:"x" ~recommended_level:99 in
  match D.strategy_for_error_mode mode with
  | R.Handoff _ -> ()
  | _ -> assert false

let () =
  test_all_level_tags ();
  test_level_to_tag_round_trip ();
  test_any_level_to_tag ();
  test_level_to_string ();
  test_to_int ();
  test_of_int_opt ();
  test_authorize_transition_allows_same_or_degradation ();
  test_authorize_transition_rejects_restoration_without_policy ();
  test_l1_returns_canonical_for_transient ();
  test_l1_returns_canonical_for_permanent_handoff ();
  test_l2_downgrades_retry_to_fallback ();
  test_l2_preserves_handoff_for_permanent ();
  test_l3_forces_handoff_regardless ();
  test_l4_forces_abort_regardless ();
  test_of_recovery_recommended_level_for_degradation_required ();
  test_of_recovery_recommended_level_returns_none_for_other_modes ();
  test_of_recovery_recommended_level_returns_none_for_out_of_range ();
  test_strategy_for_error_mode_uses_level_when_present ();
  test_strategy_for_error_mode_falls_back_to_default_for_other_modes ();
  test_strategy_for_error_mode_falls_back_when_level_out_of_range ();
  print_endline "test_degradation: all assertions passed"
