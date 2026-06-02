(** #9766: dashboard_execution slow render warns at >10s but the
    pre-fix log only said "total=59804ms (keepers=9)" — no breakdown
    of which phase ate the budget.  These tests pin the phase-timing
    formatter so production WARNs reliably contain the per-phase ms
    counts and the per-keeper enrich average. *)

open Alcotest
module DE = Masc_mcp.Dashboard_execution
module Prom = Masc_mcp.Prometheus

let sample_timings () : DE.render_phase_timings_ms = {
  total_ms = 59800.0;
  snapshot_ms = 1200.0;
  operations_ms = 800.0;
  enrich_ms = 54000.0;
  data_load_ms = 2500.0;
  assemble_ms = 1300.0;
  n_keepers = 9;
}

let test_per_keeper_average () =
  let t = sample_timings () in
  (* 54000 / 9 = 6000 *)
  check (float 1e-3) "average per-keeper enrich ms"
    6000.0
    (DE.per_keeper_enrich_ms t)

let test_per_keeper_zero_keepers_safe () =
  let t = { (sample_timings ()) with n_keepers = 0; enrich_ms = 0.0 } in
  check (float 1e-9) "zero keepers does not divide-by-zero"
    0.0
    (DE.per_keeper_enrich_ms t)

let test_format_includes_all_phases () =
  let s = DE.format_slow_render_timings (sample_timings ()) in
  let must_contain affix =
    check bool ("contains: " ^ affix) true
      (Astring.String.is_infix ~affix s)
  in
  must_contain "total=59800ms";
  must_contain "keepers=9";
  must_contain "snapshot=1200ms";
  must_contain "operations=800ms";
  must_contain "enrich=54000ms";
  must_contain "per_keeper=6000ms";
  must_contain "data_load=2500ms";
  must_contain "assemble=1300ms"

let test_format_with_zero_keepers () =
  let t = { (sample_timings ()) with n_keepers = 0; enrich_ms = 0.0 } in
  let s = DE.format_slow_render_timings t in
  check bool "zero keepers reports per_keeper=0" true
    (Astring.String.is_infix ~affix:"per_keeper=0ms" s)

let phase_sum phase =
  Prom.metric_value_or_zero
    Prom.metric_dashboard_execution_render_phase_sec
    ~labels:[("phase", phase)]
    ()

let phase_count phase =
  Prom.metric_value_or_zero
    (Prom.metric_dashboard_execution_render_phase_sec ^ "_count")
    ~labels:[("phase", phase)]
    ()

let snapshot_latency_bucket le =
  Prom.metric_value_or_zero
    Prom.metric_dashboard_snapshot_latency_seconds_bucket
    ~labels:[("le", le)]
    ()

let dashboard_all_zero_value () =
  Prom.metric_value_or_zero
    Prom.metric_dashboard_metric_all_zeros
    ~labels:[("keeper_name", "__dashboard__")]
    ()

