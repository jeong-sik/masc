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

let test_await_reporting_drops_reports_each_drop_once () =
  run_eio (fun ~sw:_ ~env ->
    let bus = mk_bus () in
    let h = I.subscribe ~purpose:"await_drop_report" bus in
    List.iter
      (fun tag -> I.publish bus (mk_custom_event tag))
      [ "a"; "b"; "c"; "d"; "e" ];
    let read () =
      match I.await_reporting_drops h with
      | Batch batch -> batch
      | Unsubscribed -> fail "subscription ended before batch"
    in
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5.0 (fun () ->
      let { I.events; overflow_loss } = read () in
      check (list string) "the newest three survive"
        [ "custom:c"; "custom:d"; "custom:e" ] (payload_kinds events);
      (match overflow_loss with
       | I.Dropped 2 -> ()
       | I.Dropped count -> failf "expected two drops, got %d" count
       | I.Nothing_dropped -> fail "the drops were not reported");
      I.publish bus (mk_custom_event "f");
      let { I.events; overflow_loss } = read () in
      check (list string) "next batch" [ "custom:f" ] (payload_kinds events);
      (match overflow_loss with
       | I.Nothing_dropped -> ()
       | I.Dropped count -> failf "earlier drops reported twice (%d)" count));
    I.unsubscribe bus h)

let with_bridge f =
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let base = Filename.temp_dir "masc-event-wakeup-" ".workspace" in
    let subscriber_id = "test-event-bridge-wakeup" in
    Fun.protect
      ~finally:(fun () ->
        Masc.Sse.unsubscribe_external subscriber_id;
        Fs_compat.remove_tree base)
      (fun () ->
        let bus = mk_bus () in
        let config = Masc.Workspace.default_config base in
        f ~env ~bus ~config ~subscriber_id))

let event_type (event : Masc.Sse.external_event) =
  match event.ext_payload with
  | `Assoc fields -> List.assoc_opt "event_type" fields
  | _ -> None

let run_bridge ?(retry_interval = 60.0) ~env ~bus ~config run =
  let ready, mark_ready = Eio.Promise.create () in
  let never, _ = Eio.Promise.create () in
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15.0 (fun () ->
    Eio.Fiber.first
      (fun () ->
        Eio.Switch.run (fun sw ->
          Masc.Keeper_event_bridge.For_testing.start_with_retry_interval
            ~interval_s:retry_interval ~sw ~clock:(Eio.Stdenv.clock env) ~config ~bus;
          Eio.Promise.resolve mark_ready ();
          Eio.Promise.await never))
      (fun () -> Eio.Promise.await ready; run ()))

let test_bridge_delivers_second_event_without_retry_timer () =
  with_bridge (fun ~env ~bus ~config ~subscriber_id ->
    let first, first_seen = Eio.Promise.create () in
    let second, second_seen = Eio.Promise.create () in
    Masc.Sse.subscribe_external ~id:subscriber_id
      ~callback:(fun event ->
        match event_type event with
        | Some (`String "bridge-first") -> Eio.Promise.resolve first_seen ()
        | Some (`String "bridge-second") -> Eio.Promise.resolve second_seen ()
        | _ -> ()) ();
    run_bridge ~env ~bus ~config (fun () ->
      I.publish bus (mk_custom_event "bridge-first");
      Eio.Promise.await first;
      Eio.Fiber.yield ();
      I.publish bus (mk_custom_event "bridge-second");
      Eio.Promise.await second))

let test_bridge_records_subscription_overflow () =
  with_bridge (fun ~env ~bus ~config ~subscriber_id ->
    let entered, entered_resolver = Eio.Promise.create () in
    let release, release_resolver = Eio.Promise.create () in
    let survivor, survivor_resolver = Eio.Promise.create () in
    let seen_survivor = ref false in
    let queue_drops () =
      Masc.Otel_metric_store.get_metric_value
        Masc.Otel_metric_store.metric_agent_core_sse_relay_drops
        ~labels:[ "stage", "queue" ] ()
      |> Option.value ~default:0.0
    in
    let before = queue_drops () in
    Masc.Sse.subscribe_external ~id:subscriber_id
      ~callback:(fun event ->
        match event_type event with
        | Some (`String "bridge-hold") ->
          (* A deliberately stalled downstream lets the real subscriber queue
             fill before the bridge can take another batch. *)
          Eio.Promise.resolve entered_resolver ();
          Eio.Promise.await release
        | Some (`String "bridge-queued") when not !seen_survivor ->
          seen_survivor := true;
          Eio.Promise.resolve survivor_resolver ()
        | _ -> ()) ();
    run_bridge ~env ~bus ~config (fun () ->
      I.publish bus (mk_custom_event "bridge-hold");
      Eio.Promise.await entered;
      for _ = 1 to 300 do I.publish bus (mk_custom_event "bridge-queued") done;
      Eio.Promise.resolve release_resolver ();
      Eio.Promise.await survivor;
      check (float 0.0) "44 subscription drops recorded" 44.0 (queue_drops () -. before)))

let test_bridge_retries_then_drains_queued_events () =
  List.iter
    (fun failures ->
      with_bridge (fun ~env ~bus ~config ~subscriber_id ->
        let started, mark_started = Eio.Promise.create () in
        let release, mark_release = Eio.Promise.create () in
        let received_second, mark_second = Eio.Promise.create () in
        let attempts = ref 0 and received = ref [] in
        Masc.Sse.subscribe_external ~id:subscriber_id
          ~callback:(fun event ->
            match event_type event with
            | Some (`String name) ->
              received := name :: !received;
              if String.equal name "retry-second" then Eio.Promise.resolve mark_second ()
            | _ -> ()) ();
        Dated_jsonl.set_append_guard (fun append ->
          incr attempts;
          if !attempts = 1 then (
            Eio.Promise.resolve mark_started ();
            Eio.Promise.await release);
          if !attempts <= failures then failwith "injected append failure";
          append ());
        Fun.protect
          ~finally:(fun () -> Dated_jsonl.set_append_guard (fun append -> append ()))
          (fun () ->
            run_bridge ~retry_interval:0.05 ~env ~bus ~config (fun () ->
              I.publish bus (mk_custom_event "retry-first");
              Eio.Promise.await started;
              I.publish bus (mk_custom_event "retry-second");
              Eio.Promise.resolve mark_release ();
              Eio.Promise.await received_second);
            let expected =
              if failures = 1 then [ "retry-first"; "retry-second" ]
              else [ "relay_dropped"; "retry-second" ]
            in
            check (list string) "retained event or drop marker before queued event"
              expected (List.rev !received);
            check int "failed attempts followed by next batch"
              (if failures = 1 then 3 else 4) !attempts)))
    [ 1; 3 ]

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
      test_case "await reports drops once" `Quick
        test_await_reporting_drops_reports_each_drop_once;
      test_case "bridge wakes without timer" `Quick
        test_bridge_delivers_second_event_without_retry_timer;
      test_case "bridge records subscriber overflow" `Quick
        test_bridge_records_subscription_overflow;
      test_case "bridge retries then drains queued events" `Quick
        test_bridge_retries_then_drains_queued_events;
    ])
  ]
