(* test/test_keeper_supervisor_observability_10125.ml

   #10125 reports a 4h+ silent fleet death after server
   restart: 14 keepers exit on cascade exhaustion and the
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

let () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-keeper-supervisor-obs-10125-%06x"
         (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir

module R = Masc_mcp.Keeper_runtime
module Prom = Masc_mcp.Prometheus

let starts_for ~base_path =
  Prom.metric_value_or_zero
    Masc_mcp.Keeper_metrics.metric_keeper_supervisor_sweep_starts
    ~labels:[ ("base_path", base_path) ]
    ()

let last_sweep_for ~base_path =
  Prom.get_metric_value
    Masc_mcp.Keeper_metrics.metric_keeper_supervisor_last_sweep_unixtime
    ~labels:[ ("base_path", base_path) ]
    ()

(* Both metrics are declared at init, so [metric_total]
   returns a finite total even before any keeper runs.
   This pins that the registration block actually runs —
   if either name is missing the whole #10125 dashboard
   becomes invisible on a fresh install. *)
let test_metrics_registered () =
  let _ = Prom.metric_total Masc_mcp.Keeper_metrics.metric_keeper_supervisor_sweep_starts in
  let _ = Prom.metric_total Masc_mcp.Keeper_metrics.metric_keeper_supervisor_last_sweep_unixtime in
  Alcotest.(check pass) "both supervisor metrics are registered" () ()

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

(* Setting the gauge to "now" makes the helper return a
   small positive age (read-after-write).  This exercises
   the same code path [on_beat] uses to mark sweep
   liveness. *)
let test_age_helper_advances_after_gauge_set () =
  let base_path = "/tmp/test-supervisor-obs-advances-10125" in
  Prom.set_gauge
    Masc_mcp.Keeper_metrics.metric_keeper_supervisor_last_sweep_unixtime
    ~labels:[ ("base_path", base_path) ]
    (Unix.gettimeofday ());
  match R.supervisor_sweep_age_seconds ~base_path with
  | None -> Alcotest.fail "expected Some age after gauge set"
  | Some age ->
    Alcotest.(check bool)
      "age is small (< 5s) and non-negative"
      true (age >= 0.0 && age < 5.0)

(* Setting the gauge to a deliberately old timestamp
   reproduces the #10125 "stalled sweep" condition.  The
   helper returns a large positive age that dashboards
   convert into the [stale] badge. *)
let test_age_helper_reports_stale_when_gauge_old () =
  let base_path = "/tmp/test-supervisor-obs-stale-10125" in
  let stale_ts = Unix.gettimeofday () -. 3600.0 in
  Prom.set_gauge
    Masc_mcp.Keeper_metrics.metric_keeper_supervisor_last_sweep_unixtime
    ~labels:[ ("base_path", base_path) ]
    stale_ts;
  match R.supervisor_sweep_age_seconds ~base_path with
  | None -> Alcotest.fail "expected Some age"
  | Some age ->
    Alcotest.(check bool)
      "stale gauge: age >= 1 hour"
      true (age >= 3599.0)

(* Counter increments are per-base_path so a bench harness
   that exercises multiple base paths in one process can
   tell which one had its supervisor restart. *)
let test_counter_per_base_path_isolation () =
  let a = "/tmp/test-supervisor-obs-iso-A-10125" in
  let b = "/tmp/test-supervisor-obs-iso-B-10125" in
  let before_b = starts_for ~base_path:b in
  Prom.inc_counter
    Masc_mcp.Keeper_metrics.metric_keeper_supervisor_sweep_starts
    ~labels:[ ("base_path", a) ]
    ();
  Prom.inc_counter
    Masc_mcp.Keeper_metrics.metric_keeper_supervisor_sweep_starts
    ~labels:[ ("base_path", a) ]
    ();
  Alcotest.(check (float 0.0001))
    "base_path B unaffected by base_path A increments"
    before_b
    (starts_for ~base_path:b);
  Alcotest.(check (float 0.0001))
    "base_path A counter advanced by 2"
    2.0
    (starts_for ~base_path:a)

(* The textual export uses [base_path] as the label key
   for both metrics, so PromQL queries can join them on
   that label. *)
let test_prometheus_text_export_includes_metrics () =
  let base_path = "/tmp/test-supervisor-obs-export-10125" in
  Prom.inc_counter
    Masc_mcp.Keeper_metrics.metric_keeper_supervisor_sweep_starts
    ~labels:[ ("base_path", base_path) ]
    ();
  Prom.set_gauge
    Masc_mcp.Keeper_metrics.metric_keeper_supervisor_last_sweep_unixtime
    ~labels:[ ("base_path", base_path) ]
    (Unix.gettimeofday ());
  let text = Prom.to_prometheus_text () in
  let contains s sub =
    let n = String.length s and m = String.length sub in
    let rec loop i =
      if i + m > n then false
      else if String.sub s i m = sub then true
      else loop (i + 1)
    in
    loop 0
  in
  Alcotest.(check bool)
    "counter name appears in export"
    true (contains text Masc_mcp.Keeper_metrics.metric_keeper_supervisor_sweep_starts);
  Alcotest.(check bool)
    "gauge name appears in export"
    true (contains text Masc_mcp.Keeper_metrics.metric_keeper_supervisor_last_sweep_unixtime);
  Alcotest.(check bool)
    "base_path label appears for export"
    true (contains text "base_path=")

let () =
  Alcotest.run "keeper_supervisor_observability_10125"
    [
      ( "metrics-registered",
        [
          Alcotest.test_case "both metrics registered at init" `Quick
            test_metrics_registered;
        ] );
      ( "age-helper",
        [
          Alcotest.test_case "None before first sweep" `Quick
            test_age_helper_returns_none_before_first_sweep;
          Alcotest.test_case "advances after gauge set" `Quick
            test_age_helper_advances_after_gauge_set;
          Alcotest.test_case "stale gauge reports large age" `Quick
            test_age_helper_reports_stale_when_gauge_old;
        ] );
      ( "counter-isolation",
        [
          Alcotest.test_case "per-base_path label isolation" `Quick
            test_counter_per_base_path_isolation;
        ] );
      ( "export",
        [
          Alcotest.test_case "metrics appear in /metrics text" `Quick
            test_prometheus_text_export_includes_metrics;
        ] );
    ]
