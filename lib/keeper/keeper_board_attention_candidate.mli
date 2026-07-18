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
  | Partition_membership_conflict
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

type record_result =
  | Recorded of candidate
  | Duplicate of candidate
  | Record_error of string

type persistence =
  | Candidate_recorded
  | Candidate_already_present

type drain_report =
  { attempted : int
  ; consumed : int
  ; remaining : int
  }

module Candidate_map : Map.S with type key = string

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
val candidate_id_of_signal : keeper_name:string -> Board_dispatch.board_signal -> string

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

val discover_keeper_names : base_path:string -> (string list, string) result
(** Discover exact durable Keeper identities by parsing candidate rows, not by
    reversing sanitized filenames. A malformed ledger or a filename collision
    containing multiple identities is an error. *)

val record : base_path:string -> candidate -> record_result

val keeper_context_key : candidate -> (string, string) result
(** Canonical persisted Keeper-context identity used to form immutable
    judgment cohorts. Equality is structural JSON equality after key sorting;
    no prompt-size or provider-capacity estimate participates. *)

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
(** Test-only state-machine boundary for focused single-candidate tests.
    Production judging is owned by {!Keeper_board_attention_worker}. *)

val judge_batch_exact :
  base_path:string ->
  candidate list ->
  (judgment Candidate_map.t, retryable_failure) result
(** Execute one prepared same-context partition and accept the response only
    when its candidate-id set is exactly the requested set. *)

val apply_completed_judgments :
  base_path:string ->
  keeper_name:string ->
  (string * judgment) list ->
  (drain_report, string) result
(** Idempotently apply already-completed partition results on the owner lane.
    Pending rows become [Judged] in one ledger rewrite, relevant events are
    enqueued by candidate identity, and all rows become [Consumed] in one
    further rewrite. Replays require an exactly equal persisted judgment;
    conflicting results fail without overwriting either value. *)

val consume_judged_on_owner_lane :
  base_path:string -> keeper_name:string -> (drain_report, string) result
(** Deliver and consume legacy or crash-recovered [Judged] rows without any
    provider call. *)

module For_testing : sig
  val set_ledger_rewrite_observer : (unit -> unit) -> unit
  val reset_ledger_rewrite_observer : unit -> unit
  (** Observe ledger-rewrite transaction calls in focused tests. Production
      installs no observer. *)

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
  (** Execute one exact-context cohort without a fixed cardinality cap. This
      test adapter does not represent the production partition worker. *)
end
