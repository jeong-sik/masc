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

  val direct_empty_no_progress_retry_reason :
    Agent_sdk.Error.sdk_error -> Keeper_error_classify.degraded_retry_reason option
  (** Return [Some Empty_no_progress] only for direct-message accept rejections
      that are safe to rotate before surfacing an error. *)
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
  _ Keeper_types_profile.context -> Yojson.Safe.t -> tool_result
(** [event_bus] is captured at the handler boundary and reused by the admitted
    turn body. Callers that omit it keep the legacy process/domain fallback, but
    async wrappers should pass an explicit value captured before submitting the
    background turn. *)

(** Stop a running keeper agent. *)
val handle_keeper_down : _ Keeper_types_profile.context -> Yojson.Safe.t -> tool_result
