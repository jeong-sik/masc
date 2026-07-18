(** Durable, capacity-agnostic Board-attention judgment partitions.

    A root partition contains every currently-unassigned Pending candidate in
    one exact persisted Keeper-context cohort. No candidate-count, byte-count,
    token estimate, wall-clock expiry, or attempt budget chooses its size.

    Lifecycle:

    {v
      Ready -> Running -> Completed -> Settled
                         -> Split (two Ready children)
                         -> Deferred
                         -> Blocked
    v}

    [Running] is a process claim, not a time lease. A lane actor recovers it
    to [Ready] only after the prior actor is known to have ended or on process
    startup. [Deferred] is resumed only by a new durable lane signal or process
    startup. *)

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
  | Split of
      { failure : Candidate.retryable_failure
      ; left_partition_id : string
      ; right_partition_id : string
      ; split_at : float
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
  ; parent_partition_id : string option
  ; keeper_name : string
  ; context_key : string
  ; candidate_ids : string list
  ; created_at : float
  ; state : state
  }

type transition =
  | Partition_completed of t
  | Partition_split of
      { parent : t
      ; left : t
      ; right : t
      }
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
(** Persist one root for each exact context cohort among unassigned Pending
    candidates. Candidate order is [(recorded_at, candidate_id)]. Existing
    live leaf membership is validated as a one-to-one assignment. *)

val recover_and_resume :
  base_path:string -> keeper_name:string -> (int, string) result
(** Change every [Running] and [Deferred] leaf to [Ready] in one durable
    rewrite. The caller must own the keeper lane actor lifecycle. Returns the
    number of recovered rows. *)

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
(** A response-contract failure deterministically bisects a non-singleton
    partition by stable member order. A singleton response failure and any
    membership conflict become [Blocked]. Runtime, prompt, and provider
    failures become [Deferred] without timers or attempt counters. *)

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

val fleet_summary_json : base_path:string -> Yojson.Safe.t
(** Exact on-disk partition state for operators. [Blocked], [Deferred], and
    ledger read failures require operator action and make the component
    degraded. No process-local worker state is inferred here. *)

module For_testing : sig
  val path : base_path:string -> keeper_name:string -> string
end
