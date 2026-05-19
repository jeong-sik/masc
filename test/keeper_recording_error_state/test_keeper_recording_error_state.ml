(** MASC/OAS Error-Warn Reduction Goal §P6 — coverage for
    Keeper_recording_error_state.

    Each test resets the global dedupe table to avoid order-dependent
    coupling between cases. *)

open Alcotest
module S = Keeper_recording_error_state

let reset () = S.reset_for_test ()

(* ─────────────────────────── classifier ─────────────────────────── *)

let test_classify_sandbox_docker () =
  check
    bool
    "sandbox docker → Sandbox_docker"
    true
    (S.classify_error
       "sandbox docker exec failed (masc-keeper-sandbox:local, exit=2): \
        ls: cannot access '...': No such file or directory"
     = S.Sandbox_docker)
;;

let test_classify_path_syntax () =
  check
    bool
    "Path syntax blocked → Path_syntax_blocked"
    true
    (S.classify_error
       "Path syntax blocked: shell quoting, globbing, brace expansion ..."
     = S.Path_syntax_blocked)
;;

let test_classify_stale_turn () =
  check
    bool
    "stale_turn_timeout(...) → Stale_turn_timeout"
    true
    (S.classify_error "stale_turn_timeout(idle_turn(1559s))"
     = S.Stale_turn_timeout)
;;

let test_classify_fiber_unresolved () =
  check
    bool
    "fiber_unresolved → Fiber_unresolved"
    true
    (S.classify_error "fiber_unresolved" = S.Fiber_unresolved)
;;

let test_classify_oas_timeout () =
  check
    bool
    "oas_timeout_budget_loop(count=1) → Oas_timeout_budget"
    true
    (S.classify_error "oas_timeout_budget_loop(count=1)"
     = S.Oas_timeout_budget)
;;

let test_classify_state_machine_guard () =
  check
    bool
    "state machine guard … → State_machine_guard"
    true
    (S.classify_error
       "state machine guard violation: transition not allowed"
     = S.State_machine_guard)
;;

let test_classify_expected_version () =
  check
    bool
    "expected_version mismatch → Expected_version_mismatch"
    true
    (S.classify_error "CAS rejected: expected_version mismatch (saw 12, want 11)"
     = S.Expected_version_mismatch)
;;

let test_classify_unknown_phase () =
  check
    bool
    "unknown phase … → Unknown_phase_transition"
    true
    (S.classify_error "unknown phase transition: Idle → Mystery"
     = S.Unknown_phase_transition)
;;

let test_classify_other () =
  check
    bool
    "novel error → Other (no silent default)"
    true
    (S.classify_error "novel_error_text" = S.Other)
;;

(* error_kind ↔ string round trip: every inhabitant of [all_error_kinds]
   must survive [to_string ∘ of_string]; the inverse must reject the
   empty string instead of collapsing to [Other]. *)
