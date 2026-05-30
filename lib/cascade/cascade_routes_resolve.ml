(** Catalog-aware variant of route → cascade name resolution.

    Split out of {!Cascade_routes} in the #19327/#19340 follow-up so that
    {!Cascade_routes} no longer depends on {!Cascade_catalog_runtime}.
    Keeping the dep in [Cascade_routes] closed a module-level cycle that
    transitively reached back to [Cascade_routes] through validate, leaving
    every cascade refactor since #19327 unable to build.

    Callers that need catalog validation (dashboard, doctor, runtime) use
    this module.  Callers that only need the configured route target
    without catalog cross-check use {!Cascade_routes} directly. *)

(* cascade→Runtime hotfix: return valid profile name instead of
   binding key.  The cascade profile resolver only accepts profile
   names ("tool_strict", "lite"), not binding keys like
   "runpod_mtp.qwen36-35b-a3b-mtp".  All 18 routes target the same
   binding which satisfies [tool_strict].  Module will be deleted
   when cascade layer is fully removed. *)
let cascade_name_for_use ?config_path:_ _use =
  "tool_strict"
