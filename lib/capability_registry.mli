(** Capability_registry — canonical tool/capability SSOT.

    Public MCP tools and internal agent-facing tool surfaces are
    projections over one capability inventory. Some surfaces
    intentionally reuse the same tool name with a narrower schema
    (e.g. local worker projections).

    Internal helpers ([StringSet] / [StringMap], [dedupe_schemas],
    [dedupe_projections], [prefixed_tool_names],
    [canonical_capability_id],
    [audience_to_string], [projection_to_schema], [make_seed],
    [public_projection_seeds_from], [local_worker_internal_seeds],
    [keeper_projection_seeds], [surface_tool_schemas_from],
    [surface_tool_names_from], [public_raw_tool_schemas_from],
    [keeper_all_tool_names],
    [keeper_wrapped_server_tools],
    [keeper_wrapped_internal_tools], [capability_to_json],
    [oauth_login_stage], the surface-name lists
    [spawned_agent_public_tool_names],
    [local_worker_public_tool_names],
    [local_worker_internal_schemas]) are hidden — callers consume the
    typed projections, the [from] entry points, and the snapshot /
    schema accessors below. *)

(** {1 Audience / surface} *)

type audience =
  | External_mcp_client
  | Spawned_managed_agent
  | Local_worker_agent
  | Keeper_agent

type surface =
  | Public_mcp
  | Spawned_agent_mcp
  | Local_worker
  | Keeper

val surface_to_string : surface -> string
(** Stable ["public_mcp"] / ["spawned_agent_mcp"] / ... names used
    in JSON snapshots and dashboard payloads. *)

(** {1 Projections + capabilities} *)

type projection = {
  surface : surface;
  tool_name : string;
  description : string;
  input_schema : Yojson.Safe.t;
  backend_tool_name : string;
}

type capability_def = {
  capability_id : string;
  audiences : audience list;
  supports_audit_evidence : bool;
  supports_direct_user_discovery : bool;
  projections : projection list;
}

type capability_seed = {
  capability_id : string;
  audiences : audience list;
  supports_audit_evidence : bool;
  supports_direct_user_discovery : bool;
  projection : projection;
}

(** {1 Seed / capability builders} *)

val all_projection_seeds_from :
  Masc_domain.tool_schema list -> capability_seed list
(** Combine public, local-worker-internal, and keeper seeds into one
    flat list keyed off [public_tool_source_schemas] (the canonical
    public schema list owned by [Tool_help_registry]). *)

val all_capabilities_from :
  Masc_domain.tool_schema list -> capability_def list
(** Group {!all_projection_seeds_from} by [capability_id] into a
    deduplicated capability inventory. [audiences] / [projections] are
    union'd preserving order. *)

(** {1 Public surface accessors} *)

val public_tool_schemas_from :
  Masc_domain.tool_schema list -> Masc_domain.tool_schema list
(** Canonicalised + deduped public-MCP schemas. *)

val visible_public_tool_schemas_from :
  ?include_hidden:bool ->
  Masc_domain.tool_schema list ->
  Masc_domain.tool_schema list
(** [public_tool_schemas_from] filtered through [Tool_catalog.is_visible].
    [include_hidden] defaults to [false]. *)

val local_worker_tool_schemas :
  ?names:string list ->
  unit ->
  (Masc_domain.tool_schema list, string) result
(** Delegates to [Keeper_tool_surfaces.local_worker_tool_schemas]. *)

(** {1 Spawned-agent tool naming} *)

val spawned_agent_prefixed_tools : string list
(** Every spawned-agent tool name with the [mcp__masc__] prefix
    that external MCP clients see. *)

(** {1 Keeper surface naming} *)

val keeper_backend_tool_name : string -> string
(** Resolve a keeper-facing tool alias to its [masc_*] backend
    name; identity for non-aliased tools. Pulls from
    runtime-owned aliases are resolved behind the runtime boundary. *)

(** {1 Snapshot} *)

val surface_snapshot_json : Masc_domain.tool_schema list -> Yojson.Safe.t
(** Per-surface tool counts and tool name lists, plus the
    [keeper_wrapped_server_tools] hardcoded set. Used by the
    dashboard's capability inventory pane. *)
