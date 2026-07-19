(** Test suite for work-as-heartbeat enablement,
    keepalive config, and Phase 0 percentile function.

    Note: env_config values are top-level let bindings, evaluated once at
    program start. Runtime putenv does NOT affect them. Tests verify defaults
    (no env override in test dune env-vars). *)

open Alcotest

(* Env_config from masc.config (unwrapped library) *)
module Cfg = Env_config
module KK = Masc.Keeper_keepalive

(* ── Config default values ──────────────────────────────── *)

let test_wah_enabled_default () =
  (* MASC_KEEPER_WORK_AS_HEARTBEAT not set in test env → default true *)
  check bool "work-as-heartbeat enabled by default"
    true Cfg.WorkAsHeartbeat.enabled

(* ── KeeperKeepalive config defaults ───────────────────── *)

let test_keepalive_interval_default () =
  check int "default interval 30s" 30 Cfg.KeeperKeepalive.interval_sec

let test_keepalive_interval_positive () =
  let v = Cfg.KeeperKeepalive.interval_sec in
  check bool "interval is positive" true (v > 0)

let test_keepalive_interval_has_one_resolved_ssot () =
  Runtime_settings.ensure_init ();
  check
    int
    "heartbeat loop interval resolves from the configured interval"
    Cfg.KeeperKeepalive.interval_sec
    (Masc.Keeper_heartbeat_snapshot.keepalive_interval_sec ())
;;

let test_keepalive_sleep_chunk_default () =
  check (float 0.01) "default sleep chunk 2.0s" 2.0
    Cfg.KeeperKeepalive.sleep_chunk_sec

(* ── KeeperGrpc config defaults ────────────────────────── *)

let test_grpc_backoff_default () =
  check (float 0.1) "default grpc backoff 5.0s" 5.0
    Cfg.KeeperGrpc.reconnect_backoff_sec

let test_grpc_backoff_range () =
  let v = Cfg.KeeperGrpc.reconnect_backoff_sec in
  check bool "backoff >= 1.0" true (v >= 1.0);
  check bool "backoff <= 60.0" true (v <= 60.0)

(* ── KeeperProactive config defaults ──────────────────── *)
(* max_attempts cases removed with the knob (masc#25123 dead-knob audit). *)

let test_timing_ring_size_default () =
  check int "default timing ring size 100" 100
    Cfg.KeeperProactive.stage_timing_ring_size

let test_timing_ring_size_range () =
  let v = Cfg.KeeperProactive.stage_timing_ring_size in
  check bool "ring >= 10" true (v >= 10);
  check bool "ring <= 1000" true (v <= 1000)

(* ── Config invariant properties ───────────────────────── *)

let test_config_invariant_sweep_independent () =
  let sweep = Cfg.KeeperSupervisor.sweep_interval_sec in
  check bool "sweep > 0" true (sweep > 0.0)


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
    ];
    "keepalive_config", [
      test_case "interval default" `Quick test_keepalive_interval_default;
      test_case "interval positive" `Quick test_keepalive_interval_positive;
      test_case "interval has one resolved SSOT" `Quick
        test_keepalive_interval_has_one_resolved_ssot;
      test_case "sleep_chunk default" `Quick test_keepalive_sleep_chunk_default;
    ];
    "grpc_config", [
      test_case "backoff default" `Quick test_grpc_backoff_default;
      test_case "backoff range" `Quick test_grpc_backoff_range;
    ];
    "proactive_config", [
      test_case "timing_ring default" `Quick test_timing_ring_size_default;
      test_case "timing_ring range" `Quick test_timing_ring_size_range;
    ];
    "config_invariants", [
      test_case "sweep interval positive" `Quick test_config_invariant_sweep_independent;
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
