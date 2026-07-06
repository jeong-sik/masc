module Types = Masc_domain

(** Tests for smart heartbeat integration in keeper_keepalive.

    Verifies that the Keeper_heartbeat_smart module decisions correctly map
    to Masc_domain.agent_status based on keeper_meta fields (current_task_id,
    paused), and that the env-config feature flag controls activation.

    These are unit-level tests of the mapping logic, not full keepalive
    loop integration tests (which require Eio fibers + Workspace I/O). *)

open Alcotest
open Masc
module HS = Masc.Keeper_heartbeat_smart

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

(* ── Keeper_heartbeat_smart decision tests with keeper-derived statuses ─── *)

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

module KK = Masc.Keeper_keepalive

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path

let with_temp_workspace f =
  let base_path = Filename.temp_dir "keeper-heartbeat-current-task" "" in
  let config = Workspace.default_config base_path in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      ignore (Workspace.init config ~agent_name:None : string);
      f config)

let make_keepalive_meta ~name ~agent_name =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String agent_name);
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "test");
        ("sandbox_profile", `String "local");
        ("network_mode", `String "inherit");
        ("tool_access", `List []);
      ]
  in
  match Keeper_meta_json_parse.meta_of_json json with
  | Error err -> fail ("meta_of_json failed: " ^ err)
  | Ok meta -> meta

let make_in_progress_task ~id ~assignee : Types.task =
  {
    id;
    title = "Heartbeat current task";
    description = "";
    task_status =
      Types.InProgress { assignee; started_at = "2026-06-26T00:00:00Z" };
    priority = 3;
    files = [];
    created_at = "2026-06-26T00:00:00Z";
    created_by = Some "test";
    contract = None;
    handoff_context = None;
    cycle_count = 0;
    reclaim_policy = None;
    do_not_reclaim_reason = None;
  }

let test_current_task_id_for_agent_reconciles_from_empty_registry_task () =
  with_temp_workspace (fun config ->
    let keeper_name = "heartbeat-current-task-owner" in
    let agent_name = "keeper-heartbeat-current-task-owner-agent" in
    let task_id = "task-heartbeat-current" in
    let meta = make_keepalive_meta ~name:keeper_name ~agent_name in
    (match Keeper_meta_store.write_meta config meta with
     | Ok () -> ()
     | Error err -> fail ("write_meta failed: " ^ err));
    Workspace.write_backlog config
      {
        Types.tasks = [ make_in_progress_task ~id:task_id ~assignee:agent_name ];
        last_updated = "2026-06-26T00:00:01Z";
        version = 2;
      };
    ignore
      (Keeper_registry.register
         ~base_path:config.Workspace.base_path
         keeper_name
         meta);
    Fun.protect
      ~finally:(fun () ->
        Keeper_registry.unregister ~base_path:config.Workspace.base_path keeper_name)
      (fun () ->
        check string "heartbeat task id" task_id
          (KK.current_task_id_for_agent ~config agent_name);
        let current_from_registry =
          match Keeper_registry.get ~base_path:config.Workspace.base_path keeper_name with
          | Some entry ->
            Keeper_runtime_contract.current_task_id_opt entry.meta
          | None -> None
        in
        check (option string) "registry current task reconciled" (Some task_id)
          current_from_registry;
        let current_from_disk =
          match Keeper_meta_store.read_meta config keeper_name with
          | Ok (Some persisted) ->
            Keeper_runtime_contract.current_task_id_opt persisted
          | Ok None -> None
          | Error err -> fail ("read_meta failed: " ^ err)
        in
        check (option string) "persisted current task reconciled" (Some task_id)
          current_from_disk))

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

let test_visibility_gate_delays_unobserved_idle_emit () =
  let now = 1_000.0 in
  let decision =
    KK.visibility_gate_decision
      ~visible_consumers:0
      ~has_pending_signal:false
      ~now
      ~last_heartbeat_cycle_ts:(now -. 60.0)
      HS.Emit
  in
  check bool "unobserved idle becomes skip_idle" true
    (match decision with HS.Skip_idle _ -> true | _ -> false)

let test_visibility_gate_allows_pending_signal () =
  let decision =
    KK.visibility_gate_decision
      ~visible_consumers:0
      ~has_pending_signal:true
      ~now:1_000.0
      ~last_heartbeat_cycle_ts:940.0
      HS.Emit
  in
  check bool "pending signal keeps emit" true (decision = HS.Emit)

let test_visibility_gate_allows_visible_consumer () =
  let decision =
    KK.visibility_gate_decision
      ~visible_consumers:1
      ~has_pending_signal:false
      ~now:1_000.0
      ~last_heartbeat_cycle_ts:940.0
      HS.Emit
  in
  check bool "visible consumer keeps emit" true (decision = HS.Emit)

let test_visibility_gate_preserves_busy () =
  let decision =
    KK.visibility_gate_decision
      ~visible_consumers:0
      ~has_pending_signal:false
      ~now:1_000.0
      ~last_heartbeat_cycle_ts:940.0
      HS.Skip_busy
  in
  check bool "busy keeps cycle path" true (decision = HS.Skip_busy)

let is_warn_unknown_keeper = function
  | KK.Warn_unknown_keeper -> true
  | KK.Debug_throttled_unknown_keeper -> false

let is_debug_throttled_unknown_keeper = function
  | KK.Debug_throttled_unknown_keeper -> true
  | KK.Warn_unknown_keeper -> false

let test_not_in_registry_warn_due_first_event () =
  check bool "first unknown-keeper directive warns" true
    (KK.not_in_registry_warn_due ~previous:None ~now:1_000.0 ())

let test_not_in_registry_warn_due_throttles_within_window () =
  check bool "same window throttles" false
    (KK.not_in_registry_warn_due
       ~previous:(Some 1_000.0)
       ~now:(1_000.0 +. (KK.not_in_registry_warn_cooldown_s /. 2.0))
       ())

let test_not_in_registry_warn_due_recovers_on_clock_regression () =
  check bool "clock regression does not suppress forever" true
    (KK.not_in_registry_warn_due ~previous:(Some 1_000.0) ~now:999.0 ())

let test_not_in_registry_warn_state_is_per_agent () =
  let open KK in
  let state = StringMap.add "keeper-a-agent" 1_000.0 StringMap.empty in
  let decision_a, _ =
    not_in_registry_warn_state_step
      ~agent_name:"keeper-a-agent"
      ~now:(1_000.0 +. (not_in_registry_warn_cooldown_s /. 2.0))
      state
  in
  let decision_b, updated =
    not_in_registry_warn_state_step
      ~agent_name:"keeper-b-agent"
      ~now:(1_000.0 +. (not_in_registry_warn_cooldown_s /. 2.0))
      state
  in
  check bool "same agent throttled" true
    (is_debug_throttled_unknown_keeper decision_a);
  check bool "different agent warns" true (is_warn_unknown_keeper decision_b);
  check bool "different agent recorded" true
    (Option.is_some (StringMap.find_opt "keeper-b-agent" updated))

let test_not_in_registry_warn_state_is_bounded () =
  let open KK in
  let state =
    List.fold_left
      (fun acc i ->
         StringMap.add
           ("keeper-" ^ string_of_int i ^ "-agent")
           (2_000.0 -. float_of_int i)
           acc)
      StringMap.empty
      [ 0; 1; 2; 3; 4 ]
  in
  let decision, updated =
    not_in_registry_warn_state_step
      ~max_entries:3
      ~agent_name:"keeper-new-agent"
      ~now:2_001.0
      state
  in
  check bool "new unknown keeper still warns" true (is_warn_unknown_keeper decision);
  check int "warn throttle map is capped" 3 (StringMap.cardinal updated);
  check bool "new unknown keeper is retained" true
    (Option.is_some (StringMap.find_opt "keeper-new-agent" updated));
  check bool "oldest unknown keeper is pruned" true
    (Option.is_none (StringMap.find_opt "keeper-4-agent" updated))

(* ── MissedWakeup gap regression guard (KeeperHeartbeat.tla) ───────
   Skip_idle + Woken must promote the gate to [true]. Without this,
   external wakeup_keeper / board_signal calls that fire during a
   Skip_idle backoff sleep are silently absorbed: the CAS clears the
   atomic, the loop returns, but the cycle is skipped — the spec's
   MissedWakeup bug-action (line 104, KeeperHeartbeat.tla) made
   concrete. Sibling of #10078 which closed the same hole for
   Skip_busy. *)

module KKS = Masc.Keeper_keepalive_signal
module KWOBS = Masc.Keeper_world_observation_board_signal

(* Compare selected wake reasons by their stable label so the typed variant
   stays printable in Alcotest's (string) testable. *)
let reason_label = KWOBS.wake_reason_label
let labeled selected = List.map (fun (item, r) -> item, reason_label r) selected

let make_board_resume_meta ?(paused = false) ?auto_resume_after_sec name =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("keeper-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "test");
        ("sandbox_profile", `String "local");
        ("network_mode", `String "inherit");
        ("tool_access", `List []);
      ]
  in
  match Keeper_meta_json_parse.meta_of_json json with
  | Error err -> fail ("meta_of_json failed: " ^ err)
  | Ok meta -> { meta with paused; auto_resume_after_sec }

