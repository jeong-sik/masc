(** Publish current ordinary and source-bound Memory OS facts for demand recall.

    Ordinary facts come from the same snapshot as the dashboard. Source-bound
    facts are revalidated against their exact file bytes before injection;
    changed or unavailable sources contribute a typed invalidation instead of
    their old claim. The complete projection is stored as an immutable artifact;
    the prompt carries its identity and availability, not all stored knowledge.
    Search and paged artifact reads retain access to verified selected facts.
    Unreadable source claims remain stored but are projected only as deferred
    source identity, reason, and re-read instructions, never claim text.
    Invalidations and deferred identities remain inline on every tool surface.
    Artifact publication failure preserves readable-store availability and
    search guidance. If retrieval is unavailable, readable ordinary facts and
    verified source facts are included inline without a truncation cap.
    Callers supply both tool capabilities from the selected runtime surface.
    Before publication, each snapshot reference is persisted structurally in
    the keeper runtime tree. The latest published snapshot has a current pin;
    historical references follow the existing dated Keeper history retention
    policy. Replacing memory or the latest prompt capture does not release
    snapshots while their dated reference history remains retained.
    A failed pin write uses the same readable-store fallback as publication
    failure, without publishing an unowned artifact link.

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
    passed as [now] drives revalidation and dates retention history; it never
    appears in the text. *)

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
  -> ?memory_search_available:bool
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> keepers_dir:string
  -> keeper_id:string
  -> now:float
  -> unit
  -> string option

(** Returns a block for every state, including disabled or unavailable recall.
    The option-shaped interface is shared with the prompt assembly. *)
