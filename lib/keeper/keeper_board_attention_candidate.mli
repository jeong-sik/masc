(** Durable Board-attention judgment boundary.

    A candidate is persisted before any model call. Its only lifecycle is
    [Pending -> Judged -> Consumed]. Relevant judgments become normal
    Keeper-lane events only after an exact candidate-id durable queue commit;
    failures retain the latest retryable evidence and never consume or
    silently expire the candidate. *)

type retryable_failure_kind =
  | Runtime_configuration_unavailable
  | Prompt_contract_unavailable
  | Provider_unavailable
  | Response_contract_unavailable
  | Durable_delivery_unavailable
  | Lifecycle_policy_migrated

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
(** Synchronously process at most one fresh-pending batch plus all already
    judged durable candidates. Production
    calls this only while holding the Keeper's turn admission slot; no
    dashboard/producer domain may call it.

    Semantics:
    - Already-judged verdicts deliver without new model calls.
    - One provider call receives only candidates whose persisted
      [keeper_context] values are structurally equal. Other contexts remain
      pending for a later admission.
    - At most one provider call runs per admission. Remaining candidates are
      reported durably rather than drained behind the first call.
    - The response must cover the exact requested candidate-id set. Unknown,
      duplicate, or missing identities fail the whole attempted batch and
      persist retryable response-contract evidence for every attempted row.
    - Pending rows never expire from wall-clock age. Supersession or operator
      discard requires a separate typed lifecycle operation. *)

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