let test_error_kind_round_trip () =
  List.iter
    (fun k ->
      let s = S.error_kind_to_string k in
      match S.error_kind_of_string s with
      | None -> failf "round-trip lost %s" s
      | Some k' ->
        check
          bool
          (Printf.sprintf "round-trip %s" s)
          true
          (S.error_kind_to_string k' = s))
    S.all_error_kinds
;;

let test_error_kind_of_string_unknown_is_none () =
  check (option string) "unknown label → None" None
    (Option.map S.error_kind_to_string (S.error_kind_of_string ""))
;;

(* ─────────────────────────── record dedupe ─────────────────────────── *)

let test_record_first_then_repeated () =
  reset ();
  let err = "sandbox docker exec failed (exit=2): ls: no such file" in
  check
    bool
    "first call → `First"
    true
    (S.record ~keeper:"verifier" ~error:err = `First);
  check
    bool
    "second call same (keeper, error) → `Repeated 2"
    true
    (S.record ~keeper:"verifier" ~error:err = `Repeated 2);
  check
    bool
    "third call same → `Repeated 3"
    true
    (S.record ~keeper:"verifier" ~error:err = `Repeated 3)
;;

let test_record_distinct_keepers_independent () =
  reset ();
  let err = "fiber_unresolved" in
  check
    bool
    "keeper=A first → `First"
    true
    (S.record ~keeper:"A" ~error:err = `First);
  check
    bool
    "keeper=B first → `First (independent of A)"
    true
    (S.record ~keeper:"B" ~error:err = `First);
  check int "cardinality = 2" 2 (S.cardinality ())
;;

let test_record_distinct_errors_independent () =
  reset ();
  check
    bool
    "(A, err1) first → `First"
    true
    (S.record ~keeper:"A" ~error:"err1" = `First);
  check
    bool
    "(A, err2) first → `First (textually distinct)"
    true
    (S.record ~keeper:"A" ~error:"err2" = `First);
  check int "cardinality = 2" 2 (S.cardinality ())
;;

let test_record_ten_in_a_row () =
  reset ();
  let err = "Path syntax blocked: shell quoting ..." in
  let outcomes =
    List.init 10 (fun _ -> S.record ~keeper:"taskmaster" ~error:err)
  in
  let firsts =
    List.length (List.filter (fun o -> o = `First) outcomes)
  in
  let repeats =
    List.length
      (List.filter
         (function
           | `Repeated _ -> true
           | `First -> false)
         outcomes)
  in
  check int "exactly 1 First in 10 calls" 1 firsts;
  check int "exactly 9 Repeated in 10 calls" 9 repeats;
  check int "cardinality stays 1" 1 (S.cardinality ())
;;

let test_classify_outcome_bundles () =
  reset ();
  let err = "sandbox docker exec failed (exit=1)" in
  let kind, outcome = S.classify_outcome ~keeper:"qa-king" ~error:err in
  check bool "kind = Sandbox_docker" true (kind = S.Sandbox_docker);
  check bool "outcome = `First" true (outcome = `First);
  let kind2, outcome2 = S.classify_outcome ~keeper:"qa-king" ~error:err in
  check bool "kind still Sandbox_docker" true (kind2 = S.Sandbox_docker);
  check
    bool
    "outcome bumps to `Repeated 2"
    true
    (outcome2 = `Repeated 2)
;;

let test_reset_for_test_clears_state () =
  reset ();
  let _ = S.record ~keeper:"x" ~error:"y" in
  check int "cardinality = 1 after one record" 1 (S.cardinality ());
  S.reset_for_test ();
  check int "cardinality = 0 after reset" 0 (S.cardinality ());
  check
    bool
    "post-reset is `First again"
    true
    (S.record ~keeper:"x" ~error:"y" = `First)
;;

(* ─────────────────────────── runner ─────────────────────────── *)

let () =
  Alcotest.run
    "Keeper_recording_error_state"
    [ ( "classifier"
      , [ test_case "sandbox docker" `Quick test_classify_sandbox_docker
        ; test_case "path syntax blocked" `Quick test_classify_path_syntax
        ; test_case "stale_turn_timeout" `Quick test_classify_stale_turn
        ; test_case "fiber_unresolved" `Quick test_classify_fiber_unresolved
        ; test_case "oas_timeout_budget" `Quick test_classify_oas_timeout
        ; test_case
            "state machine guard"
            `Quick
            test_classify_state_machine_guard
        ; test_case
            "expected_version mismatch"
            `Quick
            test_classify_expected_version
        ; test_case
            "unknown phase transition"
            `Quick
            test_classify_unknown_phase
        ; test_case "novel → Other" `Quick test_classify_other
        ] )
    ; ( "round_trip"
      , [ test_case "to_string ∘ of_string" `Quick test_error_kind_round_trip
        ; test_case
            "of_string \"\" → None"
            `Quick
            test_error_kind_of_string_unknown_is_none
        ] )
    ; ( "dedupe"
      , [ test_case "First then Repeated" `Quick test_record_first_then_repeated
        ; test_case
            "distinct keepers independent"
            `Quick
            test_record_distinct_keepers_independent
        ; test_case
            "distinct errors independent"
            `Quick
            test_record_distinct_errors_independent
        ; test_case "10 in a row" `Quick test_record_ten_in_a_row
        ; test_case
            "classify_outcome bundles"
            `Quick
            test_classify_outcome_bundles
        ; test_case "reset_for_test" `Quick test_reset_for_test_clears_state
        ] )
    ]
;;
