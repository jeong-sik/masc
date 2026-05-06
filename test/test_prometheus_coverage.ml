(** Prometheus Module Coverage Tests

    Tests for MASC Prometheus metrics:
    - metric_type enum (Counter, Gauge, Histogram)
    - type_to_string: metric type to Prometheus format
    - labels_to_string: label list to Prometheus format
    - register_counter, register_gauge
    - inc_counter, set_gauge, inc_gauge, dec_gauge
    - to_prometheus_text: full export
    - convenience functions
*)

open Alcotest

module Backend = Backend
module Backend_mutex_metrics = Masc_mcp.Backend_mutex_metrics
module Prometheus = Masc_mcp.Prometheus

(* ============================================================
   type_to_string Tests
   ============================================================ *)

let test_type_to_string_counter () =
  check string "counter" "counter" (Prometheus.type_to_string Prometheus.Counter)

let test_type_to_string_gauge () =
  check string "gauge" "gauge" (Prometheus.type_to_string Prometheus.Gauge)

let test_type_to_string_histogram () =
  check string "histogram" "histogram" (Prometheus.type_to_string Prometheus.Histogram)

(* ============================================================
   labels_to_string Tests
   ============================================================ *)

let test_labels_to_string_empty () =
  check string "empty" "" (Prometheus.labels_to_string [])

let test_labels_to_string_single () =
  let result = Prometheus.labels_to_string [("key", "value")] in
  check string "single" "{key=\"value\"}" result

let test_labels_to_string_multiple () =
  let result = Prometheus.labels_to_string [("k1", "v1"); ("k2", "v2")] in
  check string "multiple" "{k1=\"v1\",k2=\"v2\"}" result

let test_labels_to_string_escaped () =
  let result = Prometheus.labels_to_string [("key", "value\"with\"quotes")] in
  check bool "escaped" true (String.length result > 0)

(* ============================================================
   register_counter Tests
   ============================================================ *)

let test_register_counter_basic () =
  Prometheus.register_counter ~name:"test_counter_basic" ~help:"A test counter" ();
  (* Registration should not throw *)
  ()

let test_register_counter_with_labels () =
  Prometheus.register_counter
    ~name:"test_counter_labels"
    ~help:"Counter with labels"
    ~labels:[("env", "test")]
    ();
  ()

let test_register_counter_idempotent () =
  Prometheus.register_counter ~name:"test_counter_idem" ~help:"Idempotent" ();
  Prometheus.register_counter ~name:"test_counter_idem" ~help:"Idempotent" ();
  ()

(* ============================================================
   register_gauge Tests
   ============================================================ *)

let test_register_gauge_basic () =
  Prometheus.register_gauge ~name:"test_gauge_basic" ~help:"A test gauge" ();
  ()

let test_register_gauge_with_labels () =
  Prometheus.register_gauge
    ~name:"test_gauge_labels"
    ~help:"Gauge with labels"
    ~labels:[("env", "test")]
    ();
  ()

(* ============================================================
   inc_counter Tests
   ============================================================ *)

let test_inc_counter_default () =
  Prometheus.inc_counter "test_inc_default" ();
  ()

let test_inc_counter_with_delta () =
  Prometheus.inc_counter "test_inc_delta" ~delta:5.0 ();
  ()

let test_inc_counter_with_labels () =
  Prometheus.inc_counter "test_inc_labels" ~labels:[("type", "test")] ();
  ()

let test_inc_counter_auto_register () =
  Prometheus.inc_counter "test_auto_register" ();
  (* Counter is auto-registered if not exists *)
  ()

let test_metric_key_avoids_label_boundary_collision () =
  let name1 = "test_metric_key_collision_ab" in
  let labels1 = [("c", "")] in
  let name2 = "test_metric_key_collision_a" in
  let labels2 = [("bc", "")] in
  Prometheus.inc_counter name1 ~labels:labels1 ();
  Prometheus.inc_counter name2 ~labels:labels2 ~delta:2.0 ();
  check (option (float 0.001)) "first series"
    (Some 1.0)
    (Prometheus.get_metric_value name1 ~labels:labels1 ());
  check (option (float 0.001)) "second series"
    (Some 2.0)
    (Prometheus.get_metric_value name2 ~labels:labels2 ())

