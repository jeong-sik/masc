(** Keeper_unified_turn_types — pure helpers extracted from
    Keeper_unified_turn (3020 LoC godfile).

    See keeper_unified_turn_types.mli for rationale and contract.
    Re-included from Keeper_unified_turn so existing callers continue to
    use [Keeper_unified_turn.<name>] unchanged. *)

module StringMap = Set_util.StringMap

(** Immutable per-turn accumulator that replaces the casual [ref] cells
    previously threaded through [run_keeper_cycle] and the retry loop. *)
type turn_state =
  { cycle_completed : bool
  ; manifest_seq : int
  ; current_turn_blocker_info : Keeper_meta_contract.blocker_info option
  ; last_execution : Keeper_turn_runtime_budget.runtime_execution option
  ; degraded_retry_info : Keeper_error_classify.degraded_retry option
  ; runtime_rotation_attempts : Keeper_execution_receipt.runtime_rotation_attempt list
  ; failure_reason : Keeper_turn_fsm.failure_reason option
  ; retry_phase_started_at : float option
  }

let require_last_execution_for_finalize ~keeper_name turn_state =
  match turn_state.last_execution with
  | Some exec -> Ok exec
  | None ->
    let err =
      Agent_sdk.Error.Internal
        (Printf.sprintf "%s: last_execution missing at turn finalize" keeper_name)
    in
    Log.Keeper.error "%s" (Agent_sdk.Error.to_string err);
    Error err
;;

let turn_event_bus_manifest_decision
      (summary : Keeper_turn_runtime_budget.turn_event_bus_summary)
  =
  `Assoc
    [
      ("correlation_id", Json_util.string_opt_to_json summary.correlation_id);
      ("run_id", Json_util.string_opt_to_json summary.run_id);
      ("caused_by", Json_util.string_opt_to_json summary.caused_by);
      ("event_count", `Int summary.event_count);
      ("payload_kinds", Json_util.json_string_list summary.payload_kinds);
    ]
;;

let runtime_exhaustion_reason_code
      (reason : Keeper_internal_error.runtime_exhaustion_reason)
  =
  match reason with
  | Keeper_internal_error.Connection_refused -> "runtime_exhausted_connection_refused"
  | Keeper_internal_error.Dns_failure -> "runtime_exhausted_dns_failure"
  | Keeper_internal_error.No_providers_available -> "runtime_exhausted_no_providers_available"
  | Keeper_internal_error.All_providers_failed -> "runtime_exhausted_all_providers_failed"
  | Keeper_internal_error.Candidates_filtered_after_cycles ->
    "runtime_exhausted_candidates_filtered"
  | Keeper_internal_error.Session_conflict -> "runtime_exhausted_session_conflict"
  | Keeper_internal_error.Capacity_exhausted -> "runtime_exhausted_capacity_exhausted"
  | Keeper_internal_error.Other_detail _ -> "runtime_exhausted_provider_failure"
;;

let registry_reason_of_internal_reason
    (reason : Keeper_internal_error.runtime_exhaustion_reason)
  : Keeper_meta_contract.runtime_exhaustion_reason
  =
  match reason with
  | Keeper_internal_error.Connection_refused -> Keeper_meta_contract.Connection_refused
  | Keeper_internal_error.Dns_failure -> Keeper_meta_contract.Dns_failure
  | Keeper_internal_error.No_providers_available ->
    Keeper_meta_contract.No_providers_available
  | Keeper_internal_error.All_providers_failed ->
    Keeper_meta_contract.All_providers_failed
  | Keeper_internal_error.Candidates_filtered_after_cycles ->
    Keeper_meta_contract.Candidates_filtered_after_cycles
  | Keeper_internal_error.Session_conflict ->
    Keeper_meta_contract.Session_conflict
  | Keeper_internal_error.Capacity_exhausted ->
    Keeper_meta_contract.Capacity_exhausted
  | Keeper_internal_error.Other_detail detail ->
    Keeper_meta_contract.Other_detail detail
;;

