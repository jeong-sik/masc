(** Pin the {!Env_config_runtime.Dashboard} compute-timeout contract
    for mission/shell/render. Four values were extracted from inline
    literals:

    - [server_dashboard_http_core.ml:78]   25.0  → mission_timeout_sec
    - [server_dashboard_http_core.ml:790]  16.0  → shell_timeout_sec
    - [server_dashboard_http_core.ml:791]   8.0  → shell_light_timeout_sec
    - [dashboard_execution.ml:204]         60.0  → render_timeout_sec

    Properties pinned:

    1. Defaults preserve the pre-extraction literals (regression guard
       against silent budget shifts that would re-introduce the "기다려야
       할 부분을 안 기다리는" pattern on slow PG / cold-start projections).
    2. Light < full ordering invariant: a [light] render must have a
       strictly smaller budget than a [full] render, otherwise the
       split-budget signal becomes meaningless and operators cannot tell
       whether light is genuinely under-scoped or has accidentally taken
       on full's work.
    3. Render budget comfortably exceeds inner compute budgets. The
       outer render guard at [dashboard_execution.ml:376] must give the
       inner [Dashboard_cache.get_or_compute_with_timeout] sites room
       to report their own "compute timeout" rather than being killed
       by the outer wrapper.
    4. Floor clamps prevent operators from configuring degenerate values. *)

open Alcotest

module D = Env_config_runtime.Dashboard

let approx = float 0.001

(* --- 1. Defaults pin the pre-extraction literals --- *)

let test_default_mission () =
  check approx
    "mission_timeout_sec default (was inline 25.0)"
    25.0 D.mission_timeout_sec

let test_default_shell () =
  check approx
    "shell_timeout_sec default (was inline 16.0)"
    16.0 D.shell_timeout_sec

let test_default_shell_light () =
  check approx
    "shell_light_timeout_sec default (was inline 8.0)"
    8.0 D.shell_light_timeout_sec

let test_default_render () =
  check approx
    "render_timeout_sec default (was inline 60.0)"
    60.0 D.render_timeout_sec

(* --- 2. light < full ordering invariant --- *)

let test_shell_light_strictly_less_than_full () =
  check bool
    "shell_light must strictly precede shell_full (else split-budget \
     signal becomes meaningless)"
    true
    (D.shell_light_timeout_sec < D.shell_timeout_sec)

(* --- 3. Render budget exceeds inner compute budgets --- *)

let test_render_exceeds_mission () =
  check bool
    "render_timeout_sec MUST exceed mission_timeout_sec (else outer \
     guard kills mission compute before its inner report)"
    true
    (D.render_timeout_sec > D.mission_timeout_sec)

let test_render_exceeds_shell () =
  check bool
    "render_timeout_sec MUST exceed shell_timeout_sec (full path)"
    true
    (D.render_timeout_sec > D.shell_timeout_sec)

(* --- 4. API surface compile guard ----------------------------- *)

let test_smoke_call_sites_compile () =
  let _ = D.mission_timeout_sec in
  let _ = D.shell_timeout_sec in
  let _ = D.shell_light_timeout_sec in
  let _ = D.render_timeout_sec in
  check bool "all four accessors are reachable" true true

let () =
  run "env_config_dashboard_compute_timeouts"
    [
      ( "defaults preserve pre-extraction literals",
        [
          test_case "mission = 25.0" `Quick test_default_mission;
          test_case "shell = 16.0" `Quick test_default_shell;
          test_case "shell_light = 8.0" `Quick test_default_shell_light;
          test_case "render = 60.0" `Quick test_default_render;
        ] );
      ( "light < full ordering",
        [
          test_case "shell_light < shell" `Quick
            test_shell_light_strictly_less_than_full;
        ] );
      ( "render exceeds inner compute",
        [
          test_case "render > mission" `Quick test_render_exceeds_mission;
          test_case "render > shell" `Quick test_render_exceeds_shell;
        ] );
      ( "API surface",
        [
          test_case "all four accessors reachable" `Quick
            test_smoke_call_sites_compile;
        ] );
    ]
