module Types = Masc_domain

(** Tests for smart heartbeat integration in keeper_keepalive.

    Verifies that the Heartbeat_smart module decisions correctly map
    to Masc_domain.agent_status based on keeper_meta fields (current_task_id,
    paused), and that the env-config feature flag controls activation.

    These are unit-level tests of the mapping logic, not full keepalive
    loop integration tests (which require Eio fibers + Coord I/O). *)

open Alcotest
module HS = Masc_mcp.Heartbeat_smart

(* ── agent_status derivation from keeper_meta fields ─── *)

(** Derive agent_status from keeper_meta fields, mirroring the logic
    in keeper_keepalive.ml run_heartbeat_loop. *)
let derive_agent_status ~paused ~current_task_id =
  if paused then Masc_domain.Inactive
  else match current_task_id with
    | Some _ -> Masc_domain.Busy
    | None -> Masc_domain.Active

let test_status_busy_when_task_claimed () =
  let status = derive_agent_status ~paused:false ~current_task_id:(Some "task-42") in
  check string "busy when task claimed" (Masc_domain.show_agent_status Masc_domain.Busy)
    (Masc_domain.show_agent_status status)

let test_status_active_when_no_task () =
  let status = derive_agent_status ~paused:false ~current_task_id:None in
  check string "active when no task" (Masc_domain.show_agent_status Masc_domain.Active)
    (Masc_domain.show_agent_status status)

let test_status_inactive_when_paused () =
  let status = derive_agent_status ~paused:true ~current_task_id:(Some "task-99") in
  check string "inactive when paused" (Masc_domain.show_agent_status Masc_domain.Inactive)
    (Masc_domain.show_agent_status status)

let test_status_inactive_when_paused_no_task () =
  let status = derive_agent_status ~paused:true ~current_task_id:None in
  check string "inactive when paused, no task" (Masc_domain.show_agent_status Masc_domain.Inactive)
    (Masc_domain.show_agent_status status)

(* ── Heartbeat_smart decision tests with keeper-derived statuses ─── *)

let test_skip_busy_with_task () =
  let config = HS.default_config in
  let now = Unix.gettimeofday () in
  let decision = HS.should_emit
    ~config
    ~agent_status:Masc_domain.Busy
    ~last_activity:now
    ~last_heartbeat:(now -. 10.0) in
  check string "skip when busy" "skip:busy"
    (HS.decision_to_string decision)

let test_emit_when_active_and_interval_elapsed () =
  let config = HS.default_config in
  let now = Unix.gettimeofday () in
  (* last_heartbeat 31s ago, base interval 30s *)
  let decision = HS.should_emit
    ~config
    ~agent_status:Masc_domain.Active
    ~last_activity:now
    ~last_heartbeat:(now -. 31.0) in
  check bool "should emit" true (HS.should_emit_now decision)

let test_skip_idle_when_interval_not_elapsed () =
  let config = HS.default_config in
  let now = Unix.gettimeofday () in
  (* last_heartbeat 10s ago, base interval 30s *)
  let decision = HS.should_emit
    ~config
    ~agent_status:Masc_domain.Active
    ~last_activity:now
    ~last_heartbeat:(now -. 10.0) in
  check bool "should not emit" false (HS.should_emit_now decision);
  (match decision with
   | HS.Skip_idle _ -> ()
   | _ -> fail "expected Skip_idle decision")

let test_idle_multiplier_extends_interval () =
  let config = HS.default_config in
  let now = Unix.gettimeofday () in
  (* Agent idle for 6 minutes (> 5min threshold) *)
  let last_activity = now -. 360.0 in
  let interval = HS.effective_interval ~config ~last_activity in
  (* Should be base * multiplier = 30 * 3 = 90 *)
  check (float 0.1) "idle interval is 90s" 90.0 interval

let test_active_uses_base_interval () =
  let config = HS.default_config in
  let now = Unix.gettimeofday () in
  (* Agent active 10s ago (< 5min threshold) *)
  let last_activity = now -. 10.0 in
  let interval = HS.effective_interval ~config ~last_activity in
  check (float 0.1) "active interval is 30s" 30.0 interval

(* ── Feature flag behavior ─── *)

let test_feature_flag_disabled () =
  (* When smart_hb_enabled=false, decision should always be Emit.
     This mirrors the logic: if not enabled then Emit. *)
  let decision = HS.Emit in
  check bool "emit when disabled" true (HS.should_emit_now decision)

