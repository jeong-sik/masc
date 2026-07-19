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
  | Judgment_worker_requested of Keeper_board_attention_worker_wake.wake_result
  | Wake_not_required

type record_acceptance =
  { candidate : candidate
  ; persistence : persistence
  ; wake : wake_decision
  }

exception Candidate_unavailable of string

val retryable_failure_kind_to_string : retryable_failure_kind -> string
val retryable_failure_kind_of_string : string -> retryable_failure_kind option
val retryable_failure_to_yojson : retryable_failure -> Yojson.Safe.t
val retryable_failure_of_yojson : Yojson.Safe.t -> (retryable_failure, string) result
val judgment_to_yojson : judgment -> Yojson.Safe.t
val judgment_of_yojson : Yojson.Safe.t -> (judgment, string) result
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

val judge_singleton :
  sw:Eio.Switch.t ->
  net:Eio_context.eio_net option ->
  base_path:string ->
  candidate ->
  (judgment, retryable_failure) result
(** Invoke the configured structured judge for exactly one immutable
    candidate. The response must cover that exact candidate identity. This is
    Provider work and must never run under Keeper turn admission. *)

val apply_judgment_and_deliver :
  base_path:string ->
  keeper_name:string ->
  candidate_id:string ->
  judgment:judgment ->
  (candidate, string) result
(** Idempotently apply one completed worker judgment and finish its durable
    event delivery. Success means the candidate is [Consumed]. Conflicting
    prior judgment or a non-terminal delivery result is explicit. *)

val record_and_wake :
  base_path:string -> candidate -> (record_acceptance, string) result
(** Persist the exact candidate, then request the per-Keeper judgment worker.
    The durable row is authoritative: an unregistered worker is a typed,
    successful deferral recovered by worker startup drain. A consumed duplicate
    needs no wake. This function never invokes the model judge. *)