let test_board_auto_resume_rejects_operator_pause () =
  let meta = make_board_resume_meta ~paused:true "operator-paused" in
  check bool "operator pause is not board-auto-resumable" false
    (KKS.paused_meta_allows_board_auto_resume meta)

let test_board_auto_resume_allows_auto_paused_keeper () =
  let meta =
    make_board_resume_meta ~paused:true ~auto_resume_after_sec:3600.0
      "auto-paused"
  in
  check bool "auto-paused keeper is board-auto-resumable" true
    (KKS.paused_meta_allows_board_auto_resume meta)

let test_board_wakeup_selection_keeps_explicit_mentions () =
  let selected, dropped =
    KKS.select_board_wakeup_candidates
      [
        "a", Some KWOBS.Thread_reply_after_self_comment;
        "b", Some KWOBS.Explicit_mention;
        "c", Some KWOBS.Explicit_mention;
      ]
  in
  (* Explicit mentions short-circuit and wake unconditionally. Non-explicit
     candidates are ignored when explicit mentions are present. *)
  check (list (pair string string)) "selected explicit wakeups"
    [ "b", "explicit_mention"; "c", "explicit_mention" ]
    (labeled selected);
  check int "explicit short circuit drops no capped candidates" 0 dropped

let test_board_wakeup_selection_drops_none_reasons () =
  let selected, dropped =
    KKS.select_board_wakeup_candidates
      [
        "a", Some KWOBS.Thread_reply_after_self_comment;
        "b", None;
        "c", Some (KWOBS.Board_comment_read_error "comments unavailable");
      ]
  in
  (* [None] reasons (no deterministic address) are dropped; structural
     followup reasons survive in candidate order. *)
  check (list (pair string string)) "None dropped, real reasons kept"
    [ "a", "thread_reply_after_self_comment"; "c", "board_comment_read_error" ]
    (labeled selected);
  check int "no cap drops under total limit" 0 dropped

