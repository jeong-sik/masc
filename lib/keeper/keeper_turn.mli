(** Keeper_turn — keeper lifecycle and message-turn handlers.

    Provides MCP tool handlers for keeper agent management:
    start/stop and message dispatch.
    Internal helpers (team session dispatch, planner/executor spawn,
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
val preflight_keeper_msg :
  _ Keeper_types_profile.context -> Yojson.Safe.t -> (unit, string) result
(** Run synchronous validation for [handle_keeper_msg] before an async wrapper
    accepts the turn for later execution. *)

val keeper_msg_timeout_override : Yojson.Safe.t -> (float option, string) result
(** Parse the optional [timeout_sec] override used by [masc_keeper_msg]. The
    value bounds the OAS turn and, for async dispatch, the request result
    lifecycle exposed via [masc_keeper_msg_result]. *)

module For_testing : sig
  val direct_owner_conversation_context :
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    direct_reply:bool ->
    channel_session_key:string option ->
    channel:string ->
    string

  val surface_context_to_instructions : Yojson.Safe.t -> string option
  (** Format a dashboard co-view context object ({ label, route, scene, fields })
      into turn instructions when no explicit [turn_instructions] is supplied. *)

  val direct_success_may_clear_no_progress_pause :
    Keeper_agent_run.run_result -> bool
  (** Typed recovery predicate for direct-message success: only a healthy
      operator disposition plus non-passive typed progress or validated run
      evidence may clear a no-progress forced pause. Text-only visible replies
      are not sufficient. *)

  val clear_direct_success_no_progress_pause :
    config:Workspace.config ->
    pre_turn_meta:Keeper_meta_contract.keeper_meta ->
    result:Keeper_agent_run.run_result ->
    Keeper_meta_contract.keeper_meta ->
    Keeper_meta_contract.keeper_meta
  (** Apply the direct-message success recovery that clears a no-progress
      forced pause without running a live LLM turn. *)

  val direct_no_progress_retry_reason :
    Agent_sdk.Error.sdk_error -> Keeper_error_classify.degraded_retry_reason option
  (** Return a direct-message no-progress retry reason for accept rejections
      that are safe to rotate before surfacing an error. *)

  val direct_no_progress_retry_decision :
    base_runtime:string ->
    effective_runtime:string ->
    attempted_runtimes:string list ->
    estimated_input_tokens:int ->
    ?time_spent_in_turn_s:float ->
    remaining_turn_budget_s:float ->
    Agent_sdk.Error.sdk_error ->
    Keeper_turn_runtime_budget.degraded_retry_budget_decision
  (** Shared-budget retry decision for direct-message no-progress accept
      rejections. Read-only no-progress remains terminal here because it
      already consumed tool execution in the current attempt. *)

  val run_direct_no_progress_retry_loop :
    keeper_name:string ->
    base_runtime:string ->
    initial_runtime:string ->
    initial_max_context:int ->
    estimated_input_tokens:int ->
    timeout_sec:float ->
    remaining_turn_budget_s:(unit -> float) ->
    current_turn_phase_elapsed_ms:(float option -> int * int option) ->
    now_s:(unit -> float) ->
    setup_retry_runtime:
      (string ->
       (Keeper_turn_runtime_budget.runtime_execution, Agent_sdk.Error.sdk_error) result) ->
    publish_cascade_resolution:
      (runtime_id:string ->
       decision:Keeper_unified_turn_cascade_resolution.cascade_decision_kind ->
       reason:string ->
       next_runtime:string option ->
       attempt:int ->
       Agent_sdk.Error.sdk_error ->
       unit) ->
    emit_runtime_selected:
      (runtime_id:string -> fallback_reason:string -> unit) ->
    emit_runtime_rotation:
      (from_runtime:string -> to_runtime:string -> reason:string -> unit) ->
    record_retry_setup_failure:
      (from_runtime:string ->
       retry:Keeper_error_classify.degraded_retry ->
       rotation_attempt:Keeper_execution_receipt.runtime_rotation_attempt ->
       fail_open_err:Agent_sdk.Error.sdk_error ->
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
       ('a, Agent_sdk.Error.sdk_error) result) ->
    unit ->
    ('a * int, Agent_sdk.Error.sdk_error) result
  (** Execute the direct-message no-progress retry loop with injected side
      effects. Exposed only to verify that fallback selection reaches the next
      keeper run attempt. *)
end

(** Format a dashboard co-view context object ({ label, route, scene, fields })
    into turn instructions. Accepts [fields] as both a [`List] of {k,v} objects
    (dashboard wire shape) and a plain [`Assoc] map. This is the single SSOT
    formatter shared by the HTTP copilot route
    ([Server_routes_http_keeper_stream]) and the masc_keeper_msg MCP tool path,
    so the two surfaces cannot drift. Returns [None] when there is nothing to
    render. *)
val surface_context_to_instructions : Yojson.Safe.t -> string option

val handle_keeper_msg :
  ?on_text_delta:(string -> unit) ->
  ?on_event:(Agent_sdk.Types.sse_event -> unit) ->
  ?event_bus:Agent_sdk.Event_bus.t ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?on_admission_rejected:(Keeper_turn_admission.rejection -> unit) ->
  ?on_admitted:(unit -> (unit, string) result) ->
  _ Keeper_types_profile.context -> Yojson.Safe.t -> tool_result
(** [event_bus] is captured at the handler boundary and reused by the admitted
    turn body. Callers that omit it keep the legacy process/domain fallback, but
    async wrappers should pass an explicit value captured before submitting the
    background turn. [on_admission_rejected] receives the typed admission
    result before the legacy tool error is rendered; queue consumers use it to
    keep a leased receipt pending without matching diagnostic strings. *)

val handle_keeper_msg_if_free :
  ?on_text_delta:(string -> unit) ->
  ?on_event:(Agent_sdk.Types.sse_event -> unit) ->
  ?event_bus:Agent_sdk.Event_bus.t ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?before_run:(unit -> (unit, string) result) ->
  _ Keeper_types_profile.context ->
  Yojson.Safe.t ->
  [ `Ran of tool_result | `Busy of Keeper_turn_admission.rejection ]
(** Non-blocking chat entrypoint for direct dashboard streaming. It runs the
    same admitted turn body as [handle_keeper_msg] only when the keeper slot is
    immediately available; otherwise it returns [`Busy] without parking behind
    an in-flight turn. *)

(** Stop a running keeper agent. *)
val handle_keeper_down : _ Keeper_types_profile.context -> Yojson.Safe.t -> tool_result
