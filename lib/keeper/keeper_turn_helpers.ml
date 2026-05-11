(* Keeper_turn_helpers — string matching, event reporting, trajectory/receipt
   helpers, FSM guard post-actions, and local discovery readiness.

   Extracted from keeper_unified_turn.ml (L21-326) during the god-file split. *)

open Keeper_types
open Keeper_exec_context

(* Interval (seconds) for the per-turn background fiber that drains the
   `keeper_turn` subscription on the OAS event bus.  See
   [start_background_turn_event_bus_drain] for context.

   Step 14(b) of the bloodflow restoration plan inlined the env knob
   [MASC_KEEPER_TURN_DRAIN_INTERVAL_SEC]: hyperparameters belong in
   code, not in [Sys.getenv_opt].  Calibrated values move via PR with
   measurement evidence, not as silent operator overrides. *)
let default_turn_event_bus_drain_interval_sec = 0.05
let turn_event_bus_drain_interval_sec () = default_turn_event_bus_drain_interval_sec

let substring_matches_at ~(needle : string) (haystack : string) start_idx =
  let needle_len = String.length needle in
  let rec loop offset =
    if offset = needle_len
    then true
    else if haystack.[start_idx + offset] <> needle.[offset]
    then false
    else loop (offset + 1)
  in
  loop 0
;;

let string_contains_substring ~(needle : string) (haystack : string) : bool =
  let needle_len = String.length needle in
  let hay_len = String.length haystack in
  if needle_len = 0
  then true
  else if needle_len > hay_len
  then false
  else (
    let rec loop i =
      if i + needle_len > hay_len
      then false
      else if substring_matches_at ~needle haystack i
      then true
      else loop (i + 1)
    in
    loop 0)
;;