let runtime_exhausted_failure_reason_of_raw_error ~detail raw_error =
  match Keeper_internal_error.classify_masc_internal_error_of_string raw_error with
  | Some (Keeper_internal_error.Runtime_exhausted { reason; runtime_id }) ->
    Some
      (Keeper_registry.Provider_runtime_error
         { code = runtime_exhaustion_reason_code reason
         ; detail
         ; provider_id = None
         ; http_status = None
         ; runtime_id = Some (runtime_id)
         ; reason = Some (registry_reason_of_internal_reason reason)
         })
  | Some (Keeper_internal_error.Capacity_backpressure { detail = capacity_detail; _ }) ->
    Some
      (Keeper_registry.Provider_runtime_error
         { code = "capacity_backpressure"
         ; detail = capacity_detail
         ; provider_id = None
         ; http_status = None
         ; runtime_id = None
         ; reason = None
         })
  | Some
      ( Keeper_internal_error.Resumable_cli_session _
      | Keeper_internal_error.Accept_rejected _
      (* RFC-0159 Phase A: typed [Internal_*] variants are not
         runtime-exhaustion reasons; they map to opaque
         internal-error events upstream. *)
      | Keeper_internal_error.Internal_unhandled_exception _
      | Keeper_internal_error.Internal_bridge_exception _
      | Keeper_internal_error.Internal_contract_rejected _
      | Keeper_internal_error.Receipt_persistence_failed _ )
  | None -> None
;;

(* RFC-0047 follow-up: exhaustive match on [Keeper_turn_disposition.t].
   Pre-fix this used [String.starts_with ~prefix:"api_error_"] on the
   wire form of [terminal_reason.code]; that substring guard depended
   on SDK-error wires being routed through [Unknown { raw_error = _ }]
   because [normalize_code] no longer collapsed them to "provider_error".
   With [of_failure] now emitting [Provider_error (Sdk_error _)] typed
   for the SDK-error fallback, this routing reduces to a clean variant
   match — no substring classifier left in this function. *)
let registry_failure_reason_of_terminal_reason
      (terminal_reason : Keeper_turn_terminal.t)
      ~(raw_error : string)
  : Keeper_registry.failure_reason option
  =
  let detail = Keeper_types_profile.short_preview raw_error in
  match runtime_exhausted_failure_reason_of_raw_error ~detail raw_error with
  | Some _ as reason -> reason
  | None ->
  match terminal_reason.disposition with
  | Keeper_turn_disposition.Provider_error c ->
    Some
      (Keeper_registry.Provider_runtime_error
         { code = Keeper_turn_terminal_code.to_wire c
         ; detail
         ; provider_id = None
         ; http_status = None
         ; runtime_id = None
         ; reason = None
         })
  | Keeper_turn_disposition.Runtime_attempts_exhausted ->
    Some
      (Keeper_registry.Provider_runtime_error
         { code = "runtime_attempts_exhausted"
         ; detail
         ; provider_id = None
         ; http_status = None
         ; runtime_id = None
         ; reason = None
         })
  | Keeper_turn_disposition.Success
  | Keeper_turn_disposition.External_cancel
  | Keeper_turn_disposition.Input_required
  | Keeper_turn_disposition.Turn_wall_clock_timeout
  | Keeper_turn_disposition.Unknown _ -> None
;;

(** Tracker for matching ToolCalled/ToolCompleted event pairs within a
    single keeper turn. Pure immutable accumulator: a map from tool name to
    the FIFO list of pending inputs and the first integrity error observed
    while matching events. *)
type turn_tool_event_tracker =
  { pending_tool_inputs : Yojson.Safe.t list StringMap.t
  ; tool_completed_count : int
  ; integrity_error : Agent_sdk.Error.sdk_error option
  }

let create_turn_tool_event_tracker () =
  { pending_tool_inputs = StringMap.empty
  ; tool_completed_count = 0
  ; integrity_error = None
  }
;;

let turn_tool_event_integrity_error tracker = tracker.integrity_error
let turn_tool_completed_count tracker = tracker.tool_completed_count

let push_turn_tool_input tracker tool_name input =
  let inputs =
    match StringMap.find_opt tool_name tracker.pending_tool_inputs with
    | Some inputs -> inputs @ [ input ]
    | None -> [ input ]
  in
  { tracker with pending_tool_inputs = StringMap.add tool_name inputs tracker.pending_tool_inputs }
;;

let pop_turn_tool_input tracker tool_name =
  match StringMap.find_opt tool_name tracker.pending_tool_inputs with
  | Some (input :: rest) ->
    let pending =
      match rest with
      | [] -> StringMap.remove tool_name tracker.pending_tool_inputs
      | head :: tail ->
        StringMap.add tool_name (head :: tail) tracker.pending_tool_inputs
    in
    Some input, { tracker with pending_tool_inputs = pending }
  | Some [] -> None, tracker
  | None -> None, tracker
