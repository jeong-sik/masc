(** Keeper_unified_turn_types — pure helpers extracted from
    Keeper_unified_turn (3020 LoC godfile).

    See keeper_unified_turn_types.mli for rationale and contract.
    Re-included from Keeper_unified_turn so existing callers continue to
    use [Keeper_unified_turn.<name>] unchanged. *)

let turn_event_bus_manifest_decision
      (summary : Keeper_turn_runtime_budget.turn_event_bus_summary)
  =
  let overflow =
    match summary.overflow_imminent with
    | None -> `Null
    | Some overflow ->
      `Assoc
        [
          ("estimated_tokens", `Int overflow.estimated_tokens);
          ("limit_tokens", `Int overflow.limit_tokens);
        ]
  in
  let last_compaction =
    match summary.last_compaction with
    | None -> `Null
    | Some compaction ->
      `Assoc
        [
          ("before_tokens", `Int compaction.before_tokens);
          ("after_tokens", `Int compaction.after_tokens);
          ("tokens_freed", `Int compaction.tokens_freed);
          ("phase_hint", `String compaction.phase_hint);
        ]
  in
  `Assoc
    [
      ("correlation_id", Json_util.string_opt_to_json summary.correlation_id);
      ("run_id", Json_util.string_opt_to_json summary.run_id);
      ("caused_by", Json_util.string_opt_to_json summary.caused_by);
      ("event_count", `Int summary.event_count);
      ("payload_kinds", Json_util.json_string_list summary.payload_kinds);
      ("overflow_imminent", overflow);
      ( "context_compact_started_count",
        `Int summary.context_compact_started_count );
      ("context_compacted_count", `Int summary.context_compacted_count);
      ("last_compaction", last_compaction);
    ]
;;

(* Pure constructor for the SDK retry-timeout error wire shape. *)
let sdk_error_of_retry_slot_reacquire_timeout
      ~(keeper_name : string)
      (timeout : Keeper_turn_slot.semaphore_wait_timeout)
  =
  let phase = Keeper_turn_slot.semaphore_wait_phase_to_string timeout.timeout_phase in
  let holder_summary = Keeper_turn_slot.format_slot_holders timeout.timeout_holders in
  Agent_sdk.Error.Api
    (Agent_sdk.Retry.Timeout
       { message =
           Printf.sprintf
             "keeper turn slot reacquire timed out after degraded retry (keeper=%s \
              phase=%s wait=%.0fs holders=%s)"
             keeper_name
             phase
             timeout.timeout_wait_sec
             holder_summary
       })
;;

let runtime_exhaustion_detail_code detail =
  let contains needle = String_util.contains_substring_ci detail needle in
  if contains "no_first_token"
  then "runtime_exhausted_no_first_token"
  else if contains "inter_chunk_idle"
  then "runtime_exhausted_inter_chunk_idle"
  else if contains "http 429" || contains "usage limit" || contains "rate limit"
  then "runtime_exhausted_rate_limited"
  else if contains "max_execution_time"
  then "runtime_exhausted_max_execution_time"
  else if contains "wall-clock timeout"
  then "runtime_exhausted_wall_clock_timeout"
  else if contains "connection closed by peer"
  then "runtime_exhausted_connection_closed"
  else if contains "connection refused"
  then "runtime_exhausted_connection_refused"
  else "runtime_exhausted_provider_failure"
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
  | Keeper_internal_error.Max_turns_exceeded -> "runtime_exhausted_max_turns"
  | Keeper_internal_error.Structural_attempt_timeout _ ->
    "runtime_exhausted_structural_attempt_timeout"
  | Keeper_internal_error.Capacity_exhausted -> "runtime_exhausted_capacity_exhausted"
  | Keeper_internal_error.Other_detail detail -> runtime_exhaustion_detail_code detail
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
  | Keeper_internal_error.Max_turns_exceeded ->
    Keeper_meta_contract.Max_turns_exceeded
  | Keeper_internal_error.Structural_attempt_timeout { detail } ->
    Keeper_meta_contract.Structural_attempt_timeout { detail }
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
      | Keeper_internal_error.Admission_queue_timeout _
      | Keeper_internal_error.Admission_queue_rejected _
      | Keeper_internal_error.Turn_timeout _
      | Keeper_internal_error.Provider_timeout _
      | Keeper_internal_error.Max_tokens_ceiling_violation _
      | Keeper_internal_error.Ambiguous_post_commit _
      (* RFC-0158: pre-dispatch admission denial is not a runtime-exhaustion
         reason; the keeper decided not to attempt a provider call. *)
      | Keeper_internal_error.Retry_admission_denied _
      (* RFC-0159 Phase A: typed [Internal_*] variants are not
         runtime-exhaustion reasons; they map to opaque
         internal-error events upstream. *)
      | Keeper_internal_error.Internal_unhandled_exception _
      | Keeper_internal_error.Internal_bridge_exception _
      | Keeper_internal_error.Internal_contract_rejected _ )
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
  | Keeper_turn_disposition.Post_commit_ambiguous
  | Keeper_turn_disposition.Unknown _ -> None
