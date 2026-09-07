(** A derived read index over the keeper tool-call ledger (RFC-0437).

    The ledger is the authority. This holds only where each row lives and the
    two fields the reads filter on, and it can be deleted at any time: the
    next read rebuilds it from the ledger.

    There is no gate. {!recent_rows} advances the index to the ledger's
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
    reads the rows it names back out of the ledger. A read failure returns
    [Error] and leaves no index behind. *)

val forget_for_ledger : ledger_dir:string -> unit
(** Drop the open handle for this ledger. The file stays; the next read
    reopens it. For a caller that has just removed or replaced the ledger
    directory. *)
