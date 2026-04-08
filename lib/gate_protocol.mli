(** Gate_protocol -- wire-level types for the Channel Gate HTTP API.

    Pure module: no Eio, no Agent_identity, no Tool_keeper, no Room.
    Only depends on Yojson for JSON serialization.

    Connectors (Discord, Telegram, etc.) and the gate orchestrator
    both speak this protocol.  Neither side knows about the other's
    internals.

    @since 2.222.0 *)

(** {1 Wire Types} *)

(** Message arriving from an external channel consumer. *)
type inbound_message = {
  channel : string;
      (** Opaque channel label ("discord", "telegram", …).
          The gate never interprets this beyond passing it to metrics. *)
  channel_user_id : string;
  channel_user_name : string;
  channel_room_id : string;
  keeper_name : string;
  content : string;
  idempotency_key : string;
  metadata : (string * string) list;
}

(** Turn-level statistics from the keeper. *)
type turn_stats = {
  model_used : string;
  duration_ms : int;
  tokens_used : int;
}

(** Successful response to send back to the consumer. *)
type outbound_message = {
  keeper_name : string;
  content : string;
  structured : Yojson.Safe.t option;
      (** Optional structured content blocks (opaque JSON).
          Gate passes this through without interpretation.
          See [docs/spec/structured-content-schema.md] for the JSON schema. *)
  turn_stats : turn_stats option;
}

(** {1 Validation} *)

type validation_error =
  | Empty_content
  | Content_too_long of int
  | Empty_keeper_name
  | Empty_channel_user_id
  | Empty_idempotency_key
  | Duplicate_message of string

val validation_error_to_string : validation_error -> string

val validate :
  max_content_length:int ->
  dedup_check:(string -> bool) ->
  inbound_message ->
  (unit, validation_error) result
(** Pure validation with injected dedup check.
    Returns [Ok ()] when the message can proceed.
    The [dedup_check] function is provided by the caller
    so this module stays free of mutable state. *)

(** {1 Errors} *)

type gate_error =
  | Validation of validation_error
  | Keeper_error of string
  | Dispatch_unavailable
  | Internal of string

val gate_error_to_string : gate_error -> string

(** {1 Dispatch Result}

    Returned by the injected dispatch function.
    Lives here so that [Channel_gate] does not depend on [Gate_keeper_backend]. *)

type dispatch_result =
  | Reply of { content : string; structured : Yojson.Safe.t option; stats : turn_stats option }
  | Keeper_error_result of string
  | Unavailable_result

(** {1 JSON Codecs} *)

val inbound_of_json : Yojson.Safe.t -> (inbound_message, string) result
(** Parse an inbound message from the HTTP request body.
    The [channel] field is kept as a raw string -- no variant conversion. *)

val outbound_to_json : outbound_message -> Yojson.Safe.t
(** Serialize an outbound message to JSON for the HTTP response. *)

val error_json : string -> Yojson.Safe.t
(** [{ok: false, error: "<msg>"}] *)
