(** Channel_gate -- deterministic router for external chat platforms.

    Sits between external consumers (Discord, Telegram, etc.)
    and the keeper subsystem.  All logic is deterministic:
    same input always produces the same routing decision.
    No LLM calls, no heuristics, no fuzzy matching.

    Consumers talk to the gate via HTTP ([/api/v1/gate/*]).
    The gate dispatches to keepers through an injected [dispatch]
    function, keeping it decoupled from [Tool_keeper] internals.

    Wire types live in {!Gate_protocol}.
    Keeper dispatch adapter lives in {!Gate_keeper_backend}.

    @since 2.217.0
    @modified 2.222.0 Decoupled from Agent_identity and Tool_keeper *)

(** {1 Re-exported Wire Types} *)

type inbound_message = Gate_protocol.inbound_message =
  { channel : string
  ; channel_user_id : string
  ; channel_user_name : string
  ; channel_room_id : string
  ; keeper_name : string
  ; content : string
  ; idempotency_key : string
  ; metadata : (string * string) list
  }

type turn_stats = Gate_protocol.turn_stats =
  { model_used : string
  ; duration_ms : int
  ; tokens_used : int
  }

type outbound_message = Gate_protocol.outbound_message =
  { keeper_name : string
  ; content : string
  ; structured : Yojson.Safe.t option
  ; turn_stats : turn_stats option
  }

(** {1 Validation} *)

type validation_error = Gate_protocol.validation_error =
  | Empty_content
  | Content_too_long of int
  | Empty_keeper_name
  | Empty_channel_user_id
  | Empty_idempotency_key
  | Duplicate_message of string

(** Validation plus idempotency gate.  Returns [Ok ()] when the message can proceed.
    Duplicate detection consumes the idempotency key on first success. *)
val validate : inbound_message -> (unit, validation_error) result

val validation_error_to_string : validation_error -> string

(** {1 Deduplication} *)

(** [dedup_check key] returns [true] if [key] was already seen
    within the TTL window (default 300 s).  Thread-safe. *)
val dedup_check : string -> bool

(** Evict expired entries.  Called periodically by the Pulse consumer
    returned by {!make_dedup_cleanup_consumer}. *)
val dedup_cleanup : now:float -> unit

(** Current number of entries in the dedup table.  For metrics. *)
val dedup_table_size : unit -> int

(** Pulse consumer that sweeps TTL-expired entries on every beat.
    Wire into an existing Pulse engine (e.g. the orchestrator zombie
    pulse) during server startup.  Without this, stale entries only
    leave the table once it hits [dedup_max_entries] and the O(n)
    evict-one-oldest branch takes over on every subsequent insert. *)
val make_dedup_cleanup_consumer : unit -> (module Pulse.Consumer)

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
  channel:string
  -> channel_user_id:string
  -> channel_user_name:string
  -> channel_room_id:string
  -> keeper_name:string
  -> content:string
  -> Gate_protocol.dispatch_result

(** Validate, dedup, dispatch to keeper, return response.
    The only non-deterministic step is the keeper turn itself
    (which is on the other side of the [dispatch] boundary). *)
val handle_inbound
  :  dispatch:dispatch_fn
  -> inbound_message
  -> (outbound_message, gate_error) result

(** {1 JSON helpers} *)

(** Parse an inbound message from the HTTP request body. *)
val inbound_of_json : Yojson.Safe.t -> (inbound_message, string) result

(** Serialize an outbound message to JSON for the HTTP response. *)
val outbound_to_json : outbound_message -> Yojson.Safe.t

(** [{ok: false, error: "<msg>"}] *)
val error_json : string -> Yojson.Safe.t

(** {1 Configuration} *)

(** [MASC_CHANNEL_GATE_MAX_CONTENT_LENGTH], default 4000. *)
val max_content_length : unit -> int

(** [MASC_CHANNEL_GATE_DEDUP_TTL_SEC], default 300.0. *)
val dedup_ttl_sec : unit -> float
