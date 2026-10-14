(** Per-keeper shared workspace memory reader cursor and immutable pending
    delivery state with deterministic retry and context-overflow bisection
    (RFC-shared-memory-appends-a-log-and-keepers-read-from-their-position). *)

type pending_delivery = {
  from_seq : Workspace_memory_log.seq;
  to_seq : Workspace_memory_log.seq;
  digest_sha256 : string;
  entry_count : int;
}

type reader_state = {
  keeper : string;
  acknowledged_seq : Workspace_memory_log.seq;
  pending : pending_delivery option;
}

type turn_outcome =
  | Turn_succeeded
  | Turn_failed_transient
  | Context_overflow

type error =
  | No_pending_delivery
  | Digest_mismatch of { expected : string; actual : string }
  | Missing_committed_entries of
      { from_seq : Workspace_memory_log.seq
      ; to_seq : Workspace_memory_log.seq
      }
  | Invalid_reader_state of string
  | Malformed_json of string
  | Io_error of string

val error_to_string : error -> string

val init
  :  keeper:string
  -> ?acknowledged_seq:Workspace_memory_log.seq
  -> unit
  -> reader_state
(** Create an initial reader state for [keeper] with [pending = None] and
    [acknowledged_seq] defaulting to [0]. *)

val compute_digest : Workspace_memory_log.change_entry list -> string
(** Compute the canonical lowercase hex SHA-256 digest of a slice of
    [change_entry] records. *)

val plan_delivery
  :  reader_state
  -> committed:Workspace_memory_log.change_entry list
  -> ?max_entries:int
  -> unit
  -> reader_state * Workspace_memory_log.change_entry list
(** Deterministically plan the next slice of committed entries to deliver:
    - When [pending] is [Some p], re-deliver the exact committed slice
      [[p.from_seq .. p.to_seq]] after verifying [p.digest_sha256].
    - When [pending] is [None], select committed entries with
      [seq > acknowledged_seq] (up to [max_entries] when specified),
      compute [digest_sha256], and record [pending]. *)

val apply_turn_outcome
  :  reader_state
  -> committed:Workspace_memory_log.change_entry list
  -> turn_outcome
  -> (reader_state, error) result
(** Apply the outcome of a turn that carried [reader_state.pending]:
    - [Turn_succeeded]: advance [acknowledged_seq <- p.to_seq] and clear
      [pending <- None].
    - [Turn_failed_transient]: preserve [acknowledged_seq] and keep
      [pending] unchanged for deterministic retry.
    - [Context_overflow]: bisect the pending slice to
      [half = max 1 (p.entry_count / 2)], recomputing [to_seq] and
      [digest_sha256] for the first half without losing position. *)

val reader_state_to_yojson : reader_state -> Yojson.Safe.t
val reader_state_of_yojson : Yojson.Safe.t -> (reader_state, error) result

val reader_path : base_path:string -> keeper:string -> string
(** Path to [<base_path>/.masc/workspace-memory/readers/<keeper>.json]. *)

val save_reader_state : path:string -> reader_state -> (unit, error) result
(** Atomically persist [reader_state] as JSON at [path]. *)

val load_reader_state : path:string -> (reader_state, error) result
(** Load and validate [reader_state] from [path]. *)
