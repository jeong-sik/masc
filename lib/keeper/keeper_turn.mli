(** Keeper_turn — keeper lifecycle and message-turn handlers.

    Provides MCP tool handlers for keeper agent management:
    start/stop and message dispatch.
    Internal helpers (planner/executor spawn,
    JSON serialization) are hidden.
*)

(** Tool handler return type: (success, message). *)
type tool_result = Keeper_types_profile.tool_result

(** Start or reconfigure a keeper agent. *)
val handle_keeper_up : _ Keeper_types_profile.context -> Yojson.Safe.t -> tool_result

(** Send a message to a running keeper agent.

    When [on_text_delta] is provided, the initial MODEL call uses streaming
    and forwards text deltas through the callback in real time. Follow-up
    calls (tool loops, corrections, prompt fallback) run in batch mode.
    If streaming fails, the function falls back to batch automatically.

    @since 2.110.0 *)
val preflight_keeper_msg_resolved :
  base_path:string ->
  meta:Keeper_meta_contract.keeper_meta ->
  Keeper_invocation_contract.direct_message ->
  (Keeper_invocation_contract.direct_message, string) result
(** Run synchronous validation for [handle_keeper_msg] before an async wrapper
    accepts the turn for later execution. Requires a current registry entry and
    takes the effective meta the resolution step already read, so no second
    store read happens here. A missing entry may mean autoboot has not registered
    the Keeper yet or that it is stopped; callers receive a retry-or-start
    message rather than a permanent-state claim. *)

val preflight_keeper_delegate :
  _ Keeper_types_profile.context ->
  Keeper_invocation_contract.request ->
  (Keeper_invocation_contract.request, string) result
(** Validate one typed delegated invocation before durable submission. *)

module For_testing : sig
  val direct_owner_conversation_context :
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    direct_reply:bool ->
    channel_session_key:string option ->
    channel:string ->
    string

  val direct_turn_dynamic_context :
    current_task:Keeper_world_observation_inputs.current_task_observation ->
    held_task_skills:Keeper_world_observation_inputs.held_task_skills list ->
    task_skill_surfaces:(string * Keeper_skill_catalog.exact_surface list) list ->
    approval_authority_text:string ->
    recent_direct_conversation_text:string ->
    worktree_text:string ->
    telemetry_feedback_text:string ->
    turn_instructions_text:string ->
    string
  (** Production composition boundary for fresh direct-turn context. The
      result is prompt-only and must never enter durable conversation history. *)

  val surface_context_to_instructions : Yojson.Safe.t -> string option
  (** Format a dashboard co-view context object ({ label, route, scene, fields })
      into turn instructions when no explicit [turn_instructions] is supplied. *)

  val direct_no_progress_retry_reason :
    Agent_core.Error.t -> Keeper_error_classify.degraded_retry_reason option
  (** Return a direct-message no-progress retry reason for accept rejections
      that are safe to rotate before surfacing an error. *)

  val direct_no_progress_retry_decision :
    base_runtime:string ->
    effective_runtime:string ->
    attempted_runtimes:string list ->
    Agent_core.Error.t ->
    Keeper_turn_runtime_budget.degraded_retry_decision
  (** Retry decision for direct-message no-progress accept rejections.
      Read-only no-progress remains terminal here because it already consumed
      tool execution in the current attempt. *)

  val run_direct_no_progress_retry_loop :
    keeper_name:string ->
    base_runtime:string ->
    initial_execution:Keeper_turn_runtime_budget.runtime_execution ->
    current_turn_phase_elapsed_ms:(float option -> int * int option) ->
    now_s:(unit -> float) ->
    setup_retry_runtime:
      (string ->
       (Keeper_turn_runtime_budget.runtime_execution, Agent_core.Error.t) result) ->
    publish_cascade_resolution:
      (runtime_id:string ->
       decision:Keeper_unified_turn_cascade_resolution.cascade_decision_kind ->
       reason:string ->
       next_runtime:string option ->
       attempt:int ->
       Agent_core.Error.t ->
       unit) ->
    emit_runtime_selected:
      (runtime_id:string -> fallback_reason:string -> unit) ->
    emit_runtime_rotation:
      (from_runtime:string -> to_runtime:string -> reason:string -> unit) ->
    record_retry_setup_failure:
      (from_runtime:string ->
       retry:Keeper_error_classify.degraded_retry ->
       rotation_attempt:Keeper_execution_receipt.runtime_rotation_attempt ->
       fail_open_err:Agent_core.Error.t ->
       unit) ->
    before_retry:(unit -> unit) ->
    run_once:
      (runtime_id:string ->
       max_context:int ->
       is_retry:bool ->
       degraded_retry_runtime:string option ->
       fallback_reason:Keeper_error_classify.degraded_retry_reason option ->
       runtime_rotation_attempts:
         Keeper_execution_receipt.runtime_rotation_attempt list ->
       ('a, Agent_core.Error.t) result) ->
    unit ->
    ('a * int, Agent_core.Error.t) result
  (** Execute the direct-message no-progress retry loop with injected side
      effects. The initial attempt receives its typed runtime execution record,
      just like a retry. Exposed only to verify fallback selection without
      duplicating the provider call inside the test. *)
end

(** Format a dashboard co-view context object ({ label, route, scene, fields })
    into turn instructions. Accepts [fields] as both a [`List] of {k,v} objects
    (dashboard wire shape) and a plain [`Assoc] map. This is the single SSOT
    formatter shared by the HTTP copilot route
    ([Server_routes_http_keeper_stream]) and the masc_keeper_msg MCP tool path,
    so the two surfaces cannot drift. Returns [None] when there is nothing to
    render. *)
val surface_context_to_instructions : Yojson.Safe.t -> string option

val handle_keeper_msg_admitted :
  admission_token:Keeper_turn_dispatch_authority.token ->
  ?on_text_delta:(string -> unit) ->
  ?on_event:(Agent_core.Types.sse_event -> unit) ->
  ?on_tool_stream_observation:
    (Keeper_hooks_agent_core.tool_stream_observation -> unit) ->
  ?on_tool_result_ready:(tool_call_id:string -> turn:int -> planned_index:int -> execution_id:Ids.Execution_id.t -> unit) ->
  ?approval_gate:Keeper_tool_approval_gate.t ->
  ?event_bus:Agent_core.Event_bus.t ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  _ Keeper_types_profile.context ->
  Keeper_invocation_contract.direct_message ->
  tool_result
(** Execute a direct message under an already-held chat admission token. Only
    the Owner operation child uses this path, after atomically claiming the
    latest durable operation body. *)

(** Stop a running keeper agent. *)
val handle_keeper_down : _ Keeper_types_profile.context -> Yojson.Safe.t -> tool_result
