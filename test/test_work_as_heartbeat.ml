(** Test suite for Phase 1: Work-as-heartbeat config defaults,
    keepalive cycle actions, and Phase 0 percentile function.

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

let keeper_setting env_name =
  match
    List.find_opt
      (fun (setting : Keeper_runtime_setting_registry.setting) ->
        String.equal setting.env_name env_name)
      Keeper_runtime_setting_registry.all
  with
  | Some setting -> setting
  | None -> failf "missing Keeper runtime registry row for %s" env_name
;;

let test_keepalive_registry_defaults_match_runtime () =
  let interval = keeper_setting "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC" in
  check string "interval registry default matches runtime"
    (string_of_int Cfg.KeeperKeepalive.interval_sec)
    interval.default_display
;;

(* ── KeeperKeepalive config defaults ───────────────────── *)

let test_keepalive_interval_default () =
  check int "default interval 300s" 300 Cfg.KeeperKeepalive.interval_sec

let test_keepalive_interval_positive () =
  let v = Cfg.KeeperKeepalive.interval_sec in
  check bool "interval is positive" true (v > 0)

let test_keeper_heartbeat_stale_window_tracks_cadence () =
  check (float 0.1) "30s cycle respects the 300s snapshot producer" 360.0
    (Masc.Keeper_status_runtime.keeper_heartbeat_stale_after_s
       ~keepalive_interval_s:30.0
       ~snapshot_interval_s:300.0);
  check (float 0.1) "300s cadence receives 60s slack" 360.0
    (Masc.Keeper_status_runtime.keeper_heartbeat_stale_after_s
       ~keepalive_interval_s:300.0
       ~snapshot_interval_s:30.0)
;;

let test_keeper_turn_record_freshness_tracks_cadence () =
  check (float 0.1) "short cadence preserves the historical 300s floor" 300.0
    (Masc.Keeper_status_runtime.keeper_turn_record_freshness_slo_s
       ~keepalive_interval_s:30.0);
  check (float 0.1) "300s cadence receives full-cycle slack" 420.0
    (Masc.Keeper_status_runtime.keeper_turn_record_freshness_slo_s
       ~keepalive_interval_s:300.0)
;;

let test_keeper_metric_freshness_tracks_runtime_cadence () =
  check (float 0.1) "short cadence preserves telemetry floor" 300.0
    (Telemetry_unified.source_freshness_slo_s
       ~keeper_keepalive_interval_s:30.0
       Telemetry_unified.Keeper_metric);
  check (float 0.1) "keeper metric receives full-cycle slack" 420.0
    (Telemetry_unified.source_freshness_slo_s
       ~keeper_keepalive_interval_s:300.0
       Telemetry_unified.Keeper_metric)
;;

(* A recorded coverage gap outranks freshness: a store can be current about
   the window it did record and still be missing an hour of it. Everything
   below that is the turn-record ladder, which is the point -- the two
   handlers that serve tool-call sources each carried their own copy of it. *)
let test_a_coverage_gap_outranks_freshness () =
  let health, stale_reason =
    Masc.Keeper_status_runtime.keeper_tool_call_source_health
      ~gap_reason:(Some "telemetry gap 02:00-03:00Z")
      ~latest_age_s:(Some 1.0)
      ~freshness_slo_s:420.0
  in
  check string "a gap is the verdict even on a fresh store" "coverage_gap"
    health;
  (* The gap's own message, not one derived from the word. Every other verdict
     this pair can return restates itself; this is the one that cannot. *)
  check string "and it carries the gap's own message"
    "telemetry gap 02:00-03:00Z" stale_reason;
  let with_gap = (health, stale_reason) in
  let without_gap =
    Masc.Keeper_status_runtime.keeper_tool_call_source_health ~gap_reason:None
      ~latest_age_s:(Some 900.0) ~freshness_slo_s:420.0
  in
  check bool "a gap and no gap are not the same answer" false
    (with_gap = without_gap);
  check
    (pair string string)
    "with no gap it is the turn-record ladder, idle and not skipping rows"
    (Masc.Keeper_status_runtime.keeper_turn_record_source_health
       ~skipped_rows:0 ~live_turn_in_progress:false ~latest_age_s:(Some 900.0)
       ~freshness_slo_s:420.0)
    without_gap;
  check
    (pair string string)
    "and an empty store answers the same way through both"
    (Masc.Keeper_status_runtime.keeper_turn_record_source_health
       ~skipped_rows:0 ~live_turn_in_progress:false ~latest_age_s:None
       ~freshness_slo_s:420.0)
    (Masc.Keeper_status_runtime.keeper_tool_call_source_health ~gap_reason:None
       ~latest_age_s:None ~freshness_slo_s:420.0)
;;

let test_live_turn_keeps_turn_record_source_healthy () =
  let health, stale_reason =
    Masc.Keeper_status_runtime.keeper_turn_record_source_health
      ~skipped_rows:0
      ~live_turn_in_progress:true
      ~latest_age_s:(Some 900.0)
      ~freshness_slo_s:420.0
  in
  (* Not "ok": that additionally claims the newest finished record is inside
     the SLO, and here it is 900s against 420s. The running turn has not
     written its record yet, so there is nothing to judge (#28720). *)
  check string "a running turn reports live, not ok" "live" health;
  check string "live producer has no stale reason" "" stale_reason;
  let health, stale_reason =
    Masc.Keeper_status_runtime.keeper_turn_record_source_health
      ~skipped_rows:0
      ~live_turn_in_progress:false
      ~latest_age_s:(Some 900.0)
      ~freshness_slo_s:420.0
  in
  check string "idle old producer is stale" "stale" health;
  check string "idle old producer explains staleness"
    "freshness_slo_exceeded" stale_reason
;;

let test_keepalive_interval_has_one_resolved_ssot () =
  Runtime_settings.ensure_init ();
  check
    int
    "heartbeat loop interval resolves from the configured interval"
    Cfg.KeeperKeepalive.interval_sec
    (Masc.Keeper_heartbeat_snapshot.keepalive_interval_sec ())
;;

let test_keepalive_sleep_chunk_default () =
  check (float 0.01) "default sleep chunk 0.5s" 0.5
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


let test_completed_cycle_records_and_refreshes () =
  match
    Masc.Keeper_heartbeat_loop.decide_keepalive_cycle_action
      Masc.Keeper_heartbeat_loop.Turn_cycle_completed
  with
  | Masc.Keeper_heartbeat_loop.Record_turn_status Refresh_work_heartbeat -> ()
  | _ -> fail "completed cycle must record and refresh work-heartbeat"
;;

let test_crashed_cycle_records_and_preserves_work_heartbeat () =
  match
    Masc.Keeper_heartbeat_loop.decide_keepalive_cycle_action
      Masc.Keeper_heartbeat_loop.Turn_cycle_crashed
  with
  | Masc.Keeper_heartbeat_loop.Record_turn_status Preserve_work_heartbeat -> ()
  | _ -> fail "crashed cycle must record without refreshing work-heartbeat"
;;

let test_busy_cycle_defers_typed_block () =
  match
    Masc.Keeper_heartbeat_loop.decide_keepalive_cycle_action
      (Masc.Keeper_heartbeat_loop.Turn_cycle_busy
         (Masc.Keeper_owner.Turn_busy None))
  with
  | Masc.Keeper_heartbeat_loop.Defer_autonomous_work
      (Masc.Keeper_owner.Turn_busy None) -> ()
  | _ -> fail "busy cycle must preserve its typed admission block"
;;

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
      test_case "registry defaults match runtime" `Quick
        test_keepalive_registry_defaults_match_runtime;
    ];
    "keepalive_config", [
      test_case "interval default" `Quick test_keepalive_interval_default;
      test_case "interval positive" `Quick test_keepalive_interval_positive;
      test_case "stale window tracks cadence" `Quick
        test_keeper_heartbeat_stale_window_tracks_cadence;
      test_case "turn-record freshness tracks cadence" `Quick
        test_keeper_turn_record_freshness_tracks_cadence;
      test_case "keeper metric freshness tracks runtime cadence" `Quick
        test_keeper_metric_freshness_tracks_runtime_cadence;
      test_case "live turn keeps record source healthy" `Quick
        test_live_turn_keeps_turn_record_source_healthy;
      test_case "a coverage gap outranks freshness" `Quick
        test_a_coverage_gap_outranks_freshness;
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
    "cycle_action", [
      test_case
        "completed records and refreshes work-heartbeat"
        `Quick
        test_completed_cycle_records_and_refreshes;
      test_case
        "crashed records and preserves work-heartbeat"
        `Quick
        test_crashed_cycle_records_and_preserves_work_heartbeat;
      test_case
        "busy defers with its typed admission block"
        `Quick
        test_busy_cycle_defers_typed_block;
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
