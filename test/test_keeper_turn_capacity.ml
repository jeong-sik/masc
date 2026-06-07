open Alcotest

let set_capacity_limit value =
  Masc.Keeper_config.ensure_runtime_params_init ();
  match Masc.Runtime_params.set_by_key "keeper.turn.capacity_limit" (`Int value) with
  | Ok () -> ()
  | Error msg -> fail ("set capacity limit failed: " ^ msg)
;;

let clear_capacity_limit () =
  match Masc.Runtime_params.clear_by_key "keeper.turn.capacity_limit" with
  | Ok () -> ()
  | Error msg -> fail ("clear capacity limit failed: " ^ msg)
;;

let set_per_keeper_limit value =
  match Masc.Runtime_params.set_by_key "keeper.turn.per_keeper_capacity_limit" (`Int value) with
  | Ok () -> ()
  | Error msg -> fail ("set per-keeper limit failed: " ^ msg)
;;

let clear_per_keeper_limit () =
  match Masc.Runtime_params.clear_by_key "keeper.turn.per_keeper_capacity_limit" with
  | Ok () -> ()
  | Error msg -> fail ("clear per-keeper limit failed: " ^ msg)
;;

let with_limits ~global ~per_keeper f =
  set_capacity_limit global;
  set_per_keeper_limit per_keeper;
  Fun.protect
    ~finally:(fun () -> clear_capacity_limit (); clear_per_keeper_limit ())
    f
;;

let run_eio f = Eio_main.run (fun _env -> f ())

let test_default_capacity_preserves_fleet_gate () =
  Masc.Keeper_config.ensure_runtime_params_init ();
  clear_capacity_limit ();
  check int "default capacity limit" 32 (Masc.Keeper_config.keeper_turn_capacity_limit ())
;;

let test_global_capacity_blocks_nested_turn () =
  run_eio (fun () ->
    with_limits ~global:1 ~per_keeper:0 (fun () ->
      let result =
        Masc.Keeper_turn_capacity.with_turn_capacity
          ~timeout_s:0.001
          ~keeper_name:"keeper-a"
          ~channel:Masc.Keeper_world_observation.Scheduled_autonomous
          (fun ~capacity_wait_ms:_ ->
             let inner =
               Masc.Keeper_turn_capacity.with_turn_capacity
                 ~timeout_s:0.001
                 ~keeper_name:"keeper-b"
                 ~channel:Masc.Keeper_world_observation.Scheduled_autonomous
                 (fun ~capacity_wait_ms:_ -> ())
             in
             match inner with
             | Error { Masc.Keeper_turn_capacity.limit; inflight; _ } ->
               check int "limit" 1 limit;
               check int "inflight" 1 inflight
             | Ok () -> fail "nested turn bypassed global capacity")
      in
      match result with
      | Ok () -> ()
      | Error err ->
        failf
          "first turn unexpectedly rejected limit=%d inflight=%d"
          err.Masc.Keeper_turn_capacity.limit
          err.inflight);
    check int "released" 0 (Masc.Keeper_turn_capacity.inflight_for_test ()))
;;

let test_disabled_capacity_allows_nested_turn () =
  run_eio (fun () ->
    with_limits ~global:0 ~per_keeper:0 (fun () ->
      let result =
        Masc.Keeper_turn_capacity.with_turn_capacity
          ~timeout_s:0.001
          ~keeper_name:"keeper-a"
          ~channel:Masc.Keeper_world_observation.Scheduled_autonomous
          (fun ~capacity_wait_ms:_ ->
             let inner =
               Masc.Keeper_turn_capacity.with_turn_capacity
                 ~timeout_s:0.001
                 ~keeper_name:"keeper-b"
                 ~channel:Masc.Keeper_world_observation.Scheduled_autonomous
                 (fun ~capacity_wait_ms:_ -> ())
             in
             match inner with
             | Ok () -> ()
             | Error err ->
               failf
                 "nested turn rejected while disabled limit=%d inflight=%d"
                 err.Masc.Keeper_turn_capacity.limit
                 err.inflight)
      in
      match result with
      | Ok () -> ()
      | Error err ->
        failf
          "first turn rejected while disabled limit=%d inflight=%d"
          err.Masc.Keeper_turn_capacity.limit
          err.inflight);
    check int "disabled does not leak" 0 (Masc.Keeper_turn_capacity.inflight_for_test ()))
;;

(* Per-keeper capacity tests *)

