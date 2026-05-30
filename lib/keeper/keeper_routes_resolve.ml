(** Catalog-aware variant of route → cascade name resolution.

    Split out of {!Keeper_routes} in the #19327/#19340 follow-up so that
    {!Keeper_routes} no longer depends on {!Keeper_catalog_runtime}.
    Keeping the dep in [Keeper_routes] closed a module-level cycle that
    transitively reached back to [Keeper_routes] through validate, leaving
    every cascade refactor since #19327 unable to build.

    Callers that need catalog validation (dashboard, doctor, runtime) use
    this module.  Callers that only need the configured route target
    without catalog cross-check use {!Keeper_routes} directly. *)

let cascade_name_for_use ?config_path:_ _use =
  Runtime.get_default_runtime_id ()
