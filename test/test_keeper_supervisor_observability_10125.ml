(* test/test_keeper_supervisor_observability_10125.ml

   #10125 reports a 4h+ silent fleet death after server
   restart: 14 keepers exit on runtime exhaustion and the
   supervisor sweep never restarts (the
   "keeper supervisor sweep started" log line is missing
   for the entire post-restart session).

   The deeper fix is to remove the conditional gate on
   [maybe_start_supervisor_sweep] so the sweep starts
   unconditionally during server boot.  This test covers
   the observability half: a counter that advances each
   time the Pulse actually starts, and a gauge that
   advances on every sweep beat.  Operators alert on:

     - counter_starts == 0 after a server restart
       (sweep never came up); and
     - now - last_sweep_unixtime > 2 × interval
       (sweep stalled).

   Pulse-driven integration is too heavy for a unit test
   (needs Eio switch, clock, full ctx) so the tests below
   exercise the metric surface and helper directly.  The
   wiring inside [start_supervisor_sweep] is verified by
   reading the diff: counter increments before the log
   line, gauge sets before AND after each beat.
*)

open Masc

let () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-keeper-supervisor-obs-10125-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir
;;

module R = Masc.Keeper_runtime
module Metrics = Masc.Otel_metric_store

let starts_for ~base_path =
  Metrics.metric_value_or_zero
    Keeper_metrics.(to_string SupervisorSweepStarts)
    ~labels:[ "base_path", base_path ]
    ()
;;

let last_sweep_for ~base_path =
  Metrics.get_metric_value
    Keeper_metrics.(to_string SupervisorLastSweepUnixtime)
    ~labels:[ "base_path", base_path ]
    ()
;;

(* The sweep-start counter and unlabeled last-sweep gauge cell are declared at
   init via zero-fill so [get_metric_value ~labels:[] ()] returns [Some 0.0] if
   and only if the registration block actually ran. Labelled [base_path] gauge
   cells intentionally stay lazy until a sweep beat writes an honest value.

   Note: [metric_total] cannot be used as a registration check because
   it folds across all labelled variants and returns [0.0] for both
   "not registered" and "registered but no observations yet". *)
let test_counter_and_unlabeled_gauge_registered () =
  let starts =
    Metrics.get_metric_value Keeper_metrics.(to_string SupervisorSweepStarts) ()
  in
  let last_sweep =
    Metrics.get_metric_value
      Keeper_metrics.(to_string SupervisorLastSweepUnixtime)
      ()
  in
  Alcotest.(check bool) "sweep_starts registered" true (Option.is_some starts);
  Alcotest.(check (option (float 0.001)))
    "last_sweep_unixtime registered at zero"
    (Some 0.0)
    last_sweep
;;

(* Helper returns [None] before the sweep gauge is set in
   this process.  Dashboards must distinguish "never set"
   (sweep never started) from "set in the past" (sweep
   started then stalled) — a numeric default of 0 would
   blur that boundary. *)
let test_age_helper_returns_none_before_first_sweep () =
  let base_path = "/tmp/test-supervisor-obs-never-started-10125" in
  Alcotest.(check (option (float 0.001)))
    "no gauge label set yet"
    None
    (last_sweep_for ~base_path);
  Alcotest.(check (option (float 0.001)))
    "age helper agrees: None"
    None
    (R.supervisor_sweep_age_seconds ~base_path)
;;

(* Setting the gauge to "now" makes the helper return a
   small positive age (read-after-write).  This exercises
   the same code path [on_beat] uses to mark sweep
   liveness. *)
let test_age_helper_advances_after_gauge_set () =
  let base_path = "/tmp/test-supervisor-obs-advances-10125" in
  Metrics.set_gauge
    Keeper_metrics.(to_string SupervisorLastSweepUnixtime)
    ~labels:[ "base_path", base_path ]
    (Unix.gettimeofday ());
  match R.supervisor_sweep_age_seconds ~base_path with
  | None -> Alcotest.fail "expected Some age after gauge set"
  | Some age ->
    Alcotest.(check bool)
      "age is small (< 5s) and non-negative"
      true
      (age >= 0.0 && age < 5.0)
