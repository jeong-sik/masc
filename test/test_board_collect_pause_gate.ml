(** Regression: a paused keeper must not collect board events.

    [Keeper_heartbeat_loop_board_events.collect_keepalive_board_events] advances
    and acks the per-keeper board cursor as a side effect of collection. A
    keeper that cannot run this cycle must not collect (and advance the cursor),
    or it would step past posts it never processed — silently dropping them with
    no requeue. This pins the pure decision gate [should_collect_board_events]
    that guards that side effect. *)

open Alcotest
module BE = Masc.Keeper_heartbeat_loop_board_events

let gate
      ?(approval_pending = false)
      ?(keeper_backpressured = false)
      ?(provider_cooldown_pending = false)
      ~warm
      ~paused
      ()
  =
  BE.should_collect_board_events
    ~proactive_warmup_elapsed:warm
    ~paused
    ~approval_pending
    ~keeper_backpressured
    ~provider_cooldown_pending

let test_warm_unpaused_collects () =
  check bool "warmed + unpaused keeper collects board events" true
    (gate ~warm:true ~paused:false ())

(* The regression: before the fix, a warmed keeper collected (and advanced the
   cursor) regardless of pause state, dropping board posts for paused keepers. *)
let test_warm_paused_skips () =
  check bool "warmed + PAUSED keeper must not collect (cursor stays put)" false
    (gate ~warm:true ~paused:true ())

let test_cold_unpaused_skips () =
  check bool "not-yet-warmed keeper does not collect" false
    (gate ~warm:false ~paused:false ())

let test_cold_paused_skips () =
  check bool "not-yet-warmed + paused keeper does not collect" false
    (gate ~warm:false ~paused:true ())

let test_warm_approval_pending_skips () =
  check bool
    "warmed + approval-pending keeper must not collect (cursor stays put)"
    false
    (gate ~warm:true ~paused:false ~approval_pending:true ())

let test_warm_keeper_backpressured_skips () =
  check bool
    "warmed + keeper-health-backpressured keeper must not collect"
    false
    (gate ~warm:true ~paused:false ~keeper_backpressured:true ())

let test_warm_provider_cooldown_skips () =
  check bool
    "warmed + provider-cooldown keeper must not collect"
    false
    (gate ~warm:true ~paused:false ~provider_cooldown_pending:true ())

let test_collection_failure_health_degrades_and_clears () =
  let base_path = "/tmp/masc-board-collection-health-test" in
  let keeper_name = "reactive-keeper" in
  BE.For_testing.reset ();
  Fun.protect
    ~finally:BE.For_testing.reset
    (fun () ->
      BE.For_testing.record_collection_failure
        ~base_path
        ~keeper_name
        ~message:"board store unavailable";
      let failed = BE.fleet_health_json ~base_path ~keeper_names:[ keeper_name ] in
      let open Yojson.Safe.Util in
      check string "collection health degraded" "degraded"
        (failed |> member "status" |> to_string);
      check bool "collection health requires operator action" true
        (failed |> member "operator_action_required" |> to_bool);
      check int "failed keeper count" 1
        (failed |> member "failed_keeper_count" |> to_int);
      check bool "failure reason surfaced" true
        (failed |> member "status_reasons" |> to_list
         |> List.map to_string
         |> List.exists (String.equal "board_event_collection_failure"));
      let failure =
        failed |> member "failures" |> to_list |> function
        | [ value ] -> value
        | values -> failf "expected one failure, got %d" (List.length values)
      in
      check string "failure keeper" keeper_name
        (failure |> member "keeper_name" |> to_string);
      check string "failure message" "board store unavailable"
        (failure |> member "last_error_message" |> to_string);
      BE.For_testing.clear_collection_failure ~base_path ~keeper_name;
      let cleared = BE.fleet_health_json ~base_path ~keeper_names:[ keeper_name ] in
      check string "collection health clears after success" "ok"
        (cleared |> member "status" |> to_string);
      check bool "collection health no longer requires action" false
        (cleared |> member "operator_action_required" |> to_bool);
      check int "cleared failed keeper count" 0
        (cleared |> member "failed_keeper_count" |> to_int))

let () =
  run "board_collect_pause_gate"
    [
      ( "should_collect_board_events",
        [
          test_case "warm + unpaused -> collect" `Quick test_warm_unpaused_collects;
          test_case "warm + paused -> skip" `Quick test_warm_paused_skips;
          test_case "cold + unpaused -> skip" `Quick test_cold_unpaused_skips;
          test_case "cold + paused -> skip" `Quick test_cold_paused_skips;
          test_case "warm + approval pending -> skip" `Quick
            test_warm_approval_pending_skips;
          test_case "warm + keeper backpressure -> skip" `Quick
            test_warm_keeper_backpressured_skips;
          test_case "warm + provider cooldown -> skip" `Quick
            test_warm_provider_cooldown_skips;
          test_case "collection failure health degrades and clears" `Quick
            test_collection_failure_health_degrades_and_clears;
        ] );
    ]
