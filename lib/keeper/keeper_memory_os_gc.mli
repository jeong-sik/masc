(** Deterministic garbage collection for Memory OS facts. *)

open Keeper_memory_os_types

type gc_report =
  { total_input : int
  ; ttl_expired : int
  ; ttl_expired_ephemeral : int
  ; ttl_expired_non_ephemeral : int
  ; ttl_expired_by_category : (string * int) list
  ; written : int
  ; dry_run : bool
  }

exception Fact_store_corrupt of string

(** [ttl_expired ~now fact] is [not (fact_is_current ~now fact)]: expiry uses
    only the exact producer-supplied [valid_until]. *)
val ttl_expired : now:float -> fact -> bool

(** Run the deterministic explicit-expiry sweep for one keeper. It does not
    deduplicate, rank, or otherwise decide semantic forgetting. Unless [dry_run],
    it rewrites the store after removing facts past their exact [valid_until].

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