;;

(* Setting the gauge to a deliberately old timestamp
   reproduces the #10125 "stalled sweep" condition.  The
   helper returns a large positive age that dashboards
   convert into the [stale] badge. *)
let test_age_helper_reports_stale_when_gauge_old () =
  let base_path = "/tmp/test-supervisor-obs-stale-10125" in
  let stale_ts = Unix.gettimeofday () -. 3600.0 in
  Metrics.set_gauge
    Keeper_metrics.(to_string SupervisorLastSweepUnixtime)
    ~labels:[ "base_path", base_path ]
    stale_ts;
  match R.supervisor_sweep_age_seconds ~base_path with
  | None -> Alcotest.fail "expected Some age"
  | Some age -> Alcotest.(check bool) "stale gauge: age >= 1 hour" true (age >= 3599.0)
;;

(* Counter increments are per-base_path so a bench harness
   that exercises multiple base paths in one process can
   tell which one had its supervisor restart. *)
let test_counter_per_base_path_isolation () =
  let a = "/tmp/test-supervisor-obs-iso-A-10125" in
  let b = "/tmp/test-supervisor-obs-iso-B-10125" in
  let before_b = starts_for ~base_path:b in
  Metrics.inc_counter
    Keeper_metrics.(to_string SupervisorSweepStarts)
    ~labels:[ "base_path", a ]
    ();
  Metrics.inc_counter
    Keeper_metrics.(to_string SupervisorSweepStarts)
    ~labels:[ "base_path", a ]
    ();
  Alcotest.(check (float 0.0001))
    "base_path B unaffected by base_path A increments"
    before_b
    (starts_for ~base_path:b);
  Alcotest.(check (float 0.0001))
    "base_path A counter advanced by 2"
    2.0
    (starts_for ~base_path:a)
;;

(* The registry uses [base_path] as the label key for both metrics, so
   downstream OTel export keeps the join key intact. *)
let test_registry_snapshot_includes_metrics () =
  let base_path = "/tmp/test-supervisor-obs-export-10125" in
  let starts = Keeper_metrics.(to_string SupervisorSweepStarts) in
  let last_sweep = Keeper_metrics.(to_string SupervisorLastSweepUnixtime) in
  Metrics.inc_counter
    starts
    ~labels:[ "base_path", base_path ]
    ();
  Metrics.set_gauge
    last_sweep
    ~labels:[ "base_path", base_path ]
    (Unix.gettimeofday ());
  let has_metric name metric_type =
    Metrics.snapshot ()
    |> List.exists (fun (m : Metrics.metric) ->
      String.equal m.name name
      && m.metric_type = metric_type
      && List.mem ("base_path", base_path) m.labels)
  in
  Alcotest.(check bool)
    "counter name appears in registry"
    true
    (has_metric starts Metrics.Counter);
  Alcotest.(check bool)
    "gauge name appears in registry"
    true
    (has_metric last_sweep Metrics.Gauge)
;;

let () =
  Alcotest.run
    "keeper_supervisor_observability_10125"
    [ ( "metrics-registered"
      , [ Alcotest.test_case
            "counter and unlabeled gauge registered at init"
            `Quick
            test_counter_and_unlabeled_gauge_registered
        ] )
    ; ( "age-helper"
      , [ Alcotest.test_case
            "None before first sweep"
            `Quick
            test_age_helper_returns_none_before_first_sweep
        ; Alcotest.test_case
            "advances after gauge set"
            `Quick
            test_age_helper_advances_after_gauge_set
        ; Alcotest.test_case
            "stale gauge reports large age"
            `Quick
            test_age_helper_reports_stale_when_gauge_old
        ] )
    ; ( "counter-isolation"
      , [ Alcotest.test_case
            "per-base_path label isolation"
            `Quick
            test_counter_per_base_path_isolation
        ] )
    ; ( "registry"
      , [ Alcotest.test_case
            "metrics appear in registry"
            `Quick
            test_registry_snapshot_includes_metrics
        ] )
    ]
;;
