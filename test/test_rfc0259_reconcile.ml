(** RFC-0259 P2/P3 — grounding reconciler core (pure classify / dry_run /
    reconcile_facts).

    Drives the classifier with a fake [verify_fn] so Confirmed/Contradicted/Unknown
    paths are deterministic. P2 pins classification; P3 pins the retraction
    transform (terminal->drop, open->advance, unknown/fresh->keep). Pins:
    - no external_ref           -> Fresh (never grounded)
    - referenced but in-horizon -> Fresh (not re-checked yet)
    - past horizon, open        -> Stale_open
    - past horizon, terminal    -> Stale_terminal
    - past horizon, unverifiable -> Stale_unknown (never deleted on uncertainty)
    - dry_run aggregates counts and lists only the stale facts, in order. *)

module Types = Masc.Keeper_memory_os_types
module R = Masc.Keeper_memory_os_reconcile

let now = 1_000_000.0
let horizon = 3600.0

let fact ?(external_ref = None) ?last_verified_at ~first_seen claim =
  { Types.claim
  ; category = Types.Fact
  ; external_ref
  ; source = { Types.trace_id = "t"; turn = 1; tool_call_id = None }
  ; observed_by = []
  ; first_seen
  ; valid_until = None
  ; last_verified_at
  ; schema_version = Types.schema_version
  }
;;

let pr id = Some { Types.kind = Types.Pr; id }

(* A fake verifier keyed on id so each test fixes the external state. *)
let verify_const state : R.verify_fn = fun _ref -> state
let verify_by_id table : R.verify_fn =
  fun (r : Types.external_ref) ->
  match List.assoc_opt r.Types.id table with
  | Some s -> s
  | None -> R.Unverifiable
;;

let verdict = Alcotest.testable (fun ppf v -> Format.fprintf ppf "%s" (R.verdict_to_string v)) ( = )

let check_classify name expected ~verify f =
  Alcotest.check verdict name expected (R.classify ~now ~horizon ~verify f)
;;

let test_no_ref_is_fresh () =
  (* old, but no external_ref → never a reconciler concern *)
  check_classify
    "no ref"
    R.Fresh
    ~verify:(verify_const R.Terminal)
    (fact ~first_seen:(now -. 100_000.0) "deployment uses blue-green")
;;

let test_in_horizon_is_fresh () =
  (* referenced, but verified within the horizon → not re-checked (verify must
     not even be consulted; use a verify that would FAIL the test if called) *)
  let verify : R.verify_fn = fun _ -> Alcotest.fail "verify called inside horizon" in
  check_classify
    "in horizon"
    R.Fresh
    ~verify
    (fact ~external_ref:(pr "1") ~last_verified_at:(now -. 10.0) ~first_seen:(now -. 10.0) "PR #1 open")
;;

let test_past_horizon_open () =
  check_classify
    "past horizon, open"
    R.Stale_open
    ~verify:(verify_const R.Still_open)
    (fact ~external_ref:(pr "2") ~last_verified_at:(now -. 100_000.0) ~first_seen:(now -. 100_000.0) "PR #2 open")
;;

let test_past_horizon_terminal () =
  (* the live-store false-fact class: a closed/merged PR backing an in-progress claim *)
  check_classify
    "past horizon, terminal"
    R.Stale_terminal
    ~verify:(verify_const R.Terminal)
    (fact ~external_ref:(pr "21515") ~first_seen:(now -. 100_000.0) "PR #21515 blocked, needs fix")
;;

let test_past_horizon_unknown () =
  (* uncertainty (gh failure / Task kind) is never a contradiction *)
  check_classify
    "past horizon, unverifiable"
    R.Stale_unknown
    ~verify:(verify_const R.Unverifiable)
    (fact ~external_ref:(pr "3") ~first_seen:(now -. 100_000.0) "PR #3 status unknown")
;;

let test_no_last_verified_uses_first_seen () =
  (* last_verified_at = None → first_seen is the reference time *)
  check_classify
    "none last_verified, old first_seen → checked"
    R.Stale_terminal
    ~verify:(verify_const R.Terminal)
    (fact ~external_ref:(pr "4") ~first_seen:(now -. 100_000.0) "PR #4 merged");
  check_classify
    "none last_verified, fresh first_seen → fresh"
    R.Fresh
    ~verify:(verify_const R.Terminal)
    (fact ~external_ref:(pr "5") ~first_seen:(now -. 10.0) "PR #5 just seen")
;;

let test_dry_run_aggregates () =
  let facts =
    [ fact ~first_seen:(now -. 100_000.0) "no ref durable"
    ; fact ~external_ref:(pr "10") ~first_seen:(now -. 100_000.0) "PR #10"
    ; fact ~external_ref:(pr "11") ~first_seen:(now -. 100_000.0) "PR #11"
    ; fact ~external_ref:(pr "12") ~first_seen:(now -. 100_000.0) "PR #12"
    ; fact ~external_ref:(pr "13") ~last_verified_at:(now -. 5.0) ~first_seen:(now -. 5.0) "PR #13 recent"
    ]
  in
  let verify =
    verify_by_id
      [ "10", R.Still_open; "11", R.Terminal; "12", R.Unverifiable; "13", R.Terminal ]
  in
  let report, items = R.dry_run ~now ~horizon ~verify facts in
  Alcotest.(check int) "scanned" 5 report.R.scanned;
  Alcotest.(check int) "stale_open" 1 report.R.stale_open;
  Alcotest.(check int) "stale_terminal" 1 report.R.stale_terminal;
  Alcotest.(check int) "stale_unknown" 1 report.R.stale_unknown;
  (* only the 3 stale facts are listed; the durable and the in-horizon are omitted *)
  Alcotest.(check int) "items length" 3 (List.length items);
  let claims = List.map (fun (f, _) -> f.Types.claim) items in
  Alcotest.(check (list string)) "stale claims in order" [ "PR #10"; "PR #11"; "PR #12" ] claims
