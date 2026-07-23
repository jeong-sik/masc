open Alcotest

module Bridge = Masc.Agent_sdk_metrics_bridge

let event index =
  Agent_sdk.Event_bus.mk_event
    (Agent_sdk.Event_bus.Custom ("test.event", `Int index))
;;

let event_index (event : Agent_sdk.Event_bus.event) =
  match event.payload with
  | Agent_sdk.Event_bus.Custom ("test.event", `Int index) -> index
  | _ -> fail "unexpected event payload"
;;

let subscription_stats purpose bus =
  Agent_sdk.Event_bus.(stats bus).subscriptions
  |> List.find (fun (stats : Agent_sdk.Event_bus.subscription_stats) ->
    stats.purpose = Some purpose)
;;

let test_subscribers_own_independent_overflow () =
  Eio_main.run (fun _env ->
    let bus = Agent_sdk.Event_bus.create () in
    let oldest =
      Bridge.subscribe
        ~capacity:2
        ~overflow:Agent_sdk.Event_bus.Drop_oldest
        ~purpose:"oldest"
        bus
    in
    let newest =
      Bridge.subscribe
        ~capacity:2
        ~overflow:Agent_sdk.Event_bus.Drop_newest
        ~purpose:"newest"
        bus
    in
    List.iter (Bridge.publish bus) [ event 1; event 2; event 3 ];
    check (list int) "drop oldest keeps latest events" [ 2; 3 ]
      (List.map event_index (Bridge.drain oldest));
    check (list int) "drop newest keeps queued events" [ 1; 2 ]
      (List.map event_index (Bridge.drain newest));
    check int "oldest drop observed" 1 (subscription_stats "oldest" bus).dropped_total;
    check int "newest drop observed" 1 (subscription_stats "newest" bus).dropped_total;
    Bridge.unsubscribe bus oldest;
    Bridge.unsubscribe bus newest)
;;

let () =
  run
    "event_bus_subscription_contract"
    [ ( "subscriber_contract"
      , [ test_case
            "overflow is isolated per subscriber"
            `Quick
            test_subscribers_own_independent_overflow
        ] )
    ]
;;
