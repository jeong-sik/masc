(** Deterministic garbage collection for Memory OS facts. *)

open Keeper_memory_os_types

type gc_report =
  { total_input : int
  ; ttl_expired : int
  ; dedup_removed : int
  ; written : int
  ; dry_run : bool
  }

val ttl_expired : now:float -> fact -> bool

(** Run the deterministic forgetting sweep for one keeper: hard-expire facts past
    their Ephemeral TTL, then dedup duplicate claims keeping the
    most-recently-verified, and (unless [dry_run]) rewrite the store atomically.

    The whole read-modify-rewrite runs under [File_lock_eio.with_lock] on the
    keeper's [facts_path] — the same lock the librarian write path and the
    consolidation runtime hold — so GC cannot lose-update a concurrent keeper
    write. Must therefore be called inside an Eio context. Reads strictly: a
    malformed JSONL row raises [Invalid_argument] and leaves the store untouched
    rather than dropping the bad row and overwriting the survivors. *)
val run_gc
  :  ?dry_run:bool
  -> keeper_id:string
  -> now:float
  -> unit
  -> gc_report