let test_env_config_default_enabled () =
  (* Verify default value matches expectation *)
  check bool "smart heartbeat default enabled" true
    Env_config.SmartHeartbeat.enabled

(* ── decision_to_string coverage ─── *)

let test_decision_to_string_emit () =
  check string "emit string" "emit" (HS.decision_to_string HS.Emit)

let test_decision_to_string_skip_busy () =
  check string "skip_busy string" "skip:busy" (HS.decision_to_string HS.Skip_busy)

let test_decision_to_string_skip_idle () =
  let s = HS.decision_to_string (HS.Skip_idle (Unix.gettimeofday () +. 60.0)) in
  check bool "starts with skip:idle" true
    (String.length s > 9 && String.sub s 0 9 = "skip:idle")

(* ── Cycle-gate regression guard ───────────────────────────────────
   Claim-holding keeper starvation (2026-04-25): 8 of 14 keepers
   were frozen because Skip_busy (emitted whenever current_task_id
   was Some _) was mis-used as a cycle-skip signal. The only way to
   reach the turn evaluator is through [run_smart_heartbeat_gate]
   returning true. These tests codify the correct mapping: Skip_busy
   debounces the broadcast but must NEVER skip the cycle itself. *)

module KK = Masc_mcp.Keeper_keepalive

let test_cycle_continues_on_skip_busy () =
  check bool "Skip_busy cycle continues" true
    (KK.smart_heartbeat_cycle_continues HS.Skip_busy)

let test_cycle_continues_on_emit () =
  check bool "Emit cycle continues" true
    (KK.smart_heartbeat_cycle_continues HS.Emit)

let test_cycle_pauses_on_skip_idle () =
  let next = Unix.gettimeofday () +. 60.0 in
  check bool "Skip_idle pauses cycle" false
    (KK.smart_heartbeat_cycle_continues (HS.Skip_idle next))

(* ── MissedWakeup gap regression guard (KeeperHeartbeat.tla) ───────
   Skip_idle + Woken must promote the gate to [true]. Without this,
   external wakeup_keeper / board_signal calls that fire during a
   Skip_idle backoff sleep are silently absorbed: the CAS clears the
   atomic, the loop returns, but the cycle is skipped — the spec's
   MissedWakeup bug-action (line 104, KeeperHeartbeat.tla) made
   concrete. Sibling of #10078 which closed the same hole for
   Skip_busy. *)

module KKS = Masc_mcp.Keeper_keepalive_signal

let test_board_wakeup_selection_caps_generic_activity () =
  let selected, dropped =
    KKS.select_board_wakeup_candidates
      ~generic_limit:2
      [
        "a", Some "board_activity";
        "b", Some "board_activity";
        "c", Some "board_activity";
        "d", None;
      ]
  in
  check (list (pair string string)) "selected generic wakeups"
    [ "a", "board_activity"; "b", "board_activity" ]
    selected;
  check int "dropped generic wakeups" 1 dropped

let test_board_wakeup_selection_keeps_explicit_mentions () =
  let selected, dropped =
    KKS.select_board_wakeup_candidates
      ~generic_limit:1
      [
        "a", Some "board_activity";
        "b", Some "explicit_mention";
        "c", Some "explicit_mention";
      ]
  in
  check (list (pair string string)) "selected explicit wakeups"
    [ "b", "explicit_mention"; "c", "explicit_mention" ]
    selected;
  check int "dropped generic wakeups" 0 dropped

let test_board_wakeup_selection_keeps_specific_reasons_past_generic_cap () =
  let selected, dropped =
    KKS.select_board_wakeup_candidates
      ~generic_limit:1
      [
        "a", Some "board_activity";
        "b", Some "thread_reply_after_self_comment";
        "c", Some "board_activity";
      ]
  in
  check (list (pair string string)) "selected mixed wakeups"
    [ "b", "thread_reply_after_self_comment"; "a", "board_activity" ]
    selected;
  check int "dropped generic wakeups" 1 dropped

let test_board_wakeup_selection_caps_total_non_explicit () =
  (* Non-generic reasons are prioritized over board_activity before total cap *)
  let selected, dropped =
    KKS.select_board_wakeup_candidates
      ~generic_limit:4
      ~total_limit:2
      [
        "a", Some "board_activity";
        "b", Some "thread_reply_after_self_comment";
        "c", Some "board_activity";
        "d", Some "thread_reply_after_self_comment";
      ]
  in
  check (list (pair string string)) "selected total wakeups"
    [ "b", "thread_reply_after_self_comment"; "d", "thread_reply_after_self_comment" ]
    selected;
  check int "dropped total wakeups" 2 dropped

