(** Durable Board-attention judgment boundary.

    A candidate is persisted before any model call. Its lifecycle is
    [Pending -> Judged -> Consumed]. Relevant judgments become normal
    Keeper-lane events only after an exact candidate-id durable queue commit;
    failures retain the latest retryable evidence and never consume the
    candidate. Pending work has no wall-clock expiry: it remains durable until
    judgment and delivery succeed. *)

type retryable_failure_kind =
  | Runtime_configuration_unavailable
  | Prompt_contract_unavailable
  | Provider_unavailable
  | Response_contract_unavailable
  | Durable_delivery_unavailable

type retryable_failure =
  { kind : retryable_failure_kind
  ; detail : string
  ; failed_at : float
  }

type judgment =
  { verdict : Keeper_board_attention_judgment.t
  ; runtime_id : string
  ; judged_at : float
  }

type delivery =
  | Enqueued_to_keeper_lane
  | Not_relevant

type pending_state = { last_failure : retryable_failure option }

type judged_state =
  { judgment : judgment
  ; last_failure : retryable_failure option
  }

type consumed_state =
  { judgment : judgment
  ; delivery : delivery
  ; consumed_at : float
  }

type status =
  | Pending of pending_state
  | Judged of judged_state
  | Consumed of consumed_state

type candidate =
  { candidate_id : string
  ; keeper_name : string
  ; signal : Board_dispatch.board_signal
  ; judgment_request : Yojson.Safe.t
  ; recorded_at : float
  ; status : status
  }

module Context_key : sig
  type t

  val of_candidate : candidate -> (t, string) result
  val of_yojson : Yojson.Safe.t -> (t, string) result
  val to_yojson : t -> Yojson.Safe.t
  val to_canonical_string : t -> string
  val equal : t -> t -> bool
end
(** Exact persisted Keeper-context identity for immutable judgment
    partitions. Object field order is canonicalized, while duplicate object
    keys, missing context, or multiple [keeper_context] fields are rejected.
    Lists retain their original order. No prompt-size, token, time, or provider
    capacity estimate participates in this identity. *)

type record_result =
  | Recorded of candidate
  | Duplicate of candidate
  | Record_error of string

type persistence =
  | Candidate_recorded
  | Candidate_already_present

type wake_decision =
  | Wake_requested of Keeper_registry.wakeup_outcome
  | Wake_not_required

type record_acceptance =
  { candidate : candidate
  ; persistence : persistence
  ; wake : wake_decision
  }

type drain_report =
  { attempted : int
  ; consumed : int
  ; remaining : int
  }

exception Candidate_unavailable of string

val retryable_failure_kind_to_string : retryable_failure_kind -> string
val retryable_failure_kind_of_string : string -> retryable_failure_kind option
val delivery_to_string : delivery -> string
val delivery_of_string : string -> delivery option
val signal_to_yojson : Board_dispatch.board_signal -> Yojson.Safe.t

val of_board_evidence :
  meta:Keeper_meta_contract.keeper_meta ->
  recorded_at:float ->
  signal:Board_dispatch.board_signal ->
  post:Board.post ->
  comments:Board.comment list ->
  (candidate, string) result

val of_board_signal :
  meta:Keeper_meta_contract.keeper_meta ->
  recorded_at:float ->
  Board_dispatch.board_signal ->
  candidate Keeper_world_observation_board_signal.board_read
(** Reads the complete persisted post and comment set. Board failures remain
    typed [Unavailable] and no partial candidate is synthesized. *)

val candidate_to_json : candidate -> Yojson.Safe.t
val candidate_of_json : Yojson.Safe.t -> (candidate, string) result

val load_candidates :
  base_path:string -> keeper_name:string -> (candidate list, string) result

val record : base_path:string -> candidate -> record_result

val record_retryable_failure :
  base_path:string ->
  candidate ->
  retryable_failure ->
  (candidate, string) result

val record_judgment :
  base_path:string -> candidate -> judgment -> (candidate, string) result

val process_with_judge :
  base_path:string ->
  judge:(candidate -> (judgment, retryable_failure) result) ->
  candidate ->
  (candidate, string) result
(** Testable state-machine boundary. Production drains the configured
    structured judge through {!drain_pending_on_owner_lane}. *)

val record_and_wake :
  base_path:string -> candidate -> (record_acceptance, string) result
(** Persist the exact candidate, then request a live wake from the registered
    running Keeper. The durable row is authoritative: a deferred wake remains
    a successful acceptance and is returned as a typed
    {!Keeper_registry.wakeup_outcome}. A consumed duplicate needs no wake.
    This function never invokes the model judge. *)

val drain_pending_on_owner_lane :
  base_path:string -> keeper_name:string -> (drain_report, string) result
(** Synchronously process every non-terminal durable candidate. Production
    calls this only while holding the Keeper's turn admission slot; no
    dashboard/producer domain may call it.

    Semantics:
    - Already-judged verdicts deliver without new model calls.
    - Pending rows are judged in batches of up to
      {!batch_max_candidates} per model call. A failed batch aborts the round:
      the next keepalive turn owns the retry cadence, so provider outages
      cannot turn the drain into a hot retry loop.
    - A successful response must cover the exact requested candidate-id set.
      Unknown, duplicate, or missing identities fail the attempted batch and
      persist retryable response-contract evidence on every requested row.
    - An exact response commits all requested [Pending -> Judged] transitions
      in one candidate-ledger rewrite or commits none. Durable queue delivery
      and terminal [Consumed] transitions then proceed idempotently from the
      committed judgments; they are not presented as a cross-file transaction.
    - Failure-evidence persistence errors propagate to the caller; they are
      never reduced to logs. *)

val batch_max_candidates : int
(** Maximum candidates judged per model call. *)

module Candidate_map : Map.S with type key = string

module For_testing : sig
  val drain_pending_with_judge :
    base_path:string ->
    keeper_name:string ->
    judge:(candidate -> (judgment, retryable_failure) result) ->
    (drain_report, string) result
  (** Per-candidate judging adapter over the batch engine. *)

  val drain_pending_with_judge_batch :
    base_path:string ->
    keeper_name:string ->
    judge_batch:(candidate list -> (judgment Candidate_map.t, retryable_failure) result) ->
    (drain_report, string) result
end
