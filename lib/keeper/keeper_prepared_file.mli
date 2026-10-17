(** Existing local file resources, pinned independently of permission or replay. *)
type operation = Read | Edit
type t

val prepare
  : sw:Eio.Switch.t
  -> operation:operation
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> args:Yojson.Safe.t
  -> confined:Keeper_alerting_path.confined_path
  -> (t option, string) result
(** Inspect an existing regular source and pin its existing target/source parent
    capabilities on [sw]. [None] leaves an unsupported or missing resource on
    the ordinary execution path. Partial capabilities are released before any
    refusal or fallback. This performs no write, Gate decision or source read.
    Native directory identities include complete physical ancestry, so nested
    allowed roots and aliases cannot mint unrelated scheduling resources. *)

val scopes : t -> Agent_core.Tool_contract.Resource_scope.t list
(** For [Edit], the lexical replacement entry carries [Write]; the resolved source entry
    carries [Read]. Each entry is identified by its physical parent and leaf,
    and retains its parent and complete physical ancestry. Different entries
    may overlap even in the same or nested directories. Additional target
    [Write] and source [Read] object claims retain the backend's inode-based
    mutation ordering for hard links and filesystem spelling aliases. Entry
    claims keep successive atomic replacements ordered after inode changes.
    [Read] carries only [Read] claims for these same entries and objects. *)

val release : t -> unit
(** Release a preparation that an aggregate producer cannot transfer. Safe to
    repeat; the owning switch also closes the resources. A released token
    cannot be consumed. Cancellation cannot interrupt this cleanup. *)

val with_parents
  : operation:operation
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> args:Yojson.Safe.t
  -> confined:Keeper_alerting_path.confined_path
  -> t
  -> (parent_dir:Eio.Fs.dir_ty Eio.Path.t
      -> parent_components:string list
      -> leaf:string
      -> source_parent_dir:Eio.Fs.dir_ty Eio.Path.t
      -> source_leaf:string
      -> ('a, string) result)
  -> ('a, string) result
(** Revalidate the exact owner/input, current confined resolution, root and
    physical directory bindings and operation, then consume the pinned parents.
    The source file opens at execution, retaining sequential reads/patches
    after an earlier atomic replacement. This
    does not authorize the effect or bypass Gate/publication recovery. *)

module Write : sig
  type t

  val prepare
    : sw:Eio.Switch.t
    -> operation:Keeper_tool_write_mode.t
    -> config:Workspace.config
    -> meta:Keeper_meta_contract.keeper_meta
    -> args:Yojson.Safe.t
    -> confined:Keeper_alerting_path.confined_path
    -> (t option, string) result
  (** Pin existing target/resolved-source parents, or their deepest existing
      ancestors, for Overwrite or Append. The file and child directories may
      be absent. Preparation creates nothing; unsupported resources retain
      ordinary execution through [None]. *)

  val scopes : t -> Agent_core.Tool_contract.Resource_scope.t list
  (** Existing objects carry entry and inode writes. An absent object claims
      its actual parent for creation. Missing directories claim their existing
      ancestor subtree, so filesystem spelling aliases and intervening parent
      creation are ordered without guessed normalization. Disjoint subtrees
      retain independent resource scopes. *)
  val release : t -> unit

  val with_parents
    : operation:Keeper_tool_write_mode.t
    -> config:Workspace.config
    -> meta:Keeper_meta_contract.keeper_meta
    -> args:Yojson.Safe.t
    -> confined:Keeper_alerting_path.confined_path
    -> t
    -> (root_dir:Eio.Fs.dir_ty Eio.Path.t
        -> parent_dir:Eio.Fs.dir_ty Eio.Path.t
        -> parent_components:string list
        -> missing_parents:string list
        -> leaf:string
        -> ('a, string) result)
    -> ('a, string) result
  (** Revalidate the exact operation, owner/input, confinement and pinned
      physical directory bindings, then invoke the original write consumer.
      For missing parents, resolution may advance inside the claimed physical
      ancestor as predecessors create directories; execution recomputes the
      remaining missing segments before Gate. A redirect outside that ancestor
      is refused, never an unprepared fallback. This supplies neither Gate
      permission nor durable replay authority. *)
end
