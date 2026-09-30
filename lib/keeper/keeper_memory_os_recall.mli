(** Publish current ordinary and source-bound Memory OS facts for demand recall.

    Ordinary facts come from the same snapshot as the dashboard. Source-bound
    facts are revalidated against their exact file bytes before injection;
    changed or unavailable sources contribute a typed invalidation instead of
    their old claim. The complete projection is stored as an immutable artifact;
    the prompt carries its identity and availability, not all stored knowledge.
    Search and paged artifact reads retain access to every selected fact.

    Each store is rendered as present, authoritatively empty/absent, or
    unavailable. Empty and absent states explicitly supersede earlier current
    facts. Read failures mark prior facts as unverified without claiming they
    were deleted. Source-store failure retains readable ordinary facts.
    Disabling recall emits a stable suspension marker. These explicit states
    let resumed sessions observe withdrawal, uncertainty and later recovery.

    The rendered block depends on fact contents and provenance, availability,
    invalidations and per-pass source readability. Snapshot commit revisions
    and update times remain in the durable stores and tools; identical facts
    recommitted by a later Librarian tick render identically. The wall clock
    passed as [now] drives revalidation only and never appears in the text. *)

(** Render only the ordinary snapshot. Kept as the focused ordinary-store
    projection; production prompt assembly calls [render_if_enabled]. *)
val render_context
  :  keepers_dir:string
  -> keeper_id:string
  -> unit
  -> string

val enabled : unit -> bool

val render_if_enabled
  :  ?artifact_reader_available:bool
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> keepers_dir:string
  -> keeper_id:string
  -> now:float
  -> unit
  -> string option

(** Returns a block for every state, including disabled or unavailable recall.
    The option-shaped interface is shared with the prompt assembly. *)
