(** Public facade for MASC Lock-Free MVCC World Memory.

    Connects per-Keeper Librarians bidirectionally to the workspace's
    SQLite WAL World Memory store ([<base_path>/.masc/world_memory.db]) and
    single async {!World_memory_curator} fiber. *)

module Types = World_memory_types
module Store = World_memory_store
module Curator = World_memory_curator

(** Start and register the workspace's single async World Curator fiber on [sw],
    unregistering it automatically when [sw] releases. *)
val start_workspace_curator
  :  sw:Eio.Switch.t
  -> base_path:string
  -> now:(unit -> float)
  -> on_updated:(unit -> unit)
  -> Curator.t

val find_workspace_curator : base_path:string -> Curator.t option

(** Deliver [Promote_to_world] proposals emitted by a Keeper's Librarian.
    Routes through the running async {!Curator.t} when registered, or executes
    off-domain synchronously via {!Curator.process_promotions_sync} otherwise. *)
val promote_from_librarian
  :  base_path:string
  -> keeper_id:string
  -> Librarian_lifecycle.world_promotion list
  -> unit

(** Read-only World Memory Index snapshot injected into per-Keeper Librarian
    context so sibling Keepers see shared canonical knowledge without blocking. *)
val read_index_snapshot_for_librarian : base_path:string -> string option
