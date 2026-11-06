(** JSON builder for [GET /api/v1/runtime/resolved] — the single resolved
    runtime document (bugs #14/#15/#36): every configured runtime's effective
    max-context and which source produced it, effective image admission and
    the model's optional image declaration, every configured lane in its
    declared candidate order, and the
    full keeper fleet joined against [\[runtime.assignments\]] with the
    [\[runtime\].default] rider made explicit. This is the sole document the
    Settings surface consumes; it replaces the dashboard's divergent
    [/api/v1/dashboard/runtime-defaults] projections. *)

val build_at : now:float -> generated_at_iso:string -> config:Workspace.config -> Yojson.Safe.t
(** Render every runtime's quota and rate-limit state at the same observation
    time, including the provider-declared Retry-After boundary. *)

val build : generated_at_iso:string -> config:Workspace.config -> Yojson.Safe.t
(** [build ~generated_at_iso ~config] renders the resolved document from the
    live [Runtime] singleton state. [config] supplies the full keeper name
    list (bug #14: an assignments-only listing misses keepers riding
    [\[runtime\].default] with no explicit [\[runtime.assignments\]] entry). *)

val standing : now:float -> config:Workspace.config -> Yojson.Safe.t
(** {!build_at} with an empty [generated_at_iso]: two readings are equal
    unless a runtime's standing, a usage window or the catalog changed. *)

val next_standing_change_at : now:float -> float option
(** The earliest future time a runtime's quota rest (a stated window, or an
    observation without a reset at its fallback cap) or provider-stated rate
    limit ends, when its standing in {!standing} changes with no write. *)

