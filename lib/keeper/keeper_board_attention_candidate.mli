(** Durable Board-attention judgment boundary.

    A candidate is persisted before any model call. Its lifecycle is
    [Pending -> Judged -> Consumed]. A terminal exact-flow failure first
    projects to [Quarantine Quarantined]; an operator-owned recovery advances
    it through [Requeue_requested] to [Requeued] without losing the prior
    domain state. Relevant judgments cross the owner lane only when the owner durably applies and consumes the exact candidate judgment;
    delivery failures retain the latest failure evidence and never consume the
    candidate. Pending work has no wall-clock expiry: it remains durable until
    judgment and delivery succeed. *)

module Partition_generation = Keeper_board_attention_partition_generation

type delivery_failure_kind =
  | Durable_delivery_unavailable

type delivery_failure =
  { kind : delivery_failure_kind
  ; detail : string
  ; failed_at : float
  }

type judgment_source =
  | Exact_attempt of
      { call_id : string
      ; plan_fingerprint : string
      ; request_body_sha256 : string
      }
      (** An admitted catalog slot answered over HTTP. These three name the
          AGENT_CORE receipt of that attempt, and completion matches them
          against the durable pre-dispatch binding. *)
  | Cli_lane_slot
      (** A [cli_slots] official client answered as a one-shot after every
          catalog slot was exhausted (RFC cli-runtimes-as-lane-slots). No
          AGENT_CORE attempt was allocated, so no receipt exists to name and
          none is invented: the slot id is the whole provenance. *)

type judgment =
  { verdict : Keeper_board_attention_judgment.t
  ; slot_id : string
  ; source : judgment_source
  ; judged_at : float
  }
(** [slot_id] names whichever slot answered; [source] says which kind of slot
    it was, because the two carry different evidence and only one of them has
    a receipt to bind a completion to. *)

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

type resumable_status =
  | Resumable_pending of pending_state
  | Resumable_judged of judged_state
  | Resumable_consumed of consumed_state

type quarantine_failure_category =
  | Candidate_membership_conflict
  | Durable_partition_invariant
  | Exact_setup_unavailable
  | Exact_flow_replayed
  | Exact_execution_terminal
  | Domain_output_invalid
  | Execution_provenance_mismatch
  | Unexpected_worker_failure
  | Exact_execution_quarantined

type attempt_provenance =
  { slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  }

type quarantine =
  { quarantine_id : string
  ; partition_id : string
  ; partition_generation : Partition_generation.t
  ; failure_category : quarantine_failure_category
  ; attempt_provenance : attempt_provenance option
  ; quarantined_at : float
  ; prior_status : resumable_status
  }

type quarantine_phase =
  | Quarantined
  | Requeue_requested of { requested_at : float }
  | Requeued of { requeued_at : float }

type quarantine_state =
  { quarantine : quarantine
  ; phase : quarantine_phase
  }

type status =
  | Pending of pending_state
  | Judged of judged_state
  | Consumed of consumed_state
  | Quarantine of quarantine_state

type status_view =
  | Direct_resumable of resumable_status
      (** A candidate that has never entered quarantine. *)
  | Requeued_resumable of
      { resumable : resumable_status
      ; quarantine : quarantine_state
      }
      (** A requeued candidate is operationally resumable while retaining the
          quarantine identity needed by reconciliation and audit. *)
  | Suspended_quarantine of quarantine_state
      (** A quarantined or requeue-requested candidate is not operationally
          resumable. *)

type candidate =
  { candidate_id : string
  ; keeper_name : string
  ; signal : Board_dispatch.board_signal
  ; judgment_request : Yojson.Safe.t
  ; recorded_at : float
  ; status : status
  }
(** Every durable write is validated against the same current schema accepted
    on load. All floats in the signal, exact judgment request (including nested
    Board evidence), and lifecycle state must be finite. [Judged] and
    [Consumed] states additionally require a nonblank verdict rationale and
    nonblank judgment provenance. *)

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

(* The [delivery_failure], [delivery] and [quarantine_failure_category] codecs
   are not listed here. They serialize this module's own durable ledger and no
   caller outside it ever named one -- exporting them offered a second way to
   read and write the ledger's shape beside the operations that own it. The
   functions stay; only the interface stops advertising them.
   [quarantine_failure_category_to_string] is the exception and is kept:
   [Keeper_board_attention_quarantine_command] renders the category. *)

val judgment_to_yojson : judgment -> Yojson.Safe.t
val judgment_of_yojson : Yojson.Safe.t -> (judgment, string) result
val quarantine_failure_category_to_string : quarantine_failure_category -> string
val status_view : status -> status_view
(** Total classification of a durable status. Unlike the removed pair of
    optional projections, this preserves both operational resumability and
    quarantine provenance without forcing callers to inspect [status] again. *)
val signal_to_yojson : Board_dispatch.board_signal -> Yojson.Safe.t

val candidate_id_of_signal :
  keeper_name:string -> Board_dispatch.board_signal -> string
