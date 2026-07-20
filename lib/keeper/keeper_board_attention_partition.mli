(** Durable, capacity-agnostic Board-attention judgment partitions.

    Every currently-unassigned non-terminal candidate receives one singleton root.
    A candidate is the irreducible work identity until the dispatched Provider
    exposes typed actual-wire split authority. No byte count, token estimate,
    wall-clock expiry, retry counter, or configured batch cap chooses
    membership. *)

module Candidate = Keeper_board_attention_candidate
module Failure = Keeper_board_attention_failure

module Worker_epoch : sig
  type t

  val generate : unit -> t
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

type completed_item =
  { candidate_id : string
  ; judgment : Candidate.judgment
  }

type blocked_reason =
  | Candidate_membership_conflict of string
  | Durable_partition_invariant of string
  | Judgment_blocked of Failure.blocked

type state =
  | Ready
  | Running of
      { worker_epoch : Worker_epoch.t
      ; started_at : float
      }
  | Deferred of
      { failure : Failure.retryable
      ; deferred_at : float
      }
  | Completed of
      { item : completed_item
      ; completed_at : float
      }
  | Settled of { settled_at : float }
  | Blocked of
      { reason : blocked_reason
      ; blocked_at : float
      }

type t = private
  { partition_id : string
  ; keeper_name : string
  ; context_key : Candidate.Context_key.t
  ; candidate_id : string
  ; created_at : float
  ; state : state
  }

type completion =
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
  (int, string) result
(** Persist one deterministic singleton root for each unassigned [Pending] or
    [Judged]
    candidate and return the number created by this transaction. Existing live
    membership is validated as one-to-one. *)

val recover_for_process_start :
  base_path:string -> keeper_name:string -> (int, string) result
(** Release prior-process [Running] rows to [Ready] in one rewrite. [Deferred]
    rows retain their exact retry requirement; process restart is not retry
    authority. *)

val release_due_provider_retries :
  now:float -> base_path:string -> keeper_name:string -> (int, string) result
(** Release only [Deferred] rows whose typed Provider retry-after deadline has
    been reached. No local delay or retry counter is synthesized. *)

val next_provider_retry_deadline :
  base_path:string -> keeper_name:string -> (float option, string) result
(** Earliest exact Provider-authored retry deadline, if any. Deferred rows
    requiring another typed state change are intentionally absent. *)

val claim_next :
  now:float ->
  worker_epoch:Worker_epoch.t ->
  base_path:string ->
  keeper_name:string ->
  (t option, string) result
(** Claim the oldest [Ready] root. [started_at] is observation only, never a
    lease or timeout authority. *)

val recover_claim_after_lane_abort :
  worker_epoch:Worker_epoch.t ->
  base_path:string ->
  partition:t ->
  (claim_recovery, string) result

val complete :
  now:float ->
  worker_epoch:Worker_epoch.t ->
  base_path:string ->
  partition:t ->
  item:completed_item ->
  (completion, string) result
(** Commit [Completed] only for the exact singleton candidate identity. *)

val defer :
  now:float ->
  worker_epoch:Worker_epoch.t ->
  base_path:string ->
  partition:t ->
  Failure.retryable ->
  (completion, string) result

val block :
  now:float ->
  worker_epoch:Worker_epoch.t ->
  base_path:string ->
  partition:t ->
  blocked_reason ->
  (completion, string) result

val completed : base_path:string -> keeper_name:string -> (t list, string) result

val settle :
  now:float -> base_path:string -> partition:t -> (t, string) result
(** Idempotently mark one [Completed] root [Settled] after its candidate result
    and delivery obligation have been durably applied. *)

module For_testing : sig
  val path : base_path:string -> keeper_name:string -> string
end