;;

(* ---------- P3: reconcile_facts (pure retraction core) ---------- *)

let test_reconcile_retracts_terminal () =
  (* a merged/closed PR backing an in-progress claim is dropped *)
  let facts =
    [ fact ~external_ref:(pr "21515") ~first_seen:(now -. 100_000.0) "PR #21515 blocked, needs fix"
    ; fact ~first_seen:(now -. 100_000.0) "deployment uses blue-green"
    ]
  in
  let survivors, report =
    R.reconcile_facts ~now ~horizon ~verify:(verify_const R.Terminal) facts
  in
  Alcotest.(check int) "scanned" 2 report.R.scanned;
  Alcotest.(check int) "retracted" 1 report.R.retracted;
  Alcotest.(check int) "advanced" 0 report.R.advanced;
  Alcotest.(check int) "kept" 1 report.R.kept;
  (* the durable non-ref claim survives; the terminal ref is gone *)
  Alcotest.(check (list string))
    "only durable survives"
    [ "deployment uses blue-green" ]
    (List.map (fun f -> f.Types.claim) survivors)
;;

let test_reconcile_advances_open () =
  (* a still-open ref is kept, last_verified_at advanced to now *)
  let f =
    fact ~external_ref:(pr "2") ~first_seen:(now -. 100_000.0) "PR #2 in review"
  in
  let survivors, report =
    R.reconcile_facts ~now ~horizon ~verify:(verify_const R.Still_open) [ f ]
  in
  Alcotest.(check int) "advanced" 1 report.R.advanced;
  Alcotest.(check int) "retracted" 0 report.R.retracted;
  (match survivors with
   | [ s ] ->
     Alcotest.(check (option (float 0.001)))
       "last_verified advanced to now"
       (Some now)
       s.Types.last_verified_at
   | _ -> Alcotest.fail "expected exactly one survivor")
;;

let test_reconcile_keeps_unknown_and_fresh () =
  (* uncertainty never deletes; in-horizon and non-ref are untouched *)
  let facts =
    [ fact ~external_ref:(pr "3") ~first_seen:(now -. 100_000.0) "PR #3 unknown state"
    ; fact ~external_ref:(pr "4") ~last_verified_at:(now -. 5.0) ~first_seen:(now -. 5.0) "PR #4 recent"
    ; fact ~first_seen:(now -. 100_000.0) "user prefers concise"
    ]
  in
  let survivors, report =
    R.reconcile_facts ~now ~horizon ~verify:(verify_const R.Unverifiable) facts
  in
  Alcotest.(check int) "nothing retracted" 0 report.R.retracted;
  Alcotest.(check int) "nothing advanced" 0 report.R.advanced;
  Alcotest.(check int) "all kept" 3 report.R.kept;
  Alcotest.(check int) "all survive" 3 (List.length survivors)
;;

let test_reconcile_order_preserved () =
  (* survivors keep input order after a middle retraction *)
  let facts =
    [ fact ~first_seen:(now -. 100_000.0) "A durable"
    ; fact ~external_ref:(pr "21515") ~first_seen:(now -. 100_000.0) "B terminal ref"
    ; fact ~first_seen:(now -. 100_000.0) "C durable"
    ]
  in
  let survivors, _ =
    R.reconcile_facts ~now ~horizon ~verify:(verify_const R.Terminal) facts
  in
  Alcotest.(check (list string))
    "order preserved minus retracted"
    [ "A durable"; "C durable" ]
    (List.map (fun f -> f.Types.claim) survivors)
;;

let () =
  Alcotest.run
    "rfc0259_reconcile"
    [ ( "classify"
      , [ Alcotest.test_case "no-ref-fresh" `Quick test_no_ref_is_fresh
        ; Alcotest.test_case "in-horizon-fresh" `Quick test_in_horizon_is_fresh
        ; Alcotest.test_case "past-open" `Quick test_past_horizon_open
        ; Alcotest.test_case "past-terminal" `Quick test_past_horizon_terminal
        ; Alcotest.test_case "past-unknown" `Quick test_past_horizon_unknown
        ; Alcotest.test_case "ref-time-fallback" `Quick test_no_last_verified_uses_first_seen
        ] )
    ; ("dry_run", [ Alcotest.test_case "aggregates" `Quick test_dry_run_aggregates ])
    ; ( "reconcile_facts"
      , [ Alcotest.test_case "retract-terminal" `Quick test_reconcile_retracts_terminal
        ; Alcotest.test_case "advance-open" `Quick test_reconcile_advances_open
        ; Alcotest.test_case "keep-unknown-fresh" `Quick test_reconcile_keeps_unknown_and_fresh
        ; Alcotest.test_case "order-preserved" `Quick test_reconcile_order_preserved
        ] )
    ]
;;