;;

let record_unmatched_tool_completed
      tracker
      ~keeper_name
      ~tool_name
      ~outcome
  =
  let message =
    Printf.sprintf
      "%s: keeper turn event-bus integrity error: ToolCompleted(%s) for tool=%s arrived \
       without matching ToolCalled"
      keeper_name
      outcome
      tool_name
  in
  Log.Keeper.error "%s" message;
  match tracker.integrity_error with
  | Some _ -> tracker
  | None ->
    { tracker with integrity_error = Some (Agent_sdk.Error.Internal message) }
;;

let record_turn_tool_events
      ~(keeper_name : string)
      (tracker : turn_tool_event_tracker)
      (events : Agent_sdk.Event_bus.event list)
  : turn_tool_event_tracker
  =
  List.fold_left
    (fun tracker (evt : Agent_sdk.Event_bus.event) ->
       match evt.payload with
       | Agent_sdk.Event_bus.ToolCalled { tool_name; input; _ } ->
         push_turn_tool_input tracker tool_name input
       | Agent_sdk.Event_bus.ToolCompleted { tool_name; output = Ok _; _ } ->
         let tracker =
           { tracker with tool_completed_count = tracker.tool_completed_count + 1 }
         in
         (match pop_turn_tool_input tracker tool_name with
          | Some _, tracker -> tracker
          | None, tracker ->
            record_unmatched_tool_completed
              tracker
              ~keeper_name
              ~tool_name
              ~outcome:"ok")
       | Agent_sdk.Event_bus.ToolCompleted { tool_name; output = Error _; _ } ->
         let tracker =
           { tracker with tool_completed_count = tracker.tool_completed_count + 1 }
         in
         (match pop_turn_tool_input tracker tool_name with
          | Some _, tracker -> tracker
          | None, tracker ->
            record_unmatched_tool_completed
              tracker
              ~keeper_name
              ~tool_name
              ~outcome:"error")
       | _ -> tracker)
    tracker
    events
;;

type streaming_cancellation_source =
  | Supervisor_stop
  | External_cancel

let streaming_cancellation_source_to_code = function
  | Supervisor_stop -> "supervisor_stop"
  | External_cancel -> "external_cancel"

let streaming_cancellation_source_to_fsm = function
  | Supervisor_stop -> Keeper_turn_fsm.Cancelled_supervisor_stop
  | External_cancel -> Keeper_turn_fsm.Cancelled_external

(** Record the observation for a streaming turn that was cancelled. *)
let record_streaming_cancelled_observation
      ~(config : Workspace.config)
      ~(run_meta : Keeper_meta_contract.keeper_meta)
      ~(run_generation : int)
      ~(runtime_id : string)
      ~(keeper_turn_id : int)
      ()
  : unit
  =
  let fiber_stop_set =
    match Keeper_registry.get ~base_path:config.base_path run_meta.name with
    | Some entry -> Atomic.get entry.fiber_stop
    | None -> false
  in
  let cancellation_source =
    if fiber_stop_set then Supervisor_stop else External_cancel
  in
  let terminal_reason_code =
    streaming_cancellation_source_to_code cancellation_source
  in
  if fiber_stop_set
  then
    (* FSM: SupervisorRequestsStop — stop signal confirmed while streaming;
       turn about to cancel cooperatively. *)
    Keeper_turn_fsm.emit_transition
      ~keeper_name:run_meta.name
      ~turn_id:keeper_turn_id
      ~prev:Keeper_turn_fsm.Streaming
      Keeper_turn_fsm.Streaming;
  Keeper_turn_helpers.record_pre_dispatch_terminal_observation
    ~config
    ~meta:run_meta
    ~generation:run_generation
    ~runtime_id
    ~outcome:`Cancelled
    ~terminal_reason_code
    ~activity_kind:"keeper.turn_cancelled"
    ~trajectory_outcome:(Trajectory.Gated terminal_reason_code)
    ~keeper_turn_id
    ();
  Keeper_turn_fsm.emit_transition
    ~keeper_name:run_meta.name
    ~turn_id:keeper_turn_id
    ~prev:Keeper_turn_fsm.Streaming
    (Keeper_turn_fsm.Cancelled
       (streaming_cancellation_source_to_fsm cancellation_source))
;;
