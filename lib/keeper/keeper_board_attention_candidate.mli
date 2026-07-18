(** Durable Board-attention judgment boundary.

    A candidate is persisted before any model call. Its lifecycle is
    [Pending -> Judged -> Consumed]. Pending work has no time, count, cost, or
    turn-based terminal gate: it remains durable until a typed judgment is
    delivered. Relevant judgments become normal Keeper-lane events only after
    an exact candidate-id durable queue commit; failures retain the latest
    retryable evidence and never consume the candidate. *)

module Attempt_count : sig
  type t

  val one : t
  val of_string : string -> (t, string) result
  val to_string : t -> string
end
(** Canonical arbitrary-precision positive count. It is serialized as a decimal
    string so observation never becomes a machine-integer behavior gate. *)

type retryable_failure_kind =
  | Runtime_configuration_unavailable
  | Prompt_contract_unavailable
  | Provider_unavailable
  | Response_contract_unavailable
  | Durable_delivery_unavailable

type retryable_failure =
  { kind : retryable_failure_kind
  ; detail : string
  ; attempt_count : Attempt_count.t
  ; first_failed_at : float
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
      (** Immutable producer occurrence used for candidate identity and judge
          evidence; it is never consulted by queue intake. *)
  ; delivery_signal : Keeper_event_queue.board_stimulus
      (** Complete Keeper-specific prompt snapshot materialized with the same
          Board evidence set. Once admitted, this is the sole intake authority. *)
  ; judgment_request : Yojson.Safe.t
  ; recorded_at : float
  ; status : status
  }

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
(** Reads only the owner-bound current v2 authority. Retired JSONL bytes are
    never decoded, migrated, renamed, deleted, or used as fallback input. *)

val retired_epoch_residue :
  base_path:string -> keeper_name:string -> (string option, string) result
(** Raw [lstat] observation of the retired candidate epoch. [Some path] is
    operator evidence only and never blocks or augments current behavior. *)

val record : base_path:string -> candidate -> record_result
(** Initial admission accepts only [Pending { last_failure = None }] and
    validates the complete canonical candidate before the durable write.
    Invalid record values are returned as [Record_error] and cannot poison the
    current epoch. *)

val record_retryable_failure :
  base_path:string ->
  candidate ->
  retryable_failure ->
  (candidate, string) result
(** The supplied failure is one new occurrence: [attempt_count] must be [1],
    [first_failed_at] and [failed_at] must be identical finite timestamps. The
    store derives the unbounded aggregate count and first timestamp from
    durable state. *)

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
    - All Pending rows owned by this Keeper lane form one typed array request;
      no arbitrary count budget is a behavior gate. Provider failure records
      retryable evidence for the complete requested set, and the next owner
      turn controls retry cadence rather than a hot loop.
    - A successful response must contain exactly one verdict for every
      requested candidate identity. Unknown, duplicate, or omitted identities
      are response-contract failures recorded on the complete requested set;
      no partial verdict is applied. *)

module Candidate_map : Map.S with type key = string

module For_testing : sig
  val next_retryable_failure :
    previous:retryable_failure option ->
    retryable_failure ->
    (retryable_failure, string) result

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