let test_board_wakeup_selection_total_limit_prefers_non_generic () =
  (* A late non-generic entry must survive when a generic entry would displace it
     under candidate order alone.  After prioritization the two non-generic items
     fill the cap and the generic one is dropped instead. *)
  let selected, dropped =
    KKS.select_board_wakeup_candidates
      ~generic_limit:5
      ~total_limit:2
      [
        "a", Some "board_activity";
        "b", Some "board_activity";
        "c", Some "thread_reply_after_self_comment";
      ]
  in
  check (list (pair string string)) "non-generic survives cap"
    [ "c", "thread_reply_after_self_comment"; "a", "board_activity" ]
    selected;
  check int "dropped generic" 1 dropped

let test_after_wake_idle_woken_continues () =
  let next = Unix.gettimeofday () +. 60.0 in
  check bool "Skip_idle + Woken -> cycle resumes" true
    (KK.cycle_continues_after_wake (HS.Skip_idle next) KKS.Woken)

let test_after_wake_idle_timeout_pauses () =
  let next = Unix.gettimeofday () +. 60.0 in
  check bool "Skip_idle + Timeout -> cycle still paused" false
    (KK.cycle_continues_after_wake (HS.Skip_idle next) KKS.Timeout)

let test_after_wake_idle_stopped_pauses () =
  let next = Unix.gettimeofday () +. 60.0 in
  check bool "Skip_idle + Stopped -> cycle paused (shutdown path)" false
    (KK.cycle_continues_after_wake (HS.Skip_idle next) KKS.Stopped)

let test_after_wake_busy_unchanged () =
  (* Skip_busy already continues per #10078; outcome must not regress
     that decision regardless of the sleep outcome (this branch never
     sleeps in practice, but the helper is total). *)
  check bool "Skip_busy + Woken -> still continues" true
    (KK.cycle_continues_after_wake HS.Skip_busy KKS.Woken);
  check bool "Skip_busy + Timeout -> still continues" true
    (KK.cycle_continues_after_wake HS.Skip_busy KKS.Timeout)

let test_after_wake_emit_unchanged () =
  check bool "Emit + Timeout -> continues" true
    (KK.cycle_continues_after_wake HS.Emit KKS.Timeout);
  check bool "Emit + Woken -> continues" true
    (KK.cycle_continues_after_wake HS.Emit KKS.Woken)

(* ── Operator telemetry: positive signal counter ───────────────────
   Sibling to masc_keeper_stale_termination_by_class_total (negative).
   Operators read these two together: rate(positive) > 0 + rate(negative
   {class=idle_turn}) trending to 0 = fix is firing. Both metrics must
   be registered (no dead series), accept a [keeper] label, and increment
   monotonically. *)

module Prom = Masc_mcp.Prometheus

let test_skip_idle_wake_resumed_metric_registered () =
  let labels = [ ("keeper", "test_keeper_a") ] in
  let before =
    Prom.metric_value_or_zero
      Prom.metric_keeper_skip_idle_wake_resumed ~labels ()
  in
  Prom.inc_counter
    Prom.metric_keeper_skip_idle_wake_resumed ~labels ();
  let after =
    Prom.metric_value_or_zero
      Prom.metric_keeper_skip_idle_wake_resumed ~labels ()
  in
  check (float 0.001) "counter increments by 1" 1.0 (after -. before)

let test_skip_idle_wake_resumed_label_isolation () =
  (* Per-keeper labels must not bleed: a delta on keeper_a should not
     show on keeper_b. Otherwise operators cannot attribute the fix
     activity to specific keepers in fleet dashboards. *)
  let la = [ ("keeper", "test_keeper_iso_a") ] in
  let lb = [ ("keeper", "test_keeper_iso_b") ] in
  let b_before =
    Prom.metric_value_or_zero
      Prom.metric_keeper_skip_idle_wake_resumed ~labels:lb ()
  in
  Prom.inc_counter
    Prom.metric_keeper_skip_idle_wake_resumed ~labels:la ();
  Prom.inc_counter
    Prom.metric_keeper_skip_idle_wake_resumed ~labels:la ();
  let b_after =
    Prom.metric_value_or_zero
      Prom.metric_keeper_skip_idle_wake_resumed ~labels:lb ()
  in
  check (float 0.001) "keeper_b counter unchanged" 0.0
    (b_after -. b_before)

