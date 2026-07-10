(* Keeper_turn_helpers — string matching, event reporting, trajectory/receipt
   helpers, FSM guard post-actions, and local discovery readiness.

   Extracted from keeper_unified_turn.ml (L21-326) during the god-file split. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime

(* Interval (seconds) for the per-turn background fiber that drains the
   `keeper_turn` subscription on the OAS event bus.  See
   [start_background_turn_event_bus_drain] for context.

   Step 14(b) of the bloodflow restoration plan inlined the env knob
   [MASC_KEEPER_TURN_DRAIN_INTERVAL_SEC]: hyperparameters belong in
   code, not in [Sys.getenv_opt].  Calibrated values move via PR with
   measurement evidence, not as silent operator overrides. *)
let default_turn_event_bus_drain_interval_sec = 0.05
let turn_event_bus_drain_interval_sec () = default_turn_event_bus_drain_interval_sec

let string_contains_substring = String_util.string_contains_substring
;;

let string_contains_substring_ci = String_util.string_contains_substring_ci
;;

let side_effect_metric_label side_effect =
  let trimmed = String.trim side_effect in
  let normalized =
    String.map
      (function
        | ' ' | ':' | '/' -> '_'
        | c -> c)
      trimmed
  in
  if String.equal normalized "" then "unknown" else normalized
;;

let report_keeper_cycle_side_effect_issue
      ~(config : Workspace.config)
      ~(keeper_name : string)
      ~(side_effect : string)
      ?(severity = `Warn)
      (detail : string)
  : unit
  =
  let message = Printf.sprintf "keeper cycle %s failed: %s" side_effect detail in
  Keeper_registry_error_recording.record ~base_path:config.base_path keeper_name message;
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string DispatchEventFailures)
    ~labels:[ "keeper", keeper_name; "site", side_effect_metric_label side_effect ]
    ();
  match severity with
  | `Warn -> Log.Keeper.warn "%s: %s" keeper_name message
  | `Error -> Log.Keeper.error "%s: %s" keeper_name message
;;

let dispatch_keeper_phase_event_checked
      ~(config : Workspace.config)
      ~(keeper_name : string)
      ~(side_effect : string)
      (event : Keeper_state_machine.event)
  : unit
  =
  match Keeper_registry.dispatch_event ~base_path:config.base_path keeper_name event with
  | Ok _ -> ()
  | Error err ->
    report_keeper_cycle_side_effect_issue
      ~config
      ~keeper_name
      ~side_effect
      (Printf.sprintf
         "phase dispatch %s failed: %s"
         (Keeper_state_machine.event_to_string event)
         (Keeper_state_machine.transition_error_to_string err))
;;

let finalize_trajectory_acc
      ~(config : Workspace.config)
      ~(keeper_name : string)
      (trajectory_acc : Trajectory.accumulator)
      (outcome : Trajectory.trajectory_outcome)
  : unit
  =
  try
    let trajectory = Trajectory.finalize trajectory_acc outcome in
    Log.Keeper.debug
      "%s: trajectory finalized outcome=%s total_tool_calls=%d"
      keeper_name
      (Trajectory.outcome_to_string trajectory.outcome)
      trajectory.total_tool_calls
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    report_keeper_cycle_side_effect_issue
      ~config
      ~keeper_name
      ~side_effect:"trajectory finalize"
      ~severity:`Error
      (Printexc.to_string exn)
;;

let record_execution_receipt_gap
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(stale_reason : string)
      ~(error : string)
      ()
  : unit
  =
  try
    let masc_root = Workspace.masc_root_dir config in
    Telemetry_coverage_gap.record
      ~masc_root
      ~source:"execution_receipt"
      ~producer:"keeper_unified_turn.pre_dispatch"
      ~durable_store:
        (Filename.concat
           (Filename.concat
              (Filename.concat masc_root Common.keepers_runtime_dirname)
              meta.name)
           Keeper_types_support.execution_receipts_dirname)
      ~dashboard_surface:"/api/v1/dashboard/execution-trust"
      ~stale_reason
      ~keeper_name:meta.name
      ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      ~error
      ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string WriteMetaFailures)
      ~labels:[ "keeper", meta.name; "phase", "receipt_coverage_gap" ]
      ();
    Log.Keeper.warn ~keeper_name:meta.name
      "pre-dispatch execution_receipt coverage gap append failed: %s"
      (Printexc.to_string exn)
;;

(* -- KeeperTaskAcquisition.tla spec-action runtime guards (Cycle 44) ---

   Identity helpers carrying [@@fsm_guard] payloads that mirror the
   honest actions of [specs/keeper-state-machine/KeeperTaskAcquisition.tla].
   Each helper is wrapped at the call site by
   [Keeper_fsm_guard_runtime.wrap_unit] so an [Assert_failure] from a
   PPX-injected guard increments the Otel_metric_store violation counter and
   re-raises. Bug-action [TaskRejected] is NOT
   instrumented -- it is the failure mode these guards are designed to
   detect.

   This pattern follows PR #11696 (Cycle 43, KeeperHeartbeat closeout)
   which introduced [Keeper_fsm_guard_runtime]. *)

(* AssignTask: the channel decision picks "turn" when at least one of
   [pending_mentions], [pending_board_events], or
   [pending_scope_messages] is non-empty. The post-action guard pins
   the structural invariant that drove the decision. *)
let post_assign_task ~(any_pending : bool) ~(channel : string) =
  ignore any_pending;
  ignore channel
[@@fsm_guard "any_pending = true && channel = \"turn\""]
;;

(* EmptyQueueSleep: complementary branch -- every pending list is empty
   and the cycle exits without claiming. *)
let post_empty_queue_sleep ~(any_pending : bool) ~(channel : string) =
  ignore any_pending;
  ignore channel
[@@fsm_guard "any_pending = false && channel = \"scheduled_autonomous\""]
;;

(* TurnComplete (KeeperTaskAcquisition.tla, Cycle 45 follow-up to
   PR #11716): the [run_keeper_cycle] body has produced an [Ok meta]
   for this cycle. The post-action invariant pins that
   [cycle_completed] is true before the result is returned -- catches
   a regression where a future refactor splits the bottom of
   [run_keeper_cycle] into branches that forget to record completion.
   The immutable [turn_state] is single-fiber by construction: each
   [run_keeper_cycle] invocation runs in its own fiber, and the state
   is allocated fresh inside the function. *)
let post_turn_complete_task ~(cycle_completed : bool) = ignore cycle_completed
[@@fsm_guard "cycle_completed = true"]
;;

let pre_dispatch_tool_surface : Keeper_execution_receipt.tool_surface =
  { turn_lane = Keeper_agent_tool_surface.Lane_pre_dispatch }
;;

let record_pre_dispatch_terminal_observation
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(generation : int)
      ~(runtime_id : string)
      ~(outcome : Keeper_execution_receipt.outcome_kind)
      ~(terminal_reason_code : string)
      ~(activity_kind : string)
      ~(trajectory_outcome : Trajectory.trajectory_outcome)
      ?error_kind
      ?error_message
      ?(degraded_retry_applied = false)
      ?degraded_retry_runtime
      ?fallback_reason
      ?(runtime_rotation_attempts = [])
      ?keeper_turn_id
      ()
  : unit
  =
  let runtime_id_string =
    runtime_id
  in
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let started_at = now_iso () in
  let masc_root = Workspace.masc_root_dir config in
  let trajectory_acc =
    Trajectory.create_accumulator ~masc_root ~keeper_name:meta.name ~trace_id ~generation ()
  in
  finalize_trajectory_acc ~config ~keeper_name:meta.name trajectory_acc trajectory_outcome;
  let ended_at = now_iso () in
  let receipt : Keeper_execution_receipt.t =
    { keeper_name = meta.name
    ; agent_name = meta.agent_name
    ; trace_id
    ; generation
    ; turn_count =
        (match keeper_turn_id with
         | Some _ -> keeper_turn_id
         | None -> Some meta.runtime.usage.total_turns)
    ; oas_turn_count = None
    ; oas_dispatch_mode = None
    ; oas_internal_runtime_disabled = true
    ; post_turn_memory_job_id = None
    ; current_task_id = Option.map Keeper_id.Task_id.to_string meta.current_task_id
    ; goal_ids = meta.active_goal_ids
    ; outcome
    ; terminal_reason_code
    ; response_text_present = false
    ; model_used = None
    ; completion_contract_result = Keeper_execution_receipt.Contract_not_dispatched
    ; actionable_signal = None
      (* Pre-dispatch receipt: the turn never ran, so no world observation was
         captured. [Contract_not_dispatched] never reaches the
         [passive_only_without_work_scope] carve-out, so [None] is inert here. *)
    ; tool_surface = pre_dispatch_tool_surface
    ; sandbox_kind = Keeper_execution_receipt.sandbox_kind_of_meta meta
    ; sandbox_root = Some (Keeper_sandbox.host_root_abs_of_meta ~config meta)
    ; network_mode = meta.network_mode
    ; runtime_id
    ; runtime_selected_model = None
    ; runtime_attempt_count = 0
    ; runtime_fallback_applied = false
    ; runtime_outcome = Keeper_execution_receipt.Runtime_not_dispatched
    ; degraded_retry_applied
    ; degraded_retry_runtime
    ; fallback_reason
    ; runtime_rotation_attempts
    ; stop_reason = None
    ; error_kind
    ; error_message
    ; started_at
    ; ended_at
    ; extra_system_context_digest = None
    ; extra_system_context_injected_size = None
    ; extra_system_context_computed_size = None
    ; pre_dispatch_compacted = false
    ; pre_dispatch_compaction_trigger = None
    ; pre_dispatch_compaction_before_tokens = None
    ; pre_dispatch_compaction_after_tokens = None
    ; oas_internal_runtime_allowed = false
    }
  in
  let receipt_path =
    Keeper_runtime_manifest.execution_receipt_path_for_today config
      ~keeper_name:meta.name
  in
  let append_manifest ?status ?decision ~site event =
    let status =
      match status with
      | Some status -> status
      | None -> Keeper_execution_receipt.outcome_kind_to_string outcome
    in
    Keeper_runtime_manifest.make ~ts:ended_at ~keeper_name:meta.name
      ~agent_name:meta.agent_name ~trace_id ~generation ?keeper_turn_id ~event
      ~runtime_id:runtime_id_string ~status ?decision ~receipt_path ()
    |> Keeper_runtime_manifest.append_best_effort ~site config
  in
  append_manifest
    ~site:"pre_dispatch_blocked"
    ~decision:
      (`Assoc
        [
          ("activity_kind", `String activity_kind);
          ( "outcome",
            `String (Keeper_execution_receipt.outcome_kind_to_string outcome)
          );
          ("terminal_reason_code", `String terminal_reason_code);
          ("runtime_id", `String runtime_id_string);
          ( "error_message",
            match error_message with
            | None -> `Null
            | Some message -> `String message );
        ])
    Keeper_runtime_manifest.Pre_dispatch_blocked;
  let receipt_append_ok =
    try
      Keeper_execution_receipt.append config receipt;
      true
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      let error = Printexc.to_string exn in
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string WriteMetaFailures)
        ~labels:[ "keeper", meta.name; "phase", "receipt_append" ]
        ();
      Log.Keeper.warn ~keeper_name:meta.name
        "pre-dispatch execution_receipt append failed: %s"
        error;
      record_execution_receipt_gap
        ~config
        ~meta
        ~stale_reason:"pre_dispatch_execution_receipt_append_failed"
        ~error
        ();
      false
  in
  if receipt_append_ok then
    Keeper_status_detail.invalidate_status_cache_for meta.name;
  if receipt_append_ok then
    append_manifest
      ~site:"pre_dispatch_receipt_appended"
      Keeper_runtime_manifest.Receipt_appended;
  append_manifest
    ~site:"pre_dispatch_turn_finished"
    ~decision:
      (`Assoc
        [
          ( "outcome",
            `String (Keeper_execution_receipt.outcome_kind_to_string outcome)
          );
          ("terminal_reason_code", `String terminal_reason_code);
          ("receipt_append_ok", `Bool receipt_append_ok);
        ])
    Keeper_runtime_manifest.Turn_finished;
  try
    let event =
      Activity_graph.emit
        config
        ~actor:{ kind = "agent"; id = meta.agent_name }
        ~kind:activity_kind
        ~payload:
          (`Assoc
              [ "keeper_name", `String meta.name
              ; "trace_id", `String trace_id
              ; ( "outcome"
                , `String (Keeper_execution_receipt.outcome_kind_to_string outcome)
                )
              ; "terminal_reason_code", `String terminal_reason_code
              ; "runtime_id", `String runtime_id_string
              ])
        ()
    in
    Log.Keeper.debug
      "%s: activity graph %s emitted seq=%d"
      meta.name
      activity_kind
      event.seq
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    report_keeper_cycle_side_effect_issue
      ~config
      ~keeper_name:meta.name
      ~side_effect:(activity_kind ^ " emit")
      (Printexc.to_string exn)
;;

let local_discovery_refresh_for_test : (string list -> bool) option Atomic.t =
  Atomic.make None
;;

(* Local discovery disabled: tier-based local/non-local classification
   no longer exists. All providers are treated uniformly. *)
let ensure_local_discovery_ready ?refresh:_ (_labels : string list) : (unit, string) result =
  Ok ()
;;

module For_testing = struct
  let with_local_discovery_refresh refresh f =
    let previous = Atomic.get local_discovery_refresh_for_test in
    Atomic.set local_discovery_refresh_for_test (Some refresh);
    Eio_guard.protect
      ~finally:(fun () -> Atomic.set local_discovery_refresh_for_test previous)
      f
  ;;
end
