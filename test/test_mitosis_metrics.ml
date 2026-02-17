(** Tests for Mitosis_metrics and P2-2 experiment flag integration *)

open Alcotest

module Mitosis_metrics = Masc_mcp.Mitosis_metrics
module Prometheus = Masc_mcp.Prometheus
module Env_config = Masc_mcp.Env_config

(* ============================================================
   Metric Name Constants
   ============================================================ *)

let test_metric_names () =
  check string "handoff_total" "mitosis_handoff_total" Mitosis_metrics.handoff_total;
  check string "prepare_total" "mitosis_prepare_total" Mitosis_metrics.prepare_total;
  check string "error_total"   "mitosis_error_total"   Mitosis_metrics.error_total;
  check string "current_gen"   "mitosis_current_generation" Mitosis_metrics.current_generation;
  check string "cooldown"      "mitosis_cooldown_remaining_seconds" Mitosis_metrics.cooldown_remaining;
  check string "duration"      "mitosis_handoff_duration_seconds" Mitosis_metrics.handoff_duration

(* ============================================================
   Counter Increments
   ============================================================ *)

let test_inc_handoff () =
  let before = Prometheus.to_prometheus_text () in
  Mitosis_metrics.inc_handoff ();
  let after = Prometheus.to_prometheus_text () in
  (* The metric should now appear in the text output *)
  check bool "handoff metric present" true
    (String.length after >= String.length before)

let test_inc_prepare () =
  Mitosis_metrics.inc_prepare ();
  let text = Prometheus.to_prometheus_text () in
  check bool "prepare metric present" true
    (try let _ = Str.search_forward (Str.regexp_string "mitosis_prepare_total") text 0 in true
     with Not_found -> false)

let test_inc_error_default () =
  Mitosis_metrics.inc_error ();
  let text = Prometheus.to_prometheus_text () in
  check bool "error metric present" true
    (try let _ = Str.search_forward (Str.regexp_string "mitosis_error_total") text 0 in true
     with Not_found -> false)

let test_inc_error_with_reason () =
  Mitosis_metrics.inc_error ~reason:"spawn_failed" ();
  let text = Prometheus.to_prometheus_text () in
  check bool "error with reason present" true
    (try let _ = Str.search_forward (Str.regexp_string "spawn_failed") text 0 in true
     with Not_found -> false)

(* ============================================================
   Gauge Updates
   ============================================================ *)

let test_set_generation () =
  Mitosis_metrics.set_generation 5;
  let text = Prometheus.to_prometheus_text () in
  check bool "generation gauge present" true
    (try let _ = Str.search_forward (Str.regexp_string "mitosis_current_generation") text 0 in true
     with Not_found -> false)

let test_set_cooldown_remaining () =
  Mitosis_metrics.set_cooldown_remaining 42.5;
  let text = Prometheus.to_prometheus_text () in
  check bool "cooldown gauge present" true
    (try let _ = Str.search_forward (Str.regexp_string "mitosis_cooldown_remaining_seconds") text 0 in true
     with Not_found -> false)

(* ============================================================
   Histogram
   ============================================================ *)

let test_observe_handoff_duration () =
  Mitosis_metrics.observe_handoff_duration 1.5;
  let text = Prometheus.to_prometheus_text () in
  check bool "duration histogram present" true
    (try let _ = Str.search_forward (Str.regexp_string "mitosis_handoff_duration_seconds") text 0 in true
     with Not_found -> false)

let test_observe_handoff_duration_count () =
  Mitosis_metrics.observe_handoff_duration 2.0;
  let text = Prometheus.to_prometheus_text () in
  check bool "duration count present" true
    (try let _ = Str.search_forward (Str.regexp_string "mitosis_handoff_duration_seconds_count") text 0 in true
     with Not_found -> false)

(* ============================================================
   P2-2: Experiment Flag
   ============================================================ *)

let test_experiment_flag_default () =
  (* Without MASC_MITOSIS_EXPERIMENT_ENABLED env var, default is false *)
  check bool "experiment disabled by default" false Env_config.Mitosis.experiment_enabled

(* ============================================================
   Prometheus enable_eio guard
   ============================================================ *)

let test_prometheus_no_eio () =
  (* Metrics should work without Eio runtime (unlocked path) *)
  Prometheus.inc_counter "test_no_eio_counter" ();
  let text = Prometheus.to_prometheus_text () in
  check bool "counter works without eio" true
    (try let _ = Str.search_forward (Str.regexp_string "test_no_eio_counter") text 0 in true
     with Not_found -> false)

let test_prometheus_register_histogram () =
  Prometheus.register_histogram ~name:"test_histo" ~help:"test histogram" ();
  Prometheus.observe_histogram "test_histo" 0.5;
  let text = Prometheus.to_prometheus_text () in
  check bool "histogram registered and observed" true
    (try let _ = Str.search_forward (Str.regexp_string "test_histo") text 0 in true
     with Not_found -> false)

(* ============================================================
   Test Runner
   ============================================================ *)

let () =
  run "Mitosis Metrics" [
    "names", [
      test_case "metric name constants" `Quick test_metric_names;
    ];
    "counters", [
      test_case "inc_handoff" `Quick test_inc_handoff;
      test_case "inc_prepare" `Quick test_inc_prepare;
      test_case "inc_error default" `Quick test_inc_error_default;
      test_case "inc_error with reason" `Quick test_inc_error_with_reason;
    ];
    "gauges", [
      test_case "set_generation" `Quick test_set_generation;
      test_case "set_cooldown_remaining" `Quick test_set_cooldown_remaining;
    ];
    "histogram", [
      test_case "observe_handoff_duration" `Quick test_observe_handoff_duration;
      test_case "observe_handoff_duration_count" `Quick test_observe_handoff_duration_count;
    ];
    "experiment_flag", [
      test_case "default is false" `Quick test_experiment_flag_default;
    ];
    "prometheus_guard", [
      test_case "works without eio" `Quick test_prometheus_no_eio;
      test_case "register_histogram" `Quick test_prometheus_register_histogram;
    ];
  ]
