(** RFC-OAS-XXX (Team JJ §6) POC — typed retry admission gate.

    Verifies that
    [Keeper_turn_cascade_budget.decide_retry_admission_for_turn]
    returns:
      - [Ok ()] when remaining turn budget is well above the
        per-attempt floor ([oas_timeout_guard_sec +
        min_oas_timeout_budget_sec] = 30s) for a retry without
        wall-clock fallback.
      - [Error (Retry_budget_below_min _)] when the projected
        wall-clock budget falls below the min floor (15s).

    The min floor is a typed boundary: the gate's reason field is a
    closed-sum reason record, not a substring or counter — see
    anti-pattern self-check note in
    [keeper_turn_cascade_budget.ml]. *)

module KCB = Masc_mcp.Keeper_turn_cascade_budget

(* The runtime snapshot freezes from env defaults; test/dune sets
   MASC_BASE_PATH="" so the snapshot is deterministic. We do not
   override turn_timeout_sec — the gate inputs we control
   ([remaining_turn_budget_s], [estimated_input_tokens], [max_turns],
   [allow_wall_clock_retry_budget]) are enough to drive the
   wall-clock branch deterministically:
     usable_wall_clock_budget = remaining_turn_budget_s - 15.0
   threshold is min_oas_timeout_budget_sec = 15.0 *)

let pp_decision ppf = function
  | Ok () -> Format.fprintf ppf "Ok"
  | Error d ->
    Format.fprintf ppf "Error %s"
      (Yojson.Safe.to_string (KCB.retry_admission_denial_to_yojson d))

let decision_testable =
  Alcotest.testable pp_decision (fun a b ->
    match a, b with
    | Ok (), Ok () -> true
    | Error (KCB.Retry_budget_below_min _),
      Error (KCB.Retry_budget_below_min _) -> true
    | Error (KCB.First_attempt_budget_below_min _),
      Error (KCB.First_attempt_budget_below_min _) -> true
    | _ -> false)

let test_retry_with_sufficient_wall_clock_budget_admits () =
  (* remaining_turn_budget_s = 120s; wall-clock fallback enabled.
     wall_clock = 120 - 15 = 105 >= 15 → Ok. *)
  let result =
    KCB.decide_retry_admission_for_turn
      ~remaining_turn_budget_s:120.0
      ~attempt_kind:KCB.Retry_attempt
      ~allow_wall_clock_retry_budget:true
      ~estimated_input_tokens:1000
      ~max_turns:6
  in
  Alcotest.check decision_testable
    "retry with 120s remaining + wall-clock should admit"
    (Ok ()) result

let test_retry_below_min_denies_with_typed_reason () =
  (* remaining_turn_budget_s = 20s; wall-clock fallback off
     (i.e. usable_retry_budget alone must clear 15s).
     adaptive_timeout default = min(turn_timeout, 300). Since the
     freeze gives us a known turn_timeout_sec, and
     time_spent_in_turn = turn_timeout - 20, usable_retry_budget
     can be small / negative. We avoid asserting the exact
     [projected_usable_budget_s] value; we only assert the
     constructor + min_required_s + that the gate said NO. *)
  let result =
    KCB.decide_retry_admission_for_turn
      ~remaining_turn_budget_s:20.0
      ~attempt_kind:KCB.Retry_attempt
      ~allow_wall_clock_retry_budget:false
      ~estimated_input_tokens:1000
      ~max_turns:6
  in
  match result with
  | Ok () ->
    Alcotest.failf
      "expected admission denial with 20s remaining and no \
       wall-clock fallback, got Ok"
  | Error (KCB.First_attempt_budget_below_min _) ->
    Alcotest.failf
      "expected Retry_budget_below_min, got \
       First_attempt_budget_below_min"
  | Error (KCB.Retry_budget_below_min r) ->
    Alcotest.(check (float 0.001))
      "min_required_s is 15.0" 15.0 r.min_required_s;
    Alcotest.(check (float 0.001))
      "remaining_turn_budget_s echoed back" 20.0
      r.remaining_turn_budget_s;
    Alcotest.(check bool)
      "wall-clock flag echoed back" false
      r.allow_wall_clock_retry_budget

let () =
  Alcotest.run "d7_retry_admission_gate"
    [
      ( "decide_retry_admission_for_turn",
        [
          Alcotest.test_case
            "retry with sufficient wall-clock budget admits"
            `Quick
            test_retry_with_sufficient_wall_clock_budget_admits;
          Alcotest.test_case
            "retry below min denies with typed Retry_budget_below_min"
            `Quick
            test_retry_below_min_denies_with_typed_reason;
        ] );
    ]
