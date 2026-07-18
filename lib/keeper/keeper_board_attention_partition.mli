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

    [Running] is a process claim, not a time lease. It is recovered to [Ready]
    only at process-worker startup, after the prior process and all of its
    storage operations are known to have ended. At that boundary, [Deferred]
    is also recovered. An ordinary candidate signal may run new Ready work but
    does not retry an unrelated Deferred partition. *)

module Candidate = Keeper_board_attention_candidate

type completed_item =
  { candidate_id : string
  ; judgment : Candidate.judgment
  }

type state =
  | Ready
  | Running of
      { worker_epoch : string
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

val state_to_string : state -> string
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

val load : base_path:string -> keeper_name:string -> (t list, string) result

val ensure_roots :
  now:float ->
  base_path:string ->
  keeper_name:string ->
  Candidate.candidate list ->
  (t list, string) result
(** Persist one singleton root for each unassigned Pending candidate.
    Candidate order is [(recorded_at, candidate_id)]. Existing live leaf
    membership is validated as a one-to-one assignment. *)

val recover_for_process_start :
  base_path:string -> keeper_name:string -> (int, string) result
(** Change every [Running] and [Deferred] leaf to [Ready] in one durable
    rewrite at process-worker startup. Ordinary candidate signals must not use
    this operation to retry unrelated deferred work. Returns the number of
    recovered rows. *)

val claim_next :
  now:float ->
  worker_epoch:string ->
  base_path:string ->
  keeper_name:string ->
  (t option, string) result
(** Claim the oldest [Ready] partition. *)

val complete :
  now:float ->
  worker_epoch:string ->
  base_path:string ->
  partition:t ->
  items:completed_item list ->
  (transition, string) result
(** Commit [Completed] only when returned IDs equal [candidate_ids] exactly. *)

val fail :
  now:float ->
  worker_epoch:string ->
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
val fleet_summary_fields : fleet_summary -> (string * Yojson.Safe.t) list
val fleet_summary_to_yojson : fleet_summary -> Yojson.Safe.t
val fleet_summary_json : base_path:string -> Yojson.Safe.t
(** Exact on-disk partition state for operators. [Blocked], [Deferred], and
    ledger read failures require operator action and make the component
    degraded. No process-local worker state is inferred here. *)

module For_testing : sig
  val path : base_path:string -> keeper_name:string -> string
end
