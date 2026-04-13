(** Test suite for Phase 1: Work-as-heartbeat config defaults,
    freshness decision logic, and Phase 0 percentile function.

    Note: env_config values are top-level let bindings, evaluated once at
    program start. Runtime putenv does NOT affect them. Tests verify defaults
    (no env override in test dune env-vars). *)

open Alcotest

(* Env_config from masc_mcp.config (unwrapped library) *)
module Cfg = Env_config
module KK = Masc_mcp.Keeper_keepalive

(* ── Config default values ──────────────────────────────── *)

let test_wah_enabled_default () =
  (* MASC_KEEPER_WORK_AS_HEARTBEAT not set in test env → default true *)
  check bool "work-as-heartbeat enabled by default"
    true Cfg.WorkAsHeartbeat.enabled

let test_wah_max_silence_default () =
  (* MASC_KEEPER_MAX_SILENCE_SEC not set in test env → default 120.0 *)
  let v = Cfg.WorkAsHeartbeat.max_silence_sec in
  check (float 0.1) "default max silence 120s" 120.0 v

let test_wah_max_silence_floor_logic () =
  (* The floor clamp uses keepalive interval dynamically.
     We verify: max_silence_sec >= keepalive_interval_sec always. *)
  let v = Cfg.WorkAsHeartbeat.max_silence_sec in
  let interval = Float.of_int Cfg.KeeperKeepalive.interval_sec in
  check bool "max_silence >= keepalive interval"
    true (v >= interval)

(* ── KeeperKeepalive config defaults ───────────────────── *)

let test_keepalive_interval_default () =
  check int "default interval 30s" 30 Cfg.KeeperKeepalive.interval_sec

let test_keepalive_interval_range () =
  let v = Cfg.KeeperKeepalive.interval_sec in
  check bool "interval >= 5" true (v >= 5);
  check bool "interval <= 300" true (v <= 300)

let test_keepalive_max_failures_default () =
  check int "default max failures 5" 5
    Cfg.KeeperKeepalive.max_consecutive_failures

let test_keepalive_max_failures_range () =
  let v = Cfg.KeeperKeepalive.max_consecutive_failures in
  check bool "failures >= 2" true (v >= 2);
  check bool "failures <= 50" true (v <= 50)

let test_keepalive_board_debounce_default () =
  check (float 0.1) "default debounce 60s" 60.0
    Cfg.KeeperKeepalive.board_debounce_sec

let test_keepalive_sleep_chunk_default () =
  check (float 0.01) "default sleep chunk 2.0s" 2.0
    Cfg.KeeperKeepalive.sleep_chunk_sec

let test_keepalive_jitter_default () =
  check (float 0.001) "default jitter 0.2" 0.2
    Cfg.KeeperKeepalive.jitter_factor

let test_keepalive_jitter_range () =
  let v = Cfg.KeeperKeepalive.jitter_factor in
  check bool "jitter >= 0.0" true (v >= 0.0);
  check bool "jitter <= 0.5" true (v <= 0.5)

(* ── OAS adaptive timeout tests ───────────────────────── *)

let adaptive = Cfg.KeeperKeepalive.oas_timeout_for_context

let test_oas_timeout_32k () =
  let v = adaptive ~max_context:32_000 in
  (* 120 + 32*1.5 + min(15,40)*30 = 120+48+450 = 618 *)
  check (float 1.0) "32K → 618s" 618.0 v

let test_oas_timeout_128k () =
  let v = adaptive ~max_context:128_000 in
  (* 120 + 128*1.5 + 450 = 762 *)
  check (float 1.0) "128K → 762s" 762.0 v

let test_oas_timeout_262k () =
  let v = adaptive ~max_context:262_144 in
  (* 120 + 262.144*1.5 + min(15,40)*30 = 120+393.216+450 = 963.216 *)
  check bool "262K → [960, 970]" true (v >= 960.0 && v <= 970.0)

let test_oas_timeout_262k_scheduled_autonomous () =
  let v =
    Cfg.KeeperKeepalive.oas_timeout_for_context_with_turn_budget
      ~max_context:262_144
      ~max_turns:Cfg.KeeperKeepalive.oas_max_turns_per_call_scheduled_autonomous
  in
  (* 120 + 262.144*1.5 + min(5,40)*30 = 120+393.216+150 = 663.216 *)
  check bool "262K scheduled autonomous → [660, 670]" true
    (v >= 660.0 && v <= 670.0)

let test_oas_timeout_zero () =
  let v = adaptive ~max_context:0 in
  (* 120 + 0 + min(15,40)*30 = 570 *)
  check (float 1.0) "0 context → base+turn budget 570s" 570.0 v

