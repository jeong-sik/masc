(** Regression tests for per-runtime autonomous queue lane isolation.

    Background: the autonomous FIFO wait queue was a single global structure.
    When a slow runtime (deepseek-v4-flash, ~900s turns) held the head,
    all keepers behind it—including fast runtimes (GLM, ~180s)—timed out
    at the 180s semaphore_wait_timeout. This is classic head-of-line blocking.

    Fix: per-runtime FIFO lanes keyed by runtime_id string. Each runtime
    gets its own queue; a slow head no longer blocks fast runtimes in
    other lanes. The shared autonomous_turn_semaphore (16 permits) still
    provides global concurrency control.

    These tests exercise:
    - Lane isolation: fast lane not blocked by slow lane head
    - FIFO within lane: ordering preserved within the same runtime
    - Depth aggregation: global depth sums across all lanes
    - Cross-lane drop: ticket_lane reverse index works correctly
    - Runtime ID in waiter record: preserved through enqueue/drop *)

module KK = Masc.Keeper_keepalive

(** Reset all lane state between tests. *)
let with_fresh_lanes test_body () =
  Eio_main.run @@ fun _env ->
    KK.reset_autonomous_turn_queue_for_test ();
    test_body ()
;;

(* --------------------------------------------------------------------------
   Lane isolation: slow lane does not block fast lane
   -------------------------------------------------------------------------- *)

let test_slow_lane_does_not_block_fast_lane () =
  (* Enqueue a "slow-runtime" keeper, then a "fast-runtime" keeper.
     The fast keeper is immediately at the head of its own lane —
     it does NOT wait behind the slow keeper. *)
  let _slow_ticket =
    KK.enqueue_autonomous_waiter_for_test ~runtime_id:"deepseek" "slow-keeper"
  in
  let fast_ticket =
    KK.enqueue_autonomous_waiter_for_test ~runtime_id:"glm" "fast-keeper"
  in
  (* Fast keeper is head of the "glm" lane immediately. *)
  let fast_head =
    match KK.autonomous_waiter_head_ticket_for_test ~runtime_id:"glm" with
    | Some t -> t
    | None -> Alcotest.fail "fast lane should have a head"
  in
  Alcotest.(check int) "fast lane head = fast_ticket" fast_ticket fast_head;
  (* Slow keeper is head of the "deepseek" lane. *)
  let slow_head =
    match KK.autonomous_waiter_head_ticket_for_test ~runtime_id:"deepseek" with
    | Some t -> t
    | None -> Alcotest.fail "slow lane should have a head"
  in
  Alcotest.(check bool) "slow head != fast head" true (slow_head <> fast_head);
  (* Cleanup. *)
  KK.drop_autonomous_waiter_for_test _slow_ticket;
  KK.drop_autonomous_waiter_for_test fast_ticket
;;

(* --------------------------------------------------------------------------
   FIFO within lane: ordering preserved
   -------------------------------------------------------------------------- *)

let test_fifo_ordering_within_lane () =
  let t1 =
    KK.enqueue_autonomous_waiter_for_test ~runtime_id:"glm" "keeper-a"
  in
  let t2 =
    KK.enqueue_autonomous_waiter_for_test ~runtime_id:"glm" "keeper-b"
  in
  let t3 =
    KK.enqueue_autonomous_waiter_for_test ~runtime_id:"glm" "keeper-c"
  in
  (* Head of "glm" lane is the first enqueued. *)
  (match KK.autonomous_waiter_head_ticket_for_test ~runtime_id:"glm" with
   | Some h -> Alcotest.(check int) "head = t1" t1 h
   | None -> Alcotest.fail "glm lane should have a head");
  (* Drop t1, head advances to t2. *)
  KK.drop_autonomous_waiter_for_test t1;
  (match KK.autonomous_waiter_head_ticket_for_test ~runtime_id:"glm" with
   | Some h -> Alcotest.(check int) "head = t2 after drop t1" t2 h
   | None -> Alcotest.fail "glm lane should still have a head after drop");
  (* Drop t2, head advances to t3. *)
  KK.drop_autonomous_waiter_for_test t2;
  (match KK.autonomous_waiter_head_ticket_for_test ~runtime_id:"glm" with
   | Some h -> Alcotest.(check int) "head = t3 after drop t2" t3 h
   | None -> Alcotest.fail "glm lane should still have a head after drop t2");
  KK.drop_autonomous_waiter_for_test t3
;;

(* --------------------------------------------------------------------------
   Tombstone pruning within lane
   -------------------------------------------------------------------------- *)

let test_tombstone_does_not_block_lane_head () =
  let t1 =
    KK.enqueue_autonomous_waiter_for_test ~runtime_id:"glm" "keeper-a"
  in
  let t2 =
    KK.enqueue_autonomous_waiter_for_test ~runtime_id:"glm" "keeper-b"
  in
  (* Tombstone t1 (middle dequeue). *)
  KK.drop_autonomous_waiter_for_test t1;
  (* Head should advance to t2 after pruning. *)
  (match KK.autonomous_waiter_head_ticket_for_test ~runtime_id:"glm" with
   | Some h -> Alcotest.(check int) "head = t2 after tombstone t1" t2 h
   | None -> Alcotest.fail "glm lane should have t2 as head after tombstone");
  KK.drop_autonomous_waiter_for_test t2
;;

(* --------------------------------------------------------------------------
   Depth aggregation across lanes
   -------------------------------------------------------------------------- *)