(** Typed event identity of a Board signal for one keeper. [Board_post_created]
    hashes (keeper, kind, post_id) only — volatile post fields (updated_at,
    content) must not participate, or the backlog scanner's re-synthesized
    signals mint a fresh candidate per post update (#28607). Exported so test
    fixtures derive ids from this function instead of copying the formula. *)

val singleton_judgment_request : candidate -> (Yojson.Safe.t, string) result
(** Validate the current durable request schema and its outer candidate,
    Keeper, and signal identity, then return the one-item exact-flow input.
    Old or partial request JSON is rejected without compatibility decoding. *)

(* [of_board_evidence] is the inner step of [of_board_signal] below, which is
   the door callers use: it reads the post and comments and hands them here.
   Nothing outside supplies its own evidence. *)

val of_board_signal :
  meta:Keeper_meta_contract.keeper_meta ->
  recorded_at:float ->
  Board_dispatch.board_signal ->
  candidate Keeper_world_observation_board_signal.board_read
(** Reads the complete persisted post and comment set. Board failures remain
    typed [Unavailable] and no partial candidate is synthesized. *)

val candidate_to_json : candidate -> Yojson.Safe.t
val candidate_of_json : Yojson.Safe.t -> (candidate, string) result

(** {1 Structural decode helpers}

    Shared with {!Keeper_board_attention_partition}, which decodes the
    same candidate JSON. [context] prefixes the error message. *)

val assoc :
  context:string ->
  Yojson.Safe.t ->
  ((string * Yojson.Safe.t) list, string) result
(** [assoc ~context json] returns the fields of a [`Assoc], or an error
    saying [context] must be an object. *)

val exact_fields :
  context:string ->
  string list ->
  (string * Yojson.Safe.t) list ->
  (unit, string) result
(** [exact_fields ~context expected fields] returns [Ok ()] when the keys
    of [fields] are exactly [expected], counting duplicates.  The error
    lists both the expected and the actual keys. *)

val field :
  context:string ->
  string ->
  (string * Yojson.Safe.t) list ->
  (Yojson.Safe.t, string) result
(** [field ~context key fields] returns the value bound to [key], or an
    error naming the missing field. *)

val load_candidates :
  base_path:string -> keeper_name:string -> (candidate list, string) result

val load_candidates_with_rejections
  :  base_path:string
  -> keeper_name:string
  -> (candidate list * (int * string) list, string) result
(** Same read as {!load_candidates}, plus the rows it could not decode as
    [(line number, reason)].

    One unreadable row used to fail the whole read, and the write path reads
    before it writes, so compaction could never remove it. Measured 2026-08-28:
    17 of 575 rows carried a field a hard cut had removed and stopped all 10
    keeper ledgers, 402 WARN/day. This ledger is a projection — the board is
    the source and [latest_candidates] keeps the newest row per candidate_id —
    so the readable rows are worth more than refusing everything. The next
    write compacts the rejected rows out. *)

val record : base_path:string -> candidate -> record_result
(** Validate the complete current candidate invariant before changing the
    durable ledger. *)

(* [record_delivery_failure] is called from [consume_judged] in this module, on
   the branch where the event queue answers [Identity_conflict] or
   [Storage_error]. That is the only place a [delivery_failure] is constructed,
   so a caller outside holds none to record. *)

val record_judgment :
  base_path:string -> candidate -> judgment -> (candidate, string) result

val quarantine :
  base_path:string ->
  candidate:candidate ->
  partition_id:string ->
  partition_generation:Partition_generation.t ->
  failure_category:quarantine_failure_category ->
  attempt_provenance:attempt_provenance option ->
  quarantined_at:float ->
  (candidate, string) result

val request_quarantine_requeue :
  base_path:string ->
  candidate:candidate ->
  partition_id:string ->
  expected_quarantine_id:string ->
  requested_at:float ->
  (candidate, string) result

val finish_quarantine_requeue :
  base_path:string ->
  candidate:candidate ->
  partition_id:string ->
  expected_quarantine_id:string ->
  requeued_at:float ->
  (candidate, string) result

val normalize_requeued_consumed :
  base_path:string ->
  keeper_name:string ->
  candidate_id:string ->
  (candidate, string) result
(** Remove the recovery wrapper after owner settlement observes an already
    consumed resumable state. Direct [Consumed] is idempotent; every other
    state is rejected. *)

type judgment_delivery_outcome =
  | Delivered of candidate
  | Candidate_absent
      (** The named candidate is not in the live ledger — a retire moves the
          whole store aside as one directory and never leaves a tombstone, so
          this is indistinguishable from any other cause of absence and is
          treated the same: the delivery cannot succeed on a retry of the
          identical request, because there is no row left to update. *)

val apply_judgment_and_deliver :
  base_path:string ->
  keeper_name:string ->
  candidate_id:string ->
  judgment:judgment ->
  (judgment_delivery_outcome, string) result
(** Idempotently apply one completed worker judgment and finish its durable
    event delivery. [Delivered] means the candidate is [Consumed].
    [Candidate_absent] is explicit rather than folded into [Error] so a caller
    can settle the partition without delivery instead of retrying an update
    that structurally cannot land. Conflicting prior judgment or a
    non-terminal delivery result against a candidate that does exist remains
    an [Error]. *)

val record_and_wake :
  base_path:string -> candidate -> (record_acceptance, string) result
(** Persist the exact candidate, then request the per-Keeper judgment worker.
    The durable row is authoritative: an unregistered worker is a typed,
    successful deferral recovered by worker startup drain. A consumed duplicate
    needs no wake. This function never invokes the model judge. *)
