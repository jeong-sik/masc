(* #9771: pin canonical metric name + label vocabulary for the
   semaphore wait timeout counter.  The keepalive path emits this
   counter at three sites:
     - [autonomous_queue_head]: fairness FIFO head wait exceeded
     - [autonomous]: autonomous-track semaphore acquire timeout
     - [turn]: shared turn semaphore acquire timeout

   Test exercises the counter directly so the metric vocabulary
   is pinned independently of the surrounding Eio + semaphore
   plumbing. *)

let counter_for ~keeper ~channel =
  Masc_mcp.Prometheus.metric_value_or_zero
    Masc_mcp.Keeper_metrics.metric_keeper_semaphore_wait_timeout
    ~labels:[
      ("keeper", keeper);
      ("channel", channel);
    ]
    ()

let queue_depth_for ~channel =
  Masc_mcp.Prometheus.metric_value_or_zero
    Masc_mcp.Keeper_metrics.metric_keeper_turn_queue_depth
    ~labels:[ ("channel", channel) ]
    ()

let semaphore_wait_bucket_for ~keeper_name ~cascade_profile ~channel ~le =
  Masc_mcp.Prometheus.metric_value_or_zero
    Masc_mcp.Keeper_metrics.metric_keeper_semaphore_wait_seconds_bucket
    ~labels:[
      ("keeper_name", keeper_name);
      ("cascade_profile", cascade_profile);
      ("channel", channel);
      ("le", le);
    ]
    ()

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [
         ("name", `String name);
         ("agent_name", `String name);
         ("trace_id", `String ("trace-" ^ name));
       ])
  with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_meta failed: " ^ err)

let test_metric_name_stable () =
  Alcotest.(check string)
    "semaphore wait timeout canonical metric name"
    "masc_keeper_semaphore_wait_timeout_total"
    Masc_mcp.Keeper_metrics.metric_keeper_semaphore_wait_timeout;
  Alcotest.(check string)
    "turn queue depth canonical metric name"
    "masc_keeper_turn_queue_depth"
    Masc_mcp.Keeper_metrics.metric_keeper_turn_queue_depth;
  Alcotest.(check string)
    "semaphore wait seconds canonical metric name"
    "masc_keeper_semaphore_wait_seconds"
    Masc_mcp.Keeper_metrics.metric_keeper_semaphore_wait_seconds;
  Alcotest.(check string)
    "semaphore wait seconds bucket canonical metric name"
    "masc_keeper_semaphore_wait_seconds_bucket"
    Masc_mcp.Keeper_metrics.metric_keeper_semaphore_wait_seconds_bucket

let test_autonomous_queue_depth_gauge_tracks_fifo () =
  Eio_main.run @@ fun _env ->
  let module KK = Masc_mcp.Keeper_keepalive in
  KK.reset_autonomous_turn_queue_for_test ();
  Alcotest.(check (float 0.0001))
    "reset records zero depth"
    0.0
    (queue_depth_for ~channel:"autonomous_queue");
  let first = KK.enqueue_autonomous_waiter_for_test "alpha-depth" in
  Alcotest.(check (float 0.0001))
    "first enqueue records depth"
    1.0
    (queue_depth_for ~channel:"autonomous_queue");
  let second = KK.enqueue_autonomous_waiter_for_test "beta-depth" in
  Alcotest.(check (float 0.0001))
    "second enqueue records depth"
    2.0
    (queue_depth_for ~channel:"autonomous_queue");
  KK.drop_autonomous_waiter_for_test first;
  Alcotest.(check (float 0.0001))
    "drop records reduced depth"
    1.0
    (queue_depth_for ~channel:"autonomous_queue");
  KK.drop_autonomous_waiter_for_test second;
  Alcotest.(check (float 0.0001))
    "final drop records zero depth"
    0.0
    (queue_depth_for ~channel:"autonomous_queue")

let test_successful_acquire_emits_wait_seconds_buckets () =
  Eio_main.run @@ fun _env ->
  let module KK = Masc_mcp.Keeper_keepalive in
  let keeper_name = "wait-histogram-keeper-0506" in
  let cascade_profile = "wait-histogram-cascade-0506" in
  let channel = "scheduled_autonomous" in
  KK.reset_autonomous_completion_for_test ();
  KK.reset_autonomous_turn_queue_for_test ();
  let before_inf =
    semaphore_wait_bucket_for ~keeper_name ~cascade_profile ~channel ~le:"+Inf"
  in
  let before_60 =
    semaphore_wait_bucket_for ~keeper_name ~cascade_profile ~channel ~le:"60"
  in
  (match
     KK.with_keeper_turn_slot_for_test
       ~cascade_profile
       ~keeper_name
       ~channel:Masc_mcp.Keeper_world_observation.Scheduled_autonomous
       (fun ~semaphore_wait_ms:_ -> ())
   with
   | Ok () -> ()
   | Error (`Semaphore_wait_timeout _) ->
       Alcotest.fail "unexpected semaphore wait timeout");
  Alcotest.(check (float 0.0001))
    "+Inf bucket increments"
    (before_inf +. 1.0)
    (semaphore_wait_bucket_for ~keeper_name ~cascade_profile ~channel ~le:"+Inf");
  Alcotest.(check (float 0.0001))
    "60s bucket increments"
    (before_60 +. 1.0)
    (semaphore_wait_bucket_for ~keeper_name ~cascade_profile ~channel ~le:"60")

