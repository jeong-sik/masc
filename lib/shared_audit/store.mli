(** Shared_audit store — dated JSONL append-only store.

    Mirrors the storage pattern from [keeper_approval_queue.ml] and
    [keeper_crash_persistence.ml]. Entries are appended to
    [<base_dir>/YYYY-MM/DD.jsonl], one JSON object per line. The
    YYYY-MM/DD partitioning keeps individual files manageable and
    enables date-range queries via filesystem listing.

    The store maintains in-memory state for the latest entry's hash
    so [append] can chain automatically without re-reading the
    full log on each call. All stores whose [base_dir] resolves to the
    same canonical directory share one in-process writer owner: its
    cursor and cross-context durable lock make append one serialized
    read-write-update transaction across instances, Eio fibers,
    system threads, and Domains. The owner is initialized from the
    most recent JSONL file (if any) so sessions that resume an existing
    audit log continue the chain correctly.

    {b Single-process design}: this implementation does not orchestrate
    across processes. For multi-process audit (e.g., concurrent processes
    writing to the same log), a follow-up PR must add file-locking
    or a single-writer dispatcher.

    @stability Evolving
    @since 0.18.9 *)

type t

exception Corrupt_jsonl of {
  path : string;
  line_number : int;
  detail : string;
}
(** Raised when an audit JSONL reader encounters a malformed JSON value or an
    invalid audit envelope. Audit-chain corruption is fail-closed rather than
    skipped, and identifies the exact file and line. *)

exception Base_directory_replaced of {
  path : string;
  expected_device_id : int;
  expected_inode_id : int;
  actual_device_id : int option;
  actual_inode_id : int option;
}
(** Raised when the canonical audit directory no longer names the filesystem
    directory captured by [create]. A missing, non-directory, renamed, or
    replaced base directory is rejected before further audit I/O so an
    in-memory cursor cannot be applied to a different log. *)

val create : base_dir:string -> t
(** Create or open a store rooted at [base_dir]. The directory is
    created (with parents) if it does not exist. Stores for equivalent
    realpath-resolved directories share one in-process writer owner.
    A new owner loads the latest entry's hash from the newest non-empty
    partition; reopening an existing owner refreshes that cursor under its
    append lock. The canonical path and its filesystem identity are retained
    for all later I/O, so aliases cannot silently retarget a live writer and
    replacing the canonical directory fails closed. Each append opens and
    validates that directory, then resolves its partition and file relative to
    the validated directory descriptor; pathname replacement cannot redirect
    the write after validation. Thus [append] continues the chain across
    sessions. *)

val append :
  t ->
  category:string ->
  payload:Yojson.Safe.t ->
  Envelope.t
(** Append a new entry with [prev_hash] computed from the latest
    hash owned for this canonical base directory. Cursor read, durable
    append, and cursor update are serialized as one transaction across
    every in-process store instance. The write is bound to a freshly validated
    base-directory descriptor and does not use the process-wide pathname writer
    or mkdir caches. Returns the appended entry. Raises
    {!Base_directory_replaced} if the canonical directory identity changed. *)

val recent : t -> n:int -> Envelope.t list
(** Read the most recent [n] entries (chronologically increasing).
    Raises {!Corrupt_jsonl} when persisted audit evidence is malformed, and
    {!Base_directory_replaced} if the canonical directory identity changed. *)

val since : t -> ts:float -> Envelope.t list
(** Read all entries whose [ts] is >= the given timestamp.
    Raises {!Corrupt_jsonl} when persisted audit evidence is malformed. *)

val verify_chain : Envelope.t list -> (unit, int * string) result
(** Verify the [prev_hash] chain over a list of entries assumed in
    chronological order. Returns [Ok ()] if the chain is intact;
    [Error (idx, reason)] at the first broken link. The first entry
    must have [prev_hash = None]. *)

type verify_report = {
  entries_checked : int;
  (** Entries whose chain link verified before the first failure; equals
      the total on-disk entry count when the chain is intact. *)
  failure : (int * string) option;
  (** [Some (idx, reason)] at the first broken link; [None] when intact. *)
}

val verify : t -> verify_report
(** Read the full on-disk log and verify the [prev_hash] chain with
    {!verify_chain}. This is the runtime entry point that makes the chain
    more than a write-only cost: callers (e.g. the audit-integrity
    dashboard surface) run it against the persisted log and surface the
    result. Raises {!Corrupt_jsonl} when persisted audit evidence is
    malformed. *)

val base_dir : t -> string
(** Inspector for the base directory (mainly for tests). *)
