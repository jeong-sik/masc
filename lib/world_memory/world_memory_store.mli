(** Lock-free MVCC SQLite WAL store for MASC World Memory
    ([<base_path>/.masc/world_memory.db]).

    All SQLite access runs off the main Eio domain via
    {!Domain_pool_ref.submit_io_or_inline}. SQLite WAL mode guarantees that
    concurrent Keepers and MCP resource readers NEVER block writers or sibling
    Keepers — ZERO workspace-global {!File_lock_eio} locks! *)

open World_memory_types

type store_error =
  | Db_unavailable of string
  | Invalid_state of string

val error_to_string : store_error -> string

val database_filename : string
val db_path : base_path:string -> string
val exists : base_path:string -> bool

(** {1 Lock-Free MVCC Reads} *)

val list_facts
  :  ?include_inactive:bool
  -> base_path:string
  -> unit
  -> (world_fact list, store_error) result

val get_fact
  :  base_path:string
  -> fact_id:string
  -> (world_fact option, store_error) result

val list_edges
  :  ?fact_id:string
  -> base_path:string
  -> unit
  -> (world_edge list, store_error) result

val list_index
  :  ?kind:index_entry_kind
  -> base_path:string
  -> unit
  -> (index_entry list, store_error) result

val search_fts
  :  base_path:string
  -> query:string
  -> limit:int
  -> (search_hit list, store_error) result

val latest_digest : base_path:string -> (world_digest option, store_error) result

(** Point-in-time consistent MVCC snapshot read inside a single lock-free
    [BEGIN DEFERRED] read-only SQLite WAL transaction on one connection,
    eliminating torn reads between [facts], [edges], [entries], and [digest]. *)
type consistent_snapshot =
  { facts : world_fact list
  ; edges : world_edge list
  ; entries : index_entry list
  ; digest : world_digest option
  }

val read_snapshot
  :  ?include_inactive:bool
  -> base_path:string
  -> unit
  -> (consistent_snapshot, store_error) result

(** Read one fact and its incident edges from a single lock-free
    [BEGIN DEFERRED] read-only SQLite WAL snapshot. When [include_inactive] is
    [false] (the default), terminal ([Superseded] / [Molted]) facts are filtered
    out and returned as [Ok None]. When [visible_scope] is provided, incident
    edges whose peer fact has a scope failing [visible_scope] (or is missing)
    are withheld within the same MVCC read transaction. *)
val read_fact_with_edges
  :  ?include_inactive:bool
  -> ?visible_scope:(string -> bool)
  -> base_path:string
  -> fact_id:string
  -> unit
  -> ((world_fact * world_edge list) option, store_error) result

(** Compact, deterministic read-only snapshot of verified [Canonical] World
    Memory facts (clearly framed as untrusted workspace notes) and unified
    Wiki/Artifact/Resource index entries, injected into per-Keeper Librarian
    context. Returns [Ok None] when the DB has no [Canonical] facts or index
    entries yet. *)
val read_index_snapshot : base_path:string -> (string option, store_error) result

val read_change_log
  :  base_path:string
  -> since_seq:int
  -> limit:int
  -> (change_event list * int, store_error) result

(** Read the newest [limit] change-log events in ascending [seq] order together
    with the current maximum [seq], using a read-only [BEGIN DEFERRED] WAL
    snapshot off-domain. *)
val read_change_log_tail
  :  base_path:string
  -> limit:int
  -> (change_event list * int, store_error) result

(** {1 Atomic Off-Domain Writes} *)

val upsert_fact
  :  base_path:string
  -> now:float
  -> actor:string
  -> fact_id:string
  -> claim:string
  -> category:Keeper_memory_os_types.category
  -> facets:string list
  -> scope:string
  -> provenance:provenance
  -> lifecycle:lifecycle
  -> (world_fact, store_error) result

val add_edge
  :  base_path:string
  -> now:float
  -> actor:string
  -> from_fact_id:string
  -> to_fact_id:string
  -> kind:edge_kind
  -> reason:string
  -> (world_edge, store_error) result

val transition_fact_lifecycle
  :  base_path:string
  -> now:float
  -> actor:string
  -> fact_id:string
  -> to_lifecycle:lifecycle
  -> reason:string
  -> (world_fact, store_error) result

(** Atomically supersede [old_fact_id] with active [new_fact_id] inside ONE
    off-domain [BEGIN IMMEDIATE] SQLite WAL transaction: validates both facts
    exist, transitions [old_fact_id -> Superseded], records the [Supersedes]
    edge, and commits the updated {!world_digest}. Any failure rolls back the
    entire transaction so no dangling [Supersedes] edge is ever persisted. *)
val supersede_fact
  :  base_path:string
  -> now:float
  -> actor:string
  -> old_fact_id:string
  -> new_fact_id:string
  -> reason:string
  -> (world_digest, store_error) result

type index_sync_input =
  { entry_id : string
  ; kind : index_entry_kind
  ; title : string
  ; uri : string
  ; summary : string
  ; facets : string list
  ; sha256 : string option
  }

val upsert_index_entry
  :  base_path:string
  -> now:float
  -> actor:string
  -> entry_id:string
  -> kind:index_entry_kind
  -> title:string
  -> uri:string
  -> summary:string
  -> facets:string list
  -> sha256:string option
  -> (index_entry, store_error) result

(** Atomically reconcile the full [world_index] table in ONE off-domain SQLite
    WAL transaction: skips unchanged entries (matching metadata + [sha256]),
    upserts new/changed entries, prunes stale/deleted entries, and recomputes
    the immutable {!world_digest}. Returns
    [(upserted_count, pruned_count, digest, digest_changed)]. *)
val sync_index_batch
  :  base_path:string
  -> now:float
  -> actor:string
  -> index_sync_input list
  -> (int * int * world_digest * bool, store_error) result

(** Atomically apply a batch of per-Keeper [Promote_to_world] proposals in ONE
    off-domain SQLite WAL transaction: rejects/skips terminal ([Superseded] /
    [Molted]) facts without resurrection, performs bounded idempotent
    per-[(scope, facet)] cross-Keeper synthesis with [Synthesizes_from] edges
    and declarative [Working -> Consolidated] transitions, and commits the
    updated {!world_digest}. *)
val apply_promotion_batch
  :  base_path:string
  -> now:float
  -> keeper_id:string
  -> Librarian_lifecycle.world_promotion list
  -> (world_fact list * world_fact list * world_edge list * world_digest * bool, store_error) result

(** Deterministically compile and persist a new immutable {!world_digest}
    revision whenever the active fact set or unified index hash changed. *)
val commit_digest
  :  base_path:string
  -> now:float
  -> actor:string
  -> unit
  -> (world_digest * bool, store_error) result
