module Types = Masc_domain

(** Unit tests for [Keeper_heartbeat_smart].

    Pure functions: [make_config] clamping, [effective_interval] idle
    multiplier, [should_emit] decision matrix across (busy_skip,
    agent_status, idle vs interval, max_silence safety net). *)

open Masc
module HS = Keeper_heartbeat_smart

let check_float label expected actual =
  Alcotest.(check (float 0.001)) label expected actual

let check_bool label expected actual =
  Alcotest.(check bool) label expected actual

let decision_testable : HS.decision Alcotest.testable =
  let pp fmt = function
    | HS.Emit -> Format.fprintf fmt "Emit"
    | HS.Skip_busy -> Format.fprintf fmt "Skip_busy"
    | HS.Skip_idle f -> Format.fprintf fmt "Skip_idle %.1f" f
  in
  let eq a b =
    match (a, b) with
    | HS.Emit, HS.Emit -> true
    | HS.Skip_busy, HS.Skip_busy -> true
    | HS.Skip_idle _, HS.Skip_idle _ -> true (* compare tag only; payload is wall-clock *)
    | _ -> false
  in
  Alcotest.testable pp eq

let check_decision label expected actual =
  Alcotest.check decision_testable label expected actual

(* ── make_config: clamping ───────────────────────────────────────────── *)

let test_make_config_clamps_below_min () =
  let cfg = HS.make_config ~base_interval_s:1.0 ~idle_multiplier:0.5
              ~idle_threshold_s:1.0 () in
  check_float "base_interval_s clamped to 5.0" 5.0 cfg.base_interval_s;
  check_float "idle_multiplier clamped to 1.0" 1.0 cfg.idle_multiplier;
  check_float "idle_threshold_s clamped to 60.0" 60.0 cfg.idle_threshold_s

let test_make_config_clamps_above_max () =
  let cfg = HS.make_config ~base_interval_s:9999.0 ~idle_multiplier:99.0
              ~idle_threshold_s:99999.0 () in
  check_float "base_interval_s clamped to 300.0" 300.0 cfg.base_interval_s;
  check_float "idle_multiplier clamped to 10.0" 10.0 cfg.idle_multiplier;
  check_float "idle_threshold_s clamped to 3600.0" 3600.0 cfg.idle_threshold_s

let test_make_config_passthrough_within_bounds () =
  let cfg = HS.make_config ~base_interval_s:60.0 ~idle_multiplier:2.0
              ~idle_threshold_s:300.0 ~busy_skip:false () in
  check_float "base_interval_s passthrough" 60.0 cfg.base_interval_s;
  check_float "idle_multiplier passthrough" 2.0 cfg.idle_multiplier;
  check_float "idle_threshold_s passthrough" 300.0 cfg.idle_threshold_s;
  check_bool "busy_skip override" false cfg.busy_skip

(* ── effective_interval: idle multiplier ─────────────────────────────── *)

let make_test_config ?(base_interval_s = 30.0) ?(idle_multiplier = 3.0)
    ?(busy_skip = true) ?(idle_threshold_s = 300.0) () =
  HS.make_config ~base_interval_s ~idle_multiplier ~busy_skip
    ~idle_threshold_s ()

let test_effective_interval_recent_activity () =
  let config = make_test_config () in
  let now = Time_compat.now () in
  let last_activity = now -. 60.0 (* 1 min ago, below 300s threshold *) in
  check_float "recent activity uses base interval" 30.0
    (HS.effective_interval ~config ~last_activity)

let test_effective_interval_idle_uses_multiplier () =
  let config = make_test_config () in
  let now = Time_compat.now () in
  let last_activity = now -. 600.0 (* 10 min ago, above 300s threshold *) in
  check_float "idle uses base * multiplier (30 * 3)" 90.0
    (HS.effective_interval ~config ~last_activity)

let test_effective_interval_at_threshold_boundary () =
  let config = make_test_config () in
  let now = Time_compat.now () in
  (* idle_duration <= threshold should NOT trigger multiplier
     (the implementation uses strict >, see heartbeat_smart.ml) *)
  let last_activity = now -. 300.0 (* exactly at threshold *) in
  check_float "exactly-at-threshold uses base interval" 30.0
    (HS.effective_interval_at ~config ~now ~last_activity)

(* ── should_emit: decision matrix ────────────────────────────────────── *)

