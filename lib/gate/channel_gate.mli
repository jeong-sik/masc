(** Channel_gate -- deterministic router for external chat platforms.

    Sits between external consumers (Discord, Telegram, etc.)
    and the keeper subsystem.  All logic is deterministic:
    same input always produces the same routing decision.
    No LLM calls, no heuristics, no fuzzy matching.

    Consumers talk to the gate via HTTP ([/api/v1/gate/*]).
    The gate dispatches to keepers through an injected [dispatch]
    function, keeping it decoupled from [Keeper_tool_surface] internals.

    Wire types live in {!Gate_protocol}.
    Keeper dispatch adapter lives in {!Gate_keeper_backend}.

    @since 2.217.0
    @modified 2.222.0 Decoupled from Client_identity and Keeper_tool_surface *)

(** {1 Re-exported Wire Types} *)

type inbound_message = Gate_protocol.inbound_message = {
  channel : string;
  channel_user_id : string;
  channel_user_name : string;
  channel_workspace_id : string;
  keeper_name : string;
  content : string;
  idempotency_key : string;
  metadata : (string * string) list;
}

type turn_stats = Gate_protocol.turn_stats = {
  model_used : string;
  duration_ms : int;
  tokens_used : int;
}

type outbound_message = Gate_protocol.outbound_message = {
  keeper_name : string;
  content : string;
  structured : Yojson.Safe.t option;
  turn_stats : turn_stats option;
  message_request : Gate_protocol.message_request option;
}

(** {1 Validation} *)

type validation_error = Gate_protocol.validation_error =
  | Empty_content
  | Empty_keeper_name
  | Empty_channel_user_id
  | Empty_idempotency_key

val validate : inbound_message -> (unit, validation_error) result
(** Structural validation. Idempotency is owned by the durable dispatch sink. *)

val validation_error_to_string : validation_error -> string

(** {1 Dispatch} *)

type gate_error = Gate_protocol.gate_error =
  | Validation of validation_error
  | Keeper_error of string
  | Dispatch_unavailable
  | Internal of string

val gate_error_to_string : gate_error -> string

(** Dispatch function signature.  Provided by the wiring layer
    (typically a partial application of {!Gate_keeper_backend.dispatch}). *)
type dispatch_fn =
  channel:string ->
  channel_user_id:string ->
  channel_user_name:string ->
  channel_workspace_id:string ->
  keeper_name:string ->
  idempotency_key:string ->
  metadata:(string * string) list ->
  content:string ->
  Gate_protocol.dispatch_result

type streaming_dispatch_fn =
  on_text_snapshot:(string -> unit) ->
  channel:string ->
  channel_user_id:string ->
  channel_user_name:string ->
  channel_workspace_id:string ->
  keeper_name:string ->
  idempotency_key:string ->
  metadata:(string * string) list ->
  content:string ->
  Gate_protocol.dispatch_result
(** Streaming dispatch function signature. [on_text_snapshot] receives a
    connector-visible accumulated text snapshot suitable for transports that
    edit one message in place. {!Gate_keeper_backend.dispatch_with_text_snapshot}
    redacts provider deltas before invoking it. *)

val handle_inbound :
  dispatch:dispatch_fn ->
  inbound_message ->
  (outbound_message, gate_error) result
(** Validate and dispatch to keeper, then return the response.
    The only non-deterministic step is the keeper turn itself
    (which is on the other side of the [dispatch] boundary). *)

val handle_inbound_streaming :
  dispatch:streaming_dispatch_fn ->
  on_text_snapshot:(string -> unit) ->
  inbound_message ->
  (outbound_message, gate_error) result
(** Streaming variant of {!handle_inbound}. Validation,
    metrics, and result mapping are identical; only the injected dispatch
    receives [on_text_snapshot]. Validation failures never invoke the
    streaming callback. *)

(** {1 JSON helpers} *)

val inbound_of_json : Yojson.Safe.t -> (inbound_message, string) result
(** Parse an inbound message from the HTTP request body. *)

val outbound_to_json : outbound_message -> Yojson.Safe.t
(** Serialize an outbound message to JSON for the HTTP response. *)

val error_json : string -> Yojson.Safe.t
(** [{ok: false, error: "<msg>"}] *)
