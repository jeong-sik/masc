(** #9766: dashboard_execution slow render warns at >10s but the
    pre-fix log only said "total=59804ms (keepers=9)" — no breakdown
    of which phase ate the budget.  These tests pin the phase-timing
    formatter so production WARNs reliably contain the per-phase ms
    counts and the per-keeper enrich average. *)

open Alcotest
module DE = Masc_mcp.Dashboard_execution

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
      ]);
  ]
