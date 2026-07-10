(** Channel_gate_slack_state — Slack in-process connector state (RFC-0317).

    Implements {!Channel_gate_connector.S} so it can be registered at server
    startup via [Channel_gate_connector.register (module Channel_gate_slack_state)].
    The in-process Slack gateway ({!Slack_socket_client}, RFC-0317 PR-1) is the
    only transport; the Python sidecar is removed in PR-4. Internal helpers are
    hidden — only the {!Channel_gate_connector.S} surface plus the in-process
    gateway support is public. *)

include Channel_gate_connector.S

(** {1 In-process gateway support} *)

val keeper_for_channel : channel_id:string -> string option
(** Look up the keeper bound to a Slack channel id. [None] when no binding
    exists, the channel id is blank, or the binding store is unreadable after
    logging the read failure. *)

type keeper_binding_resolution = {
  keeper_name : string;
  incoming_channel_id : string;
  bound_channel_id : string;
  via_parent : bool;
}

val resolve_keeper_for_channel :
  channel_id:string -> keeper_binding_resolution option
(** Resolve the keeper for [channel_id]. Slack threads share the parent
    channel id, so this is a single exact lookup — no thread→parent fallback. *)

val resolve_keeper_for_channel_result :
  channel_id:string -> (keeper_binding_resolution option, string) result
(** Typed variant of {!resolve_keeper_for_channel}. Store read failures return
    [Error] instead of being collapsed into an unbound channel. *)

val record_ready : bot_user_id:string -> unit
(** Called by the in-process gateway's hello handler. Stores the bot identity
    that {!status_json} reports as [bot_user_id] / [last_ready_at]. *)

val record_startup_error : string -> unit
val clear_startup_error : unit -> unit
(** Record/clear a fail-closed gateway bootstrap error. [status_json] exposes a
    recorded error as [status = "unhealthy"] instead of presenting an invalid
    configuration as an ordinary disconnected connector. *)

val set_trigger_policy : Slack_gateway_state.trigger_policy -> unit
val get_trigger_policy : unit -> Slack_gateway_state.trigger_policy option

(** Typed failure modes for Slack REST actions. Closed sum. *)
type send_error =
  | Missing_token
  | Rest_error of Slack_rest_client.error

val pp_send_error : Format.formatter -> send_error -> unit

val send_message :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  channel_id:string ->
  content:string ->
  ?reply_to_message_id:string ->
  unit ->
  (string, send_error) result
(** Post a single message to a Slack channel via [chat.postMessage]. Returns
    the created message [ts]. [reply_to_message_id] (a Slack [ts]) posts a
    threaded reply. Bot token resolved from [SLACK_BOT_TOKEN] at call time so a
    rotation does not require a server restart. [~clock] bounds the request by
    [timeout_sec] (default {!Slack_rest_client.default_http_timeout_sec}). *)

val edit_message :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  channel_id:string ->
  message_id:string ->
  content:string ->
  unit ->
  (unit, send_error) result
(** Patch a prior message via [chat.update]. Used by the in-process gateway to
    project keeper streaming snapshots into one edited reply. [~clock] bounds
    the request by [timeout_sec]. *)
