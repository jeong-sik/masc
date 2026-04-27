(** Memory_jsonl — Session-based JSONL backend for OAS Memory.long_term_backend.

    Each session gets its own .jsonl file under
    [<base_dir>/memory/<agent_name>/<session_id>.jsonl]. Lines are
    append-only; the latest entry per key wins on read. Tombstones
    (value=null) mark removals. *)

val make_backend :
  base_dir:string ->
  agent_name:string ->
  session_id:string ->
  Oas.Memory.long_term_backend
(** [make_backend ~base_dir ~agent_name ~session_id] builds a
    {!Oas.Memory.long_term_backend} that persists/retrieves/removes/queries
    against the per-session JSONL file. Persist and remove append; retrieve
    and query fold the file with last-write-wins semantics. Errors from the
    underlying I/O are logged and surfaced through the backend's [Result]
    return types ([persist]/[remove]/[batch_persist]) or as empty
    [retrieve]/[query] results.

    Files exceeding 50 MB log a warning but are still read. Individual
    values exceeding 1 MB are truncated and re-wrapped as JSON strings. *)
