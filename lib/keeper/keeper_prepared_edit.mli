(** Existing local Edit resources, pinned independently of permission or replay. *)
type t

val prepare
  : sw:Eio.Switch.t
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> args:Yojson.Safe.t
  -> confined:Keeper_alerting_path.confined_path
  -> (t option, string) result
(** Inspect an existing regular source and pin its existing target/source parent
    capabilities on [sw]. [None] leaves an unsupported or missing resource on
    the ordinary Serial path. Partial capabilities are released before any
    refusal or fallback. This performs no write, Gate decision or source read.
    Native directory identities include complete physical ancestry, so nested
    allowed roots and aliases cannot mint unrelated scheduling resources. *)

val scopes : t -> Agent_core.Tool_contract.Resource_scope.t list
(** Conservative occupied target/source directories. A shared ancestor alone
    permits siblings; equal or ancestor/descendant directories conflict. *)

val release : t -> unit
(** Release a preparation that an aggregate producer cannot transfer. Safe to
    repeat; the owning switch also closes the resources. A released token
    cannot be consumed. Cancellation cannot interrupt this cleanup. *)

val with_parents
  : config:Workspace.config
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
    physical directory bindings, then consume the pinned parents. The actual
    source file is opened/read by the ordinary Edit consumer at execution,
    retaining sequential patches after an earlier atomic replacement. This
    does not authorize the effect or bypass Gate/publication recovery. *)