let test_oas_timeout_monotonic () =
  let v1 = adaptive ~max_context:32_000 in
  let v2 = adaptive ~max_context:128_000 in
  let v3 = adaptive ~max_context:262_144 in
  check bool "32K < 128K" true (v1 < v2);
  check bool "128K < 262K" true (v2 < v3)

let test_oas_timeout_cap () =
  let v = adaptive ~max_context:1_000_000 in
  check (float 0.1) "1M context → capped at turn timeout 1200" 1200.0 v

let test_turn_timeout_default () =
  check (float 0.1) "default turn timeout 1200s" 1200.0
    Cfg.KeeperKeepalive.turn_timeout_sec

let test_max_turns_default () =
  check int "default max_turns_per_call 15" 15
    Cfg.KeeperKeepalive.oas_max_turns_per_call

let test_scheduled_autonomous_max_turns_default () =
  check int "default scheduled autonomous max_turns_per_call 5" 5
    Cfg.KeeperKeepalive.oas_max_turns_per_call_scheduled_autonomous

let test_max_turns_range () =
  let v = Cfg.KeeperKeepalive.oas_max_turns_per_call in
  check bool "max_turns >= 1" true (v >= 1);
  check bool "max_turns <= 50" true (v <= 50)

let test_scheduled_autonomous_max_turns_range () =
  let v = Cfg.KeeperKeepalive.oas_max_turns_per_call_scheduled_autonomous in
  check bool "scheduled autonomous max_turns >= 1" true (v >= 1);
  check bool "scheduled autonomous max_turns <= global" true
    (v <= Cfg.KeeperKeepalive.oas_max_turns_per_call)

let test_oas_timeout_sec_compat () =
  (* Without env override, oas_timeout_sec returns 300.0 default *)
  let v = Cfg.KeeperKeepalive.oas_timeout_sec in
  check (float 1.0) "backward compat default 300s" 300.0 v

(* ── Semaphore wait timeout (defense against peer slot hoarding) ── *)

let test_semaphore_wait_timeout_default () =
  (* Default 60s — short enough to unblock starved keepers, long enough
     to not mis-trigger under legitimate contention. *)
  check (float 0.1) "default semaphore wait timeout 60s" 60.0
    KK.semaphore_wait_timeout_sec

let test_semaphore_wait_timeout_range () =
  let v = KK.semaphore_wait_timeout_sec in
  check bool "wait timeout >= 5s" true (v >= 5.0);
  check bool "wait timeout <= 600s" true (v <= 600.0)

let test_semaphore_wait_timeout_exception_shape () =
  (* The exception carries the wait cap in seconds so the caller can
     render it in a log line without re-reading the env var. *)
  let carried =
    try
      raise (KK.Semaphore_wait_timeout 42.5)
    with KK.Semaphore_wait_timeout v -> v
  in
  check (float 0.001) "exception carries wait sec" 42.5 carried

(* ── KeeperGrpc config defaults ────────────────────────── *)

let test_grpc_max_reconnect_default () =
  check int "default grpc max reconnect 5" 5
    Cfg.KeeperGrpc.max_reconnect_attempts

let test_grpc_max_reconnect_range () =
  let v = Cfg.KeeperGrpc.max_reconnect_attempts in
  check bool "reconnect >= 1" true (v >= 1);
  check bool "reconnect <= 20" true (v <= 20)

let test_grpc_backoff_default () =
  check (float 0.1) "default grpc backoff 5.0s" 5.0
    Cfg.KeeperGrpc.reconnect_backoff_sec

let test_grpc_backoff_range () =
  let v = Cfg.KeeperGrpc.reconnect_backoff_sec in
  check bool "backoff >= 1.0" true (v >= 1.0);
  check bool "backoff <= 60.0" true (v <= 60.0)

(* ── KeeperProactive config defaults ──────────────────── *)

let test_proactive_max_attempts_default () =
  check int "default proactive max attempts 3" 3
    Cfg.KeeperProactive.max_attempts

let test_proactive_max_attempts_range () =
  let v = Cfg.KeeperProactive.max_attempts in
  check bool "attempts >= 1" true (v >= 1);
  check bool "attempts <= 10" true (v <= 10)

let test_timing_ring_size_default () =
  check int "default timing ring size 100" 100
    Cfg.KeeperProactive.stage_timing_ring_size

let test_timing_ring_size_range () =
  let v = Cfg.KeeperProactive.stage_timing_ring_size in
  check bool "ring >= 10" true (v >= 10);
  check bool "ring <= 1000" true (v <= 1000)

