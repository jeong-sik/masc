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
  | Explicit_retract

type source =
  { kind : source_kind
  ; trace_id : string
  }

(** A proposed derived fact that did not survive truth maintenance because no
    complete proof path remained current. [missing_premise_ids] is the union
    of premises absent from the maintained fixed point across its derivations. *)
type support_invalidation =
  { fact : Keeper_memory_os_types.fact
  ; missing_premise_ids : string list
  }

type change =
  { added : Keeper_memory_os_types.fact list
  ; removed : Keeper_memory_os_types.fact list
  ; retained : int
  ; invalidated : support_invalidation list
  }

type upsert_error =
  | Unsupported_derivation of support_invalidation
  | Upsert_persistence_failed of string

val upsert_error_to_string : upsert_error -> string

type retract_error =
  | Retract_memory_id_invalid
  | Retract_reason_empty
  | Retract_fact_not_found of string
  | Retract_persistence_failed of string

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
  | Journal_quarantined of
      { recorded_at : float
      ; rejection : string
      ; rejected_path : string
      }
      (** The snapshot on disk could not be decoded, so a writer moved it to
          [rejected_path] and continued from fresh state. [rejection] is the
          decoder's own account of what it refused. Neither a pass that
          committed nor a pass that failed: the write that follows this line
          succeeds, and the revision restarts at one. *)

val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

(** Append-only sidecar recording one line per librarian pass and one per
    quarantined snapshot, each tagged with an [outcome]. A committed line
    carries
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
    build cannot parse is [Error] with the reason rather than being dropped.
    A missing journal file is an empty list, which is why the result is a list
    and not [(list, string) result]. *)
val read_journal_tail :
  keepers_dir:string
  -> keeper_id:string
  -> limit:int
  -> (journal_entry, string) result list

(** Dashboard projection of the last [limit] lines. Every row carries a
    producer-stable [structural_id] derived from the keeper and its absolute
    nonblank journal-line number, including rows this build cannot decode. *)
val read_journal_tail_projection :
  keepers_dir:string -> keeper_id:string -> limit:int -> Yojson.Safe.t list

val list_keeper_ids_for_keepers_dir : keepers_dir:string -> string list

val read_for_keepers_dir :
  keepers_dir:string -> keeper_id:string -> (t option, string) result

val apply_disposition
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?dropped_statements:Keeper_memory_os_types.dropped_statement list
  -> keepers_dir:string
  -> keeper_id:string
  -> now:float
  -> source:source
  -> retained_memory_ids:string list
  -> new_claims:Keeper_memory_os_types.fact list
  -> unit
  -> (t, string) result
(** Apply a librarian's decision to whatever the snapshot holds when the lock
    is taken.

    The librarian decides three things about the facts it was shown: keep this
    one, retire that one for the reason in [dropped_statements], add these new
    claims. Those are the decision. The whole-set list it also carries is a
    projection of them against the snapshot it read, and writing that
    projection is what forced the write to demand nothing had changed
    meanwhile — a keeper recording one fact of its own during the pass threw
    the whole pass away.

    A fact the decision never mentions is one the librarian never saw, so it is
    left alone. A retired fact is retired even if the keeper re-observed it
    during the pass: the judgment was about the claim, and a re-observation
    does not answer it.

    [retained_memory_ids] is the librarian's explicit "keep" list. It is not
    read here — keeping is what happens to anything not retired — but it is
    required, because a caller that cannot name what it kept has not made a
    total decision, and totality is what stops silent forgetting
    ({!Keeper_librarian.selection}). *)

val replace
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?dropped_statements:Keeper_memory_os_types.dropped_statement list
  -> keepers_dir:string
  -> keeper_id:string
  -> expected_revision:int option
  -> now:float
  -> source:source
  -> facts:Keeper_memory_os_types.fact list
  -> unit
  -> (t, string) result
(** Atomically replace the complete current snapshot only when its revision
    still equals [expected_revision]. Concurrently changed state fails closed
    and is not overwritten.

    Existing state this build cannot decode is moved aside and the write
    continues from fresh state, with the decoder's own account recorded as a
    [Journal_quarantined] line. Every writer reads before it writes, so
    refusing to write over an undecodable file left the keeper's memory both
    unreadable and unwritable for good. The moved-aside bytes are kept, never
    deleted. An [expected_revision] of [Some _] still fails after a
    quarantine, because a caller cannot have read a revision from a file that
    does not decode.

    [dropped_statements], when present, is the writer's own account of every
    drop in this commit (the librarian's totality output) and is recorded on
    the journal line only — the snapshot codec never stores it. Omission
    means the writer makes no drop-reason statements, not that nothing was
    dropped. *)

val upsert_fact
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> keepers_dir:string
  -> keeper_id:string
  -> now:float
  -> source:source
  -> Keeper_memory_os_types.fact
  -> (t, upsert_error) result
(** Atomically insert or replace one explicit keeper-authored fact while
    preserving the rest of the current snapshot. A matching identity (same
    claim bytes) is a re-observation, not a duplicate: the authoritative
    [first_seen] and the original [origin] are preserved (an injected copy
    re-observing an authored row must not repaint it), [last_seen] moves to
    the later of the two, and [reinforcement] counts the re-observation —
    the byte-identical reinjection loop accumulates a count, not rows. The
    basis join preserves an existing observation, promotes a derived fact
    re-observed directly to an observation, replaces the premise set for an
    existing rule identity, and appends a distinct rule identity.
    It never evicts an existing fact to admit the incoming fact; no local
    importance, recency, budget, or echo heuristic changes truth.

    A derived incoming fact commits only when it survives support maintenance
    in the same locked update. Missing support is a typed
    [Unsupported_derivation] and writes no snapshot or journal revision. *)

val retract_fact
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> keepers_dir:string
  -> keeper_id:string
  -> now:float
  -> source:source
  -> memory_id:string
  -> reason:string
  -> unit
  -> (t, retract_error) result
(** Atomically retract one exact ordinary-current fact and remove every derived
    fact that no longer has a complete support path. The direct target and its
    reason are written to the same journal commit as the resulting snapshot;
    cascaded removals are represented by [change.invalidated]. Invalid input
    and a missing target fail before any snapshot or journal write. *)

val to_json : t -> Yojson.Safe.t

(** {1 Boot-time reconcile} *)

type boot_reconcile_outcome =
  | Snapshot_absent
  | Snapshot_readable
  | Snapshot_quarantined of
      { rejection : string
      ; rejected_path : string
      }

(** Decode one keeper's current snapshot with this build's decoder and, when
    it is refused, move the bytes to a fresh [.rejected-<now>] path and
    journal the quarantine -- exactly what a writer would do on its next
    commit, done once at boot under the same locks. [Error] names a snapshot
    that was refused but could not be moved aside; it stays in place. *)
val quarantine_undecodable_for_keepers_dir
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> keepers_dir:string
  -> keeper_id:string
  -> now:float
  -> unit
  -> (boot_reconcile_outcome, string) result

(** How the basis of a claim seen again combines with the stored one: an
    observation outranks a derivation, a Board reference outranks the
    transcript, and two Board references keep the first. Pure; exposed so the
    rule is pinned by a test. *)
val merge_basis
  :  Keeper_memory_os_types.basis
  -> Keeper_memory_os_types.basis
  -> Keeper_memory_os_types.basis
