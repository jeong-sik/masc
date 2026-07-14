(** Regression tests for the MASC subscription boundary over OAS Event_bus. *)

open Alcotest

module I = Masc.Agent_sdk_metrics_bridge

let mk_bus () = Agent_sdk.Event_bus.create ()

let contract =
  Masc.Masc_event_bus_subscription.for_subscriber
    Masc.Masc_event_bus_subscription.Sse_bridge
;;

let mk_custom_event tag =
  Agent_sdk.Event_bus.mk_event
    (Agent_sdk.Event_bus.Custom (tag, `Assoc []))
;;

let run_eio f =
  Eio_main.run (fun env -> Eio.Switch.run (fun sw -> f ~sw ~env))
;;

let only_subscription bus =
  match (Agent_sdk.Event_bus.stats bus).subscriptions with
  | [ stats ] -> stats
  | stats ->
    failf "expected exactly one OAS subscription, got %d" (List.length stats)
;;

let test_subscribe_forwards_typed_contract () =
  run_eio (fun ~sw:_ ~env:_ ->
    let bus = mk_bus () in
    let h = I.subscribe ~contract bus in
    let stats = only_subscription bus in
    check (option string)
      "bounded purpose"
      (Some (Masc.Masc_event_bus_subscription.purpose contract))
      stats.purpose;
    check int
      "validated capacity"
      (Masc.Masc_event_bus_subscription.capacity contract)
      stats.capacity;
    check bool
      "typed overflow"
      true
      (stats.overflow = Masc.Masc_event_bus_subscription.overflow contract);
    I.unsubscribe bus h)
;;

let test_publish_forwards_to_matching_subscribers () =
  run_eio (fun ~sw:_ ~env:_ ->
    let bus = mk_bus () in
    let h_all = I.subscribe ~contract bus in
    let h_foo =
      I.subscribe
        ~contract
        ~filter:(Agent_sdk.Event_bus.filter_topic "foo")
        bus
    in
    I.publish bus (mk_custom_event "foo");
    check int "accept_all subscriber saw event" 1 (List.length (I.drain h_all));
    check int
      "typed topic subscriber saw matching event"
      1
      (List.length (I.drain h_foo));
    I.publish bus (mk_custom_event "bar");
    check int "accept_all subscriber saw bar too" 1 (List.length (I.drain h_all));
    check int
      "typed topic subscriber ignored non-matching event"
      0
      (List.length (I.drain h_foo));
    I.unsubscribe bus h_all;
    I.unsubscribe bus h_foo)
;;

let test_drain_updates_real_oas_stats () =
  run_eio (fun ~sw:_ ~env:_ ->
    let bus = mk_bus () in
    let h = I.subscribe ~contract bus in
    for _ = 1 to 3 do
      I.publish bus (mk_custom_event "x")
    done;
    let before = only_subscription bus in
    check int "live depth before drain" 3 before.depth;
    check int "published before drain" 3 before.published_total;
    let events = I.drain h in
    check int "drain returned all events" 3 (List.length events);
    let after = only_subscription bus in
    check int "live depth after drain" 0 after.depth;
    check int "drained total after drain" 3 after.drained_total;
    I.unsubscribe bus h)
;;

let test_overflow_is_nonblocking_and_observable () =
  run_eio (fun ~sw:_ ~env:_ ->
    let bus = mk_bus () in
    let h = I.subscribe ~contract bus in
    let capacity = Masc.Masc_event_bus_subscription.capacity contract in
    for _ = 1 to capacity + 1 do
      I.publish bus (mk_custom_event "x")
    done;
    let stats = only_subscription bus in
    check int "queue remains capacity-bounded" capacity stats.depth;
    check int "OAS exposes the dropped event" 1 stats.dropped_total;
    check int "all matching publishes are counted" (capacity + 1) stats.published_total;
    I.unsubscribe bus h)
;;

let () =
  run
    "oas_bus_instrument"
    [ ( "subscription_boundary"
      , [ test_case "subscribe forwards typed contract" `Quick
            test_subscribe_forwards_typed_contract
        ; test_case "typed filter routes events" `Quick
            test_publish_forwards_to_matching_subscribers
        ; test_case "drain updates real OAS stats" `Quick
            test_drain_updates_real_oas_stats
        ; test_case "overflow is observable" `Quick
            test_overflow_is_nonblocking_and_observable
        ] )
    ]
;;