let test_depth_aggregation () =
  Alcotest.(check int) "empty depth" 0 (KK.autonomous_wait_queue_depth_for_test ());
  let t1 =
    KK.enqueue_autonomous_waiter_for_test ~runtime_id:"glm" "glm-keeper"
  in
  Alcotest.(check int) "depth=1 after one enqueue" 1
    (KK.autonomous_wait_queue_depth_for_test ());
  let t2 =
    KK.enqueue_autonomous_waiter_for_test ~runtime_id:"deepseek" "deepseek-keeper"
  in
  Alcotest.(check int) "depth=2 after two lanes" 2
    (KK.autonomous_wait_queue_depth_for_test ());
  let t3 =
    KK.enqueue_autonomous_waiter_for_test ~runtime_id:"glm" "glm-keeper-2"
  in
  Alcotest.(check int) "depth=3 after second glm enqueue" 3
    (KK.autonomous_wait_queue_depth_for_test ());
  KK.drop_autonomous_waiter_for_test t1;
  Alcotest.(check int) "depth=2 after drop" 2
    (KK.autonomous_wait_queue_depth_for_test ());
  KK.drop_autonomous_waiter_for_test t2;
  KK.drop_autonomous_waiter_for_test t3;
  Alcotest.(check int) "depth=0 after all drops" 0
    (KK.autonomous_wait_queue_depth_for_test ())
;;

(* --------------------------------------------------------------------------
   Cross-lane drop via ticket_lane reverse index
   -------------------------------------------------------------------------- *)

let test_cross_lane_drop () =
  let t_slow =
    KK.enqueue_autonomous_waiter_for_test ~runtime_id:"deepseek" "slow-keeper"
  in
  let t_fast =
    KK.enqueue_autonomous_waiter_for_test ~runtime_id:"glm" "fast-keeper"
  in
  (* Drop the slow keeper — should use ticket_lane to find "deepseek" lane. *)
  KK.drop_autonomous_waiter_for_test t_slow;
  (* "deepseek" lane should be empty now. *)
  (match KK.autonomous_waiter_head_ticket_for_test ~runtime_id:"deepseek" with
   | None -> ()
   | Some _ -> Alcotest.fail "deepseek lane should be empty after drop");
  (* "glm" lane should still have the fast keeper. *)
  (match KK.autonomous_waiter_head_ticket_for_test ~runtime_id:"glm" with
   | Some h -> Alcotest.(check int) "glm head intact" t_fast h
   | None -> Alcotest.fail "glm lane should still have fast-keeper");
  KK.drop_autonomous_waiter_for_test t_fast
;;

(* --------------------------------------------------------------------------
   Empty lane returns None for head
   -------------------------------------------------------------------------- *)

let test_empty_lane_head_is_none () =
  (match KK.autonomous_waiter_head_ticket_for_test ~runtime_id:"nonexistent" with
   | None -> ()
   | Some _ -> Alcotest.fail "nonexistent lane should have no head")
;;

(* --------------------------------------------------------------------------
   Waiter snapshot aggregates across lanes
   -------------------------------------------------------------------------- *)

let test_snapshot_cross_lane () =
  let _t1 =
    KK.enqueue_autonomous_waiter_for_test ~runtime_id:"deepseek" "slow-keeper"
  in
  let _t2 =
    KK.enqueue_autonomous_waiter_for_test ~runtime_id:"glm" "fast-keeper"
  in
  let snapshot = KK.autonomous_waiter_snapshot_for_test () in
  (* Snapshot should contain both keepers, order is lane-iteration order. *)
  let has_slow = List.exists (fun n -> String.equal n "slow-keeper") snapshot in
  let has_fast = List.exists (fun n -> String.equal n "fast-keeper") snapshot in
  Alcotest.(check bool) "snapshot has slow-keeper" true has_slow;
  Alcotest.(check bool) "snapshot has fast-keeper" true has_fast;
  Alcotest.(check int) "snapshot length = 2" 2 (List.length snapshot)
;;

(* --------------------------------------------------------------------------
   Suite
   -------------------------------------------------------------------------- *)

let () =
  Alcotest.run
    "keeper_turn_slot_lane_isolation"
    [ ( "lane_isolation"
      , [ Alcotest.test_case "slow does not block fast" `Quick
             (with_fresh_lanes test_slow_lane_does_not_block_fast_lane)
        ] )
    ; ( "fifo_within_lane"
      , [ Alcotest.test_case "ordering preserved" `Quick
             (with_fresh_lanes test_fifo_ordering_within_lane)
        ] )
    ; ( "tombstone"
      , [ Alcotest.test_case "tombstone pruning" `Quick
             (with_fresh_lanes test_tombstone_does_not_block_lane_head)
        ] )
    ; ( "depth"
      , [ Alcotest.test_case "aggregation across lanes" `Quick
             (with_fresh_lanes test_depth_aggregation)
        ] )
    ; ( "cross_lane_drop"
      , [ Alcotest.test_case "ticket reverse index" `Quick
             (with_fresh_lanes test_cross_lane_drop)
        ] )
    ; ( "empty_lane"
      , [ Alcotest.test_case "head is None" `Quick
             (with_fresh_lanes test_empty_lane_head_is_none)
        ] )
    ; ( "snapshot"
      , [ Alcotest.test_case "cross-lane aggregation" `Quick
             (with_fresh_lanes test_snapshot_cross_lane)
        ] )
    ]
;;
