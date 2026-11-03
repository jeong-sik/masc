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

let run_bridge ?(retry_interval = 60.0) ?(before_prepare = fun () -> ()) ~env ~bus ~config run =
  let ready, mark_ready = Eio.Promise.create () in
  let never, _ = Eio.Promise.create () in
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15.0 (fun () ->
    Eio.Fiber.first
      (fun () ->
        Eio.Switch.run (fun sw ->
          Masc.Keeper_event_bridge.For_testing.start_with_preparation_hook
            ~before_prepare ~interval_s:retry_interval ~sw ~clock:(Eio.Stdenv.clock env) ~config ~bus;
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
    let notice = ref None in
    let other_notice = ref false and unscoped_notice = ref false in
    let attempts = ref 0 in
    let authority = Masc.Sse.runtime_authority_exn ~base_path:config.base_path in
    let other_base = Filename.concat config.base_path "other" in
    Fs_compat.mkdir_p (Filename.concat other_base ".masc");
    let other_authority = Masc.Sse.runtime_authority_exn ~base_path:other_base in
    let other_id = subscriber_id ^ "-other" and unscoped_id = subscriber_id ^ "-unscoped" in
    let queue_drops () =
      Masc.Otel_metric_store.get_metric_value
        Masc.Otel_metric_store.metric_agent_core_sse_relay_drops
        ~labels:[ "stage", "queue" ] ()
      |> Option.value ~default:0.0
    in
    let before = queue_drops () in
    Masc.Sse.subscribe_external ~runtime_authority:other_authority ~id:other_id
      ~callback:(fun event ->
        if event_type event = Some (`String Masc.Keeper_event_bridge.subscription_loss_event_type)
        then other_notice := true) ();
    Masc.Sse.subscribe_external ~id:unscoped_id
      ~callback:(fun event ->
        if event_type event = Some (`String Masc.Keeper_event_bridge.subscription_loss_event_type)
        then unscoped_notice := true) ();
    Masc.Sse.subscribe_external ~runtime_authority:authority ~id:subscriber_id
      ~callback:(fun event ->
        match event_type event with
        | Some (`String "bridge-hold") ->
          (* A deliberately stalled downstream lets the real subscriber queue
             fill before the bridge can take another batch. *)
          Eio.Promise.resolve entered_resolver ();
          Eio.Promise.await release
        | Some (`String name)
          when String.equal name Masc.Keeper_event_bridge.subscription_loss_event_type ->
          notice := Some (event.ext_event_id, event.ext_payload)
        | Some (`String "bridge-queued") when not !seen_survivor ->
          seen_survivor := true;
          Eio.Promise.resolve survivor_resolver ()
        | _ -> ()) ();
    Fun.protect
      ~finally:(fun () ->
        Atomic.set Masc.Sse.buffer_commit_test_hook None;
        Masc.Sse.unsubscribe_external other_id;
        Masc.Sse.unsubscribe_external unscoped_id)
      (fun () ->
        run_bridge ~retry_interval:0.02 ~env ~bus ~config (fun () ->
          I.publish bus (mk_custom_event "bridge-hold");
          Eio.Promise.await entered;
          for _ = 1 to 300 do I.publish bus (mk_custom_event "bridge-queued") done;
          Atomic.set Masc.Sse.buffer_commit_test_hook (Some (fun () ->
            incr attempts;
            if !attempts <= 4 then failwith "injected notice broadcast failure"));
          Eio.Promise.resolve release_resolver ();
          Eio.Promise.await survivor;
          check (float 0.0) "44 subscription drops recorded" 44.0 (queue_drops () -. before);
          check bool "the notice retried past the normal relay limit" true (!attempts >= 5);
          let id, payload = match !notice with
            | Some value -> value
            | None -> fail "a queued event arrived before the loss notice" in
          let open Yojson.Safe.Util in
          check int "the notice names the dropped count" 44
            (payload |> member "payload" |> member "dropped_count" |> to_int);
          check bool "another runtime did not receive the notice" false !other_notice;
          check bool "an unscoped subscriber did not receive the notice" false !unscoped_notice;
          check bool "the notice is in the replay buffer" true
            (List.exists (fun (delivery : Masc.Sse.delivery) -> delivery.event_id = id)
               (Masc.Sse.get_events_after_for_test (id - 1)));
          let replay ?runtime_authority () =
            (Masc.Sse.replay_after_for_session ?runtime_authority ~session_id:"loss-probe"
               ~kind:Masc.Sse.Observer (id - 1)).deliveries in
          let contains_notice deliveries =
            List.exists (fun (delivery : Masc.Sse.delivery) -> delivery.event_id = id) deliveries in
          check bool "same runtime can replay the notice" true
            (contains_notice (replay ~runtime_authority:authority ()));
          check bool "another runtime cannot replay the notice" false
            (contains_notice (replay ~runtime_authority:other_authority ()));
          check bool "unscoped observer cannot replay the notice" false
            (contains_notice (replay ())))))

let test_loss_notice_does_not_block_on_store_failure () =
  with_bridge (fun ~env ~bus ~config ~subscriber_id ->
    let entered, entered_resolver = Eio.Promise.create () in
    let release, release_resolver = Eio.Promise.create () in
    let survivor, survivor_resolver = Eio.Promise.create () in
    let notice_seen, notice_resolver = Eio.Promise.create () in
    let notices = ref [] and fail_appends = ref false and seen_survivor = ref false in
    let append_drops () =
      Masc.Otel_metric_store.get_metric_value
        Masc.Otel_metric_store.metric_agent_core_sse_relay_drops
        ~labels:[ "stage", "append" ] ()
      |> Option.value ~default:0.0 in
    let before = append_drops () in
    Masc.Sse.subscribe_external
      ~runtime_authority:(Masc.Sse.runtime_authority_exn ~base_path:config.base_path)
      ~id:subscriber_id ~callback:(fun event ->
        match event_type event with
        | Some (`String "hold-store") ->
            Eio.Promise.resolve entered_resolver ();
            Eio.Promise.await release
        | Some (`String name)
          when String.equal name Masc.Keeper_event_bridge.subscription_loss_event_type ->
            let open Yojson.Safe.Util in
            let payload = event.ext_payload |> member "payload" in
            let key = (payload |> member "source_id" |> to_string),
                      (payload |> member "sequence" |> to_int) in
            let first = !notices = [] in
            notices := key :: !notices;
            if first then Eio.Promise.resolve notice_resolver ()
        | Some (`String "after-store") when not !seen_survivor ->
            seen_survivor := true;
            Eio.Promise.resolve survivor_resolver ()
        | _ -> ()) ();
    Dated_jsonl.set_append_guard (fun append ->
      if !fail_appends then
        failwith "injected permanent notice-store failure";
      append ());
    Fun.protect
      ~finally:(fun () -> Dated_jsonl.set_append_guard (fun append -> append ()))
      (fun () ->
        run_bridge ~retry_interval:0.02 ~env ~bus ~config (fun () ->
          I.publish bus (mk_custom_event "hold-store");
          Eio.Promise.await entered;
          for _ = 1 to 300 do I.publish bus (mk_custom_event "queued-store") done;
          fail_appends := true;
          Eio.Promise.resolve release_resolver ();
          Eio.Promise.await notice_seen;
          Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5.0 (fun () ->
            while append_drops () <= before do
              Eio.Time.sleep (Eio.Stdenv.clock env) 0.02
            done);
          fail_appends := false;
          I.publish bus (mk_custom_event "after-store");
          Eio.Promise.await survivor;
          (* A later source event may itself exhaust retries while the store
             is down. That is a new loss, not a repeat of the first notice. *)
          let notices = List.rev !notices in
          let first = match notices with
            | first :: _ -> first
            | [] -> fail "the overflow notice was not delivered" in
          check int "the already broadcast notice is not repeated" 1
            (List.length (List.filter (( = ) first) notices));
          check int "each delivered notice has a distinct source sequence"
            (List.length notices) (List.length (List.sort_uniq compare notices));
          check bool "an append exhausts its retry budget while the store fails" true
            (append_drops () > before))))

let test_loss_notice_survives_postcommit_external_failure () =
  with_bridge (fun ~env ~bus ~config ~subscriber_id ->
    let entered, entered_resolver = Eio.Promise.create () in
    let release, release_resolver = Eio.Promise.create () in
    let survivor, survivor_resolver = Eio.Promise.create () in
    let seen_survivor = ref false and armed = ref false and raised = ref false in
    let fail_id = "000-loss-postcommit" in
    let authority = Masc.Sse.runtime_authority_exn ~base_path:config.base_path in
    let initial_id = Masc.Sse.current_id () in
    Masc.Sse.subscribe_external ~runtime_authority:authority ~id:fail_id
      ~is_alive:(fun () ->
        if !armed then (armed := false; raised := true; failwith "postcommit fanout failure");
        true)
      ~callback:(fun _ -> ()) ();
    Masc.Sse.subscribe_external ~runtime_authority:authority ~id:subscriber_id
      ~callback:(fun event ->
        match event_type event with
        | Some (`String "hold-postcommit") ->
            Eio.Promise.resolve entered_resolver ();
            Eio.Promise.await release
        | Some (`String "after-postcommit") when not !seen_survivor ->
            seen_survivor := true;
            Eio.Promise.resolve survivor_resolver ()
        | _ -> ()) ();
    Fun.protect
      ~finally:(fun () -> Masc.Sse.unsubscribe_external fail_id)
      (fun () ->
        run_bridge ~retry_interval:0.02 ~env ~bus ~config (fun () ->
          I.publish bus (mk_custom_event "hold-postcommit");
          Eio.Promise.await entered;
          for _ = 1 to 300 do I.publish bus (mk_custom_event "after-postcommit") done;
          armed := true;
          Eio.Promise.resolve release_resolver ();
          Eio.Promise.await survivor;
          check bool "postcommit external failure was injected" true !raised;
          let notices =
            Masc.Sse.get_events_after_for_test initial_id
            |> List.filter (fun (delivery : Masc.Sse.delivery) ->
                 match delivery.payload with
                 | `Assoc fields ->
                     List.assoc_opt "event_type" fields
                     = Some (`String Masc.Keeper_event_bridge.subscription_loss_event_type)
                 | _ -> false)
          in
          check int "the committed notice is not published again" 1 (List.length notices))))

let test_bridge_retries_then_drains_queued_events () =
  List.iter
    (fun failures ->
      with_bridge (fun ~env ~bus ~config ~subscriber_id ->
        let started, mark_started = Eio.Promise.create () in
        let release, mark_release = Eio.Promise.create () in
        let received_second, mark_second = Eio.Promise.create () in
        let attempts = ref 0 and received = ref [] in
        let loss_attempts = ref 0 in
        let before_id = Masc.Sse.current_id () in
        let authority = Masc.Sse.runtime_authority_exn ~base_path:config.base_path in
        Masc.Sse.subscribe_external ~runtime_authority:authority ~id:subscriber_id
          ~callback:(fun event ->
            match event_type event with
            | Some (`String name) ->
              received := name :: !received;
              if failures = 3 && String.equal name "relay_dropped" then
                Atomic.set Masc.Sse.buffer_commit_test_hook (Some (fun () ->
                  incr loss_attempts;
                  if !loss_attempts <= 4 then failwith "injected loss notice failure"));
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
          ~finally:(fun () ->
            Atomic.set Masc.Sse.buffer_commit_test_hook None;
            Dated_jsonl.set_append_guard (fun append -> append ()))
          (fun () ->
            run_bridge ~retry_interval:0.05 ~env ~bus ~config (fun () ->
              I.publish bus (mk_custom_event "retry-first");
              Eio.Promise.await started;
              I.publish bus (mk_custom_event "retry-second");
              Eio.Promise.resolve mark_release ();
              Eio.Promise.await received_second);
            let expected =
              if failures = 1 then [ "retry-first"; "retry-second" ]
              else [ "relay_dropped"; Masc.Keeper_event_bridge.subscription_loss_event_type;
                     "retry-second" ]
            in
            check (list string) "retained event or loss notice before queued event"
              expected (List.rev !received);
            check int "failed attempts followed by next batch"
              (if failures = 1 then 3 else 5) !attempts;
            if failures = 3 then begin
              check bool "loss notice retries past the ordinary limit" true (!loss_attempts >= 5);
              let replayed = Masc.Sse.get_events_after_for_test before_id
                |> List.filter (fun (delivery : Masc.Sse.delivery) ->
                  match delivery.payload with
                  | `Assoc fields -> List.assoc_opt "event_type" fields
                      = Some (`String Masc.Keeper_event_bridge.subscription_loss_event_type)
                  | _ -> false) in
              check int "the loss notice is replayable" 1 (List.length replayed)
            end)))
    [ 1; 3 ]

let test_bridge_reports_loss_before_later_event_in_same_batch () =
  with_bridge (fun ~env ~bus ~config ~subscriber_id ->
    let entered, mark_entered = Eio.Promise.create () in
    let release, mark_release = Eio.Promise.create () in
    let received_second, mark_second = Eio.Promise.create () in
    let armed = ref false and attempts = ref 0 and loss_attempts = ref 0 in
    let received = ref [] in
    Masc.Sse.subscribe_external
      ~runtime_authority:(Masc.Sse.runtime_authority_exn ~base_path:config.base_path)
      ~id:subscriber_id ~callback:(fun event ->
        match event_type event with
        | Some (`String "batch-hold") ->
            Eio.Promise.resolve mark_entered ();
            Eio.Promise.await release
        | Some (`String name) ->
            received := name :: !received;
            if String.equal name "relay_dropped" then
              Atomic.set Masc.Sse.buffer_commit_test_hook (Some (fun () ->
                incr loss_attempts;
                if !loss_attempts <= 4 then failwith "injected loss notice failure"));
            if String.equal name "batch-second" then Eio.Promise.resolve mark_second ()
        | _ -> ()) ();
    Dated_jsonl.set_append_guard (fun append ->
      if !armed then begin
        incr attempts;
        if !attempts <= 3 then failwith "injected first-event append failure"
      end;
      append ());
    Fun.protect
      ~finally:(fun () ->
        Atomic.set Masc.Sse.buffer_commit_test_hook None;
        Dated_jsonl.set_append_guard (fun append -> append ()))
      (fun () ->
        run_bridge ~retry_interval:0.02 ~env ~bus ~config (fun () ->
          I.publish bus (mk_custom_event "batch-hold");
          Eio.Promise.await entered;
          (* Both events are waiting when the bridge resumes, so the second
             belongs to the same subscriber batch as the failing first. *)
          I.publish bus (mk_custom_event "batch-first");
          I.publish bus (mk_custom_event "batch-second");
          armed := true;
          Eio.Promise.resolve mark_release ();
          Eio.Promise.await received_second);
        check (list string) "loss notice precedes later event from the same batch"
          [ "relay_dropped"; Masc.Keeper_event_bridge.subscription_loss_event_type;
            "batch-second" ] (List.rev !received);
        check bool "the notice survives repeated delivery failures" true (!loss_attempts >= 5)))

let test_bridge_reports_a_batch_that_cannot_be_prepared () =
  with_bridge (fun ~env ~bus ~config ~subscriber_id ->
    let entered, mark_entered = Eio.Promise.create () in
    let release, mark_release = Eio.Promise.create () in
    let received_after, mark_after = Eio.Promise.create () in
    let fail_next = ref false and dropped = ref None and received = ref [] in
    let preparation_drops () =
      Masc.Otel_metric_store.get_metric_value
        Masc.Otel_metric_store.metric_agent_core_sse_relay_drops
        ~labels:[ "stage", "prepare" ] ()
      |> Option.value ~default:0.0 in
    let before = preparation_drops () in
    let before_prepare () =
      if !fail_next then (fail_next := false; failwith "injected preparation failure") in
    Masc.Sse.subscribe_external
      ~runtime_authority:(Masc.Sse.runtime_authority_exn ~base_path:config.base_path)
      ~id:subscriber_id ~callback:(fun event ->
        match event_type event with
        | Some (`String "prepare-hold") ->
            Eio.Promise.resolve mark_entered ();
            Eio.Promise.await release
        | Some (`String name) ->
            received := name :: !received;
            if String.equal name Masc.Keeper_event_bridge.subscription_loss_event_type then begin
              let open Yojson.Safe.Util in
              dropped := Some (event.ext_payload |> member "payload" |> member "dropped_count" |> to_int);
              I.publish bus (mk_custom_event "prepare-after")
            end;
            if String.equal name "prepare-after" then Eio.Promise.resolve mark_after ()
        | _ -> ()) ();
    run_bridge ~retry_interval:0.02 ~before_prepare ~env ~bus ~config (fun () ->
      I.publish bus (mk_custom_event "prepare-hold");
      Eio.Promise.await entered;
      I.publish bus (mk_custom_event "prepare-lost-one");
      I.publish bus (mk_custom_event "prepare-lost-two");
      fail_next := true;
      Eio.Promise.resolve mark_release ();
      Eio.Promise.await received_after);
    check (option int) "the notice counts the drained batch" (Some 2) !dropped;
    check (float 0.0) "preparation losses appear in transport metrics" 2.0
      (preparation_drops () -. before);
    check (list string) "batch loss is reported before the next event"
      [ Masc.Keeper_event_bridge.subscription_loss_event_type; "prepare-after" ]
      (List.rev !received))

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
      test_case "loss notice does not block on store failure" `Quick
        test_loss_notice_does_not_block_on_store_failure;
      test_case "loss notice survives postcommit external failure" `Quick
        test_loss_notice_survives_postcommit_external_failure;
      test_case "bridge retries then drains queued events" `Quick
        test_bridge_retries_then_drains_queued_events;
      test_case "loss precedes later event in the same batch" `Quick
        test_bridge_reports_loss_before_later_event_in_same_batch;
      test_case "unprepared batch produces a loss notice" `Quick
        test_bridge_reports_a_batch_that_cannot_be_prepared;
    ])
  ]
