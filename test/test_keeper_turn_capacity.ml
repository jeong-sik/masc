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

let with_capacity_limit value f =
  Masc.Keeper_turn_capacity.reset_for_test ();
  set_capacity_limit value;
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_turn_capacity.reset_for_test ();
      clear_capacity_limit ())
    f
;;

let run_eio f = Eio_main.run (fun _env -> f ())

let test_global_capacity_blocks_nested_turn () =
  run_eio (fun () ->
    with_capacity_limit 1 (fun () ->
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
    with_capacity_limit 0 (fun () ->
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

let test_force_release_does_not_double_release_later_turn () =
  run_eio (fun () ->
    with_capacity_limit 2 (fun () ->
      Eio.Switch.run (fun sw ->
        let b_entered, b_entered_resolver = Eio.Promise.create () in
        let b_can_finish, b_can_finish_resolver = Eio.Promise.create () in
        let b_done, b_done_resolver = Eio.Promise.create () in
        let body_a () =
          check int "a acquired" 1 (Masc.Keeper_turn_capacity.inflight_for_test ());
          check int "force released a" 1
            (Masc.Keeper_turn_capacity.force_release_for_keeper ~keeper_name:"keeper-a");
          check int "a force release clears inflight" 0
            (Masc.Keeper_turn_capacity.inflight_for_test ());
          Eio.Fiber.fork ~sw (fun () ->
            (match
               Masc.Keeper_turn_capacity.with_turn_capacity
                 ~timeout_s:0.001
                 ~keeper_name:"keeper-b"
                 ~channel:Masc.Keeper_world_observation.Scheduled_autonomous
                 (fun ~capacity_wait_ms:_ ->
                    Eio.Promise.resolve b_entered_resolver ();
                    Eio.Promise.await b_can_finish)
             with
             | Ok () -> ()
             | Error err ->
               failf
                 "keeper-b unexpectedly rejected limit=%d inflight=%d"
                 err.Masc.Keeper_turn_capacity.limit
                 err.inflight);
            Eio.Promise.resolve b_done_resolver ());
          Eio.Promise.await b_entered;
          check int "b acquired while a body still active" 1
            (Masc.Keeper_turn_capacity.inflight_for_test ())
        in
        (match
           Masc.Keeper_turn_capacity.with_turn_capacity
             ~timeout_s:0.001
             ~keeper_name:"keeper-a"
             ~channel:Masc.Keeper_world_observation.Scheduled_autonomous
             (fun ~capacity_wait_ms:_ -> body_a ())
         with
         | Ok () -> ()
         | Error err ->
           failf
             "keeper-a unexpectedly rejected limit=%d inflight=%d"
             err.Masc.Keeper_turn_capacity.limit
             err.inflight);
        check int "a finalizer did not release b" 1
          (Masc.Keeper_turn_capacity.inflight_for_test ());
        Eio.Promise.resolve b_can_finish_resolver ();
        Eio.Promise.await b_done;
        check int "all released" 0 (Masc.Keeper_turn_capacity.inflight_for_test ())))
    )
;;

let () =
  run
    "keeper_turn_capacity"
    [ ( "global gate"
      , [ test_case "blocks nested turn at cap" `Quick test_global_capacity_blocks_nested_turn
        ; test_case "disabled gate allows nested turn" `Quick test_disabled_capacity_allows_nested_turn
        ; test_case "force release is idempotent" `Quick
            test_force_release_does_not_double_release_later_turn
        ] )
    ]