(* ── Config invariant properties ───────────────────────── *)

let test_config_invariant_silence_ge_interval () =
  let silence = Cfg.WorkAsHeartbeat.max_silence_sec in
  let interval = Float.of_int Cfg.KeeperKeepalive.interval_sec in
  check bool "max_silence >= interval (invariant)" true (silence >= interval)

let test_config_invariant_sweep_independent () =
  let sweep = Cfg.KeeperSupervisor.sweep_interval_sec in
  let backoff_base = Cfg.KeeperSupervisor.backoff_base_s in
  check bool "sweep > 0" true (sweep > 0.0);
  check bool "backoff_base > 0" true (backoff_base > 0.0);
  check bool "backoff_max >= backoff_base" true
    (Cfg.KeeperSupervisor.backoff_max_s >= backoff_base)

let test_config_invariant_debounce_ge_interval () =
  let debounce = Cfg.KeeperKeepalive.board_debounce_sec in
  let interval = Float.of_int Cfg.KeeperKeepalive.interval_sec in
  check bool "board debounce >= interval" true (debounce >= interval)

(* ── Freshness decision pure logic ──────────────────────── *)

let test_freshness_fresh () =
  let now = 100.0 in
  let last_hb = 50.0 in
  let max_silence = 120.0 in
  let fresh = now -. last_hb < max_silence in
  check bool "50s ago < 120s window → fresh" true fresh

let test_freshness_stale () =
  let now = 200.0 in
  let last_hb = 50.0 in
  let max_silence = 120.0 in
  let fresh = now -. last_hb < max_silence in
  check bool "150s ago >= 120s window → stale" false fresh

let test_freshness_exact_boundary () =
  let now = 170.0 in
  let last_hb = 50.0 in
  let max_silence = 120.0 in
  let fresh = now -. last_hb < max_silence in
  check bool "exactly 120s → NOT fresh (< is strict)" false fresh

let test_freshness_never_heartbeated () =
  (* Initial last_hb = 0.0. At unix epoch + 200s:
     200.0 - 0.0 = 200.0 >= 120.0 → stale.
     This correctly forces initial presence sync. *)
  let now = 200.0 in
  let last_hb = 0.0 in
  let max_silence = 120.0 in
  let fresh = now -. last_hb < max_silence in
  check bool "never heartbeated (0.0) → stale → forces presence sync"
    false fresh

let test_freshness_disabled_flag () =
  (* When work_as_hb = false, presence_fresh is always false regardless of timestamp *)
  let work_as_hb = false in
  let now = 100.0 in
  let last_hb = 99.0 in
  let max_silence = 120.0 in
  let fresh = work_as_hb && (now -. last_hb < max_silence) in
  check bool "feature disabled → always stale" false fresh

(* ── Percentile function (Phase 0 profiling) ────────────── *)

let test_percentile_empty () =
  let arr = [||] in
  check (float 0.001) "empty → 0.0" 0.0 (KK.percentile arr 0.5)

let test_percentile_single () =
  let arr = [| 42.0 |] in
  check (float 0.001) "single → that element" 42.0 (KK.percentile arr 0.5)

let test_percentile_two_elements () =
  let arr = [| 10.0; 20.0 |] in
  let p0 = KK.percentile arr 0.0 in
  let p100 = KK.percentile arr 1.0 in
  check (float 0.001) "p0 = min" 10.0 p0;
  check (float 0.001) "p100 = max" 20.0 p100

let test_percentile_sorted () =
  let arr = [| 1.0; 2.0; 3.0; 4.0; 5.0 |] in
  let p50 = KK.percentile arr 0.5 in
  (* index = round(4 * 0.5) = round(2.0) = 2 → sorted[2] = 3.0 *)
  check (float 0.001) "p50 of 1..5 = 3.0" 3.0 p50;
  let p95 = KK.percentile arr 0.95 in
  (* index = round(4 * 0.95) = round(3.8) = 4 → sorted[4] = 5.0 *)
  check (float 0.001) "p95 of 1..5 = 5.0" 5.0 p95

let test_percentile_unsorted () =
  let arr = [| 5.0; 1.0; 3.0; 2.0; 4.0 |] in
  let p50 = KK.percentile arr 0.5 in
  check (float 0.001) "p50 of shuffled 1..5 = 3.0" 3.0 p50