(* ============================================================
   set_gauge Tests
   ============================================================ *)

let test_set_gauge_basic () =
  Prometheus.set_gauge "test_set_basic" 42.0;
  ()

let test_set_gauge_with_labels () =
  Prometheus.set_gauge "test_set_labels" ~labels:[("env", "test")] 100.0;
  ()

let test_set_gauge_auto_register () =
  Prometheus.set_gauge "test_set_auto" 1.0;
  ()

let test_set_gauge_overwrite () =
  Prometheus.set_gauge "test_set_overwrite" 1.0;
  Prometheus.set_gauge "test_set_overwrite" 2.0;
  ()

(* ============================================================
   inc_gauge Tests
   ============================================================ *)

let test_inc_gauge_default () =
  Prometheus.inc_gauge "test_inc_gauge_default" ();
  ()

let test_inc_gauge_with_delta () =
  Prometheus.inc_gauge "test_inc_gauge_delta" ~delta:10.0 ();
  ()

let test_inc_gauge_with_labels () =
  Prometheus.inc_gauge "test_inc_gauge_labels" ~labels:[("type", "test")] ();
  ()

(* ============================================================
   dec_gauge Tests
   ============================================================ *)

let test_dec_gauge_default () =
  Prometheus.set_gauge "test_dec_gauge" 10.0;
  Prometheus.dec_gauge "test_dec_gauge" ();
  ()

let test_dec_gauge_with_delta () =
  Prometheus.set_gauge "test_dec_delta" 10.0;
  Prometheus.dec_gauge "test_dec_delta" ~delta:5.0 ();
  ()

(* ============================================================
   to_prometheus_text Tests
   ============================================================ *)

let test_to_prometheus_text_not_empty () =
  let text = Prometheus.to_prometheus_text () in
  check bool "not empty" true (String.length text > 0)

let test_to_prometheus_text_has_help () =
  let text = Prometheus.to_prometheus_text () in
  check bool "has HELP" true
    (try
      let _ = Str.search_forward (Str.regexp "# HELP") text 0 in true
    with Not_found -> false)

let test_to_prometheus_text_has_type () =
  let text = Prometheus.to_prometheus_text () in
  check bool "has TYPE" true
    (try
      let _ = Str.search_forward (Str.regexp "# TYPE") text 0 in true
    with Not_found -> false)

let test_to_prometheus_text_has_uptime () =
  let text = Prometheus.to_prometheus_text () in
  check bool "has uptime" true
    (try
      let _ = Str.search_forward (Str.regexp "masc_uptime_seconds") text 0 in true
    with Not_found -> false)

let test_to_prometheus_text_has_sse_metrics () =
  let text = Prometheus.to_prometheus_text () in
  let has metric =
    try
      let _ = Str.search_forward (Str.regexp metric) text 0 in
      true
    with Not_found -> false
  in
  check bool "has sse active gauge" true (has "masc_sse_connections_active");
  check bool "has sse reconnect counter" true (has "masc_sse_reconnects_total");
  check bool "has sse idle eviction counter" true (has "masc_sse_idle_evictions_total");
  check bool "has sse write failure counter" true (has "masc_sse_write_failures_total");
  check bool "has sse reject counter" true (has "masc_sse_rejects_total")

let text_has_literal text literal =
  try
    ignore (Str.search_forward (Str.regexp_string literal) text 0);
    true
  with Not_found -> false

let sample_value text prefix =
  String.split_on_char '\n' text
  |> List.find_map (fun line ->
         if String.starts_with ~prefix line then
           match List.rev (String.split_on_char ' ' line) with
           | raw :: _ -> float_of_string_opt raw
           | [] -> None
         else None)

let count_lines_with_prefix text prefix =
  String.split_on_char '\n' text
  |> List.filter (fun line -> String.starts_with ~prefix line)
  |> List.length

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun entry -> rm_rf (Filename.concat path entry));
      Unix.rmdir path
    end else
      Sys.remove path

