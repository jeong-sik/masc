(** Tests for smart heartbeat integration in keeper_keepalive.

    Verifies that the Heartbeat_smart module decisions correctly map
    to Types.agent_status based on keeper_meta fields (current_task_id,
    paused), and that the env-config feature flag controls activation.

    These are unit-level tests of the mapping logic, not full keepalive
    loop integration tests (which require Eio fibers + Coord I/O). *)

open Alcotest
module HS = Masc_mcp.Heartbeat_smart

(* ── agent_status derivation from keeper_meta fields ─── *)

(** Derive agent_status from keeper_meta fields, mirroring the logic
    in keeper_keepalive.ml run_heartbeat_loop. *)
let derive_agent_status ~paused ~current_task_id =
  if paused
  then Types.Inactive
  else (
    match current_task_id with
    | Some _ -> Types.Busy
    | None -> Types.Active)
;;

let test_status_busy_when_task_claimed () =
  let status = derive_agent_status ~paused:false ~current_task_id:(Some "task-42") in
  check
    string
    "busy when task claimed"
    (Types.show_agent_status Types.Busy)
    (Types.show_agent_status status)
;;

let test_status_active_when_no_task () =
  let status = derive_agent_status ~paused:false ~current_task_id:None in
  check
    string
    "active when no task"
    (Types.show_agent_status Types.Active)
    (Types.show_agent_status status)
;;

let test_status_inactive_when_paused () =
  let status = derive_agent_status ~paused:true ~current_task_id:(Some "task-99") in
  check
    string
    "inactive when paused"
    (Types.show_agent_status Types.Inactive)
    (Types.show_agent_status status)
;;

let test_status_inactive_when_paused_no_task () =
  let status = derive_agent_status ~paused:true ~current_task_id:None in
  check
    string
    "inactive when paused, no task"
    (Types.show_agent_status Types.Inactive)
    (Types.show_agent_status status)
;;

(* ── Heartbeat_smart decision tests with keeper-derived statuses ─── *)

let test_skip_busy_with_task () =
  let config = HS.default_config in
  let now = Unix.gettimeofday () in
  let decision =
    HS.should_emit
      ~config
      ~agent_status:Types.Busy
      ~last_activity:now
      ~last_heartbeat:(now -. 10.0)
  in
  check string "skip when busy" "skip:busy" (HS.decision_to_string decision)
;;

let test_emit_when_active_and_interval_elapsed () =
  let config = HS.default_config in
  let now = Unix.gettimeofday () in
  (* last_heartbeat 31s ago, base interval 30s *)
  let decision =
    HS.should_emit
      ~config
      ~agent_status:Types.Active
      ~last_activity:now
      ~last_heartbeat:(now -. 31.0)
  in
  check bool "should emit" true (HS.should_emit_now decision)
;;

let test_skip_idle_when_interval_not_elapsed () =
  let config = HS.default_config in
  let now = Unix.gettimeofday () in
  (* last_heartbeat 10s ago, base interval 30s *)
  let decision =
    HS.should_emit
      ~config
      ~agent_status:Types.Active
      ~last_activity:now
      ~last_heartbeat:(now -. 10.0)
  in
  check bool "should not emit" false (HS.should_emit_now decision);
  match decision with
  | HS.Skip_idle _ -> ()
  | _ -> fail "expected Skip_idle decision"
;;

let test_idle_multiplier_extends_interval () =
  let config = HS.default_config in
  let now = Unix.gettimeofday () in
  (* Agent idle for 6 minutes (> 5min threshold) *)
  let last_activity = now -. 360.0 in
  let interval = HS.effective_interval ~config ~last_activity in
  (* Should be base * multiplier = 30 * 3 = 90 *)
  check (float 0.1) "idle interval is 90s" 90.0 interval
;;

let test_active_uses_base_interval () =
  let config = HS.default_config in
  let now = Unix.gettimeofday () in
  (* Agent active 10s ago (< 5min threshold) *)
  let last_activity = now -. 10.0 in
  let interval = HS.effective_interval ~config ~last_activity in
  check (float 0.1) "active interval is 30s" 30.0 interval
;;

(* ── Feature flag behavior ─── *)

let test_feature_flag_disabled () =
  (* When smart_hb_enabled=false, decision should always be Emit.
     This mirrors the logic: if not enabled then Emit. *)
  let decision = HS.Emit in
  check bool "emit when disabled" true (HS.should_emit_now decision)
;;

let test_env_config_default_enabled () =
  (* Verify default value matches expectation *)
  check bool "smart heartbeat default enabled" true Env_config.SmartHeartbeat.enabled
