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
    Masc_mcp.Prometheus.metric_keeper_semaphore_wait_timeout
    ~labels:[
      ("keeper", keeper);
      ("channel", channel);
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
    Masc_mcp.Prometheus.metric_keeper_semaphore_wait_timeout

let test_increments_per_channel () =
  let keeper = "sangsu-test-9771" in
  let channels =
    [ "autonomous_queue_head"; "autonomous"; "turn" ]
  in
  List.iter
    (fun channel ->
      let before = counter_for ~keeper ~channel in
      Masc_mcp.Prometheus.inc_counter
        Masc_mcp.Prometheus.metric_keeper_semaphore_wait_timeout
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
    Masc_mcp.Prometheus.metric_keeper_semaphore_wait_timeout
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
    Masc_mcp.Prometheus.metric_keeper_semaphore_wait_timeout
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
       ~channel:Masc_mcp.Keeper_world_observation.Reactive);
  Alcotest.(check (list string))
    "timeout scheduled autonomous reasons"
    [
      "semaphore_wait_timeout";
      "peers_holding_slot";
      "channel_scheduled_autonomous";
    ]
    (Masc_mcp.Keeper_heartbeat_loop.semaphore_wait_observation_reasons
       ~kind:Masc_mcp.Keeper_heartbeat_loop.Semaphore_wait_timeout
       ~channel:Masc_mcp.Keeper_world_observation.Scheduled_autonomous)

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
        ~kind:Masc_mcp.Keeper_heartbeat_loop.Semaphore_wait_pending;
      match Masc_mcp.Keeper_registry.get ~base_path keeper with
      | Some { Masc_mcp.Keeper_registry.last_skip_observation = Some (_, reasons); _ } ->
        Alcotest.(check (list string))
          "pending wait stamped for watchdog suppression"
          [ "semaphore_wait_pending"; "peers_holding_slot"; "channel_reactive" ]
          reasons
      | Some _ -> Alcotest.fail "last_skip_observation was not stamped"
      | None -> Alcotest.fail "registered keeper missing")

let () =
  Alcotest.run "keeper_semaphore_wait_counter_9771" [
    "metric_name", [
      Alcotest.test_case "canonical name stable" `Quick
        test_metric_name_stable;
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
    ];
  ]