let test_increments_per_channel () =
  let keeper = "sangsu-test-9771" in
  let channels =
    [ "autonomous_queue_head"; "autonomous"; "turn" ]
  in
  List.iter
    (fun channel ->
      let before = counter_for ~keeper ~channel in
      Masc_mcp.Prometheus.inc_counter
        Masc_mcp.Keeper_metrics.metric_keeper_semaphore_wait_timeout
        ~labels:[ ("keeper", keeper); ("channel", channel) ]
        ();
      Alcotest.(check (float 0.0001))
        (Printf.sprintf "%s +1" channel)
        (before +. 1.0)
        (counter_for ~keeper ~channel))
    channels

let test_keeper_isolation () =
  (* Different keepers must land in different series. *)
  let channel = "autonomous" in
  let keeper_a = "alpha-9771" in
  let keeper_b = "beta-9771" in
  let before_a = counter_for ~keeper:keeper_a ~channel in
  Masc_mcp.Prometheus.inc_counter
    Masc_mcp.Keeper_metrics.metric_keeper_semaphore_wait_timeout
    ~labels:[ ("keeper", keeper_b); ("channel", channel) ]
    ();
  Alcotest.(check (float 0.0001))
    "alpha unaffected by beta"
    before_a
    (counter_for ~keeper:keeper_a ~channel)

let test_channel_isolation () =
  (* Different channels for the same keeper must not bleed. *)
  let keeper = "channel-iso-9771" in
  let before_turn = counter_for ~keeper ~channel:"turn" in
  Masc_mcp.Prometheus.inc_counter
    Masc_mcp.Keeper_metrics.metric_keeper_semaphore_wait_timeout
    ~labels:[ ("keeper", keeper); ("channel", "autonomous_queue_head") ]
    ();
  Alcotest.(check (float 0.0001))
    "turn channel unchanged when queue_head fires"
    before_turn
    (counter_for ~keeper ~channel:"turn")

let test_wait_observation_reason_labels () =
  Alcotest.(check (list string))
    "pending reactive reasons"
    [ "semaphore_wait_pending"; "peers_holding_slot"; "channel_reactive" ]
    (Masc_mcp.Keeper_heartbeat_loop.semaphore_wait_observation_reasons
       ~kind:Masc_mcp.Keeper_heartbeat_loop.Semaphore_wait_pending
       ~channel:Masc_mcp.Keeper_world_observation.Reactive
       ());
  Alcotest.(check (list string))
    "timeout scheduled autonomous reasons"
    [
      "semaphore_wait_timeout";
      "peers_holding_slot";
      "channel_scheduled_autonomous";
    ]
    (Masc_mcp.Keeper_heartbeat_loop.semaphore_wait_observation_reasons
       ~kind:Masc_mcp.Keeper_heartbeat_loop.Semaphore_wait_timeout
       ~channel:Masc_mcp.Keeper_world_observation.Scheduled_autonomous
       ());
  Alcotest.(check (list string))
    "timeout reasons can carry precise phase"
    [
      "semaphore_wait_timeout";
      "phase_autonomous_queue_head";
      "channel_scheduled_autonomous";
    ]
    (Masc_mcp.Keeper_heartbeat_loop.semaphore_wait_observation_reasons
       ~phase_label:"autonomous_queue_head"
       ~kind:Masc_mcp.Keeper_heartbeat_loop.Semaphore_wait_timeout
       ~channel:Masc_mcp.Keeper_world_observation.Scheduled_autonomous
       ())

