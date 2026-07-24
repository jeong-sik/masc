(** Durable Board-attention judgment boundary.

    A candidate is persisted before any model call. Its lifecycle is
    [Pending -> Judged -> Consumed]. Relevant judgments become normal
    Keeper-lane events only after an exact candidate-id durable queue commit;
    delivery failures retain the latest failure evidence and never consume the
    candidate. Pending work has no wall-clock expiry: it remains durable until
    judgment and delivery succeed. *)

type delivery_failure_kind =
  | Durable_delivery_unavailable

type delivery_failure =
  { kind : delivery_failure_kind
  ; detail : string
  ; failed_at : float
  }

type judgment =
  { verdict : Keeper_board_attention_judgment.t
  ; slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  ; judged_at : float
  }

type delivery =
  | Enqueued_to_keeper_lane
  | Not_relevant

type pending_state = { last_delivery_failure : delivery_failure option }

type judged_state =
  { judgment : judgment
  ; last_delivery_failure : delivery_failure option
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
(** All persisted lifecycle timestamps are finite. Non-finite [recorded_at],
    delivery failure [failed_at], and [consumed_at] values are rejected on
    both record and load. *)

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

val delivery_failure_kind_to_string : delivery_failure_kind -> string
val delivery_failure_kind_of_string : string -> delivery_failure_kind option
val delivery_failure_to_yojson : delivery_failure -> Yojson.Safe.t
val delivery_failure_of_yojson : Yojson.Safe.t -> (delivery_failure, string) result
val judgment_to_yojson : judgment -> Yojson.Safe.t
val judgment_of_yojson : Yojson.Safe.t -> (judgment, string) result
val delivery_to_string : delivery -> string
val delivery_of_string : string -> delivery option
val signal_to_yojson : Board_dispatch.board_signal -> Yojson.Safe.t

val singleton_judgment_request : candidate -> (Yojson.Safe.t, string) result
(** Validate the current durable request schema and its outer candidate,
    Keeper, and signal identity, then return the one-item exact-flow input.
    Old or partial request JSON is rejected without compatibility decoding. *)

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
(** Validate the current request schema and finite lifecycle timestamps before
    changing the durable ledger. *)

val record_delivery_failure :
  base_path:string ->
  candidate ->
  delivery_failure ->
  (candidate, string) result

val record_judgment :
  base_path:string -> candidate -> judgment -> (candidate, string) result

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
