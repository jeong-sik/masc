(** Otel_runtime_observables — computed-sample source regression tests.

    The source must always yield the console-sink and transition-audit
    samples (present from process start: no absence-vs-zero ambiguity),
    omit bus/pool families when those subsystems are not running (unit
    test process), and report watched-store sizes from a real directory
    walk with the 60s cache honored. *)

open Alcotest
module Obs = Masc.Otel_runtime_observables

let sample_names samples = List.map (fun (s : Otel_metrics.sample) -> s.name) samples

let find name samples =
  List.find_opt (fun (s : Otel_metrics.sample) -> String.equal s.name name) samples

let with_temp_masc_root f =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "otel-obs-test-%d" (Unix.getpid ()))
  in
  let store = Filename.concat root "tool_calls" in
  Unix.mkdir root 0o755;
  Unix.mkdir store 0o755;
  let oc = open_out (Filename.concat store "2026-06-10.jsonl") in
  output_string oc "{\"a\":1}\n{\"b\":2}\n";
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      Sys.remove (Filename.concat store "2026-06-10.jsonl");
      Unix.rmdir store;
      Unix.rmdir root)
    (fun () -> f root)

let test_core_samples_always_present () =
  with_temp_masc_root (fun root ->
    Obs.For_testing.reset_store_cache ();
    let samples = Obs.For_testing.samples ~masc_root:root () in
    List.iter
      (fun name ->
        check bool (Printf.sprintf "sample %s present" name) true
          (Option.is_some (find name samples)))
      [ "masc_console_sink_dropped_total"
      ; "masc_console_sink_queue_depth"
      ; "masc_keeper_transition_audit_queue_depth"
      ];
    match find "masc_console_sink_dropped_total" samples with
    | None -> fail "unreachable"
    | Some s -> check bool "dropped is a counter" true (s.kind = Otel_metrics.Counter))

let test_bus_and_pool_absent_without_subsystems () =
  with_temp_masc_root (fun root ->
    Obs.For_testing.reset_store_cache ();
    let names = sample_names (Obs.For_testing.samples ~masc_root:root ()) in
    List.iter
      (fun prefix ->
        check bool
          (Printf.sprintf "no %s* without the subsystem" prefix)
          false
          (List.exists (fun n -> String.starts_with ~prefix n) names))
      [ "masc_event_bus_"; "masc_pool_" ])

let test_store_bytes_from_walk () =
  with_temp_masc_root (fun root ->
    Obs.For_testing.reset_store_cache ();
    let samples = Obs.For_testing.samples ~masc_root:root () in
    let bytes =
      List.find_opt
        (fun (s : Otel_metrics.sample) ->
          String.equal s.name "masc_store_bytes"
          && s.labels = [ "store", "tool_calls" ])
        samples
    in
    match bytes with
    | None -> fail "masc_store_bytes{store=tool_calls} missing"
    | Some s ->
      check bool "bytes counted" true (s.value > 0.0);
      (* second call inside the 60s window serves the cache *)
      let again = Obs.For_testing.samples ~masc_root:root () in
      (match
         List.find_opt
           (fun (x : Otel_metrics.sample) ->
             String.equal x.name "masc_store_bytes"
             && x.labels = [ "store", "tool_calls" ])
           again
       with
       | None -> fail "cached store sample missing"
       | Some s2 -> check (float 0.0) "cached value identical" s.value s2.value))

let test_fd_samples_present () =
  with_temp_masc_root (fun root ->
    Obs.For_testing.reset_store_cache ();
    let samples = Obs.For_testing.samples ~masc_root:root () in
    check bool "active-operation gauge present" true
      (Option.is_some (find "masc_fd_active_operations" samples));
    check bool "typed resource-error counter present" true
      (Option.is_some (find "masc_fd_resource_errors_total" samples));
    check bool "legacy pressure gauge absent" true
      (Option.is_none (find "masc_fd_pressure_active" samples)))

let test_bus_samples_project_real_oas_stats () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun _sw ->
      let bus = Agent_sdk.Event_bus.create () in
      let contract =
        Masc.Masc_event_bus_subscription.for_subscriber
          Masc.Masc_event_bus_subscription.Sse_bridge
      in
      let sub = Masc.Agent_sdk_metrics_bridge.subscribe ~contract bus in
      let capacity = Masc.Masc_event_bus_subscription.capacity contract in
      let event =
        Agent_sdk.Event_bus.mk_event
          (Agent_sdk.Event_bus.Custom ("observable_test", `Null))
      in
      for _ = 1 to capacity + 1 do
        Masc.Agent_sdk_metrics_bridge.publish bus event
      done;
      let labels =
        [ "bus", "test"
        ; "purpose", Masc.Masc_event_bus_subscription.purpose contract
        ; ( "overflow"
          , Masc.Masc_event_bus_subscription.overflow contract
            |> Masc.Masc_event_bus_subscription.overflow_label )
        ]
      in
      let samples = Obs.For_testing.bus_samples_of ~bus_label:"test" bus in
      let value name =
        match
          List.find_opt
            (fun (sample : Otel_metrics.sample) ->
               String.equal sample.name name && sample.labels = labels)
            samples
        with
        | Some sample -> sample.value
        | None -> failf "missing %s sample" name
      in
      check (float 0.0)
        "capacity is the live OAS contract"
        (Float.of_int capacity)
        (value "masc_event_bus_subscriber_capacity");
      check (float 0.0)
        "depth is capacity-bounded"
        (Float.of_int capacity)
        (value "masc_event_bus_subscriber_depth");
      check (float 0.0)
        "published is projected"
        (Float.of_int (capacity + 1))
        (value "masc_event_bus_subscriber_published");
      check (float 0.0)
        "drop is observable"
        1.0
        (value "masc_event_bus_subscriber_dropped");
      Masc.Agent_sdk_metrics_bridge.unsubscribe bus sub))

let () =
  run "otel_runtime_observables"
    [ ( "samples"
      , [ test_case "core samples always present" `Quick test_core_samples_always_present
        ; test_case "bus/pool absent without subsystems" `Quick
            test_bus_and_pool_absent_without_subsystems
        ; test_case "store bytes from walk + cache" `Quick test_store_bytes_from_walk
        ; test_case "fd samples present" `Quick test_fd_samples_present
        ; test_case "event bus samples use live OAS stats" `Quick
            test_bus_samples_project_real_oas_stats
        ] )
    ]
