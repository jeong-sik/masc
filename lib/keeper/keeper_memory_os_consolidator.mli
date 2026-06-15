(** Keeper_memory_os_consolidator — RFC-0244 Tier 2 cross-keeper consolidation.

    Reads per-keeper Tier-1 stores read-only and promotes claims corroborated by
    [>= min_keepers] distinct keepers (above [threshold], on [categories]) into
    the shared Tier-2 store ([Keeper_memory_os_types.shared_store_id]). Additive:
    it never mutates a keeper's own store. Pure and deterministic — [promote_facts]
    is a function of its inputs, emitted in normalized-claim order. *)

open Keeper_memory_os_types

(** Categories shared across keepers by default ([fact]; [constraint]). Anything
    else is default-denied as keeper- or task-local. *)
val default_promote_categories : string list

(** Minimum confidence for an observation to count as corroboration. *)
val default_confidence_threshold : float

(** Minimum distinct keepers required before a claim is shared (2). *)
val default_min_keepers : int

type report =
  { keepers_scanned : int
  ; claims_considered : int
  ; promoted : int
  ; dry_run : bool
  }

(** Pure core: given [keeper_facts] (each keeper's Tier-1 facts), return
    [(claims_considered, shared_facts)]. [shared_facts] is in normalized-claim
    order; each carries [observed_by] = its sorted contributing keeper set and a
    noisy-OR confidence over the per-keeper best confidences. No IO; [now] sets
    the shared facts' [last_verified_at]. *)
val promote_facts
  :  ?categories:string list
  -> ?threshold:float
  -> ?min_keepers:int
  -> now:float
  -> keeper_facts:(string * fact list) list
  -> unit
  -> int * fact list

(** IO-driven sweep: read each keeper's Tier-1 store (the [shared_store_id] is
    filtered out of [keeper_ids]), consolidate, and unless [dry_run] rewrite the
    shared store atomically. *)
val run
  :  ?dry_run:bool
  -> ?categories:string list
  -> ?threshold:float
  -> ?min_keepers:int
  -> keeper_ids:string list
  -> now:float
  -> unit
  -> report
