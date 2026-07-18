(** Durable, capacity-agnostic Board-attention judgment partitions.

    Until the actual dispatched provider artifact exposes typed fit authority,
    each root contains exactly one currently-unassigned Pending candidate. One
    candidate is the irreducible work identity, not a guessed batch cap. No
    byte count, token estimate, wall-clock expiry, or attempt budget chooses
    membership.

    Lifecycle:

    {v
      Ready -> Running -> Completed -> Settled
      Ready -> Running -> Deferred
      Ready -> Running -> Blocked
    v}

    [Running] is a process claim, not a time lease. Process-worker startup
    recovers every [Running] and [Deferred] only after the prior process and all
    of its storage operations are known to have ended. Independently, a live
    lane abort releases only its exact same-[worker_epoch] [Running] claim via
    cancellation-protected recovery; it never recovers [Deferred] or another
    epoch. An ordinary candidate signal may run new Ready work but does not
    retry unrelated deferred work. *)

module Candidate = Keeper_board_attention_candidate

module Worker_epoch : sig
  type t

  val generate : unit -> t
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
end
(** Process-claim identity. UUID entropy distinguishes process workers only;
    scheduling and recovery never branch on its random contents. *)

type completed_item =
  { candidate_id : string
  ; judgment : Candidate.judgment
  }

type state =
  | Ready
  | Running of
      { worker_epoch : Worker_epoch.t
      ; started_at : float
      }
  | Deferred of
      { failure : Candidate.retryable_failure
      ; deferred_at : float
      }
  | Completed of
      { items : completed_item list
      ; completed_at : float
      }
  | Settled of { settled_at : float }
  | Blocked of
      { failure : Candidate.retryable_failure
      ; blocked_at : float
      }

type t =
  { partition_id : string
  ; keeper_name : string
  ; context_key : string
  ; candidate_ids : string list
  ; created_at : float
  ; state : state
  }

type transition =
  | Partition_completed of t
  | Partition_deferred of t
  | Partition_blocked of t

type claim_recovery =
  | Claim_released of t
  | Claim_already_transitioned of t

val state_to_string : state -> string
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

val load : base_path:string -> keeper_name:string -> (t list, string) result

val ensure_roots :
  base_path:string ->
  keeper_name:string ->
  Candidate.candidate list ->
  (t list, string) result
(** Persist one singleton root for each unassigned Pending candidate.
    Root creation time and claim order come from the exact candidate
    [(recorded_at, candidate_id)] identity, not worker observation time.
    Existing live leaf membership is validated as a one-to-one assignment;
    an exact historical root is idempotent even when a concurrently-settled
    candidate snapshot is stale. Returns only roots created by this call; an
    idempotent replay returns the empty list. *)

val recover_for_process_start :
  base_path:string -> keeper_name:string -> (int, string) result
(** At process-worker startup, change every [Running] and [Deferred] leaf to
    [Ready] and canonically compact the ledger to one latest row per partition.
    [Settled] receipts remain durable. This is the only whole-ledger compaction
    authority; ordinary signals append transitions and never retry unrelated
    deferred work. Returns the number of recovered partitions. *)

val claim_next :
  now:float ->
  worker_epoch:Worker_epoch.t ->
  base_path:string ->
  keeper_name:string ->
  (t option, string) result
(** Claim the oldest [Ready] partition. *)

val recover_claim_after_lane_abort :
  worker_epoch:Worker_epoch.t ->
  base_path:string ->
  partition:t ->
  (claim_recovery, string) result
(** Release a [Running] claim owned by [worker_epoch] back to [Ready] when its
    process lane aborts before returning a typed transition. If the durable
    partition already reached another state, report [Claim_already_transitioned]
    without rewriting it. A different live worker epoch is never revoked. *)

val complete :
  now:float ->
  worker_epoch:Worker_epoch.t ->
  base_path:string ->
  partition:t ->
  items:completed_item list ->
  (transition, string) result
(** Commit [Completed] only when returned IDs equal [candidate_ids] exactly. *)

val fail :
  now:float ->
  worker_epoch:Worker_epoch.t ->
  base_path:string ->
  partition:t ->
  Candidate.retryable_failure ->
  (transition, string) result
(** Runtime, prompt, provider, and response-contract failures become
    [Deferred] without timers or attempt counters. A response failure is not
    evidence of provider capacity and never authorizes partition splitting.
    Membership conflicts and impossible delivery failures become [Blocked]. *)

val completed :
  base_path:string -> keeper_name:string -> (t list, string) result

val settle_many :
  now:float ->
  base_path:string ->
  keeper_name:string ->
  partition_ids:string list ->
  (t list, string) result
(** Mark completed partitions [Settled] after candidate results have been
    durably applied. A replay of already-settled rows is accepted. *)

type fleet_summary

val fleet_summary : base_path:string -> fleet_summary
val pending_candidate_count : fleet_summary -> int
val status_reasons : fleet_summary -> string list
val operator_action_required : fleet_summary -> bool
val fleet_summary_schema : string
val fleet_summary_detail_fields : fleet_summary -> (string * Yojson.Safe.t) list
val empty_fleet_summary_detail_fields : (string * Yojson.Safe.t) list
(** Exact zero-value detail projection for an explicitly unavailable outer
    component. This owns the field shape; callers must also publish a non-OK
    typed status and must not present these values as an observed empty fleet. *)
val fleet_summary_fields : fleet_summary -> (string * Yojson.Safe.t) list
val fleet_summary_to_yojson : fleet_summary -> Yojson.Safe.t
val fleet_summary_json : base_path:string -> Yojson.Safe.t
(** Exact on-disk partition state for operators. [Blocked], [Deferred],
    [Completed] delivery obligations, and ledger read failures require
    operator action and make the component degraded. No process-local worker
    state is inferred here. *)

module For_testing : sig
  val path : base_path:string -> keeper_name:string -> string
end
