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

type retraction =
  { memory_id : string
  ; reason : string
  }

type retract_batch_error =
  | Retract_batch_empty
  | Retract_batch_memory_id_invalid of { index : int }
  | Retract_batch_reason_empty of { index : int }
  | Retract_batch_duplicate_memory_id of string
  | Retract_batch_snapshot_sha256_invalid
  | Retract_batch_snapshot_conflict of
      { expected_revision : int
      ; observed_revision : int option
      ; expected_snapshot_sha256 : string
      ; observed_snapshot_sha256 : string option
      }
  | Retract_batch_fact_not_found of string
  | Retract_batch_plan_evidence_pending of
      { plan_id : string
      ; snapshot_revision : int
      ; snapshot_sha256 : string
      ; detail : string
      }
  | Retract_batch_persistence_failed of string

type t =
  { revision : int
  ; updated_at : float
  ; source : source
  ; facts : Keeper_memory_os_types.fact list
  ; change : change
  }

(** Identity of one selected durable completed-turn range. Boundary row
    identities distinguish restarted histories that reuse atom numbers and
    checkpoint digests. *)
type durable_range_id =
  { receipt_scope : string
      (** Stable runtime-cluster scope. Receipts for the same Keeper name in
          other clusters remain independently recoverable. *)
  ; trace_id : string
  ; history_start_boundary_line : int
  ; start_atom : int
  ; end_atom : int
  ; last_atom_digest : string
  ; end_boundary_line : int
  ; boundary_lines_seen : int
  }

(** Exact official-client boundaries consumed by one Memory commit. [turns]
    is nonempty, strictly ordered after [after_boundary_line]; its final row
    identifies the consumed end. *)
type official_range_id =
  { receipt_scope : string
  ; after_boundary_line : int
  ; turns : (int * Ids.Turn_ref.t) list
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

val librarian_failure_kind_to_string : librarian_failure_kind -> string

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

(** WAL sidecar joining each runtime cluster's typed durable completed-turn
    range identity to the exact shared Memory snapshot revision and bytes
    produced from it. *)
val durable_range_receipt_path : keepers_dir:string -> keeper_id:string -> string

(** Durable recovery evidence for one destructive ordinary-current batch. The
    file exists only between plan preparation and exact journal finalization,
    and is included in whole-Keeper purge. *)
val retraction_plan_receipt_path : keepers_dir:string -> keeper_id:string -> string

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
    producer-stable [structural_id] derived from the keeper and the byte offset
    its line starts at in the journal, including rows this build cannot
    decode. *)
val read_journal_tail_projection :
  keepers_dir:string -> keeper_id:string -> limit:int -> Yojson.Safe.t list

val keeper_id_of_filename : string -> string option
(** Parse this store's filename suffix without filesystem access. [None] means
    another filename kind; [Some id] is the exact stem, which may still require
    keeper-name validation by the discovery owner. *)

val list_keeper_ids_for_keepers_dir : keepers_dir:string -> string list

val read_for_keepers_dir :
  keepers_dir:string -> keeper_id:string -> (t option, string) result

val read_with_snapshot_sha256 :
  keepers_dir:string -> keeper_id:string -> ((t * string) option, string) result
(** Read one atomically replaced snapshot and return the lowercase SHA-256 of
    its exact stored bytes alongside the decoded value. The pair is one
    observation suitable for a later revision+hash CAS. *)

val snapshot_sha256 : t -> string
(** SHA-256 of the exact canonical bytes the writer stores for [t]. A
    successful exact cleanup can return the next CAS coordinate without a
    second read. *)

val committed_durable_range
  :  keepers_dir:string
  -> keeper_id:string
  -> receipt_scope:string
  -> (durable_range_id option, string) result