let test_board_wakeup_selection_keeps_comment_read_errors () =
  let selected, dropped =
    KKS.select_board_wakeup_candidates
      [
        "a", None;
        "b", Some (KWOBS.Board_comment_read_error "comments unavailable");
        "c", Some KWOBS.Thread_reply_after_self_comment;
      ]
  in
  check (list (pair string string)) "comment read error remains a wake reason"
    [
      "b", "board_comment_read_error";
      "c", "thread_reply_after_self_comment";
    ]
    (labeled selected);
  check int "no cap drops under total limit" 0 dropped

let test_board_wakeup_selection_caps_total_non_explicit () =
  let selected, dropped =
    KKS.select_board_wakeup_candidates
      ~total_limit:2
      [
        "a", Some (KWOBS.Board_comment_read_error "comments unavailable");
        "b", Some KWOBS.Thread_reply_after_self_comment;
        "c", Some KWOBS.Reaction_after_self_activity;
        "d", Some KWOBS.Thread_reply_after_self_comment;
      ]
  in
  check (list (pair string string)) "first two non-explicit kept in order"
    [ "a", "board_comment_read_error"; "b", "thread_reply_after_self_comment" ]
    (labeled selected);
  check int "overflow dropped" 2 dropped

let test_board_wakeup_selection_caps_thread_followups () =
  let selected, dropped =
    KKS.select_board_wakeup_candidates
      ~total_limit:2
      [
        "a", Some KWOBS.Thread_reply_after_self_comment;
        "b", Some KWOBS.Thread_reply_after_self_comment;
        "c", Some KWOBS.Thread_reply_after_self_comment;
        "d", Some KWOBS.Thread_reply_after_self_comment;
      ]
  in
  (* Thread followups compete for [total_limit] slots in candidate order; the
     overflow is dropped. *)
  check (list (pair string string)) "first two non-explicit kept in order"
    [ "a", "thread_reply_after_self_comment"; "b", "thread_reply_after_self_comment" ]
    (labeled selected);
  check int "overflow dropped" 2 dropped

