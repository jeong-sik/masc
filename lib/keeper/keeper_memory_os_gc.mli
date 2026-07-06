(** Deterministic garbage collection for Memory OS facts. *)

open Keeper_memory_os_types

type gc_report =
  { total_input : int
  ; ttl_expired : int
  ; ttl_expired_ephemeral : int
  ; ttl_expired_non_ephemeral : int
  ; ttl_expired_by_category : (string * int) list
  ; dedup_removed : int
  ; written : int
  ; dry_run : bool
  }

exception Fact_store_corrupt of string

(** [ttl_expired ~now fact] is [not (fact_is_current ~now fact)]: expiry runs
    on the same effective horizon ([fact_effective_valid_until] — explicit
    [valid_until], or the RFC-0259 P7 legacy [External_state] horizon) that the
    writer cap ([partition_expired]) and recall use, so cap, recall, and GC
    cannot disagree on what is expired. *)
val ttl_expired : now:float -> fact -> bool

(** Run the deterministic forgetting sweep for one keeper: hard-expire facts past
    their effective horizon, then dedup duplicate claims keeping the
    most-recently-verified, and (unless [dry_run]) rewrite the store atomically.

    The whole read-modify-rewrite runs under [File_lock_eio.with_lock] on the
    keeper's [facts_path] — the same lock the librarian write path and the
    consolidation runtime hold — so GC cannot lose-update a concurrent keeper
    write. Must therefore be called inside an Eio context. Reads strictly: a
    malformed JSONL row raises [Fact_store_corrupt] and leaves the store
    untouched rather than dropping the bad row and overwriting the survivors. *)
val run_gc
  :  ?dry_run:bool
  -> keeper_id:string
  -> now:float
  -> unit
  -> gc_report

val run_gc_for_keepers_dir
  :  keepers_dir:string
  -> ?dry_run:bool
  -> keeper_id:string
  -> now:float
  -> unit
  -> gc_report
