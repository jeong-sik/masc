(** Channel_gate -- deterministic router for external chat platforms.

    Sits between external consumers (Discord, Telegram, etc.)
    and the keeper subsystem.  All logic is deterministic:
    same input always produces the same routing decision.
    No LLM calls, no heuristics, no fuzzy matching.

    Consumers talk to the gate via HTTP ([/api/v1/gate/*]).
    The gate talks to keepers via [Tool_keeper.dispatch].

    @since 2.217.0 *)

(** {1 Inbound / Outbound Types} *)

(** Message arriving from an external channel consumer. *)
type inbound_message = {
  channel : string;
  channel_user_id : string;
  channel_user_name : string;
  channel_room_id : string;
  keeper_name : string;
  content : string;
  idempotency_key : string;
  metadata : (string * string) list;
}

(** Successful response to send back to the consumer. *)
type outbound_message = {
  keeper_name : string;
  content : string;
  turn_stats : turn_stats option;
}

and turn_stats = {
  model_used : string;
  duration_ms : int;
  tokens_used : int;
}

(** {1 Validation} *)

type validation_error =
  | Empty_content
  | Content_too_long of int
  | Empty_keeper_name
  | Empty_channel_user_id
  | Empty_idempotency_key
  | Duplicate_message of string

val validate : inbound_message -> (unit, validation_error) result
(** Validation plus idempotency gate.  Returns [Ok ()] when the message can proceed.
    Duplicate detection consumes the idempotency key on first success. *)

val validation_error_to_string : validation_error -> string

(** {1 Deduplication} *)

val dedup_check : string -> bool
(** [dedup_check key] returns [true] if [key] was already seen
    within the TTL window (default 300 s).  Thread-safe. *)

val dedup_cleanup : now:float -> unit
(** Evict expired entries.  Called periodically. *)

val dedup_table_size : unit -> int
(** Current number of entries in the dedup table.  For metrics. *)

(** {1 Dispatch} *)

(** {1 Dispatch errors (typed, not string)} *)

type gate_error =
  | Validation of validation_error
  | Keeper_error of string
  | Dispatch_unavailable
  | Internal of string

val gate_error_to_string : gate_error -> string

val handle_inbound :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option ->
  config:Room.config ->
  inbound_message ->
  (outbound_message, gate_error) result
(** Validate, dedup, dispatch to keeper, return response.
    The only non-deterministic step is the keeper turn itself
    (which is on the other side of the boundary). *)

(** {1 JSON helpers} *)

val inbound_of_json : Yojson.Safe.t -> (inbound_message, string) result
(** Parse an inbound message from the HTTP request body. *)

val outbound_to_json : outbound_message -> Yojson.Safe.t
(** Serialize an outbound message to JSON for the HTTP response. *)

val error_json : string -> Yojson.Safe.t
(** [{ok: false, error: "<msg>"}] *)

(** {1 Configuration} *)

val max_content_length : unit -> int
(** [MASC_CHANNEL_GATE_MAX_CONTENT_LENGTH], default 4000. *)

val dedup_ttl_sec : unit -> float
(** [MASC_CHANNEL_GATE_DEDUP_TTL_SEC], default 300.0. *)
