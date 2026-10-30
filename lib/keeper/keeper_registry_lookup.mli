(** Read-only lookups over Keeper_registry. SSOT for cross-base_path
    scans used by HTTP routing, MCP tool dispatch, and keeper liveness
    checks. *)

open Keeper_registry_types

(** Look up a keeper by name across all base_paths (O(n) scan). *)
val find_by_name : string -> registry_entry option

(** Look up a keeper by name within one base path. Callers that act on the
    result inside a single workspace must use this rather than
    {!find_by_name}: a same-named Keeper registered under another base path
    is not a lane of this workspace, and treating it as one writes to a
    queue nobody reads. *)
val find_by_name_in_base_path : base_path:string -> string -> registry_entry option

(** Get tool usage by keeper name (scans all base_paths), sorted by
    call count descending. *)
val tool_usage_of_by_name : string ->
  (string * Keeper_types.tool_call_entry) list
