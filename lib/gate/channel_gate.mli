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
  | Content_too_long of int
  | Empty_keeper_name
  | Empty_channel_user_id
  | Empty_idempotency_key
  | Duplicate_message of string

type accepted_failure = Gate_protocol.accepted_failure =
  { detail : string
  ; message_id : string
  ; receipt_id : string option
  }

type accepted_replay = Gate_protocol.accepted_replay =
  { message_id : string
  ; receipt_id : string option
  }

val validate : inbound_message -> (unit, validation_error) result
(** Validation plus idempotency gate.  Returns [Ok ()] when the message can proceed.
    Duplicate detection consumes the idempotency key on first success. *)

val validation_error_to_string : validation_error -> string

(** {1 Deduplication} *)

val dedup_check : string -> bool
(** [dedup_check key] returns [true] if [key] was already seen
    within the TTL window ([MASC_CHANNEL_GATE_DEDUP_TTL_SEC], default
    3600 s).  Thread-safe. *)

val dedup_cleanup : now:float -> unit
(** Evict expired entries.  Called periodically by the Pulse consumer
    returned by {!make_dedup_cleanup_consumer}. *)

val dedup_table_size : unit -> int
(** Current number of entries in the dedup table.  For metrics. *)

val make_dedup_cleanup_consumer : unit -> (module Pulse.Consumer)
(** Pulse consumer that sweeps TTL-expired entries on every beat.
    Wire into an existing Pulse engine (e.g. the orchestrator zombie
    pulse) during server startup.  Without this, stale entries only
    leave the table once it hits [dedup_max_entries] and the O(n)
    evict-one-oldest branch takes over on every subsequent insert. *)

(** {1 Dispatch} *)

type gate_error = Gate_protocol.gate_error =
  | Validation of validation_error
  | Keeper_error of string
  | Accepted_keeper_error of accepted_failure
  | Accepted_replay of accepted_replay
  | Dispatch_unavailable
  | Internal of string

type inbound_error_notice =
  | Offline_notice
  | Retry_notice
  | Accepted_failure_notice
  | No_notice

val inbound_error_notice : gate_error -> inbound_error_notice
(** Closed connector policy for user-visible gate failures. Keeper failures
    require a generic retry notice; a failure after durable inbound acceptance
    gets a non-retry accepted-failure notice; dispatch unavailability requires
    an offline notice. Validation/internal failures remain log-only because
    their safe message is owned by the ingress boundary. *)

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
(** Validate, dedup, dispatch to keeper, return response.
    The only non-deterministic step is the keeper turn itself
    (which is on the other side of the [dispatch] boundary). *)

val handle_inbound_streaming :
  dispatch:streaming_dispatch_fn ->
  on_text_snapshot:(string -> unit) ->
  inbound_message ->
  (outbound_message, gate_error) result
(** Streaming variant of {!handle_inbound}. Validation, deduplication,
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

val gate_error_json : gate_error -> Yojson.Safe.t
(** Typed public failure envelope. It always states whether the inbound was
    durably accepted and whether replay is safe. Operator-only failure detail is
    never copied into this projection. *)

(** {1 Configuration} *)

val max_content_length : unit -> int
(** [MASC_CHANNEL_GATE_MAX_CONTENT_LENGTH], default 4000. *)

val dedup_ttl_sec : unit -> float
(** [MASC_CHANNEL_GATE_DEDUP_TTL_SEC], default 3600.0. *)
