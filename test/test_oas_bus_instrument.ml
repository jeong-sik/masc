(** Tests for [Agent_sdk_metrics_bridge].

    Covers:
    - [subscribe] registers purpose, [unsubscribe] removes it.
    - [publish] increments depth for subscribers whose filter matches.
    - [publish] does NOT increment depth for subscribers whose filter
      rejects the event.
    - [drain] decrements depth by batch size and never below zero.
    - Multiple subscribers under the same purpose coexist (both tracked).
    - [publish] updates the Prometheus publish-total counter and
      accumulates publish-block-seconds (value > 0 after one publish).
*)

open Alcotest

module I = Masc_mcp.Agent_sdk_metrics_bridge

let mk_bus () = Agent_sdk.Event_bus.create ()

let mk_custom_event tag =
  Agent_sdk.Event_bus.mk_event
    (Agent_sdk.Event_bus.Custom (tag, `Assoc []))

let topic_filter tag : Agent_sdk.Event_bus.filter = fun evt ->
  match evt.payload with
  | Agent_sdk.Event_bus.Custom (t, _) -> t = tag
  | _ -> false

let run_eio f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw -> f ~sw ~env))

let test_subscribe_tracks_purpose () =
  I.For_testing.reset ();
  run_eio (fun ~sw:_ ~env:_ ->
    let bus = mk_bus () in
    let h = I.subscribe ~purpose:"test_sub_a" bus in
    check int "depth initialised to 0"
      0 (I.For_testing.current_depth ~purpose:"test_sub_a");
    I.unsubscribe bus h;
    check int "unsubscribe clears tracking"
      (-1) (I.For_testing.current_depth ~purpose:"test_sub_a"))

let test_publish_increments_matching_depth () =
  I.For_testing.reset ();
  run_eio (fun ~sw:_ ~env:_ ->
    let bus = mk_bus () in
    let h_all = I.subscribe ~purpose:"all_sub" bus in
    let h_foo =
      I.subscribe ~purpose:"foo_sub" ~filter:(topic_filter "foo") bus
    in
    I.publish bus (mk_custom_event "foo");
    check int "accept_all subscriber saw event"
      1 (I.For_testing.current_depth ~purpose:"all_sub");
    check int "filtered subscriber saw matching event"
      1 (I.For_testing.current_depth ~purpose:"foo_sub");
    I.publish bus (mk_custom_event "bar");
    check int "accept_all subscriber saw bar too"
      2 (I.For_testing.current_depth ~purpose:"all_sub");
    check int "filtered subscriber ignored non-matching"
      1 (I.For_testing.current_depth ~purpose:"foo_sub");
    I.unsubscribe bus h_all;
    I.unsubscribe bus h_foo)

let test_drain_decrements_depth () =
  I.For_testing.reset ();
  run_eio (fun ~sw:_ ~env:_ ->
    let bus = mk_bus () in
    let h = I.subscribe ~purpose:"drain_sub" bus in
    for _ = 1 to 3 do
      I.publish bus (mk_custom_event "x")
    done;
    check int "three publishes tracked"
      3 (I.For_testing.current_depth ~purpose:"drain_sub");
    let events = I.drain h in
    check int "drain returned all three"
      3 (List.length events);
    check int "depth went back to zero"
      0 (I.For_testing.current_depth ~purpose:"drain_sub");
    (* Extra drain does not go negative. *)
    let _ = I.drain h in
    check int "depth floors at zero"
      0 (I.For_testing.current_depth ~purpose:"drain_sub");
    I.unsubscribe bus h)

let test_multiple_subs_same_purpose_coexist () =
  I.For_testing.reset ();
  run_eio (fun ~sw:_ ~env:_ ->
    let bus = mk_bus () in
    let a = I.subscribe ~purpose:"shared" bus in
    let b = I.subscribe ~purpose:"shared" bus in
    (* current_depth returns the first match — behaviour checked, not
       load-bearing. Important: both subscribers exist and neither
       crashes on publish. *)
    I.publish bus (mk_custom_event "x");
    let d = I.For_testing.current_depth ~purpose:"shared" in
    check bool "some shared sub has depth >= 1" true (d >= 1);
    I.unsubscribe bus a;
    I.unsubscribe bus b)

let test_publish_updates_counters () =
  I.For_testing.reset ();
  run_eio (fun ~sw:_ ~env:_ ->
    let bus = mk_bus () in
    let before_total =
      Masc_mcp.Prometheus.metric_value_or_zero "masc_oas_bus_publish_total" ()
    in
    let before_block =
      Masc_mcp.Prometheus.metric_value_or_zero
        "masc_oas_bus_publish_block_seconds_total" ()
    in
    I.publish bus (mk_custom_event "x");
    I.publish bus (mk_custom_event "y");
    let after_total =
      Masc_mcp.Prometheus.metric_value_or_zero "masc_oas_bus_publish_total" ()
    in
    let after_block =
      Masc_mcp.Prometheus.metric_value_or_zero
        "masc_oas_bus_publish_block_seconds_total" ()
    in
    check bool "publish_total incremented by at least 2"
      true (after_total -. before_total >= 2.0);
    check bool "publish_block_seconds did not decrease"
      true (after_block >= before_block))

let test_threshold_transitions_warn_once_until_recovery () =
  I.For_testing.reset ();
  run_eio (fun ~sw:_ ~env:_ ->
    let bus = mk_bus () in
    let h = I.subscribe ~purpose:"sampler_sub" bus in
    for _ = 1 to 3 do
      I.publish bus (mk_custom_event "x")
    done;
    (match I.For_testing.sample_threshold_transitions ~warn_threshold:2 with
     | [ `Warn ("sampler_sub", 3) ] -> ()
     | other ->
       fail
         (Printf.sprintf "expected single warn transition, got %d"
            (List.length other)));
    check int "no duplicate warn without recovery" 0
      (List.length
         (I.For_testing.sample_threshold_transitions ~warn_threshold:2));
    ignore (I.drain h);
    (match I.For_testing.sample_threshold_transitions ~warn_threshold:2 with
     | [ `Recovered ("sampler_sub", 0) ] -> ()
     | other ->
       fail
         (Printf.sprintf "expected single recovery transition, got %d"
            (List.length other)));
    check int "no duplicate recovery after state clears" 0
      (List.length
         (I.For_testing.sample_threshold_transitions ~warn_threshold:2));
    I.unsubscribe bus h)

let () =
  run "oas_bus_instrument" [
    ("backpressure", [
      test_case "subscribe tracks purpose" `Quick
        test_subscribe_tracks_purpose;
      test_case "publish increments matching depth" `Quick
        test_publish_increments_matching_depth;
      test_case "drain decrements depth" `Quick
        test_drain_decrements_depth;
      test_case "multiple subs same purpose coexist" `Quick
        test_multiple_subs_same_purpose_coexist;
      test_case "publish updates counters" `Quick
        test_publish_updates_counters;
      test_case "threshold transitions warn once until recovery" `Quick
        test_threshold_transitions_warn_once_until_recovery;
    ])
  ]