;;

(* ── decision_to_string coverage ─── *)

let test_decision_to_string_emit () =
  check string "emit string" "emit" (HS.decision_to_string HS.Emit)
;;

let test_decision_to_string_skip_busy () =
  check string "skip_busy string" "skip:busy" (HS.decision_to_string HS.Skip_busy)
;;

let test_decision_to_string_skip_idle () =
  let s = HS.decision_to_string (HS.Skip_idle (Unix.gettimeofday () +. 60.0)) in
  check
    bool
    "starts with skip:idle"
    true
    (String.length s > 9 && String.sub s 0 9 = "skip:idle")
;;

(* ── Cycle-gate regression guard ───────────────────────────────────
   Claim-holding keeper starvation (2026-04-25): 8 of 14 keepers
   were frozen because Skip_busy (emitted whenever current_task_id
   was Some _) was mis-used as a cycle-skip signal. The only way to
   reach the turn evaluator is through [run_smart_heartbeat_gate]
   returning true. These tests codify the correct mapping: Skip_busy
   debounces the broadcast but must NEVER skip the cycle itself. *)

module KK = Masc_mcp.Keeper_keepalive

let test_cycle_continues_on_skip_busy () =
  check
    bool
    "Skip_busy cycle continues"
    true
    (KK.smart_heartbeat_cycle_continues HS.Skip_busy)
;;

let test_cycle_continues_on_emit () =
  check bool "Emit cycle continues" true (KK.smart_heartbeat_cycle_continues HS.Emit)
;;

let test_cycle_pauses_on_skip_idle () =
  let next = Unix.gettimeofday () +. 60.0 in
  check
    bool
    "Skip_idle pauses cycle"
    false
    (KK.smart_heartbeat_cycle_continues (HS.Skip_idle next))
;;

let test_status_tick_usage_json_includes_cache_fields () =
  let usage = KK.status_tick_usage_json () in
  let int_member key =
    match usage with
    | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`Int value) -> value
       | _ -> fail (key ^ " should be int"))
    | _ -> fail "usage should be object"
  in
  check int "input zero" 0 (int_member "input_tokens");
  check int "output zero" 0 (int_member "output_tokens");
  check int "cache creation zero" 0 (int_member "cache_creation_tokens");
  check int "cache read zero" 0 (int_member "cache_read_tokens");
  check int "total zero" 0 (int_member "total_tokens")
;;

(* ── Test runner ─── *)

let () =
  run
    "smart_heartbeat_keepalive"
    [ ( "agent_status_derivation"
      , [ test_case "busy when task claimed" `Quick test_status_busy_when_task_claimed
        ; test_case "active when no task" `Quick test_status_active_when_no_task
        ; test_case "inactive when paused" `Quick test_status_inactive_when_paused
        ; test_case
            "inactive when paused no task"
            `Quick
            test_status_inactive_when_paused_no_task
        ] )
    ; ( "smart_heartbeat_decisions"
      , [ test_case "skip busy with task" `Quick test_skip_busy_with_task
        ; test_case
            "emit when active and interval elapsed"
            `Quick
            test_emit_when_active_and_interval_elapsed
        ; test_case
            "skip idle when interval not elapsed"
            `Quick
            test_skip_idle_when_interval_not_elapsed
        ; test_case
            "idle multiplier extends interval"
            `Quick
            test_idle_multiplier_extends_interval
        ; test_case "active uses base interval" `Quick test_active_uses_base_interval
        ] )
    ; ( "feature_flag"
      , [ test_case "disabled means emit" `Quick test_feature_flag_disabled
        ; test_case "default is enabled" `Quick test_env_config_default_enabled
        ] )
    ; ( "decision_to_string"
      , [ test_case "emit" `Quick test_decision_to_string_emit
        ; test_case "skip_busy" `Quick test_decision_to_string_skip_busy
        ; test_case "skip_idle" `Quick test_decision_to_string_skip_idle
        ] )
    ; ( "cycle_gate_regression"
      , [ test_case
            "Skip_busy -> cycle continues (#claim-starvation regression)"
            `Quick
            test_cycle_continues_on_skip_busy
        ; test_case "Emit -> cycle continues" `Quick test_cycle_continues_on_emit
        ; test_case "Skip_idle -> cycle pauses" `Quick test_cycle_pauses_on_skip_idle
        ] )
    ; ( "status_tick_usage"
      , [ test_case
            "status tick usage preserves cache fields"
            `Quick
            test_status_tick_usage_json_includes_cache_fields
        ] )
    ]
;;