;;

(** Tracker for matching ToolCalled/ToolCompleted event pairs within a
    single keeper turn. Internal mutability ([Hashtbl] + [Queue] + mutable
    fields); external API is pure-ish (push/pop are O(1) imperative). *)
type turn_tool_event_tracker =
  { pending_tool_inputs : (string, Yojson.Safe.t Queue.t) Hashtbl.t
  ; mutable mutating_tools_committed : string list
  ; mutable integrity_error : Agent_sdk.Error.sdk_error option
  }

let create_turn_tool_event_tracker () =
  { pending_tool_inputs = Hashtbl.create 8
  ; mutating_tools_committed = []
  ; integrity_error = None
  }
;;

let turn_tool_event_integrity_error tracker = tracker.integrity_error

let committed_mutating_tools_from_events tracker =
  Keeper_error_classify.committed_mutating_tools tracker.mutating_tools_committed
;;

let push_turn_tool_input tracker tool_name input =
  let q =
    match Hashtbl.find_opt tracker.pending_tool_inputs tool_name with
    | Some q -> q
    | None ->
      let q = Queue.create () in
      Hashtbl.add tracker.pending_tool_inputs tool_name q;
      q
  in
  Queue.add input q
;;

let pop_turn_tool_input tracker tool_name =
  match Hashtbl.find_opt tracker.pending_tool_inputs tool_name with
  | Some q when not (Queue.is_empty q) -> Some (Queue.pop q)
  | _ -> None
;;

let record_unmatched_tool_completed
      tracker
      ~keeper_name
      ~tool_name
      ~outcome
      ~tool_committed
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
  let mutating_tool_committed =
    tool_committed && Keeper_tool_dispatch_runtime.has_mutating_side_effect tool_name
  in
  if mutating_tool_committed
  then tracker.mutating_tools_committed <- tool_name :: tracker.mutating_tools_committed;
  match tracker.integrity_error with
  | Some _ -> ()
  | None ->
    let base_error = Agent_sdk.Error.Internal message in
    let error =
      if mutating_tool_committed
      then Keeper_error_classify.reclassify_error_after_side_effect ~tool_names:[ tool_name ] base_error
      else base_error
    in
    tracker.integrity_error <- Some error
;;

let record_turn_tool_events
      ?(has_mutating_side_effect_with_input =
        Keeper_tool_dispatch_runtime.has_mutating_side_effect_with_input)
      ~(keeper_name : string)
      (tracker : turn_tool_event_tracker)
      (events : Agent_sdk.Event_bus.event list)
  : unit
  =
  List.iter
    (fun (evt : Agent_sdk.Event_bus.event) ->
       match evt.payload with
       | Agent_sdk.Event_bus.ToolCalled { tool_name; input; _ } ->
         push_turn_tool_input tracker tool_name input
       | Agent_sdk.Event_bus.ToolCompleted { tool_name; output = Ok _; _ } ->
         (match pop_turn_tool_input tracker tool_name with
          | Some input ->
            if has_mutating_side_effect_with_input ~tool_name ~input
            then
              tracker.mutating_tools_committed
              <- tool_name :: tracker.mutating_tools_committed
          | None ->
            record_unmatched_tool_completed
              tracker
              ~keeper_name
              ~tool_name
              ~outcome:"ok"
              ~tool_committed:true)
       | Agent_sdk.Event_bus.ToolCompleted { tool_name; output = Error _; _ } ->
         (match pop_turn_tool_input tracker tool_name with
          | Some _ -> ()
          | None ->
            record_unmatched_tool_completed
              tracker
              ~keeper_name
              ~tool_name
              ~outcome:"error"
              ~tool_committed:false)
       | _ -> ())
    events
;;

(** Record the observation for a streaming turn that was cancelled
    externally (supervisor stop or external cancel). FSM emits +
    record_pre_dispatch_terminal_observation are *boundary* side
    effects intentionally retained from the godfile. *)
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
  if fiber_stop_set
  then
    (* FSM: SupervisorRequestsStop — stop signal confirmed while streaming;
       turn about to cancel cooperatively. *)
    Keeper_turn_fsm.emit_transition
      ~keeper_name:run_meta.name
      ~turn_id:keeper_turn_id
      ~prev:Keeper_turn_fsm.Streaming
      Keeper_turn_fsm.Streaming;
  let terminal_reason_code =
    if fiber_stop_set then "supervisor_stop" else "external_cancel"
  in
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
  (* FSM: HonorStopSignal — cooperative cancel. *)
  Keeper_turn_fsm.emit_transition
    ~keeper_name:run_meta.name
    ~turn_id:keeper_turn_id
    ~prev:Keeper_turn_fsm.Streaming
    (Keeper_turn_fsm.Cancelled Keeper_turn_fsm.Cancelled_supervisor_stop)
;;
