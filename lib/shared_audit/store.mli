(** Shared_audit store — dated JSONL append-only store.

    Mirrors the storage pattern from [keeper_approval_queue.ml] and
    [keeper_crash_persistence.ml]. Entries are appended to
    [<base_dir>/YYYY-MM/DD.jsonl], one JSON object per line. The
    YYYY-MM/DD partitioning keeps individual files manageable and
    enables date-range queries via filesystem listing.

    The store maintains in-memory state for the latest entry's hash
    so [append] can chain automatically without re-reading the
    full log on each call. On creation, the latest hash is loaded
    from the most recent JSONL file (if any) so sessions that resume
    an existing audit log continue the chain correctly.

    {b Single-process design}: this implementation does not orchestrate
    across processes. For multi-process audit (e.g., concurrent keepers
    writing to the same log), a follow-up PR will add file-locking
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

val create : base_dir:string -> t
(** Create or open a store rooted at [base_dir]. The directory is
    created (with parents) if it does not exist. The latest entry's
    hash is loaded from the most recent JSONL file in [base_dir],
    so [append] continues the chain across sessions. *)

val append :
  t ->
  category:string ->
  payload:Yojson.Safe.t ->
  Envelope.t
(** Append a new entry with [prev_hash] computed from the latest
    on-disk entry. Returns the appended entry. *)

val recent : t -> n:int -> Envelope.t list
(** Read the most recent [n] entries (chronologically increasing).
    Raises {!Corrupt_jsonl} when persisted audit evidence is malformed. *)

val since : t -> ts:float -> Envelope.t list
(** Read all entries whose [ts] is >= the given timestamp.
    Raises {!Corrupt_jsonl} when persisted audit evidence is malformed. *)

val verify_chain : Envelope.t list -> (unit, int * string) result
(** Verify the [prev_hash] chain over a list of entries assumed in
    chronological order. Returns [Ok ()] if the chain is intact;
    [Error (idx, reason)] at the first broken link. The first entry
    must have [prev_hash = None]. *)

val base_dir : t -> string
(** Inspector for the base directory (mainly for tests). *)
