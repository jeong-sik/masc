
(** Tool_catalog_surfaces — SSOT for curated tool-name lists.

    Flat, consumer-owned tool-name lists.  The [surface] actor-classification
    type and its dispatch/reverse-lookup machinery were deleted in the
    surface-cut refactor: tools are a flat list, and each consumer projects
    the subset it needs by referencing the named list directly.

    {b Why centralize}: keeping every list in one .ml + .mli pair prevents
    the same tool name from drifting across two consumers' definitions. *)

(** {1 Curated tool-name lists} *)

val public_mcp_surface_tools : string list
(** Externally reachable MCP tools — the public surface. *)

val public_schedule_surface_tools : string list
(** Schedule tools visible to external MCP clients. *)

val spawned_agent_surface_tools : string list
(** Tools visible to spawned worker agents. *)
