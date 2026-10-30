(** Tests for [Runtime_event_bus].

    Covers the compatibility wrapper around [Agent_core.Event_bus].
    The wrapper should forward subscribe/publish/drain semantics to agent core
    bus without a parallel sampler surface.
*)

open Alcotest

module I = struct
  include Masc.Runtime_event_bus

  let subscribe = subscribe ~capacity:3 ~overflow:Agent_core.Event_bus.Drop_oldest
end

let mk_bus () = Agent_core.Event_bus.create ()

let mk_custom_event tag =
  Agent_core.Event_bus.mk_event
    (Agent_core.Event_bus.Custom (tag, `Assoc []))

let topic_filter = Agent_core.Event_bus.filter_topic

let run_eio f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw -> f ~sw ~env))

let test_subscribe_forwards_purpose_to_agent_core_stats () =
  run_eio (fun ~sw:_ ~env:_ ->
    let bus = mk_bus () in
    let h = I.subscribe ~purpose:"stats_probe" bus in
    let stats = Agent_core.Event_bus.stats bus in
    (match stats.subscriptions with
     | [ sub_stats ] ->
       check (option string) "agent_core purpose" (Some "stats_probe") sub_stats.purpose;
       check int "subscriber capacity" 3 sub_stats.capacity;
       check bool "subscriber overflow" true
         (sub_stats.overflow = Agent_core.Event_bus.Drop_oldest)
     | _ -> fail "expected one runtime subscription");
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

let payload_kinds events =
  List.map
    (fun (event : Agent_core.Event_bus.event) ->
       Agent_core.Event_bus.payload_kind event.payload)
    events

let test_drain_reporting_drops_reports_each_drop_once () =
  run_eio (fun ~sw:_ ~env:_ ->
    let bus = mk_bus () in
    let h = I.subscribe ~purpose:"drop_report" bus in
    List.iter
      (fun tag -> I.publish bus (mk_custom_event tag))
      [ "a"; "b"; "c"; "d"; "e" ];
    let { I.events; overflow_loss } = I.drain_reporting_drops h in
    check (list string) "the newest three survive"
      [ "custom:c"; "custom:d"; "custom:e" ] (payload_kinds events);
    (match overflow_loss with
     | I.Dropped 2 -> ()
     | I.Dropped count -> failf "expected two drops, got %d" count
     | I.Nothing_dropped -> fail "the drops were not reported");
    I.publish bus (mk_custom_event "f");
    let { I.events; overflow_loss } = I.drain_reporting_drops h in
    check (list string) "the next batch" [ "custom:f" ] (payload_kinds events);
    (match overflow_loss with
     | I.Nothing_dropped -> ()
     | I.Dropped count -> failf "the earlier drops were reported again (%d)" count);
    I.unsubscribe bus h)

let () =
  run "runtime_event_bus" [
    ("backpressure", [
      test_case "subscribe forwards purpose to runtime stats" `Quick
        test_subscribe_forwards_purpose_to_agent_core_stats;
      test_case "publish forwards to matching subscribers" `Quick
        test_publish_forwards_to_matching_subscribers;
      test_case "drain returns events" `Quick
        test_drain_decrements_depth;
      test_case "multiple subs same purpose coexist" `Quick
        test_multiple_subs_same_purpose_coexist;
      test_case "drain reporting drops reports each drop once" `Quick
        test_drain_reporting_drops_reports_each_drop_once;
    ])
  ]