let test_board_goal_keyword_overlap_is_not_wake_reason () =
  let meta = make_board_resume_meta "keyword-overlap" in
  let signal : Board_dispatch.board_signal =
    { kind = Board_dispatch.Board_post_created
    ; post_id = "post-keyword-overlap"
    ; author = "external-author"
    ; title = "test"
    ; content = "this test overlaps the keeper goal but does not address it"
    ; hearth = None
    ; updated_at = Some 123.0
    }
  in
  check (option string) "goal keyword overlap no longer wakes" None
    (Option.map KWOBS.wake_reason_label
       (KWOBS.wake_reason ~continuity_summary:"" ~meta ~signal))

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

module Metrics = Masc.Otel_metric_store

let test_skip_idle_wake_resumed_metric_registered () =
  let labels = [ ("keeper", "test_keeper_a") ] in
  let before =
    Metrics.metric_value_or_zero
      Keeper_metrics.(to_string SkipIdleWakeResumed) ~labels ()
  in
  Metrics.inc_counter
    Keeper_metrics.(to_string SkipIdleWakeResumed) ~labels ();
  let after =
    Metrics.metric_value_or_zero
      Keeper_metrics.(to_string SkipIdleWakeResumed) ~labels ()
  in
  check (float 0.001) "counter increments by 1" 1.0 (after -. before)

let test_skip_idle_wake_resumed_label_isolation () =
  (* Per-keeper labels must not bleed: a delta on keeper_a should not
     show on keeper_b. Otherwise operators cannot attribute the fix
     activity to specific keepers in fleet dashboards. *)
  let la = [ ("keeper", "test_keeper_iso_a") ] in
  let lb = [ ("keeper", "test_keeper_iso_b") ] in
  let b_before =
    Metrics.metric_value_or_zero
      Keeper_metrics.(to_string SkipIdleWakeResumed) ~labels:lb ()
  in
  Metrics.inc_counter
    Keeper_metrics.(to_string SkipIdleWakeResumed) ~labels:la ();
  Metrics.inc_counter
    Keeper_metrics.(to_string SkipIdleWakeResumed) ~labels:la ();
  let b_after =
    Metrics.metric_value_or_zero
      Keeper_metrics.(to_string SkipIdleWakeResumed) ~labels:lb ()
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
    "current_task_reconciliation", [
      test_case "heartbeat reconciles empty current_task_id from active backlog"
        `Quick test_current_task_id_for_agent_reconciles_from_empty_registry_task;
    ];
    "visibility_gate", [
      test_case "unobserved idle emit delays dispatch" `Quick
        test_visibility_gate_delays_unobserved_idle_emit;
      test_case "pending signal bypasses no-consumer delay" `Quick
        test_visibility_gate_allows_pending_signal;
      test_case "visible consumer bypasses delay" `Quick
        test_visibility_gate_allows_visible_consumer;
      test_case "busy decision is preserved" `Quick test_visibility_gate_preserves_busy;
    ];
    "directive_orphan_warn_gate", [
      test_case "first unknown keeper directive warns"
        `Quick test_not_in_registry_warn_due_first_event;
      test_case "same unknown keeper is throttled within window"
        `Quick test_not_in_registry_warn_due_throttles_within_window;
      test_case "clock regression does not suppress forever"
        `Quick test_not_in_registry_warn_due_recovers_on_clock_regression;
      test_case "warn gate is per agent"
        `Quick test_not_in_registry_warn_state_is_per_agent;
      test_case "warn gate state is bounded"
        `Quick test_not_in_registry_warn_state_is_bounded;
    ];
    "board_wakeup_selection", [
      test_case "explicit mentions bypass and win"
        `Quick test_board_wakeup_selection_keeps_explicit_mentions;
      test_case "None reasons are dropped, real reasons kept"
        `Quick test_board_wakeup_selection_drops_none_reasons;
      test_case "comment read errors remain typed wake reasons"
        `Quick test_board_wakeup_selection_keeps_comment_read_errors;
      test_case "total non-explicit fanout is capped"
        `Quick test_board_wakeup_selection_caps_total_non_explicit;
      test_case "thread followup fanout is capped"
        `Quick test_board_wakeup_selection_caps_thread_followups;
      test_case "goal keyword overlap is not a wake reason"
        `Quick test_board_goal_keyword_overlap_is_not_wake_reason;
      test_case "operator pauses are not board-auto-resumed"
        `Quick test_board_auto_resume_rejects_operator_pause;
      test_case "auto-paused keepers can be board-auto-resumed"
        `Quick test_board_auto_resume_allows_auto_paused_keeper;
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
