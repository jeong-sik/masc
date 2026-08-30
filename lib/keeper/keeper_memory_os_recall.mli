(** Render current ordinary and source-bound Memory OS facts.

    Ordinary facts come from the same snapshot as the dashboard. Source-bound
    facts are revalidated against their exact file bytes before injection;
    changed or unavailable sources contribute a typed invalidation instead of
    their old claim. Recall never truncates, ranks, or partially injects facts.

    An oversized combined payload produces no recall block. A source-store read
    error falls back to ordinary recall after recording the operator-visible
    failure. An empty ordinary store still produces a block when a pending
    source invalidation exists. *)

(** Render only the ordinary snapshot. Kept as the focused ordinary-store
    projection; production prompt assembly calls [render_if_enabled]. *)
val render_context
  :  keepers_dir:string
  -> keeper_id:string
  -> now:float
  -> unit
  -> string

val enabled : unit -> bool

val render_if_enabled
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> keepers_dir:string
  -> keeper_id:string
  -> now:float
  -> unit
  -> string option