let test_status_tick_usage_json_includes_cache_fields () =
  let usage = KK.status_tick_usage_json () in
  let int_member key =
    match usage with
    | `Assoc fields -> (
        match List.assoc_opt key fields with
        | Some (`Int value) -> value
        | _ -> fail (key ^ " should be int"))
    | _ -> fail "usage should be object"
  in
  check int "input zero" 0 (int_member "input_tokens");
  check int "output zero" 0 (int_member "output_tokens");
  check int "cache creation zero" 0
    (int_member "cache_creation_tokens");
  check int "cache read zero" 0
    (int_member "cache_read_tokens");
  check int "total zero" 0 (int_member "total_tokens")

(* ── Test runner ─── *)

let () =
  run "smart_heartbeat_keepalive" [
    "agent_status_derivation", [
      test_case "busy when task claimed" `Quick test_status_busy_when_task_claimed;
      test_case "active when no task" `Quick test_status_active_when_no_task;
      test_case "inactive when paused" `Quick test_status_inactive_when_paused;
      test_case "inactive when paused no task" `Quick test_status_inactive_when_paused_no_task;
    ];
    "smart_heartbeat_decisions", [
      test_case "skip busy with task" `Quick test_skip_busy_with_task;
      test_case "emit when active and interval elapsed" `Quick test_emit_when_active_and_interval_elapsed;
      test_case "skip idle when interval not elapsed" `Quick test_skip_idle_when_interval_not_elapsed;
      test_case "idle multiplier extends interval" `Quick test_idle_multiplier_extends_interval;
      test_case "active uses base interval" `Quick test_active_uses_base_interval;
    ];
    "feature_flag", [
      test_case "disabled means emit" `Quick test_feature_flag_disabled;
      test_case "default is enabled" `Quick test_env_config_default_enabled;
    ];
    "decision_to_string", [
      test_case "emit" `Quick test_decision_to_string_emit;
      test_case "skip_busy" `Quick test_decision_to_string_skip_busy;
      test_case "skip_idle" `Quick test_decision_to_string_skip_idle;
    ];
    "cycle_gate_regression", [
      test_case "Skip_busy -> cycle continues (#claim-starvation regression)"
        `Quick test_cycle_continues_on_skip_busy;
      test_case "Emit -> cycle continues" `Quick test_cycle_continues_on_emit;
      test_case "Skip_idle -> cycle pauses" `Quick test_cycle_pauses_on_skip_idle;
    ];
    "board_wakeup_selection", [
      test_case "generic board activity is capped"
        `Quick test_board_wakeup_selection_caps_generic_activity;
      test_case "explicit mentions bypass generic cap"
        `Quick test_board_wakeup_selection_keeps_explicit_mentions;
      test_case "specific reasons survive generic cap"
        `Quick test_board_wakeup_selection_keeps_specific_reasons_past_generic_cap;
      test_case "total non-explicit fanout is capped"
        `Quick test_board_wakeup_selection_caps_total_non_explicit;
      test_case "total limit prefers non-generic over board_activity"
        `Quick test_board_wakeup_selection_total_limit_prefers_non_generic;
    ];
    "missed_wakeup_gap", [
      test_case "Skip_idle + Woken -> resumes (MissedWakeup spec gap)"
        `Quick test_after_wake_idle_woken_continues;
      test_case "Skip_idle + Timeout -> still paused"
        `Quick test_after_wake_idle_timeout_pauses;
      test_case "Skip_idle + Stopped -> paused (shutdown)"
        `Quick test_after_wake_idle_stopped_pauses;
      test_case "Skip_busy outcome-agnostic"
        `Quick test_after_wake_busy_unchanged;
      test_case "Emit outcome-agnostic"
        `Quick test_after_wake_emit_unchanged;
    ];
    "operator_telemetry", [
      test_case "skip_idle_wake_resumed counter registered"
        `Quick test_skip_idle_wake_resumed_metric_registered;
      test_case "per-keeper label isolation"
        `Quick test_skip_idle_wake_resumed_label_isolation;
    ];
    "status_tick_usage", [
      test_case "status tick usage preserves cache fields" `Quick
        test_status_tick_usage_json_includes_cache_fields;
    ];
  ]
