open Alcotest

let set_slot_pool_size value =
  match Masc.Runtime_params.set_by_key "keeper.turn.slot_pool_size" (`Int value) with
  | Ok () -> ()
  | Error msg -> fail ("set slot pool size failed: " ^ msg)
;;

let clear_slot_pool_size () =
  match Masc.Runtime_params.clear_by_key "keeper.turn.slot_pool_size" with
  | Ok () -> ()
  | Error msg -> fail ("clear slot pool size failed: " ^ msg)
;;

let with_slot_pool_size value f =
  set_slot_pool_size value;
  Fun.protect ~finally:clear_slot_pool_size f
;;

let run_eio f = Eio_main.run (fun _env -> f ())

let test_global_capacity_blocks_nested_turn () =
  run_eio (fun () ->
    with_slot_pool_size 1 (fun () ->
      match
        Masc.Keeper_turn_capacity.with_turn_capacity
          ~timeout_s:0.001
          ~keeper_name:"keeper-a"
          ~channel:Masc.Keeper_world_observation.Scheduled_autonomous
          (fun ~capacity_wait_ms:_ ->
             Masc.Keeper_turn_capacity.with_turn_capacity
               ~timeout_s:0.001
               ~keeper_name:"keeper-b"
               ~channel:Masc.Keeper_world_observation.Scheduled_autonomous
               (fun ~capacity_wait_ms:_ -> ()))
      with
      | Ok (Error { Masc.Keeper_turn_capacity.limit; inflight; _ }) ->
        check int "limit" 1 limit;
        check int "inflight" 1 inflight
      | Ok (Ok ()) -> fail "nested turn bypassed global capacity"
      | Error err ->
        failf
          "first turn unexpectedly rejected limit=%d inflight=%d"
          err.Masc.Keeper_turn_capacity.limit
          err.inflight);
    check int "released" 0 (Masc.Keeper_turn_capacity.inflight_for_test ()))
;;

let test_disabled_capacity_allows_nested_turn () =
  run_eio (fun () ->
    with_slot_pool_size 0 (fun () ->
      match
        Masc.Keeper_turn_capacity.with_turn_capacity
          ~timeout_s:0.001
          ~keeper_name:"keeper-a"
          ~channel:Masc.Keeper_world_observation.Scheduled_autonomous
          (fun ~capacity_wait_ms:_ ->
             Masc.Keeper_turn_capacity.with_turn_capacity
               ~timeout_s:0.001
               ~keeper_name:"keeper-b"
               ~channel:Masc.Keeper_world_observation.Scheduled_autonomous
               (fun ~capacity_wait_ms:_ -> ()))
      with
      | Ok (Ok ()) -> ()
      | Ok (Error err) ->
        failf
          "nested turn rejected while disabled limit=%d inflight=%d"
          err.Masc.Keeper_turn_capacity.limit
          err.inflight
      | Error err ->
        failf
          "first turn rejected while disabled limit=%d inflight=%d"
          err.Masc.Keeper_turn_capacity.limit
          err.inflight);
    check int "disabled does not leak" 0 (Masc.Keeper_turn_capacity.inflight_for_test ()))
;;

let () =
  run
    "keeper_turn_capacity"
    [ ( "global gate"
      , [ test_case "blocks nested turn at cap" `Quick test_global_capacity_blocks_nested_turn
        ; test_case "disabled gate allows nested turn" `Quick test_disabled_capacity_allows_nested_turn
        ] )
    ]
