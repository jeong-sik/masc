(** Keeper_librarian_recognition_ledger — recoverable recognition publication.

    An applied pass appends a [prepared] row containing its exact before/after
    evidence plus the complete episode payload before the fact rewrite, then a
    [committed] marker only after facts, the deterministic episode file, and the
    idempotent event are durable. Readers must treat only committed publication
    ids as published; a stranded prepared row is explicit recoverable evidence,
    never a false claim that the whole bundle was published. A per-keeper atomic
    pending pointer is the O(1) recovery authority; the dated JSONL remains the
    append-only audit history and is never scanned on the pre-turn hot path.
    Recovery reasserts the prepared row before terminalization so retention
    cannot leave a terminal-only audit. Audit rows are at-least-once across
    crash reconciliation; {!read_all_canonical} dedupes by
    [(publication_id, publication_state)].

    Row size is O(store) by design — the issue's anti-black-box requirement
    persists both full snapshots, deliberately unlike the recall ledger's
    delta rows (whose materialization needs a replay chain). The bound is
    structural, not a cap: the store itself is kept small by recognition
    (Forget/Merge) plus the consolidation pass. Empty-operation passes retain
    identical before/after snapshots so their episode/event metadata has the
    same recoverable contract. Dated files fall to [prune_older_than] with the
    other JSONL ledgers. *)

open Keeper_memory_os_types

(** [<masc_root>/librarian_recognition] — the Dated_jsonl base directory. *)
val base_dir : masc_root:string -> string

(** Stable id binding the exact recognition transition. *)
val publication_id
  :  keeper_id:string
  -> trace_id:string
  -> generation:int
  -> store_before:fact list
  -> operations:Keeper_librarian_recognition.operation list
  -> dispositions:Keeper_librarian_recognition.disposition list
  -> store_after:fact list
  -> episode:episode
  -> facts_rewrite_required:bool
  -> string

(** Pure serializers exposed for regression tests and audit consumers. *)
val prepared_to_json
  :  publication_id:string
  -> keeper_id:string
  -> trace_id:string
  -> generation:int
  -> store_before:fact list
  -> operations:Keeper_librarian_recognition.operation list
  -> dispositions:Keeper_librarian_recognition.disposition list
  -> store_after:fact list
  -> episode:episode
  -> facts_rewrite_required:bool
  -> now:float
  -> unit
  -> Yojson.Safe.t

val committed_to_json
  :  publication_id:string
  -> keeper_id:string
  -> trace_id:string
  -> generation:int
  -> now:float
  -> unit
  -> Yojson.Safe.t

val append_prepared
  :  masc_root:string
  -> publication_id:string
  -> keeper_id:string
  -> trace_id:string
  -> generation:int
  -> store_before:fact list
  -> operations:Keeper_librarian_recognition.operation list
  -> dispositions:Keeper_librarian_recognition.disposition list
  -> store_after:fact list
  -> episode:episode
  -> facts_rewrite_required:bool
  -> now:float
  -> unit
  -> (unit, string) result

type terminal_write_outcome =
  | Terminal_durable
  | Terminal_durable_marker_clear_uncertain of string

val append_committed
  :  masc_root:string
  -> publication_id:string
  -> keeper_id:string
  -> trace_id:string
  -> generation:int
  -> now:float
  -> unit
  -> (terminal_write_outcome, string) result

type recovery_outcome =
  | No_pending_publication
  | Recovered_committed of string * terminal_write_outcome
  | Recovered_aborted of string * terminal_write_outcome

(** Settle the one serialized pending publication against the canonical fact
    store while the caller holds the episode-bundle and facts locks. If current
    facts equal its [store_after] digest, idempotently ensure the prepared
    episode and event before appending the missing committed marker; if they
    equal [store_before] for a fact-mutating publication, append an aborted
    marker. A metadata-only publication has equal before/after digests and is
    completed rather than aborted. The exact prepared evidence is reasserted
    from the marker first, even when its prior dated row was pruned. Any third
    state fails closed. Repeated calls are logically idempotent because
    artifact writes are identity-checked, canonical audit reads dedupe physical
    retries, and terminal markers remove the per-keeper pointer. *)
val recover_pending
  :  masc_root:string
  -> keeper_id:string
  -> current_store:fact list
  -> now:float
  -> unit
  -> (recovery_outcome, string) result

type publication_failure =
  | Prepare_failed of string
  | Rewrite_failed of string
  | Episode_failed of string
  | Event_failed of string
  | Commit_failed of string

(** Enforce prepare -> fact rewrite -> episode -> event -> commit ordering.
    Exposed so runtime and fault-injection tests exercise the same publication
    state machine. *)
val publish
  :  prepare:(unit -> (unit, string) result)
  -> rewrite:(unit -> (unit, string) result)
  -> episode:(unit -> (unit, string) result)
  -> event:(unit -> (unit, string) result)
  -> commit:(unit -> (terminal_write_outcome, string) result)
  -> (terminal_write_outcome, publication_failure) result

(** Strict canonical audit fold. Physical rows are at-least-once; this reader
    exposes one chronological row per [(publication_id, publication_state)] and
    fails on malformed/unkeyed rows instead of silently changing evidence. *)
val read_all_canonical :
  masc_root:string -> (Yojson.Safe.t list, string) result

module For_testing : sig
  val terminal_outcome_of_remove_result :
    (unit, Keeper_fs.durable_remove_error) result
    -> (terminal_write_outcome, string) result
end

(** Drop dated files older than [retention_days]. For server maintenance. *)
val prune_older_than
  :  masc_root:string
  -> retention_days:int
  -> (int, unit) result
