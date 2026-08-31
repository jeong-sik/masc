(** Keeper-owned ordinary current Memory OS snapshot.

    This is the persistence authority for LLM-selected and source-unbound
    facts. Source-bound explicit claims live in
    [Keeper_memory_source_current]. A missing file means fresh empty state.
    Historical facts/event JSONL files, episode directories, and alternate
    store layouts are never read.

    Librarian updates replace the complete current fact set. The same atomic
    write records the exact added/removed delta that the dashboard projects.
    Recall reads [facts] from this snapshot directly; it does not rank, trim, or
    select records. *)

type source_kind =
  | Librarian
  | Explicit_write

type source =
  { kind : source_kind
  ; trace_id : string
  }

type change =
  { added : Keeper_memory_os_types.fact list
  ; removed : Keeper_memory_os_types.fact list
  ; retained : int
  }

type t =
  { revision : int
  ; updated_at : float
  ; source : source
  ; facts : Keeper_memory_os_types.fact list
  ; change : change
  }

(** Why a librarian pass produced no snapshot. The journal is the only place
    this reaches disk, so the set is closed here rather than at the call site:
    a new failure mode has to name itself before it can be recorded, and
    [journal_entry_of_json] rejects a spelling this build does not know instead
    of folding it into a catch-all. *)
type librarian_failure_kind =
  | Prompt_render_failure
  | Execution_clock_unavailable
  | Exact_setup_failure
  | Exact_execution_failure
  | Domain_output_invalid
  | Memory_snapshot_write_failure
  | Runtime_context_unavailable
  | Lane_cancelled
      (** The pass started and was cancelled before it could commit. Recorded
          because a cancelled pass is otherwise indistinguishable in this
          journal from a turn on which the librarian never ran. *)
  | Unhandled_exception

(** One decoded journal line. A committed pass carries the revision it wrote;
    a failed pass has no revision, no source, and no change, so the two are
    separate constructors rather than one record with optional fields — a
    reader cannot mistake a failure for revision 0. *)
type journal_entry =
  | Journal_committed of
      { recorded_at : float
      ; revision : int
      ; source : source
      ; change : change
      ; dropped : Keeper_memory_os_types.dropped_statement list option
      }
  | Journal_failed of
      { recorded_at : float
      ; trace_id : string
      ; kind : librarian_failure_kind
      ; detail : string
      ; snapshot_present : bool
      ; cadence_deferred : bool
      }

val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

(** Append-only sidecar recording one line per librarian pass, committed or
    failed, each tagged with an [outcome]. A committed line carries
    [recorded_at]/[revision]/[source]/[change] plus [dropped] when the writer
    supplied drop-reason statements; the resulting fact count is derivable as
    [change.retained + length change.added] and is deliberately not duplicated.
    Never read on the turn path. *)
val journal_path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

(** Record a librarian pass that produced no snapshot. The commit path already
    journals its own line, so this is the failure counterpart and never runs
    after a successful commit. Append failure degrades to a warning: the pass
    has already failed and losing its record must not raise a second failure
    into the caller. Cancellation is never absorbed. *)
val append_librarian_failure :
  keepers_dir:string
  -> keeper_id:string
  -> now:float
  -> trace_id:string
  -> kind:librarian_failure_kind
  -> detail:string
  -> snapshot_present:bool
  -> cadence_deferred:bool
  -> unit

(** Last [limit] journal lines, oldest first, one result per line. A line this
    build cannot parse is [Error] with the reason rather than being dropped:
    lines written before the [outcome] tag existed report as such instead of
    being reinterpreted as commits. A missing journal file is an empty list,
    which is why the result is a list and not [(list, string) result]. *)
val read_journal_tail :
  keepers_dir:string
  -> keeper_id:string
  -> limit:int
  -> (journal_entry, string) result list

(** Wire projection of one line as read, including the ones this build could
    not decode. An undecodable line keeps its position and carries its reason,
    so a journal with a torn line is distinguishable from a shorter one. *)
val journal_line_to_json : (journal_entry, string) result -> Yojson.Safe.t

val list_keeper_ids_for_keepers_dir : keepers_dir:string -> string list

val read_for_keepers_dir :
  keepers_dir:string -> keeper_id:string -> (t option, string) result

val replace
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?dropped_statements:Keeper_memory_os_types.dropped_statement list
  -> ?max_fact_bytes:int
  -> keepers_dir:string
  -> keeper_id:string
  -> expected_revision:int option
  -> now:float
  -> source:source
  -> facts:Keeper_memory_os_types.fact list
  -> unit
  -> (t, string) result
(** Atomically replace the complete current snapshot only when its revision
    still equals [expected_revision]. Duplicate fact identities and an
    ordinary + source-bound rendered payload above [max_fact_bytes] reject
    before writing. Both stores share an outer commit lock, so the source
    reservation cannot change between measurement and commit. The bound is
    floored to 1 byte; its default is the Memory OS capacity policy. Existing
    state must parse as the exact current schema; malformed, non-current, or
    concurrently changed state fails closed and is not overwritten.

    [dropped_statements], when present, is the writer's own account of every
    drop in this commit (the librarian's totality output) and is recorded on
    the journal line only — the snapshot codec never stores it. Omission
    means the writer makes no drop-reason statements, not that nothing was
    dropped. *)

val upsert_fact
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?max_fact_bytes:int
  -> keepers_dir:string
  -> keeper_id:string
  -> now:float
  -> source:source
  -> Keeper_memory_os_types.fact
  -> (t, string) result
(** Atomically insert or replace one explicit keeper-authored fact while
    preserving the rest of the current snapshot. A matching identity is
    updated from the explicit incoming fact while preserving its original
    [first_seen]. The same combined rendered-payload byte budget and 1-byte
    floor as [replace] apply; no local importance, recency, or echo heuristic
    participates. *)

val to_json : t -> Yojson.Safe.t