let test_wait_observation_updates_registry_skip_stamp () =
  let base_path =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-semaphore-wait-observation-%d" (Unix.getpid ()))
  in
  let keeper = "wait-observation-9771" in
  Masc_mcp.Keeper_registry.unregister ~base_path keeper;
  let meta = make_meta keeper in
  ignore (Masc_mcp.Keeper_registry.register ~base_path keeper meta);
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_registry.unregister ~base_path keeper)
    (fun () ->
      Masc_mcp.Keeper_heartbeat_loop.record_semaphore_wait_observation
        ~base_path
        ~keeper_name:keeper
        ~channel:Masc_mcp.Keeper_world_observation.Reactive
        ~kind:Masc_mcp.Keeper_heartbeat_loop.Semaphore_wait_pending
        ();
      match Masc_mcp.Keeper_registry.get ~base_path keeper with
      | Some { Masc_mcp.Keeper_registry.last_skip_observation = Some (_, reasons); _ } ->
        Alcotest.(check (list string))
          "pending wait stamped for watchdog suppression"
          [ "semaphore_wait_pending"; "peers_holding_slot"; "channel_reactive" ]
          reasons
      | Some _ -> Alcotest.fail "last_skip_observation was not stamped"
      | None -> Alcotest.fail "registered keeper missing")

let test_oas_timeout_budget_observation_reason_labels () =
  Alcotest.(check (list string))
    "timeout budget watchdog reasons"
    [
      "provider_runtime_error";
      "oas_timeout_budget";
      "keeper_turn_retry_backoff";
    ]
    Masc_mcp.Keeper_heartbeat_loop.oas_timeout_budget_observation_reasons

let test_oas_timeout_budget_observation_updates_registry () =
  let base_path =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-oas-timeout-observation-%d" (Unix.getpid ()))
  in
  let keeper = "oas-timeout-observation-12431" in
  Masc_mcp.Keeper_registry.unregister ~base_path keeper;
  let meta = make_meta keeper in
  ignore (Masc_mcp.Keeper_registry.register ~base_path keeper meta);
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_registry.unregister ~base_path keeper)
    (fun () ->
      let before =
        match Masc_mcp.Keeper_registry.get ~base_path keeper with
        | Some entry -> entry.meta.runtime.usage.last_turn_ts
        | None -> Alcotest.fail "registered keeper missing before observation"
      in
      Masc_mcp.Keeper_heartbeat_loop.record_oas_timeout_budget_observation
        ~base_path
        ~keeper_name:keeper;
      match Masc_mcp.Keeper_registry.get ~base_path keeper with
      | Some { Masc_mcp.Keeper_registry.last_skip_observation = Some (_, reasons);
               meta = updated_meta; _ } ->
        Alcotest.(check (list string))
          "timeout budget stamped for watchdog routing"
          Masc_mcp.Keeper_heartbeat_loop.oas_timeout_budget_observation_reasons
          reasons;
        Alcotest.(check bool)
          "last_turn_ts touched"
          true
          (updated_meta.runtime.usage.last_turn_ts >= before)
      | Some _ -> Alcotest.fail "last_skip_observation was not stamped"
      | None -> Alcotest.fail "registered keeper missing")

let () =
  Alcotest.run "keeper_semaphore_wait_counter_9771" [
    "metric_name", [
      Alcotest.test_case "canonical name stable" `Quick
        test_metric_name_stable;
    ];
    "queue_depth", [
      Alcotest.test_case "autonomous FIFO depth gauge tracks queue" `Quick
        test_autonomous_queue_depth_gauge_tracks_fifo;
    ];
    "histogram", [
      Alcotest.test_case "successful acquire emits wait buckets" `Quick
        test_successful_acquire_emits_wait_seconds_buckets;
    ];
    "counter", [
      Alcotest.test_case "all 3 channels increment" `Quick
        test_increments_per_channel;
    ];
    "isolation", [
      Alcotest.test_case "keepers isolated" `Quick test_keeper_isolation;
      Alcotest.test_case "channels isolated" `Quick test_channel_isolation;
    ];
    "watchdog_observation", [
      Alcotest.test_case "reason labels are stable" `Quick
        test_wait_observation_reason_labels;
      Alcotest.test_case "registry skip stamp is updated" `Quick
        test_wait_observation_updates_registry_skip_stamp;
      Alcotest.test_case "oas timeout labels are stable" `Quick
        test_oas_timeout_budget_observation_reason_labels;
      Alcotest.test_case "oas timeout registry stamp is updated" `Quick
        test_oas_timeout_budget_observation_updates_registry;
    ];
  ]
