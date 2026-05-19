(** Read-only lookups over Keeper_registry. SSOT for cross-base_path
    scans used by HTTP routing, MCP tool dispatch, and keeper liveness
    checks. *)

open Keeper_registry_types

(** Look up a keeper by name across all base_paths (O(n) scan). *)
val find_by_name : string -> registry_entry option

(** Look up a keeper by agent_name across all base_paths (O(n) scan). *)
val find_by_agent_name : string -> registry_entry option

(** Look up a keeper by stable UID across all base_paths (O(n) scan). *)
val find_by_id : Keeper_id.Uid.t -> registry_entry option

(** Get tool usage by keeper name (scans all base_paths), sorted by
    call count descending. *)
val tool_usage_of_by_name : string ->
  (string * Keeper_types.tool_call_entry) list

(** Resolve config for a keeper tool dispatch.
    Currently a no-op pass-through — the legacy fallback that
    retargeted across base_path registries has been removed; this
    function preserves the public API surface for callers. *)
val resolve_config :
  Coord_utils_backend_setup.config -> string -> Coord_utils_backend_setup.config
