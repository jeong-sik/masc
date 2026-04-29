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

(* ─── authorize_transition (stub) ─────────────────────────────── *)

let test_authorize_transition_stub_always_ok () =
  let res =
    D.authorize_transition ~from:(D.Any_level D.L1) ~to_:(D.Any_level D.L4)
  in
  assert (res = Ok ());
  let res2 =
    D.authorize_transition ~from:(D.Any_level D.L4) ~to_:(D.Any_level D.L1)
  in
  assert (res2 = Ok ())

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

let () =
  test_all_level_tags ();
  test_level_to_tag_round_trip ();
  test_any_level_to_tag ();
  test_level_to_string ();
  test_to_int ();
  test_of_int_opt ();
  test_authorize_transition_stub_always_ok ();
  test_l1_returns_canonical_for_transient ();
  test_l1_returns_canonical_for_permanent_handoff ();
  test_l2_downgrades_retry_to_fallback ();
  test_l2_preserves_handoff_for_permanent ();
  test_l3_forces_handoff_regardless ();
  test_l4_forces_abort_regardless ();
  print_endline "test_degradation: all assertions passed"
