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
  meta:Keeper_meta_contract.keeper_meta ->
  Keeper_invocation_contract.direct_message ->
  (Keeper_invocation_contract.direct_message, string) result
(** Run synchronous validation for [handle_keeper_msg] before an async wrapper
    accepts the turn for later execution. Takes the effective meta the
    resolution step already read, so no second store read happens here. *)

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
  ?on_tool_result_ready:(tool_call_id:string -> unit) ->
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
