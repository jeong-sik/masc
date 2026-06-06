(** RFC-OAS-XXX (Team JJ §6) POC — typed retry admission gate.

    Verifies that
    [Keeper_turn_runtime_budget.decide_retry_admission_for_turn]
    returns:
      - [Ok ()] for retries even when the outer keeper-turn wall clock
        is exhausted. Provider liveness, stream idle, and max-turn
        limits own retry termination.
      - [Error (First_attempt_budget_below_min _)] when a first
        attempt does not have enough startup budget.

    The min floor is a typed boundary: the gate's reason field is a
    closed-sum reason record, not a substring or counter — see
    anti-pattern self-check note in
    [keeper_turn_runtime_budget.ml]. *)

module KCB = Masc.Keeper_turn_runtime_budget

(* The runtime snapshot freezes from env defaults; test/dune sets
   MASC_BASE_PATH="" so the snapshot is deterministic. We do not
   override turn_timeout_sec — the gate inputs we control
   ([remaining_turn_budget_s], [estimated_input_tokens], [max_turns],
   [allow_wall_clock_retry_budget]) are enough to drive the
   wall-clock branch deterministically:
     usable_wall_clock_budget = remaining_turn_budget_s - 15.0
   threshold is min_provider_timeout_budget_sec = 15.0 *)

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

let test_retry_ignores_expired_outer_turn_budget () =
  (* Retry admission intentionally ignores the cumulative outer turn
     wall-clock cap. A no-first-token liveness guard can spend the old
     cap before the retry branch; denying here would turn the real
     provider failure into synthetic [retry_budget_below_min]. *)
  let result =
    KCB.decide_retry_admission_for_turn
      ~remaining_turn_budget_s:0.0
      ~attempt_kind:KCB.Retry_attempt
      ~allow_wall_clock_retry_budget:false
      ~estimated_input_tokens:1000
      ~max_turns:6
  in
  Alcotest.check decision_testable
    "retry with 0s remaining should admit"
    (Ok ()) result

let test_first_attempt_below_min_denies_with_typed_reason () =
  (* First attempts still need enough startup room for the provider
     guard plus minimum attempt budget. This keeps genuinely stale
     turn-start attempts from starting, without blocking retries after
     a provider/liveness failure. *)
  let result =
    KCB.decide_retry_admission_for_turn
      ~remaining_turn_budget_s:20.0
      ~attempt_kind:KCB.First_attempt
      ~allow_wall_clock_retry_budget:false
      ~estimated_input_tokens:1000
      ~max_turns:6
  in
  match result with
  | Ok () ->
    Alcotest.failf
      "expected first-attempt admission denial with 20s remaining, got Ok"
  | Error (KCB.Retry_budget_below_min _) ->
    Alcotest.failf
      "expected First_attempt_budget_below_min, got Retry_budget_below_min"
  | Error (KCB.First_attempt_budget_below_min r) ->
    Alcotest.(check (float 0.001))
      "min_required_s is 15.0" 15.0 r.min_required_s;
    Alcotest.(check (float 0.001))
      "remaining_turn_budget_s echoed back" 20.0
      r.remaining_turn_budget_s

let () =
  Alcotest.run "d7_retry_admission_gate"
    [
      ( "decide_retry_admission_for_turn",
        [
          Alcotest.test_case
            "retry ignores expired outer turn budget"
            `Quick
            test_retry_ignores_expired_outer_turn_budget;
          Alcotest.test_case
            "first attempt below min denies with typed First_attempt_budget_below_min"
            `Quick
            test_first_attempt_below_min_denies_with_typed_reason;
        ] );
    ]
