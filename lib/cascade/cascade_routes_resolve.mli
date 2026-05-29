(** Catalog-aware variant of route → cascade name resolution.

    Extracted from {!Cascade_routes} in the #19327/#19340 follow-up to
    break the Cascade_routes ↔ Cascade_catalog_runtime module-level cycle.

    @stability Internal *)

val cascade_name_for_use :
  ?config_path:string -> Cascade_routes.logical_use -> string
(** Return the default Runtime's binding id, ignoring [use].

    B3 (cascade→Runtime): route/cascade_name indirection is gone — a binding
    (provider × model) is a Runtime, and consumers use the default Runtime
    directly.  [use] is accepted for signature compatibility but no longer
    selects a route.

    Raises [Failure] when no default Runtime can be resolved (missing config
    path or no [\[runtime\] default]); this is a config defect, surfaced
    fail-fast rather than hidden behind a fallback name. *)
