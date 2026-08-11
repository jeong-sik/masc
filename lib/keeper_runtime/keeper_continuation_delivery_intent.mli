(** Durable-data contract for projecting an autonomous Keeper reply back to
    the exact continuation source that caused the turn.

    This module is deliberately storage-agnostic.  It defines the immutable
    identity, retained response, and closed delivery state that the existing
    delivery SSOT can persist; it is not another delivery ledger. *)

module Intent_id : sig
  type t = private string

  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

type source_identity =
  | Fusion_completion of { run_id : string }
  | Hitl_resolution of { approval_id : string }
  | Connector_attention of { event_id : string }
  | Schedule_occurrence of { occurrence_id : string }
(** Producer-owned durable identity for the continuation-bearing event.
    Constructors are closed so two producer families cannot collide merely
    because their public ids happen to contain the same bytes. *)

type origin = private
  { source : source_identity
  ; channel : Keeper_continuation_channel.t
  }

type failure_kind =
  | Adapter_rejected
  | Retry_exhausted
  | Persistence_failed

type state =
  | Pending
  | Attempting of
      { started_at : float
      ; idempotency_key : string
      }
  | Delivered of
      { completed_at : float
      ; connector_message_id : string option
      }
  | Failed of
      { completed_at : float
      ; kind : failure_kind
      ; detail : string
      }
  | Ambiguous of
      { detected_at : float
      ; detail : string
      }
(** Closed connector projection lifecycle.  [Attempting] is durable before a
    connector send.  [Ambiguous] is distinct from ordinary failure so a crash
    in the send/receipt window cannot be silently retried as a known failure. *)

type response = private
  { text : string
  ; sha256 : string
  }

type t = private
  { schema_version : int
  ; intent_id : Intent_id.t
  ; keeper_name : string
  ; keeper_turn_id : int
  ; origin : origin
  ; response : response
  ; state : state
  }

type error =
  | Invalid_source of string
  | Unroutable_channel of string
  | Invalid_keeper_name of string
  | Invalid_keeper_turn_id of int
  | Invalid_response of string
  | Invalid_timestamp of string
  | Invalid_transition of string
  | Decode_failed of string
  | Identity_mismatch of
      { encoded : string
      ; derived : string
      }
  | Response_digest_mismatch of
      { encoded : string
      ; derived : string
      }

val error_to_string : error -> string

val fusion_origin :
  run_id:string -> Keeper_continuation_channel.t -> (origin, error) result

val hitl_origin :
  approval_id:string -> Keeper_continuation_channel.t -> (origin, error) result

val connector_attention_origin :
  event_id:string -> Keeper_continuation_channel.t -> (origin, error) result

val schedule_origin :
  occurrence_id:string -> Keeper_continuation_channel.t -> (origin, error) result

val origin_of_payload : Keeper_event_queue.stimulus_payload -> origin option
(** Project the four continuation-bearing queue payload families.  A scheduled
    wake participates only when its creation boundary persisted an explicit
    result destination. Non-continuation
    payloads and an explicit [Unrouted] channel both return [None]; callers
    therefore cannot accidentally fabricate a convenience destination. *)

val same_source : origin -> origin -> bool
(** Compare only producer-owned source identity. Route changes for the same
    source are detected separately and must not create a second obligation. *)

val same_origin : origin -> origin -> bool
(** Compare source identity and exact continuation route. *)

val intent_id_for_origin :
  keeper_name:string -> origin -> (Intent_id.t, error) result
(** Deterministically resolve the one obligation path owned by a producer
    source before the response is known. This enables exact recovery without
    scanning or being blocked by malformed obligations for unrelated sources. *)

val create :
  keeper_name:string ->
  keeper_turn_id:int ->
  origin:origin ->
  response_text:string ->
  (t, error) result
(** Create a [Pending] intent.  The deterministic id is derived only from the
    keeper and producer source identity.  A replay of the same source with a
    changed route or response consequently has the same id but is classified
    as an identity conflict by {!classify_replay}. *)

val start_attempt : started_at:float -> t -> (t, error) result
(** Move [Pending] to [Attempting].  The idempotency key is the stable intent
    id and is therefore reused by recovery. *)

val mark_delivered :
  completed_at:float ->
  ?connector_message_id:string ->
  t ->
  (t, error) result

val mark_failed :
  completed_at:float ->
  kind:failure_kind ->
  detail:string ->
  t ->
  (t, error) result

val mark_ambiguous :
  detected_at:float -> detail:string -> t -> (t, error) result

type replay_classification =
  | Distinct_identity
  | Exact_replay
  | Identity_conflict

val classify_replay : existing:t -> incoming:t -> replay_classification
(** Compare immutable intent content while ignoring lifecycle progress. *)

val state_label : state -> string
val failure_kind_to_string : failure_kind -> string
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, error) result
(** Strict, round-trippable codec.  Unknown/duplicate fields, non-finite
    timestamps, response-digest drift, and deterministic-id drift fail closed. *)
