
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

val schedule_request_surface_tools : string list
(** Schedule request tools that read/create/cancel durable schedule rows. *)

val public_schedule_surface_tools : string list
(** Schedule tools visible to external MCP clients. *)

val keeper_schedule_surface_tools : string list
(** Schedule tools visible to keeper-standard projections. *)

val spawned_agent_schedule_surface_tools : string list
(** Schedule tools visible to spawned managed agents. Empty by policy until
    spawned agents have a lane ownership contract for reservations. *)

val local_worker_schedule_surface_tools : string list
(** Schedule tools visible to local worker containers. Empty by policy:
    local workers execute bounded delegated work, not durable reservations. *)

val schedule_surface_tools : string list
(** Compatibility alias for {!schedule_request_surface_tools}. *)

val spawned_agent_surface_tools : string list
(** Tools visible to spawned worker agents. *)

val local_worker_surface_tools : string list
(** Local worker container tools. *)

val session_min_surface_tools : string list
(** Minimum session tools (initialization only). *)

val workspace_role_tools : string list
val execution_role_tools : string list
