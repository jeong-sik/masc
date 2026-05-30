(** Catalog-aware variant of route → cascade name resolution.

    Extracted from {!Cascade_routes} in the #19327/#19340 follow-up to
    break the Cascade_routes ↔ Cascade_catalog_runtime module-level cycle.

    @stability Internal *)

val cascade_name_for_use :
  ?config_path:string -> Cascade_routes.logical_use -> string
(** Resolve the cascade name configured for [use], validating against the
    runtime catalog.  Falls back to a generated "route.<key>" name when no
    binding is configured or when the configured target is missing from
    the catalog snapshot.  See {!Cascade_routes} for the catalog-free
    variants. *)