let test_per_keeper_blocks_second_concurrent_turn () =
  run_eio (fun () ->
    with_limits ~global:32 ~per_keeper:1 (fun () ->
      let result =
        Masc.Keeper_turn_capacity.with_turn_capacity
          ~timeout_s:0.001
          ~keeper_name:"keeper-a"
          ~channel:Masc.Keeper_world_observation.Scheduled_autonomous
          (fun ~capacity_wait_ms:_ ->
             let inner =
               Masc.Keeper_turn_capacity.with_turn_capacity
                 ~timeout_s:0.001
                 ~keeper_name:"keeper-a"
                 ~channel:Masc.Keeper_world_observation.Scheduled_autonomous
                 (fun ~capacity_wait_ms:_ -> ())
             in
             match inner with
             | Error { per_keeper_limit; per_keeper_inflight; _ } ->
               check int "per_keeper_limit" 1 per_keeper_limit;
               check int "per_keeper_inflight" 1 per_keeper_inflight
             | Ok () ->
               fail "same keeper got a second concurrent turn despite per-keeper limit=1")
      in
      match result with
      | Ok () -> ()
      | Error err ->
        failf
          "first turn unexpectedly rejected limit=%d inflight=%d"
          err.Masc.Keeper_turn_capacity.limit
          err.inflight);
    check int "global released" 0 (Masc.Keeper_turn_capacity.inflight_for_test ());
    check int "per-keeper released" 0
      (Masc.Keeper_turn_capacity.per_keeper_inflight_for_test "keeper-a"))
;;

let test_per_keeper_allows_different_keepers () =
  run_eio (fun () ->
    with_limits ~global:32 ~per_keeper:1 (fun () ->
      let result =
        Masc.Keeper_turn_capacity.with_turn_capacity
          ~timeout_s:0.001
          ~keeper_name:"keeper-a"
          ~channel:Masc.Keeper_world_observation.Scheduled_autonomous
          (fun ~capacity_wait_ms:_ ->
             let inner =
               Masc.Keeper_turn_capacity.with_turn_capacity
                 ~timeout_s:0.001
                 ~keeper_name:"keeper-b"
                 ~channel:Masc.Keeper_world_observation.Scheduled_autonomous
                 (fun ~capacity_wait_ms:_ -> ())
             in
             match inner with
             | Ok () -> ()
             | Error err ->
               failf
                 "different keeper rejected despite per-keeper limit per_keeper_inflight=%d \
                  per_keeper_limit=%d"
                 err.per_keeper_inflight
                 err.per_keeper_limit)
      in
      match result with
      | Ok () -> ()
      | Error err ->
        failf
          "first turn rejected limit=%d inflight=%d"
          err.Masc.Keeper_turn_capacity.limit
          err.inflight);
    check int "all released" 0 (Masc.Keeper_turn_capacity.inflight_for_test ()))
;;

let test_per_keeper_disabled_allows_multiple () =
  run_eio (fun () ->
    with_limits ~global:32 ~per_keeper:0 (fun () ->
      let result =
        Masc.Keeper_turn_capacity.with_turn_capacity
          ~timeout_s:0.001
          ~keeper_name:"keeper-a"
          ~channel:Masc.Keeper_world_observation.Scheduled_autonomous
          (fun ~capacity_wait_ms:_ ->
             let inner =
               Masc.Keeper_turn_capacity.with_turn_capacity
                 ~timeout_s:0.001
                 ~keeper_name:"keeper-a"
                 ~channel:Masc.Keeper_world_observation.Scheduled_autonomous
                 (fun ~capacity_wait_ms:_ -> ())
             in
             match inner with
             | Ok () -> ()
             | Error err ->
               failf
                 "rejected while per-keeper disabled per_keeper_inflight=%d"
                 err.per_keeper_inflight)
      in
      match result with
      | Ok () -> ()
      | Error err ->
        failf
          "first turn rejected while per-keeper disabled limit=%d"
          err.Masc.Keeper_turn_capacity.limit);
    check int "no leak" 0 (Masc.Keeper_turn_capacity.inflight_for_test ()))
;;

let () =
  run
    "keeper_turn_capacity"
    [ ( "global gate"
      , [ test_case "default capacity is enabled" `Quick test_default_capacity_preserves_fleet_gate
        ; test_case "blocks nested turn at cap" `Quick test_global_capacity_blocks_nested_turn
        ; test_case "disabled gate allows nested turn" `Quick test_disabled_capacity_allows_nested_turn
        ] )
    ; ( "per-keeper gate"
      , [ test_case "blocks second concurrent turn for same keeper"
            `Quick test_per_keeper_blocks_second_concurrent_turn
        ; test_case "allows different keepers concurrently"
            `Quick test_per_keeper_allows_different_keepers
        ; test_case "disabled per-keeper allows multiple"
            `Quick test_per_keeper_disabled_allows_multiple
        ] )
    ]
