
(** Tool_catalog_surfaces — SSOT for tool-name surface membership.

    Each {!surface} variant maps to a curated string list of tool
    names visible at that surface.  Cross-cutting consumers (auth
    gate, dashboard catalog, telemetry, OAS
    hooks) read membership through {!tools_for_surface} or
    {!is_on_surface}.

    {b Why centralize}: 8+ modules consume surface-membership
    decisions (verified by [rg "tools_for_surface"]).  Keeping
    every list inside one .ml + .mli pair prevents the same tool
    name from drifting across two consumers' definitions.

    Internal: \[surface_sets\] (Hashtbl-backed reverse index used
    by {!is_on_surface} / {!surfaces_for_tool}) stays private —
    consumers reach the data through the public functions. *)

(** {1 Tool name lists (per surface)} *)

val public_mcp_surface_tools : string list
val workspace_role_tools : string list
val execution_role_tools : string list

(** {1 System-internal visibility list} *)

val system_internal_hidden : string list
(** Tools hidden from the public Full profile but callable directly and
    scoped for tool-usage logging.  A flat visibility list, not an actor
    surface; consumers project it via {!is_system_internal_hidden}.
    Formerly the [System_internal] surface variant. *)

val is_system_internal_hidden : string -> bool
(** [is_system_internal_hidden name] is O(1) membership against
    {!system_internal_hidden}. *)

(** {1 Surface variant} *)

(** Tool catalog surface — each variant identifies a curated
    visibility scope. *)
type surface =
  | Public_mcp
      (** Externally reachable MCP — most restrictive. *)
  | Spawned_agent
      (** Tools visible to spawned worker agents. *)
  | Local_worker
      (** Local worker container surface. *)
  | Session_min
      (** Minimum session surface (initialization tools only). *)
  | Admin
      (** Admin / operator dashboard surface. *)

val tools_for_surface : surface -> string list
(** [tools_for_surface s] returns the tool-name list registered for
    [s].  Each variant maps to one of the [*_surface_tools]
    constants exposed above. *)

val all_surfaces : surface list
(** Static list of every {!surface} constructor in declaration
    order.  Used by tests and the dashboard catalog index. *)

val is_on_surface : surface -> string -> bool
(** [is_on_surface s name] is [List.mem name (tools_for_surface s)]
    via the internal hashtable index — O(1) amortised. *)

val surfaces_for_tool : string -> surface list
(** [surfaces_for_tool name] returns every {!surface} whose tool
    list contains [name].  Used by the dashboard "where is this
    tool visible" view. *)

val surface_to_string : surface -> string
(** Stable human-readable label per {!surface} constructor —
    pinned at the contract seam so dashboard / log output stays
    stable across refactors. *)
