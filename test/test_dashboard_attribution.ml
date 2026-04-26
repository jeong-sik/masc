(** Tests for [Dashboard_attribution].

    Ring-buffer semantics: cap enforcement, newest-first ordering, gate
    filter, summary outcome counts, reset. *)

module DA = Masc_mcp.Dashboard_attribution
module A = Masc_mcp.Attribution

let ev = `Null
let pass gate = A.passed ~origin:Det ~gate ~evidence:ev
let fail_ gate reason = A.policy_failed ~origin:Det ~gate ~evidence:ev ~reason

let blocked gate =
  A.transition_blocked
    ~origin:Det
    ~gate
    ~evidence:ev
    ~from_state:"A"
    ~to_state:"B"
    ~reason:"denied"
;;

let partial gate =
  A.partial_pass ~origin:NonDet ~gate ~evidence:ev ~score:0.7 ~rationale:"meh"
;;

let setup () = DA.reset ()

(* --- record + recent basics --- *)

let test_record_then_recent () =
  setup ();
  DA.record (pass "cdal_verdict");
  let xs = DA.recent ~gate:"cdal_verdict" () in
  Alcotest.(check int) "1 event" 1 (List.length xs)
;;

let test_unknown_gate_returns_empty () =
  setup ();
  DA.record (pass "cdal_verdict");
  Alcotest.(check int) "unknown gate" 0 (List.length (DA.recent ~gate:"nope" ()))
;;

(* --- cap enforcement --- *)

let test_cap_enforced () =
  setup ();
  let total = DA.per_gate_cap + 50 in
  for _ = 1 to total do
    DA.record (pass "verification")
  done;
  let xs = DA.recent ~gate:"verification" ~limit:1_000 () in
  Alcotest.(check int) "cap enforced" DA.per_gate_cap (List.length xs)
;;

(* --- newest-first ordering --- *)

let test_newest_first () =
  setup ();
  DA.record (pass "g");
  Unix.sleepf 0.002;
  DA.record (fail_ "g" "r2");
  let xs = DA.recent ~gate:"g" () in
  match xs with
  | (a1, _) :: (a2, _) :: _ ->
    Alcotest.(check string)
      "newest outcome"
      "policy_failed"
      (match a1.outcome with
       | A.Policy_failed _ -> "policy_failed"
       | _ -> "other");
    Alcotest.(check string)
      "older outcome"
      "passed"
      (match a2.outcome with
       | A.Passed -> "passed"
       | _ -> "other")
  | _ -> Alcotest.fail "expected ≥2 events"
;;

(* --- gate filter --- *)

let test_gate_filter () =
  setup ();
  DA.record (pass "a");
  DA.record (pass "a");
  DA.record (pass "b");
  Alcotest.(check int) "gate a" 2 (List.length (DA.recent ~gate:"a" ()));
  Alcotest.(check int) "gate b" 1 (List.length (DA.recent ~gate:"b" ()))
;;

let test_cross_gate_merge () =
  setup ();
  DA.record (pass "a");
  DA.record (pass "b");
  DA.record (pass "c");
  Alcotest.(check int) "merged" 3 (List.length (DA.recent ()))
;;

let test_limit_zero () =
  setup ();
  DA.record (pass "a");
  Alcotest.(check int)
    "limit=0 yields empty"
    0
    (List.length (DA.recent ~gate:"a" ~limit:0 ()))
;;

let test_negative_limit_treated_as_zero () =
  setup ();
  DA.record (pass "a");
  Alcotest.(check int)
    "negative clamped"
    0
    (List.length (DA.recent ~gate:"a" ~limit:(-5) ()))
;;

(* --- summary --- *)

let test_summary_outcome_counts () =
  setup ();
  DA.record (pass "g");
  DA.record (pass "g");
  DA.record (fail_ "g" "r");
  DA.record (blocked "g");
  DA.record (partial "g");
  let s = DA.summary () in
  match List.find_opt (fun (x : DA.gate_summary) -> x.gate = "g") s with
  | None -> Alcotest.fail "gate g missing from summary"
  | Some r ->
    Alcotest.(check int) "passed" 2 r.passed;
    Alcotest.(check int) "policy_failed" 1 r.policy_failed;
    Alcotest.(check int) "transition_blocked" 1 r.transition_blocked;
    Alcotest.(check int) "partial_pass" 1 r.partial_pass;
    Alcotest.(check int) "total" 5 r.total
;;

let test_summary_multi_gate () =
  setup ();
  DA.record (pass "a");
  DA.record (pass "b");
  Alcotest.(check int) "two gates" 2 (List.length (DA.summary ()))
;;

(* --- reset --- *)

let test_reset_clears () =
  setup ();
  DA.record (pass "g");
  DA.reset ();
  Alcotest.(check int) "empty after reset" 0 (List.length (DA.recent ()));
  Alcotest.(check int) "summary empty" 0 (List.length (DA.summary ()))
;;

let () =
  Alcotest.run
    "Dashboard_attribution"
    [ ( "record_recent"
      , [ Alcotest.test_case "record + recent" `Quick test_record_then_recent
        ; Alcotest.test_case "unknown gate" `Quick test_unknown_gate_returns_empty
        ; Alcotest.test_case "newest-first ordering" `Quick test_newest_first
        ; Alcotest.test_case "limit=0" `Quick test_limit_zero
        ; Alcotest.test_case "negative limit" `Quick test_negative_limit_treated_as_zero
        ] )
    ; "cap", [ Alcotest.test_case "per-gate cap" `Quick test_cap_enforced ]
    ; ( "gate_filter"
      , [ Alcotest.test_case "gate filter" `Quick test_gate_filter
        ; Alcotest.test_case "cross-gate merge" `Quick test_cross_gate_merge
        ] )
    ; ( "summary"
      , [ Alcotest.test_case "outcome counts" `Quick test_summary_outcome_counts
        ; Alcotest.test_case "multi-gate rows" `Quick test_summary_multi_gate
        ] )
    ; "reset", [ Alcotest.test_case "reset clears" `Quick test_reset_clears ]
    ]
;;