let with_eio_backend f =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "backend-mutex-metrics-%d-%0.f" (Unix.getpid ())
         (Unix.gettimeofday () *. 1000000.))
  in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let config =
        {
          Backend.default_config with
          base_path = dir;
          node_id = "prometheus-test";
          cluster_name = "prometheus-test";
        }
      in
      let backend = Backend.FileSystem.create ~fs config in
      f backend)

let test_keeper_metrics_registered () =
  let text = Prometheus.to_prometheus_text () in
  let has metric =
    try
      let _ = Str.search_forward (Str.regexp metric) text 0 in
      true
    with Not_found -> false
  in
  check bool "has keeper compactions counter" true
    (has "masc_keeper_compactions_total");
  check bool "has keeper compaction ratio gauge" true
    (has "masc_keeper_compaction_ratio_change");
  check bool "has keeper compaction saved tokens counter" true
    (has "masc_keeper_compaction_saved_tokens_total");
  check bool "has keeper heartbeat successes counter" true
    (has "masc_keeper_heartbeat_successes_total");
  check bool "has keeper heartbeat failures counter" true
    (has "masc_keeper_heartbeat_failures_total");
  check bool "has keeper total cost gauge" true
    (text_has_literal text
       ("# TYPE " ^ Prometheus.metric_keeper_total_cost_usd ^ " gauge"));
  check bool "has keeper tool duration histogram" true
    (has "masc_keeper_tool_call_duration_seconds");
  check bool "has operator compact counter" true
    (has "masc_keeper_operator_compact_total");
  check bool "has operator clear counter" true
    (has "masc_keeper_operator_clear_total");
  check bool "has tool call counter" true
    (has "masc_tool_call_total")