let test_record_timings_observes_prometheus () =
  let phases = [
    "total"; "snapshot"; "operations"; "enrich";
    "data_load"; "assemble";
  ] in
  let snapshot_before =
    List.map (fun p -> p, phase_sum p, phase_count p) phases
  in
  let snapshot_bucket_5_before = snapshot_latency_bucket "5" in
  let snapshot_bucket_inf_before = snapshot_latency_bucket "+Inf" in
  let per_keeper_sum_before = phase_sum "enrich_per_keeper" in
  let per_keeper_count_before = phase_count "enrich_per_keeper" in
  let t = sample_timings () in
  DE.record_render_phase_timings t;
  check (float 1e-9) "normal render clears all-zero diagnostic"
    0.0
    (dashboard_all_zero_value ());
  let expected_increment = function
    | "total" -> t.total_ms /. 1000.0
    | "snapshot" -> t.snapshot_ms /. 1000.0
    | "operations" -> t.operations_ms /. 1000.0
    | "enrich" -> t.enrich_ms /. 1000.0
    | "data_load" -> t.data_load_ms /. 1000.0
    | "assemble" -> t.assemble_ms /. 1000.0
    | other -> Alcotest.failf "unexpected phase %s" other
  in
  List.iter (fun (phase, sum_before, count_before) ->
    check (float 1e-6)
      (Printf.sprintf "%s phase seconds +%.3f" phase
         (expected_increment phase))
      (sum_before +. expected_increment phase)
      (phase_sum phase);
    check (float 1e-6)
      (Printf.sprintf "%s phase count +1" phase)
      (count_before +. 1.0)
      (phase_count phase)
  ) snapshot_before;
  check (float 1e-6) "dashboard snapshot latency 5s bucket +1"
    (snapshot_bucket_5_before +. 1.0)
    (snapshot_latency_bucket "5");
  check (float 1e-6) "dashboard snapshot latency +Inf bucket +1"
    (snapshot_bucket_inf_before +. 1.0)
    (snapshot_latency_bucket "+Inf");
  (* enrich_per_keeper is observed once per keeper (n_keepers=9) so that
     Prometheus [sum / count] gives the actual average per-keeper enrich
     time weighted by fleet size, instead of averaging render-level
     means.  9 observations of 6.0s each = 54.0s sum, count +9. *)
  check (float 1e-6) "per-keeper enrich seconds += 54.0 (9 × 6.0)"
    (per_keeper_sum_before +. 54.0)
    (phase_sum "enrich_per_keeper");
  check (float 1e-6) "per-keeper enrich count += 9 (one per keeper)"
    (per_keeper_count_before +. 9.0)
    (phase_count "enrich_per_keeper")

let test_record_timings_skips_per_keeper_when_idle () =
  let per_keeper_sum_before = phase_sum "enrich_per_keeper" in
  let per_keeper_count_before = phase_count "enrich_per_keeper" in
  let total_count_before = phase_count "total" in
  let idle = { (sample_timings ()) with n_keepers = 0; enrich_ms = 0.0 } in
  DE.record_render_phase_timings idle;
  check (float 1e-9) "idle render does not emit enrich_per_keeper sum"
    per_keeper_sum_before
    (phase_sum "enrich_per_keeper");
  check (float 1e-9) "idle render does not emit enrich_per_keeper count"
    per_keeper_count_before
    (phase_count "enrich_per_keeper");
  check (float 1e-6) "idle render still records total observation"
    (total_count_before +. 1.0)
    (phase_count "total")

let test_record_timings_flags_all_zero_suboperations () =
  let all_zero : DE.render_phase_timings_ms = {
    total_ms = 1200.0;
    snapshot_ms = 0.0;
    operations_ms = 0.0;
    enrich_ms = 0.0;
    data_load_ms = 0.0;
    assemble_ms = 0.0;
    n_keepers = 3;
  } in
  DE.record_render_phase_timings all_zero;
  check (float 1e-9) "non-empty all-zero render raises diagnostic"
    1.0
    (dashboard_all_zero_value ());
  let idle = { all_zero with n_keepers = 0 } in
  DE.record_render_phase_timings idle;
  check (float 1e-9) "idle all-zero render clears diagnostic"
    0.0
    (dashboard_all_zero_value ())

let () =
  run "dashboard_render_timing_9766" [
    ("phase_timing", [
        test_case "per-keeper average is enrich/n" `Quick
          test_per_keeper_average;
        test_case "zero keepers does not divide-by-zero" `Quick
          test_per_keeper_zero_keepers_safe;
        test_case "format includes every phase" `Quick
          test_format_includes_all_phases;
        test_case "format handles zero keepers" `Quick
          test_format_with_zero_keepers;
        test_case "record timings emits Prometheus phase metrics" `Quick
          test_record_timings_observes_prometheus;
        test_case "idle render skips enrich_per_keeper observation" `Quick
          test_record_timings_skips_per_keeper_when_idle;
        test_case "record timings flags all-zero sub-operation metrics" `Quick
          test_record_timings_flags_all_zero_suboperations;
      ]);
  ]
