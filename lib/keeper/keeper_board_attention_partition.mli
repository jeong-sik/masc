(** Durable, capacity-agnostic Board-attention judgment partitions.

    Every currently-unassigned non-terminal candidate receives one singleton
    root. MASC owns candidate membership and this durable state machine. OAS
    owns admission, dispatch, and advancement; this module persists only opaque
    attempt provenance supplied by OAS. Runtime transitions append one
    cursor-fenced row. Only process-start recovery canonically compacts the
    history. *)

module Candidate = Keeper_board_attention_candidate

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

type exact_provenance =
  { slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  }
(** Opaque OAS attempt identity. MASC compares and persists these fields but
    never derives provider, model, tier, retry, or failover policy from them. *)

type running_progress =
  | Unbound
  | Bound of exact_provenance
  | Advancing of
      { failed : exact_provenance
      ; next : exact_provenance
      }

type blocked_reason =
  | Candidate_membership_conflict of string
  | Durable_partition_invariant of string
  | Exact_setup_unavailable of string
  | Exact_flow_replayed
  | Exact_execution_terminal
  | Domain_output_invalid of string
  | Execution_provenance_mismatch of string
  | Unexpected_worker_failure of string
  | Exact_execution_quarantined of running_progress

type state =
  | Ready
  | Running of
      { worker_epoch : Worker_epoch.t
      ; started_at : float
      ; progress : running_progress
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

type exact_write_outcome =
  | Fsync_completed
  | Visible_sync_unconfirmed of string

type exact_transition =
  { partition : t
  ; changed : bool
  ; write_outcome : exact_write_outcome
  }

type requeue_blocked_outcome =
  | Requeued of exact_transition
  | Generation_conflict of string

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
    [Judged] candidate. Existing live membership must remain one-to-one. *)

val recover_for_process_start :
  now:float -> base_path:string -> keeper_name:string -> (int, string) result
(** Canonically compact the append ledger. Only [Running Unbound] returns to
    [Ready]. [Bound] and [Advancing] executions become terminal
    [Blocked (Exact_execution_quarantined _)] and can never be redispatched.
    The return value is the number of Running roots terminalized or released.
    Old schema rows and non-tail malformed JSON are rejected without migration.
    A torn final append is truncated under the ledger lock. *)

val claim_next :
  now:float ->
  worker_epoch:Worker_epoch.t ->
  base_path:string ->
  keeper_name:string ->
  (t option, string) result
(** Claim the oldest [Ready] root as [Running Unbound]. [started_at] is
    observation only, never lease or retry authority. *)

val bind_before_dispatch :
  worker_epoch:Worker_epoch.t ->
  base_path:string ->
  partition:t ->
  provenance:exact_provenance ->
  (exact_transition, string) result
(** Cursor-fenced durable [before_dispatch] callback. The initial call moves
    [Unbound -> Bound]. After an exact [before_advance], only its retained
    [next] identity can move [Advancing -> Bound]. An idempotent call appends
    the same row again so only [Fsync_completed] authorizes OAS dispatch. *)

val record_before_advance :
  worker_epoch:Worker_epoch.t ->
  base_path:string ->
  partition:t ->
  failed:exact_provenance ->
  next:exact_provenance ->
  (exact_transition, string) result
(** Atomically persist [Bound failed -> Advancing {failed; next}] before OAS
    advances. The callback accepts no Provider failure, receipt phase, or
    dispatch count. Only [Fsync_completed] authorizes advancement. *)

val complete :
  now:float ->
  worker_epoch:Worker_epoch.t ->
  base_path:string ->
  partition:t ->
  item:completed_item ->
  (exact_transition, string) result
(** Commit [Completed] only from [Bound] when the candidate identity and all
    four opaque judgment provenance fields exactly match the durable binding.
    Only [Fsync_completed] confirms that the judgment can leave worker memory. *)

val complete_existing_judgment :
  now:float ->
  worker_epoch:Worker_epoch.t ->
  base_path:string ->
  partition:t ->
  item:completed_item ->
  (exact_transition, string) result
(** Atomically project a current-schema judgment already durable in the
    Candidate ledger from [Running Unbound] directly to [Completed]. This
    creates no dispatch binding; [Bound] and [Advancing] are rejected. The
    caller must inspect the exact write outcome. *)

val confirm_completed :
  base_path:string -> partition:t -> (exact_transition, string) result
(** Cursor-fenced reappend of an unchanged durable [Completed] row. The current
    ledger item must exactly match the supplied partition item. This allows a
    caller to retry local fsync confirmation without repeating exact execution
    or domain delivery. *)

val block :
  now:float ->
  worker_epoch:Worker_epoch.t ->
  base_path:string ->
  partition:t ->
  blocked_reason ->
  (exact_transition, string) result

val confirm_blocked :
  base_path:string -> partition:t -> (exact_transition, string) result

val requeue_blocked :
  base_path:string -> partition:t -> (requeue_blocked_outcome, string) result
(** Atomically move exactly the supplied [Blocked] generation to [Ready].
    A different durable generation is returned as [Generation_conflict];
    persistence and validation failures remain errors. *)

val confirm_ready :
  base_path:string -> partition:t -> (exact_transition, string) result
(** Reappend an unchanged [Ready] snapshot for fsync confirmation. This never
    converts a later [Blocked] generation back to [Ready]. *)

val completed : base_path:string -> keeper_name:string -> (t list, string) result

val settle :
  now:float -> base_path:string -> partition:t -> (t, string) result
(** Idempotently mark one [Completed] or terminal [Blocked] root [Settled]
    after its domain obligation or operator disposition has been applied. *)

module For_testing : sig
  val path : base_path:string -> keeper_name:string -> string
end
