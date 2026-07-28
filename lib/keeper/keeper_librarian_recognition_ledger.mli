(** Keeper_librarian_recognition_ledger — evidence for recognition writes.

    masc#26122: every applied librarian recognition pass persists one dated
    JSONL row carrying the exact store snapshot the model saw, the typed
    operation list it returned, the per-operation structural dispositions,
    and the resulting store. Before/After is always reconstructible from
    disk. Append failures degrade to a warning and never propagate into the
    turn.

    Row size is O(store) by design — the issue's anti-black-box requirement
    persists both full snapshots, deliberately unlike the recall ledger's
    delta rows (whose materialization needs a replay chain). The bound is
    structural, not a cap: the store itself is kept small by recognition
    (Forget/Merge) plus the consolidation pass, an empty-operation pass
    writes no row at all ([Nothing_recognized]), and dated files fall to
    [prune_older_than] with the other JSONL ledgers. *)

open Keeper_memory_os_types

(** [<masc_root>/librarian_recognition] — the Dated_jsonl base directory. *)
val base_dir : masc_root:string -> string

(** Pure row serializer (exposed for tests). *)
val to_json
  :  keeper_id:string
  -> trace_id:string
  -> generation:int
  -> store_before:fact list
  -> operations:Keeper_librarian_recognition.operation list
  -> dispositions:Keeper_librarian_recognition.disposition list
  -> store_after:fact list
  -> now:float
  -> unit
  -> Yojson.Safe.t

(** Append one recognition evidence row. Write failure logs and returns. *)
val append
  :  masc_root:string
  -> keeper_id:string
  -> trace_id:string
  -> generation:int
  -> store_before:fact list
  -> operations:Keeper_librarian_recognition.operation list
  -> dispositions:Keeper_librarian_recognition.disposition list
  -> store_after:fact list
  -> now:float
  -> unit
  -> unit

(** Drop dated files older than [retention_days]. For server maintenance. *)
val prune_older_than
  :  masc_root:string
  -> retention_days:int
  -> (int, unit) result
