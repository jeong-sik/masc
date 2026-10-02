(** Demand recall separates stored knowledge from per-turn context.

    Search-capable surfaces receive only store availability and counts plus a
    current-lookup requirement: no claim bodies, source-file revalidation,
    artifact rendering, blob writes or retention writes. The Keeper selects
    relevant facts through [keeper_memory_search], whose read boundary
    revalidates source claims before returning them.

    Artifact-only surfaces revalidate the complete projection and publish a
    retained, paged snapshot; no claim body is copied into the prompt. If no
    retrieval capability is available or publication fails, emit availability
    and explicit historical-reference withdrawal, never the complete facts.
    No stored memory is deleted by a recall decision. Source invalidations
    and unreadable-source identities accompany the artifact-only projection.

    Empty/absent, unreadable and disabled states remain distinct and stable.
    [now] drives source revalidation and artifact retention only, never notice
    identity. A notice is not verification of any previous retrieved claim;
    current facts must be looked up again when used. Caller capabilities are
    those of the actual selected runtime surface. *)

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
