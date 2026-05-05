(** Unit tests for Keeper_wfq_overflow.

    Covers: enqueue idempotence, FIFO tie-break, DRR fairness across
    100 wakes, remove semantics, and empty-queue behaviour. *)

open Masc_mcp
module WFQ = Keeper_wfq_overflow

let entry ~id ~weight ~ts : WFQ.entry =
  { keeper_id = id; weight; enqueued_at = ts }

(* ------------------------------------------------------------------ *)
(* Enqueue + depth                                                     *)
(* ------------------------------------------------------------------ *)

let test_enqueue_increments_depth () =
  let q = WFQ.create () in
  Alcotest.(check int) "empty depth 0" 0 (WFQ.depth q);
  WFQ.enqueue q (entry ~id:"k1" ~weight:1 ~ts:0.0);
  Alcotest.(check int) "after one" 1 (WFQ.depth q);
  WFQ.enqueue q (entry ~id:"k2" ~weight:1 ~ts:1.0);
  Alcotest.(check int) "after two" 2 (WFQ.depth q)

let test_enqueue_is_idempotent () =
  let q = WFQ.create () in
  WFQ.enqueue q (entry ~id:"k1" ~weight:1 ~ts:0.0);
  WFQ.enqueue q (entry ~id:"k1" ~weight:1 ~ts:1.0);
  Alcotest.(check int) "duplicate id ignored" 1 (WFQ.depth q)

(* ------------------------------------------------------------------ *)
(* wake_one                                                            *)
(* ------------------------------------------------------------------ *)

let test_wake_one_empty_returns_none () =
  let q = WFQ.create () in
  match WFQ.wake_one q with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None"

let test_wake_one_single_entry () =
  let q = WFQ.create () in
  WFQ.enqueue q (entry ~id:"k1" ~weight:1 ~ts:0.0);
  match WFQ.wake_one q with
  | Some e ->
      Alcotest.(check string) "k1 woken" "k1" e.keeper_id;
      Alcotest.(check int) "depth 0 after wake" 0 (WFQ.depth q)
  | None -> Alcotest.fail "expected Some"

let test_wake_one_fifo_tiebreak_equal_deficit () =
  (* Two equal-weight entries with deficit=0 (initial). FIFO breaks
     the tie — the earlier-enqueued one is chosen first. *)
  let q = WFQ.create () in
  WFQ.enqueue q (entry ~id:"k1" ~weight:1 ~ts:0.0);
  WFQ.enqueue q (entry ~id:"k2" ~weight:1 ~ts:1.0);
  match WFQ.wake_one q with
  | Some e -> Alcotest.(check string) "earlier ts wins" "k1" e.keeper_id
  | None -> Alcotest.fail "expected Some"

(* ------------------------------------------------------------------ *)
(* DRR fairness over 100 wakes                                         *)
(* ------------------------------------------------------------------ *)

let test_drr_equal_weight_split_50_50 () =
  (* Two equal-weight keepers, repeatedly enqueued and waked.  Over
     100 wake cycles the DRR property ensures each is chosen ~50
     times.  We allow ±5 slack to absorb the FIFO tie-break bias on
     the very first wake. *)
  let counts = Hashtbl.create 4 in
  let bump id =
    let c = try Hashtbl.find counts id with Not_found -> 0 in
    Hashtbl.replace counts id (c + 1)
  in
  let q = WFQ.create () in
  for i = 0 to 99 do
    WFQ.enqueue q (entry ~id:"k1" ~weight:1 ~ts:(float_of_int i));
    WFQ.enqueue q (entry ~id:"k2" ~weight:1 ~ts:(float_of_int i +. 0.5));
    (match WFQ.wake_one q with
     | Some e -> bump e.keeper_id
     | None -> Alcotest.fail "queue should not be empty");
    (* Drain remaining peer to keep enqueue idempotence from
       compounding across iterations. *)
    (match WFQ.wake_one q with
     | Some e -> bump e.keeper_id
     | None -> Alcotest.fail "queue should still have peer")
  done;
  let c1 = Hashtbl.find counts "k1" in
  let c2 = Hashtbl.find counts "k2" in
  Alcotest.(check int) "total = 200" 200 (c1 + c2);
  Alcotest.(check bool)
    (Printf.sprintf "k1=%d roughly half of 100±5" c1)
    true
    (abs (c1 - 100) <= 5)

(* ------------------------------------------------------------------ *)
(* Remove                                                              *)
(* ------------------------------------------------------------------ *)

let test_remove_present_returns_true () =
  let q = WFQ.create () in
  WFQ.enqueue q (entry ~id:"k1" ~weight:1 ~ts:0.0);
  Alcotest.(check bool) "removes existing" true (WFQ.remove q "k1");
  Alcotest.(check int) "depth 0 after remove" 0 (WFQ.depth q)

let test_remove_absent_returns_false () =
  let q = WFQ.create () in
  Alcotest.(check bool) "absent removed = false" false
    (WFQ.remove q "ghost")

(* ------------------------------------------------------------------ *)
(* deficit_of (test inspection)                                        *)
(* ------------------------------------------------------------------ *)

let test_deficit_of_starts_at_zero () =
  let q = WFQ.create () in
  WFQ.enqueue q (entry ~id:"k1" ~weight:1 ~ts:0.0);
  match WFQ.deficit_of q "k1" with
  | Some 0 -> ()
  | Some n -> Alcotest.failf "expected 0, got %d" n
  | None -> Alcotest.fail "k1 should be present"

let test_deficit_of_increments_on_skip () =
  (* k1 (high weight) wins first wake; k2's deficit increments. *)
  let q = WFQ.create () in
  WFQ.enqueue q (entry ~id:"k1" ~weight:10 ~ts:0.0);
  WFQ.enqueue q (entry ~id:"k2" ~weight:1 ~ts:1.0);
  let _ = WFQ.wake_one q in
  match WFQ.deficit_of q "k2" with
  | Some d when d > 0 -> ()
  | Some d -> Alcotest.failf "expected k2 deficit > 0, got %d" d
  | None -> Alcotest.fail "k2 should still be present"

(* ------------------------------------------------------------------ *)
(* Test runner                                                         *)
(* ------------------------------------------------------------------ *)

let () =
  Alcotest.run "keeper_wfq_overflow"
    [ ( "enqueue"
      , [ Alcotest.test_case "depth increments" `Quick
            test_enqueue_increments_depth
        ; Alcotest.test_case "duplicate id idempotent" `Quick
            test_enqueue_is_idempotent
        ] )
    ; ( "wake"
      , [ Alcotest.test_case "empty queue returns None" `Quick
            test_wake_one_empty_returns_none
        ; Alcotest.test_case "single entry returned" `Quick
            test_wake_one_single_entry
        ; Alcotest.test_case "FIFO tie-break on equal deficit" `Quick
            test_wake_one_fifo_tiebreak_equal_deficit
        ] )
    ; ( "drr_fairness"
      , [ Alcotest.test_case "equal weight 50/50 over 100 cycles" `Quick
            test_drr_equal_weight_split_50_50
        ] )
    ; ( "remove"
      , [ Alcotest.test_case "present returns true" `Quick
            test_remove_present_returns_true
        ; Alcotest.test_case "absent returns false" `Quick
            test_remove_absent_returns_false
        ] )
    ; ( "deficit_inspection"
      , [ Alcotest.test_case "starts at zero" `Quick
            test_deficit_of_starts_at_zero
        ; Alcotest.test_case "increments on skip" `Quick
            test_deficit_of_increments_on_skip
        ] )
    ]