let test_percentile_does_not_mutate () =
  let arr = [| 5.0; 1.0; 3.0 |] in
  let _p = KK.percentile arr 0.5 in
  (* Original array must remain unsorted *)
  check (float 0.001) "arr[0] unchanged" 5.0 arr.(0);
  check (float 0.001) "arr[1] unchanged" 1.0 arr.(1)

(* ── Test runner ────────────────────────────────────────── *)

let () =
  run "work_as_heartbeat" [
    "config", [
      test_case "enabled default" `Quick test_wah_enabled_default;
      test_case "max_silence default" `Quick test_wah_max_silence_default;
      test_case "max_silence floor invariant" `Quick test_wah_max_silence_floor_logic;
    ];
    "keepalive_config", [
      test_case "interval default" `Quick test_keepalive_interval_default;
      test_case "interval range" `Quick test_keepalive_interval_range;
      test_case "max_failures default" `Quick test_keepalive_max_failures_default;
      test_case "max_failures range" `Quick test_keepalive_max_failures_range;
      test_case "board_debounce default" `Quick test_keepalive_board_debounce_default;
      test_case "sleep_chunk default" `Quick test_keepalive_sleep_chunk_default;
      test_case "jitter default" `Quick test_keepalive_jitter_default;
      test_case "jitter range" `Quick test_keepalive_jitter_range;
    ];
    "oas_timeout_adaptive", [
      test_case "adaptive 32K context" `Quick test_oas_timeout_32k;
      test_case "adaptive 128K context" `Quick test_oas_timeout_128k;
      test_case "adaptive 262K context" `Quick test_oas_timeout_262k;
      test_case "adaptive 262K scheduled autonomous context" `Quick
        test_oas_timeout_262k_scheduled_autonomous;
      test_case "adaptive 0 context" `Quick test_oas_timeout_zero;
      test_case "adaptive monotonic" `Quick test_oas_timeout_monotonic;
      test_case "turn timeout default is 1200" `Quick test_turn_timeout_default;
      test_case "adaptive capped at turn timeout" `Quick test_oas_timeout_cap;
      test_case "max_turns default is 15" `Quick test_max_turns_default;
      test_case "scheduled autonomous max_turns default is 5" `Quick
        test_scheduled_autonomous_max_turns_default;
      test_case "max_turns range" `Quick test_max_turns_range;
      test_case "scheduled autonomous max_turns range" `Quick
        test_scheduled_autonomous_max_turns_range;
      test_case "oas_timeout_sec backward compat" `Quick test_oas_timeout_sec_compat;
    ];
    "semaphore_wait_timeout", [
      test_case "default 60s" `Quick test_semaphore_wait_timeout_default;
      test_case "range [5, 600]" `Quick test_semaphore_wait_timeout_range;
      test_case "exception carries wait sec" `Quick test_semaphore_wait_timeout_exception_shape;
    ];
    "grpc_config", [
      test_case "max_reconnect default" `Quick test_grpc_max_reconnect_default;
      test_case "max_reconnect range" `Quick test_grpc_max_reconnect_range;
      test_case "backoff default" `Quick test_grpc_backoff_default;
      test_case "backoff range" `Quick test_grpc_backoff_range;
    ];
    "proactive_config", [
      test_case "max_attempts default" `Quick test_proactive_max_attempts_default;
      test_case "max_attempts range" `Quick test_proactive_max_attempts_range;
      test_case "timing_ring default" `Quick test_timing_ring_size_default;
      test_case "timing_ring range" `Quick test_timing_ring_size_range;
    ];
    "freshness_logic", [
      test_case "within window → fresh" `Quick test_freshness_fresh;
      test_case "beyond window → stale" `Quick test_freshness_stale;
      test_case "exact boundary → stale (strict <)" `Quick test_freshness_exact_boundary;
      test_case "never heartbeated → stale" `Quick test_freshness_never_heartbeated;
      test_case "feature disabled → always stale" `Quick test_freshness_disabled_flag;
    ];
    "config_invariants", [
      test_case "max_silence >= interval" `Quick test_config_invariant_silence_ge_interval;
      test_case "sweep/backoff coherence" `Quick test_config_invariant_sweep_independent;
      test_case "debounce >= interval" `Quick test_config_invariant_debounce_ge_interval;
    ];
    "percentile", [
      test_case "empty array" `Quick test_percentile_empty;
      test_case "single element" `Quick test_percentile_single;
      test_case "two elements" `Quick test_percentile_two_elements;
      test_case "sorted input" `Quick test_percentile_sorted;
      test_case "unsorted input" `Quick test_percentile_unsorted;
      test_case "does not mutate" `Quick test_percentile_does_not_mutate;
    ];
  ]
