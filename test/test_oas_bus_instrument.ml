(** Tests for [Agent_sdk_metrics_bridge].

    Covers the compatibility wrapper around [Agent_sdk.Event_bus].
    The wrapper should forward subscribe/publish/drain semantics to the SDK
    bus without a parallel sampler surface.
*)

open Alcotest

module I = struct
  include Masc.Agent_sdk_metrics_bridge

  let subscribe = subscribe ~capacity:3 ~overflow:Agent_sdk.Event_bus.Drop_oldest
end

let mk_bus () = Agent_sdk.Event_bus.create ()

let mk_custom_event tag =
  Agent_sdk.Event_bus.mk_event
    (Agent_sdk.Event_bus.Custom (tag, `Assoc []))

let topic_filter = Agent_sdk.Event_bus.filter_topic

let run_eio f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw -> f ~sw ~env))

let test_subscribe_forwards_purpose_to_oas_stats () =
  run_eio (fun ~sw:_ ~env:_ ->
    let bus = mk_bus () in
    let h = I.subscribe ~purpose:"compact_audit" bus in
    let stats = Agent_sdk.Event_bus.stats bus in
    (match stats.subscriptions with
     | [ sub_stats ] ->
       check (option string) "oas purpose" (Some "compact_audit") sub_stats.purpose;
       check int "subscriber capacity" 3 sub_stats.capacity;
       check bool "subscriber overflow" true
         (sub_stats.overflow = Agent_sdk.Event_bus.Drop_oldest)
     | _ -> fail "expected one OAS subscription");
    I.unsubscribe bus h)

let test_publish_forwards_to_matching_subscribers () =
  run_eio (fun ~sw:_ ~env:_ ->
    let bus = mk_bus () in
    let h_all = I.subscribe ~purpose:"all_sub" bus in
    let h_foo =
      I.subscribe ~purpose:"foo_sub" ~filter:(topic_filter "foo") bus
    in
    I.publish bus (mk_custom_event "foo");
    check int "accept_all subscriber saw event" 1 (List.length (I.drain h_all));
    check int "filtered subscriber saw matching event" 1
      (List.length (I.drain h_foo));
    I.publish bus (mk_custom_event "bar");
    check int "accept_all subscriber saw bar too" 1 (List.length (I.drain h_all));
    check int "filtered subscriber ignored non-matching" 0
      (List.length (I.drain h_foo));
    I.unsubscribe bus h_all;
    I.unsubscribe bus h_foo)

let test_drain_decrements_depth () =
  run_eio (fun ~sw:_ ~env:_ ->
    let bus = mk_bus () in
    let h = I.subscribe ~purpose:"drain_sub" bus in
    for _ = 1 to 3 do
      I.publish bus (mk_custom_event "x")
    done;
    let events = I.drain h in
    check int "drain returned all three"
      3 (List.length events);
    check int "extra drain returns no events" 0 (List.length (I.drain h));
    I.unsubscribe bus h)

let test_multiple_subs_same_purpose_coexist () =
  run_eio (fun ~sw:_ ~env:_ ->
    let bus = mk_bus () in
    let a = I.subscribe ~purpose:"shared" bus in
    let b = I.subscribe ~purpose:"shared" bus in
    I.publish bus (mk_custom_event "x");
    check int "first shared subscriber receives event" 1 (List.length (I.drain a));
    check int "second shared subscriber receives event" 1 (List.length (I.drain b));
    I.unsubscribe bus a;
    I.unsubscribe bus b)

let () =
  run "oas_bus_instrument" [
    ("backpressure", [
      test_case "subscribe forwards purpose to OAS stats" `Quick
        test_subscribe_forwards_purpose_to_oas_stats;
      test_case "publish forwards to matching subscribers" `Quick
        test_publish_forwards_to_matching_subscribers;
      test_case "drain returns events" `Quick
        test_drain_decrements_depth;
      test_case "multiple subs same purpose coexist" `Quick
        test_multiple_subs_same_purpose_coexist;
    ])
  ]
