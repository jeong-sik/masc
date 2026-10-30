(** A derived read index over the keeper tool-call ledger (RFC-0437).

    The ledger is the authority. This holds only where each row lives and the
    fields the reads filter on, and it can be deleted at any time: the
    next read rebuilds it from the ledger. Hidden continuity records at the
    ledger root own generations independently of SQLite and are retired after
    the corresponding data file disappears. Changed/cold files verify their
    prefix content in the blocking worker without locking out appenders.
    This costs O(existing prefix bytes) on a changed ledger, including ordinary
    appends. The prefix is hashed at most once per advance, and again only when
    the file's inode/size/mtime/ctime changed during the scan. The observation
    a read verified is also written beside its continuity record, without
    fsync, so a later process skips the proof for a file that still reads
    exactly so against exactly that continuity; a missing or stale one means
    the prefix is read again. That post-scan check and the
    unchanged-observation fast path both assume the filesystem
    reports external modification in inode/size/mtime/ctime; neither is byte
    proof against metadata-preserving raw edits. Storage ownership optimization
    is separate.

    There is no gate. Each read advances the index to the ledger's
    current end before it queries, so "is the index current" is not a
    question the caller can ask. An index that cannot be opened, or whose
    schema version differs, is deleted and rebuilt rather than fallen back
    from, so there is one read path rather than two. *)

val database_path : ledger_dir:string -> string
(** Where the index for the ledger rooted at [ledger_dir] lives. *)

type position
type frontier
(** A set of append positions, one per dated file identity. Positions come
    from the authoritative ledger, not row counts or observation timestamps. *)

val empty_frontier : frontier
val merge_frontiers : frontier -> frontier -> frontier
val equal_frontiers : frontier -> frontier -> bool
val covers : frontier -> position -> bool
val frontier_to_json : frontier -> Yojson.Safe.t
val frontier_of_json : Yojson.Safe.t -> (frontier, string) result

type 'a positioned = { position : position; value : 'a }
type 'a batch =
  { frontier : frontier; retained : frontier; rows : 'a positioned list }

val rows_after :
  store:Dated_jsonl.t -> keeper_name:string -> after:frontier ->
  project:(Yojson.Safe.t -> 'a option) -> ('a batch, string) result
(** Read every row beyond [after], with no tail-size cutoff. Each row is read
    back from the ledger and handed to [project], which keeps what the caller
    needs (or [None] to skip the row); the parsed body is dropped before the
    next row is read, so a first read over a large ledger holds only the
    projections. Rows come back in descending file/append-offset order. This
    order does not infer chronology from provider or host timestamps. The
    returned frontier is the exact indexed snapshot queried, including files
    with no new rows. [retained] names the prior file positions still present;
    callers discard cached rows outside it after replacement, shrink or
    retention. A file gets a new generation when the index finds it replaced,
    shrunk or rewritten, so a position from the old generation covers none of
    its rows and the file is read from its beginning. Removed files disappear
    from the returned frontier. *)

val current_frontier :
  store:Dated_jsonl.t -> keeper_name:string -> (frontier, string) result
(** The current committed append positions, without reading row bodies.
    Pending appends must be flushed by the caller before recording a boundary. *)

val recent_rows :
  store:Dated_jsonl.t ->
  ?keeper_name:string ->
  n:int ->
  unit ->
  (Yojson.Safe.t list, string) result
(** The [n] most recent rows, oldest first, optionally only one keeper's.

    Unlike a tail scan this returns [n] rows whenever the ledger holds [n]
    for that keeper, so a short answer means the ledger is short - not that
    the read stopped early.

    Advances the index over what the ledger gained since the last call, then
    reads and validates the rows it names back out of the ledger. Replaced,
    shortened, or same-size modified files are reindexed in full. Earlier
    bytes of a growing inode must remain append-only; arbitrary in-place
    rewrites followed by regrowth are outside that ledger contract.

    Blocking index transactions run in a system thread for Eio callers.
    A read failure returns [Error] and leaves no index behind. *)

val by_execution_ids :
  store:Dated_jsonl.t ->
  keeper_name:string ->
  execution_ids:string list ->
  (Yojson.Safe.t list, string) result
(** Read every authoritative row matching the keeper and requested execution
    identities across the complete ledger, independent of the recent-row tail.
    Missing identities return no row. Repeated request IDs do not duplicate
    results, but multiple ledger rows with one execution ID are all returned;
    callers must reject ambiguous execution evidence rather than pick a row.

    Advances the index once for the batch, then validates each selected row's
    keeper, timestamp, and execution ID against its indexed identity. Uses the
    same rebuild and read-failure handling as {!recent_rows}. *)

val addressed_rows :
  store:Dated_jsonl.t -> codebase:string -> ?keeper_name:string ->
  limit:int -> offset:int -> unit -> (Yojson.Safe.t list, string) result
(** Exact newest-first page of producer-addressed canonical tool rows. Filtering
    precedes pagination and uses immutable journal metadata, never current Git.
    Invalid observation metadata or ambiguous execution identity is an error.
    The disposable index rebuilds these filters from canonical rows. *)

val fold_by_answer_source :
  store:Dated_jsonl.t -> keeper_name:string -> source_id:string ->
  init:'a -> f:('a -> Yojson.Safe.t -> ('a, string) result) -> ('a, string) result
(** Fold every authoritative Tool row carrying this exact answer input identity,
    independently of time windows or recent tails. The derived source index is
    rebuilt with the ledger and selected rows are revalidated. The callback runs
    in the blocking worker and must perform no Eio effects. No Tool bodies are
    retained between callback calls. This proves input membership, not causation. *)

val forget_for_ledger : ledger_dir:string -> unit
(** Drop the open handle for this ledger. The file stays; the next read
    reopens it. For a caller that has just removed or replaced the ledger
    directory. *)

module For_testing : sig
  val select_execution_sql : string
  (** Exact query used by the batch reader, for query-plan regression checks. *)
  val recent_rows :
    before_scan:(path:string -> unit) ->
    store:Dated_jsonl.t -> ?keeper_name:string -> n:int -> unit ->
    (Yojson.Safe.t list, string) result
  (** Inject a filesystem failure after the index transaction starts. The
      callback runs in the blocking worker and must not use Eio effects. *)

  val empty_digest : string
  val extend_digest : string -> string -> string
  val digest_prefix : path:string -> from:int -> until:int -> string -> string option
  (** The continuity witness: [extend_digest digest line] is the next link of
      the chain, and [digest_prefix ~path ~from ~until digest] continues
      [digest] over the complete lines of [path] from [from], answering
      [None] unless a line ends exactly at [until]. Continuity records on disk
      hold these values, so a change to either changes what every saved
      record matches. *)

  val blocking : (unit -> 'a) -> 'a
  (** Where the index does its file and SQLite work: from an Eio fiber, a
      system thread started from a CPU pool domain when a pool is installed,
      so the work never holds the calling domain's runtime lock. *)
end
