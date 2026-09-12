(** A derived read index over the keeper tool-call ledger (RFC-0437).

    The ledger is the authority. This holds only where each row lives and the
    fields the reads filter on, and it can be deleted at any time: the
    next read rebuilds it from the ledger.

    There is no gate. Each read advances the index to the ledger's
    current end before it queries, so "is the index current" is not a
    question the caller can ask. An index that cannot be opened, or whose
    schema version differs, is deleted and rebuilt rather than fallen back
    from, so there is one read path rather than two. *)

val database_path : ledger_dir:string -> string
(** Where the index for the ledger rooted at [ledger_dir] lives. *)

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
end
