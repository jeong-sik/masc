(** JSON builder for [GET /api/v1/runtime/resolved] — the single resolved
    runtime document (bugs #14/#15/#36): every configured runtime's effective
    max-context and which source produced it, every configured lane, and the
    full keeper fleet joined against [\[runtime.assignments\]] with the
    [\[runtime\].default] rider made explicit. This is the sole document the
    Settings surface consumes; it replaces the dashboard's divergent
    [/api/v1/dashboard/runtime-defaults] projections. *)

val build : generated_at_iso:string -> config:Workspace.config -> Yojson.Safe.t
(** [build ~generated_at_iso ~config] renders the resolved document from the
    live [Runtime] singleton state. [config] supplies the full keeper name
    list (bug #14: an assignments-only listing misses keepers riding
    [\[runtime\].default] with no explicit [\[runtime.assignments\]] entry). *)
