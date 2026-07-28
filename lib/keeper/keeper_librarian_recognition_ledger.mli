(** Keeper_librarian_recognition_ledger — recoverable recognition publication.

    An applied pass appends a [prepared] row containing its exact before/after
    evidence before the fact rewrite, then a [committed] marker only after the
    rewrite succeeds. Readers must treat only committed publication ids as
    published; a stranded prepared row is explicit recoverable evidence, never
    a false claim that the fact store changed.

    Row size is O(store) by design — the issue's anti-black-box requirement
    persists both full snapshots, deliberately unlike the recall ledger's
    delta rows (whose materialization needs a replay chain). The bound is
    structural, not a cap: the store itself is kept small by recognition
    (Forget/Merge) plus the consolidation pass, an empty-operation pass writes
    no recognition row (its episode metadata is persisted separately), and
    dated files fall to [prune_older_than] with the other JSONL ledgers. *)

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
  -> now:float
  -> unit
  -> (unit, string) result

val append_committed
  :  masc_root:string
  -> publication_id:string
  -> keeper_id:string
  -> trace_id:string
  -> generation:int
  -> now:float
  -> unit
  -> (unit, string) result

type publication_failure =
  | Prepare_failed of string
  | Rewrite_failed of string
  | Commit_failed of string

(** Enforce prepare -> fact rewrite -> commit ordering. Exposed so runtime and
    fault-injection tests exercise the same publication state machine. *)
val publish
  :  prepare:(unit -> (unit, string) result)
  -> rewrite:(unit -> (unit, string) result)
  -> commit:(unit -> (unit, string) result)
  -> (unit, publication_failure) result

(** Drop dated files older than [retention_days]. For server maintenance. *)
val prune_older_than
  :  masc_root:string
  -> retention_days:int
  -> (int, unit) result