(** Return this runtime cluster's last completed-turn range whose receipt is still proved by the
    current Memory snapshot. A prepared receipt requires its exact snapshot
    revision and SHA-256. A committed receipt accepts that same snapshot or a
    higher parsed revision written later under the same store lock. Missing,
    lower, or same-revision/different-byte snapshots invalidate the receipt.
    Other cluster receipts share the sidecar but are not replaced by this
    scope's commit. *)

val committed_official_range
  :  keepers_dir:string
  -> keeper_id:string
  -> receipt_scope:string
  -> (official_range_id option, string) result
(** Same snapshot proof as [committed_durable_range], independently retained
    for official-client input in the shared receipt sidecar. *)

val apply_disposition
  :  ?on_committed:(t -> unit)
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?dropped_statements:Keeper_memory_os_types.dropped_statement list
  -> ?durable_range_id:durable_range_id
  -> ?official_range_id:official_range_id
  -> absorbed:Keeper_memory_os_types.absorbed_statement list
  -> keepers_dir:string
  -> keeper_id:string
  -> now:float
  -> source:source
  -> new_claims:Keeper_memory_os_types.fact list
  -> unit
  -> (t, string) result
(** Apply a librarian's decision to whatever the snapshot holds when the lock
    is taken.

    The librarian says what changes: retire this one for the reason in
    [dropped_statements], add these new claims. Keeping is what happens to
    everything else, here and in {!Keeper_librarian.selection}.

    It used to also carry a whole-set "keep" list. That list was never read
    here, and requiring it cost the librarian a correct restatement of every
    current identity on each pass, where one slip threw the pass away — which
    left "retain everything, drop nothing, claim nothing" as the one answer
    that always passed (RFC-0456).

    A fact the decision never mentions is left alone. A retired fact is retired
    even if the keeper re-observed it during the pass: the judgment was about
    the claim, and a re-observation does not answer it.

    [on_committed] observes the successful snapshot replacement before any
    later journal, receipt, unlock or notification can be interrupted. It runs
    once under the store locks and must only update caller-owned in-memory
    state: no I/O, yielding or exceptions. It is not a scheduling callback.

    [durable_range_id] and [official_range_id] join this disposition to the
    atom and official-client ranges that produced it. When both are present,
    both identities share the same snapshot revision and SHA-256. Each source
    kind retains its latest receipt per runtime scope. The store writes a prepared transaction receipt
    before replacing the snapshot and marks it committed afterwards. Recovery
    compares a prepared receipt with the exact snapshot SHA-256, so neither
    side of a process interruption is guessed.

    An [absorbed] fact that is still current leaves the snapshot too, and its
    row is appended to {!Keeper_memory_absorbed} under the lock, after the next
    snapshot is built and printed and right before it replaces the old one; if
    that append fails, nothing is committed (RFC-0456 §4.2). Required rather
    than defaulted: a caller that leaves it out would add the merged claim and
    keep every fact it absorbs current. *)

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
    re-observing an authored row must not repaint it) and [last_seen] moves to
    the later of the two; nothing is counted (RFC-0418). The
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

val retract_facts
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> keepers_dir:string
  -> keeper_id:string
  -> expected_revision:int
  -> expected_snapshot_sha256:string
  -> now:float
  -> source:source
  -> retraction list
  -> (t, retract_batch_error) result
(** Atomically retract a non-empty batch of exact ordinary-current facts.
    Every identity and reason is validated, identities must be unique, and the
    locked snapshot must have both [expected_revision] and the exact lowercase
    SHA-256 [expected_snapshot_sha256]. Every target must then be current
    before the one replacement is written. Consequently a validation, CAS, or
    missing-target failure removes none of the batch. Support invalidations are
    computed once from the complete post-retraction set and the exact direct
    reasons share the snapshot's journal commit. A prepared plan receipt is
    durable before replacement. Ordinary success is returned only after the
    exact journal entry is durable and the receipt is cleared; an interruption
    after replacement returns [Retract_batch_plan_evidence_pending] and the
    next locked writer reconciles that receipt before making another change. *)

val to_json : t -> Yojson.Safe.t

(** {1 Boot-time reconcile} *)

(** Move one keeper's current snapshot, which this build's decoder has already
    refused with [rejection], to a fresh [.rejected-<now>] path and journal the
    quarantine -- exactly what a writer would do on its next commit, done once
    at boot under the same locks after the operator accepted it (RFC-0420).
    [Ok] carries the path the bytes went to. [Error] names a snapshot that
    could not be moved; it stays in place. *)
val move_aside_for_keepers_dir
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> keepers_dir:string
  -> keeper_id:string
  -> now:float
  -> rejection:string
  -> unit
  -> (string, string) result

(** How the basis of a claim seen again combines with the stored one: an
    observation outranks a derivation, a Board reference outranks the
    transcript, and two Board references keep the first. Pure; exposed so the
    rule is pinned by a test. *)
val merge_basis
  :  Keeper_memory_os_types.basis
  -> Keeper_memory_os_types.basis
  -> Keeper_memory_os_types.basis