(* #12801 / #12797 / #12799: new metrics registration coverage *)
let test_new_issue_metrics_registered () =
  let text = Prometheus.to_prometheus_text () in
  let check_metric_name name =
    let has_help =
      try
        let _ = Str.search_forward (Str.regexp ("# HELP " ^ name ^ " ")) text 0 in true
      with Not_found -> false
    in
    check bool (name ^ " registered") true has_help
  in
  check_metric_name Prometheus.metric_keeper_liveness_recovery_attempts;
  check_metric_name Prometheus.metric_keeper_liveness_recovery_outcomes;
  check_metric_name Prometheus.metric_cascade_server_error_skip_total;
  check_metric_name Prometheus.metric_keeper_passive_loop_detected_total;
  check_metric_name Prometheus.metric_write_meta_cas_retry_total

let test_review_blocker_metrics_registered () =
  let text = Prometheus.to_prometheus_text () in
  let check_registered metric =
    check bool (metric ^ " HELP") true
      (text_has_literal text ("# HELP " ^ metric ^ " "));
    check bool (metric ^ " TYPE") true
      (text_has_literal text ("# TYPE " ^ metric ^ " counter"))
  in
  check_registered Prometheus.metric_tool_join_required_guard;
  check_registered Prometheus.metric_timeout_policy_overshoot;
  check_registered Prometheus.metric_auth_credential_token_duplicate;
  check_registered Prometheus.metric_auth_credential_token_rotated;
  check_registered Prometheus.metric_telemetry_coverage_gap;
  check_registered Prometheus.metric_telemetry_unified_source_read_failures;
  check_registered Prometheus.metric_tool_assignment_telemetry_failures;
  check_registered Prometheus.metric_keeper_oas_hook_output_parse_failures;
  check_registered Prometheus.metric_inference_queue_rejected;
  check_registered Prometheus.metric_telemetry_observe_failures;
  check_registered Prometheus.metric_coord_telemetry_drop;
  check_registered Prometheus.metric_coord_claim_post_provision_failures;
  check_registered Prometheus.metric_keeper_lifecycle_callback_failures;
  check_registered Prometheus.metric_keeper_event_bus_drain

let test_distributed_lock_metric_registered () =
  let text = Prometheus.to_prometheus_text () in
  check bool "has distributed lock HELP" true
    (text_has_literal text
       ("# HELP " ^ Prometheus.metric_distributed_lock_acquire_failed ^ " "));
  check bool "has distributed lock TYPE" true
    (text_has_literal text
       ("# TYPE " ^ Prometheus.metric_distributed_lock_acquire_failed
        ^ " counter"))

let test_bg_task_sidecar_metric_registered () =
  let text = Prometheus.to_prometheus_text () in
  check bool "has bg task sidecar HELP" true
    (text_has_literal text
       ("# HELP " ^ Prometheus.metric_bg_task_sidecar_failures ^ " "));
  check bool "has bg task sidecar TYPE" true
    (text_has_literal text
       ("# TYPE " ^ Prometheus.metric_bg_task_sidecar_failures ^ " counter"))

let test_workspace_route_metric_registered () =
  let text = Prometheus.to_prometheus_text () in
  check bool "has workspace route failure HELP" true
    (text_has_literal text
       ("# HELP " ^ Prometheus.metric_workspace_route_failures ^ " "));
  check bool "has workspace route failure TYPE" true
    (text_has_literal text
       ("# TYPE " ^ Prometheus.metric_workspace_route_failures ^ " counter"))

let test_build_identity_probe_metric_registered () =
  let text = Prometheus.to_prometheus_text () in
  check bool "has build identity probe HELP" true
    (text_has_literal text
       ("# HELP " ^ Prometheus.metric_build_identity_probe_failures ^ " "));
  check bool "has build identity probe TYPE" true
    (text_has_literal text
       ("# TYPE " ^ Prometheus.metric_build_identity_probe_failures
        ^ " counter"))

let test_memory_usage_metric_registered () =
  let text = Prometheus.to_prometheus_text () in
  check bool "has memory usage HELP" true
    (text_has_literal text
       ("# HELP " ^ Prometheus.metric_memory_usage_bytes ^ " "));
  check bool "has memory usage TYPE" true
    (text_has_literal text
       ("# TYPE " ^ Prometheus.metric_memory_usage_bytes ^ " gauge"))

let test_builtin_gauge_update_does_not_duplicate_sample () =
  (* Save and restore the gauge so this test does not leak Prometheus
     process state into other tests that may assume the default. *)
  let prior =
    Prometheus.metric_value_or_zero Prometheus.metric_memory_usage_bytes ()
  in
  Fun.protect
    ~finally:(fun () ->
      Prometheus.set_gauge Prometheus.metric_memory_usage_bytes prior)
    (fun () ->
      Prometheus.set_gauge Prometheus.metric_memory_usage_bytes 123.0;
      let text = Prometheus.to_prometheus_text () in
      check int "single memory usage sample" 1
        (count_lines_with_prefix text
           (Prometheus.metric_memory_usage_bytes ^ " ")))

let test_goal_attainment_metrics_registered () =
  let text = Prometheus.to_prometheus_text () in
  check bool "has goal attainment pct HELP" true
    (text_has_literal text
       ("# HELP " ^ Prometheus.metric_goal_attainment_pct ^ " "));
  check bool "has goal attainment pct TYPE" true
    (text_has_literal text
       ("# TYPE " ^ Prometheus.metric_goal_attainment_pct ^ " gauge"));
  check bool "has goal attainment measured HELP" true
    (text_has_literal text
       ("# HELP " ^ Prometheus.metric_goal_attainment_measured ^ " "));
  check bool "has goal attainment measured TYPE" true
    (text_has_literal text
       ("# TYPE " ^ Prometheus.metric_goal_attainment_measured ^ " gauge"))

let test_histogram_exported_as_summary () =
  let name = "test_hist_export_fmt" in
  Prometheus.register_histogram ~name ~help:"export format test" ();
  Prometheus.observe_histogram name 1.5;
  Prometheus.observe_histogram name 2.5;
  let text = Prometheus.to_prometheus_text () in
  let has pat =
    try ignore (Str.search_forward (Str.regexp_string pat) text 0); true
    with Not_found -> false
  in
  check bool "TYPE summary" true
    (has (Printf.sprintf "# TYPE %s summary" name));
  check bool "has _sum" true
    (has (Printf.sprintf "%s_sum" name));
  check bool "has _count" true
    (has (Printf.sprintf "%s_count" name));
  check bool "no standalone _count TYPE" false
    (has (Printf.sprintf "# TYPE %s_count" name))

let test_backend_mutex_metrics_emit_after_install () =
  Backend_mutex_metrics.install ();
  with_eio_backend (fun backend ->
      match Backend.FileSystem.set backend "mutex-metric-test" "value" with
      | Ok () -> ()
      | Error _ -> fail "backend set failed");
  let text = Prometheus.to_prometheus_text () in
  let acquire_count_prefix =
    Prometheus.metric_backend_mutex_acquire_sec ^ "_count{op=\"set\"} "
  in
  let held_count_prefix =
    Prometheus.metric_backend_mutex_held_sec ^ "_count{op=\"set\"} "
  in
  check bool "backend acquire mutex sample emitted" true
    (match sample_value text acquire_count_prefix with
     | Some value -> Float.compare value 0.0 > 0
     | None -> false);
  check bool "backend held mutex sample emitted" true
    (match sample_value text held_count_prefix with
     | Some value -> Float.compare value 0.0 > 0
     | None -> false)

(* ============================================================
   Convenience Functions Tests
   ============================================================ *)

let test_record_request () =
  Prometheus.record_request ();
  ()

let test_record_task_completed () =
  Prometheus.record_task_completed ();
  ()

let test_record_task_failed () =
  Prometheus.record_task_failed ();
  ()

let test_record_error_default () =
  Prometheus.record_error ();
  ()

let test_record_error_with_type () =
  Prometheus.record_error ~error_type:"test_error" ();
  ()

let test_set_active_agents () =
  Prometheus.set_active_agents 5;
  ()

let test_set_pending_tasks () =
  Prometheus.set_pending_tasks 10;
  ()

(* ============================================================
   update_uptime Tests
   ============================================================ *)

let test_update_uptime () =
  Prometheus.update_uptime ();
  ()

(* ============================================================
   init Tests
   ============================================================ *)

let test_init () =
  (* init is called automatically on module load *)
  Prometheus.init ();
  ()

(* ============================================================
   label Type Tests
   ============================================================ *)

let test_label_type () =
  let l : Prometheus.label = ("key", "value") in
  check string "fst" "key" (fst l);
  check string "snd" "value" (snd l)

(* ============================================================
   Edge Cases
   ============================================================ *)

let test_empty_metric_name () =
  Prometheus.inc_counter "" ();
  ()

let test_special_chars_in_name () =
  Prometheus.inc_counter "metric_with_underscore" ();
  ()

let test_unicode_in_label () =
  Prometheus.inc_counter "test_unicode" ~labels:[("한글", "값")] ();
  ()

let test_negative_gauge () =
  Prometheus.set_gauge "test_negative" (-10.0);
  ()

let test_zero_gauge () =
  Prometheus.set_gauge "test_zero" 0.0;
  ()

let test_large_value () =
  Prometheus.set_gauge "test_large" 1e15;
  ()

let test_small_value () =
  Prometheus.set_gauge "test_small" 1e-15;
  ()

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run "Prometheus Coverage" [
    "type_to_string", [
      test_case "counter" `Quick test_type_to_string_counter;
      test_case "gauge" `Quick test_type_to_string_gauge;
      test_case "histogram" `Quick test_type_to_string_histogram;
    ];
    "labels_to_string", [
      test_case "empty" `Quick test_labels_to_string_empty;
      test_case "single" `Quick test_labels_to_string_single;
      test_case "multiple" `Quick test_labels_to_string_multiple;
      test_case "escaped" `Quick test_labels_to_string_escaped;
    ];
    "register_counter", [
      test_case "basic" `Quick test_register_counter_basic;
      test_case "with labels" `Quick test_register_counter_with_labels;
      test_case "idempotent" `Quick test_register_counter_idempotent;
    ];
    "register_gauge", [
      test_case "basic" `Quick test_register_gauge_basic;
      test_case "with labels" `Quick test_register_gauge_with_labels;
    ];
    "inc_counter", [
      test_case "default" `Quick test_inc_counter_default;
      test_case "with delta" `Quick test_inc_counter_with_delta;
      test_case "with labels" `Quick test_inc_counter_with_labels;
      test_case "auto register" `Quick test_inc_counter_auto_register;
      test_case "label boundary collision" `Quick
        test_metric_key_avoids_label_boundary_collision;
    ];
    "set_gauge", [
      test_case "basic" `Quick test_set_gauge_basic;
      test_case "with labels" `Quick test_set_gauge_with_labels;
      test_case "auto register" `Quick test_set_gauge_auto_register;
      test_case "overwrite" `Quick test_set_gauge_overwrite;
    ];
    "inc_gauge", [
      test_case "default" `Quick test_inc_gauge_default;
      test_case "with delta" `Quick test_inc_gauge_with_delta;
      test_case "with labels" `Quick test_inc_gauge_with_labels;
    ];
    "dec_gauge", [
      test_case "default" `Quick test_dec_gauge_default;
      test_case "with delta" `Quick test_dec_gauge_with_delta;
    ];
    "to_prometheus_text", [
      test_case "not empty" `Quick test_to_prometheus_text_not_empty;
      test_case "has HELP" `Quick test_to_prometheus_text_has_help;
      test_case "has TYPE" `Quick test_to_prometheus_text_has_type;
      test_case "has uptime" `Quick test_to_prometheus_text_has_uptime;
      test_case "has sse metrics" `Quick test_to_prometheus_text_has_sse_metrics;
      test_case "keeper metrics registered" `Quick test_keeper_metrics_registered;
      test_case "new issue metrics registered (#12801/#12797/#12799)" `Quick
        test_new_issue_metrics_registered;
      test_case "review blocker metrics registered" `Quick
        test_review_blocker_metrics_registered;
      test_case "distributed lock metric registered" `Quick
        test_distributed_lock_metric_registered;
      test_case "bg task sidecar metric registered" `Quick
        test_bg_task_sidecar_metric_registered;
      test_case "workspace route metric registered" `Quick
        test_workspace_route_metric_registered;
      test_case "build identity probe metric registered" `Quick
        test_build_identity_probe_metric_registered;
      test_case "memory usage metric registered" `Quick
        test_memory_usage_metric_registered;
      test_case "built-in gauge update does not duplicate sample" `Quick
        test_builtin_gauge_update_does_not_duplicate_sample;
      test_case "goal attainment metrics registered" `Quick
        test_goal_attainment_metrics_registered;
      test_case "histogram exported as summary with _sum/_count"
        `Quick test_histogram_exported_as_summary;
      test_case "backend mutex observers emit histogram samples" `Quick
        test_backend_mutex_metrics_emit_after_install;
    ];
    "convenience", [
      test_case "record_request" `Quick test_record_request;
      test_case "record_task_completed" `Quick test_record_task_completed;
      test_case "record_task_failed" `Quick test_record_task_failed;
      test_case "record_error default" `Quick test_record_error_default;
      test_case "record_error with type" `Quick test_record_error_with_type;
      test_case "set_active_agents" `Quick test_set_active_agents;
      test_case "set_pending_tasks" `Quick test_set_pending_tasks;
    ];
    "update_uptime", [
      test_case "update" `Quick test_update_uptime;
    ];
    "init", [
      test_case "init" `Quick test_init;
    ];
    "label", [
      test_case "type" `Quick test_label_type;
    ];
    "edge_cases", [
      test_case "empty name" `Quick test_empty_metric_name;
      test_case "underscore name" `Quick test_special_chars_in_name;
      test_case "unicode label" `Quick test_unicode_in_label;
      test_case "negative gauge" `Quick test_negative_gauge;
      test_case "zero gauge" `Quick test_zero_gauge;
      test_case "large value" `Quick test_large_value;
      test_case "small value" `Quick test_small_value;
    ];
  ]