let test_should_emit_busy_with_busy_skip () =
  let config = make_test_config ~busy_skip:true () in
  let now = Time_compat.now () in
  check_decision "busy + busy_skip=true → Skip_busy"
    HS.Skip_busy
    (HS.should_emit ~config ~agent_status:Masc_domain.Busy
       ~last_activity:(now -. 1.0) ~last_heartbeat:(now -. 60.0))

let test_should_emit_busy_without_busy_skip () =
  let config = make_test_config ~busy_skip:false () in
  let now = Time_compat.now () in
  check_decision "busy + busy_skip=false → Emit (interval elapsed)"
    HS.Emit
    (HS.should_emit ~config ~agent_status:Masc_domain.Busy
       ~last_activity:(now -. 1.0) ~last_heartbeat:(now -. 60.0))

let test_should_emit_active_interval_elapsed () =
  let config = make_test_config () in
  let now = Time_compat.now () in
  check_decision "active + interval elapsed → Emit"
    HS.Emit
    (HS.should_emit ~config ~agent_status:Masc_domain.Active
       ~last_activity:(now -. 5.0) ~last_heartbeat:(now -. 60.0))

let test_should_emit_active_within_interval () =
  let config = make_test_config () in
  let now = Time_compat.now () in
  check_decision "active + within interval → Skip_idle"
    (HS.Skip_idle 0.0)
    (HS.should_emit ~config ~agent_status:Masc_domain.Active
       ~last_activity:(now -. 5.0) ~last_heartbeat:(now -. 5.0))

let test_should_emit_max_silence_safety_net () =
  (* Construct: idle_multiplier pushes interval above 900s, but
     time_since_last >= 900 should still trigger Emit via the safety
     net. *)
  let config =
    make_test_config ~base_interval_s:300.0 ~idle_multiplier:10.0
      ~idle_threshold_s:60.0 ()
  in
  let now = Time_compat.now () in
  check_decision "very long silence (>900s) → Emit even when interval > 900"
    HS.Emit
    (HS.should_emit ~config ~agent_status:Masc_domain.Active
       ~last_activity:(now -. 1000.0) ~last_heartbeat:(now -. 1000.0))

(* ── default_config sanity ───────────────────────────────────────────── *)

let test_default_config_busy_skip_on () =
  check_bool "default busy_skip = true" true HS.default_config.busy_skip

let test_default_config_intervals_in_bounds () =
  let v = HS.default_config in
  check_bool "default base_interval_s in [5, 300]" true
    (v.base_interval_s >= 5.0 && v.base_interval_s <= 300.0);
  check_bool "default idle_multiplier in [1, 10]" true
    (v.idle_multiplier >= 1.0 && v.idle_multiplier <= 10.0);
  check_bool "default idle_threshold_s in [60, 3600]" true
    (v.idle_threshold_s >= 60.0 && v.idle_threshold_s <= 3600.0)

(* ── runner ──────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Keeper_heartbeat_smart"
    [
      ( "make_config_clamps",
        [
          Alcotest.test_case "below-min clamped" `Quick
            test_make_config_clamps_below_min;
          Alcotest.test_case "above-max clamped" `Quick
            test_make_config_clamps_above_max;
          Alcotest.test_case "within-bounds passthrough" `Quick
            test_make_config_passthrough_within_bounds;
        ] );
      ( "effective_interval",
        [
          Alcotest.test_case "recent activity → base" `Quick
            test_effective_interval_recent_activity;
          Alcotest.test_case "idle activity → base * multiplier" `Quick
            test_effective_interval_idle_uses_multiplier;
          Alcotest.test_case "at-threshold boundary uses base" `Quick
            test_effective_interval_at_threshold_boundary;
        ] );
      ( "should_emit decision",
        [
          Alcotest.test_case "busy + busy_skip → Skip_busy" `Quick
            test_should_emit_busy_with_busy_skip;
          Alcotest.test_case "busy + !busy_skip → Emit" `Quick
            test_should_emit_busy_without_busy_skip;
          Alcotest.test_case "active + elapsed → Emit" `Quick
            test_should_emit_active_interval_elapsed;
          Alcotest.test_case "active + within → Skip_idle" `Quick
            test_should_emit_active_within_interval;
          Alcotest.test_case "max_silence safety net → Emit" `Quick
            test_should_emit_max_silence_safety_net;
        ] );
      ( "default_config",
        [
          Alcotest.test_case "busy_skip on" `Quick
            test_default_config_busy_skip_on;
          Alcotest.test_case "intervals in bounds" `Quick
            test_default_config_intervals_in_bounds;
        ] );
    ]
