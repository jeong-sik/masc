(** Single async off-domain World Curator fiber for MASC World Memory.

    Consumes {!Librarian_lifecycle.world_promotion} proposals from per-Keeper
    Librarians via an async Eio mailbox, performs declarative cross-Keeper /
    cross-category synthesis and molting (zero wall-clock TTL, zero numeric
    importance scores), synchronizes unified Wiki/Artifact/Resource index
    entries, commits immutable {!World_memory_types.world_digest} revisions,
    and triggers MCP resource update notifications. *)

open World_memory_types

type batch_report =
  { upserted_facts : world_fact list
  ; synthesized_facts : world_fact list
  ; edges_added : world_edge list
  ; digest : world_digest
  ; digest_changed : bool
  }

(** Deterministic synchronous curation pass for a batch of promotions from
    [keeper_id]. Used both by the async curator fiber and by deterministic
    tests. *)
val process_promotions_sync
  :  base_path:string
  -> now:float
  -> keeper_id:string
  -> Librarian_lifecycle.world_promotion list
  -> (batch_report, World_memory_store.store_error) result

(** Declaratively supersede or molt an existing world fact with a replacement,
    recording a typed [Supersedes] edge and updating the immutable world digest. *)
val supersede_fact_sync
  :  base_path:string
  -> now:float
  -> actor:string
  -> old_fact_id:string
  -> new_fact_id:string
  -> reason:string
  -> (world_digest, World_memory_store.store_error) result

(** Scan workspace Wiki pages, published workspace artifacts, and built-in MCP
    resources into the unified [world_index] table and commit an updated
    world digest. Returns the number of indexed entries and the latest digest. *)
val sync_wiki_and_artifacts_sync
  :  base_path:string
  -> now:float
  -> unit
  -> (int * world_digest, World_memory_store.store_error) result

(** Handle to a running single-fiber async World Curator bound to an Eio switch. *)
type t

(** Spawn the single async World Curator daemon fiber under [sw].
    [on_updated] is invoked on the Eio fiber after any committed digest change
    (wired to {!Mcp_server_eio_resource.notify_world_memory_updated}). *)
val start
  :  sw:Eio.Switch.t
  -> base_path:string
  -> now:(unit -> float)
  -> on_updated:(unit -> unit)
  -> t

(** Non-blocking enqueue of [Promote_to_world] proposals from a Keeper's
    Librarian. *)
val enqueue_promotions
  :  t
  -> keeper_id:string
  -> Librarian_lifecycle.world_promotion list
  -> unit

(** Non-blocking enqueue of a Wiki/Artifact/Resource index refresh. *)
val enqueue_index_sync : t -> unit

(** Wait until all previously enqueued mailbox items have been processed and
    committed to SQLite WAL. *)
val flush : t -> unit