let string_contains_substring_ci ~(needle : string) (haystack : string) : bool =
  string_contains_substring
    ~needle:(String.lowercase_ascii needle)
    (String.lowercase_ascii haystack)
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
      ~(config : Coord.config)
      ~(keeper_name : string)
      ~(side_effect : string)
      ?(severity = `Warn)
      (detail : string)
  : unit
  =
  let message = Printf.sprintf "keeper cycle %s failed: %s" side_effect detail in
  Keeper_registry.record_error ~base_path:config.base_path keeper_name message;
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_dispatch_event_failures
    ~labels:[ "keeper", keeper_name; "site", side_effect_metric_label side_effect ]
    ();
  match severity with
  | `Warn -> Log.Keeper.warn "%s: %s" keeper_name message
  | `Error -> Log.Keeper.error "%s: %s" keeper_name message
;;

let dispatch_keeper_phase_event_checked
      ~(config : Coord.config)
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
      ~(config : Coord.config)
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
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(stale_reason : string)
      ~(error : string)
      ()
  : unit
  =
  try
    let masc_root = Coord.masc_root_dir config in
    Telemetry_coverage_gap.record
      ~masc_root
      ~source:"execution_receipt"
      ~producer:"keeper_unified_turn.pre_dispatch"
      ~durable_store:
        (Filename.concat
           (Filename.concat (Filename.concat masc_root "keepers") meta.name)
           "execution-receipts")
      ~dashboard_surface:"/api/v1/dashboard/execution-trust"
      ~stale_reason
      ~keeper_name:meta.name
      ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      ~error
      ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_write_meta_failures
      ~labels:[ "keeper", meta.name; "phase", "receipt_coverage_gap" ]
      ();
    Log.Keeper.warn
      "keeper:%s pre-dispatch execution_receipt coverage gap append failed: %s"
      meta.name
      (Printexc.to_string exn)
;;

(* -- KeeperTaskAcquisition.tla spec-action runtime guards (Cycle 44) ---

   Identity helpers carrying [@@fsm_guard] payloads that mirror the
   honest actions of [specs/keeper-state-machine/KeeperTaskAcquisition.tla].
   Each helper is wrapped at the call site by
   [Keeper_fsm_guard_runtime.wrap_unit] so an [Assert_failure] from a
   PPX-injected guard increments the Prometheus violation counter and
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
   for this cycle. The post-action invariant pins that the
   [cycle_completed] ref was actually toggled before the result is
   returned -- catches a regression where a future refactor splits
   the bottom of [run_keeper_cycle] into branches that forget to
   record completion. The ref is single-fiber by construction: each
   [run_keeper_cycle] invocation runs in its own fiber, and the ref
   is allocated fresh inside the function. *)
let post_turn_complete_task ~(cycle_completed : bool ref) = ignore cycle_completed
[@@fsm_guard "!cycle_completed = true"]
;;

let pre_dispatch_tool_surface : Keeper_execution_receipt.tool_surface =
  { turn_lane = "pre_dispatch"
  ; tool_surface_class = "none"
  ; tool_requirement = No_tools
  ; visible_tool_count = 0
  ; tool_gate_enabled = false
  ; tool_surface_fallback_used = false
  ; required_tools = []
  ; missing_required_tools = []
  }
;;

let record_pre_dispatch_terminal_observation
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(generation : int)
      ~(cascade_name : Keeper_execution_receipt.cascade_name)
      ~(outcome : string)
      ~(terminal_reason_code : string)
      ~(activity_kind : string)
      ~(trajectory_outcome : Trajectory.trajectory_outcome)
      ?error_kind
      ?error_message
      ?keeper_turn_id
      ()
  : unit
  =
  let cascade_name_string =
    Keeper_execution_receipt.cascade_name_to_string cascade_name
  in
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let started_at = now_iso () in
  let masc_root = Coord.masc_root_dir config in
  let trajectory_acc =
    Trajectory.create_accumulator ~masc_root ~keeper_name:meta.name ~trace_id ~generation
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
    ; current_task_id = Option.map Keeper_id.Task_id.to_string meta.current_task_id
    ; goal_ids = meta.active_goal_ids
    ; outcome
    ; terminal_reason_code
    ; response_text_present = false
    ; model_used = None
    ; requested_tools = []
    ; reported_tools = []
    ; observed_tools = []
    ; canonical_tools = []
    ; unexpected_tools = []
    ; tools_used = []
    ; tool_contract_result = "not_dispatched"
    ; tool_surface = pre_dispatch_tool_surface
    ; sandbox_kind = Keeper_execution_receipt.sandbox_kind_of_meta meta
    ; sandbox_root = Some (Keeper_sandbox.host_root_abs_of_meta ~config meta)
    ; network_mode = Keeper_types.network_mode_to_string meta.network_mode
    ; approval_profile = None
    ; approval_profile_derived = false
    ; cascade_name
    ; cascade_selected_model = None
    ; cascade_attempt_count = 0
    ; cascade_fallback_applied = false
    ; cascade_outcome = "not_dispatched"
    ; degraded_retry_applied = false
    ; degraded_retry_cascade = None
    ; fallback_reason = None
    ; cascade_rotation_attempts = []
    ; stop_reason = None
    ; error_kind
    ; error_message
    ; started_at
    ; ended_at
    }
  in
  (try Keeper_execution_receipt.append config receipt with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     let error = Printexc.to_string exn in
     Prometheus.inc_counter
       Keeper_metrics.metric_keeper_write_meta_failures
       ~labels:[ "keeper", meta.name; "phase", "receipt_append" ]
       ();
     Log.Keeper.warn
       "keeper:%s pre-dispatch execution_receipt append failed: %s"
       meta.name
       error;
     record_execution_receipt_gap
       ~config
       ~meta
       ~stale_reason:"pre_dispatch_execution_receipt_append_failed"
       ~error
       ());
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
              ; "outcome", `String outcome
              ; "terminal_reason_code", `String terminal_reason_code
              ; "cascade_name", `String cascade_name_string
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

let ensure_local_discovery_ready ?refresh (labels : string list) : (unit, string) result =
  let refresh_for_test = Atomic.get local_discovery_refresh_for_test in
  let refresh =
    match refresh with
    | Some f -> f
    | None ->
      (match refresh_for_test with
       | Some f -> f
       | None -> fun labels -> Cascade_runtime.refresh_local_discovery_if_possible labels)
  in
  let should_refresh =
    match refresh_for_test with
    | Some _ -> true
    | None -> Cascade_runtime.labels_require_local_discovery labels
  in
  if not should_refresh
  then Ok ()
  else (
    try
      if refresh labels
      then Ok ()
      else
        Error
          (Printf.sprintf
             "local discovery refresh required for labels [%s] but refresh failed"
             (String.concat ", " labels))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Error
        (Printf.sprintf
           "local discovery refresh raised for labels [%s]: %s"
           (String.concat ", " labels)
           (Printexc.to_string exn)))
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
