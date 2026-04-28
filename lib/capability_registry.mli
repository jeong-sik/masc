(** Capability_registry — canonical tool/capability SSOT.

    Public MCP tools and internal agent-facing tool surfaces are
    projections over one capability inventory. Some surfaces
    intentionally reuse the same tool name with a narrower schema
    (e.g. local worker projections).

    Internal helpers ([StringSet] / [StringMap], [risk_rank],
    [max_risk], [unique_preserve_order], [dedupe_schemas],
    [dedupe_projections], [prefixed_tool_names],
    [canonical_capability_id], [risk_class_to_string],
    [audience_to_string], [projection_to_schema], [make_seed],
    [public_projection_seeds_from], [local_worker_internal_seeds],
    [keeper_projection_seeds], [surface_tool_schemas_from],
    [surface_tool_names_from], [public_raw_tool_schemas_from],
    [keeper_safe_tool_names], [keeper_all_tool_names],
    [keeper_wrapped_server_tools],
    [keeper_wrapped_internal_tools], [capability_to_json],
    [oauth_login_stage], the surface-name lists
    [spawned_agent_public_tool_names],
    [local_worker_public_tool_names],
    [local_worker_internal_schemas],
    [privileged_public_tool_names]) are hidden — callers consume the
    typed projections, the [from] entry points, and the snapshot /
    schema accessors below. *)

(** {1 Risk / audience / surface} *)

type risk_class =
  | Safe
  | Audited
  | Privileged

type audience =
  | External_mcp_client
  | Spawned_managed_agent
  | Local_worker_agent
  | Keeper_agent
  | Privileged_executor

type surface =
  | Public_mcp
  | Spawned_agent_mcp
  | Local_worker
  | Keeper_standard
  | Keeper_privileged
  | Privileged_executor_surface

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
  risk_class : risk_class;
  audiences : audience list;
  supports_audit_evidence : bool;
  supports_direct_user_discovery : bool;
  projections : projection list;
}

type capability_seed = {
  capability_id : string;
  risk_class : risk_class;
  audiences : audience list;
  supports_audit_evidence : bool;
  supports_direct_user_discovery : bool;
  projection : projection;
}

(** {1 Seed / capability builders} *)

val all_projection_seeds_from :
  Types.tool_schema list -> capability_seed list
(** Combine public, local-worker-internal, and keeper seeds into one
    flat list keyed off [public_tool_source_schemas] (the canonical
    public schema list owned by [Tool_help_registry]). *)

val all_capabilities_from :
  Types.tool_schema list -> capability_def list
(** Group {!all_projection_seeds_from} by [capability_id] into a
    deduplicated capability inventory. The aggregated [risk_class]
    is the max over the seeds; [audiences] / [projections] are
    union'd preserving order. *)

(** {1 Public surface accessors} *)

val public_tool_schemas_from :
  Types.tool_schema list -> Types.tool_schema list
(** Canonicalised + deduped public-MCP schemas. *)

val visible_public_tool_schemas_from :
  ?include_hidden:bool ->
  ?include_deprecated:bool ->
  Types.tool_schema list ->
  Types.tool_schema list
(** [public_tool_schemas_from] filtered through [Tool_catalog.is_visible].
    Both inclusion flags default to [false]. *)

val local_worker_tool_schemas :
  ?names:string list ->
  unit ->
  (Types.tool_schema list, string) result
(** Delegates to [Agent_tool_surfaces.local_worker_tool_schemas]. *)

(** {1 Spawned-agent tool naming} *)

val spawned_agent_prefixed_tools : string list
(** Every spawned-agent tool name with the [mcp__masc__] prefix
    that external MCP clients see. *)

(** {1 Keeper surface naming} *)

val privileged_keeper_tool_names : string list
(** The hardcoded set of keeper tools that route to the privileged
    executor surface ([keeper_bash] / [keeper_bash_kill] /
    [keeper_bash_output] / [keeper_fs_edit] /
    [masc_worktree_create]). *)

val keeper_privileged_tool_names : string list
(** Alias for {!privileged_keeper_tool_names} kept for callers that
    read the registry through the public API. *)

val keeper_safe_tool_names : string list
(** Keeper tools that are NOT in {!privileged_keeper_tool_names},
    deduped while preserving the [Tool_shard.keeper_model_tools]
    order. Exposed for the registry test that pins the
    safe / privileged partition. *)

val keeper_backend_tool_name : string -> string
(** Resolve a keeper-facing tool alias to its [masc_*] backend
    name; identity for non-aliased tools. Pulls from
    [Tool_catalog_surfaces.keeper_internal_replacement]. *)

(** {1 Snapshot} *)

val surface_snapshot_json : Types.tool_schema list -> Yojson.Safe.t
(** Per-surface tool counts and tool name lists, plus the
    [keeper_wrapped_server_tools] hardcoded set. Used by the
    dashboard's capability inventory pane. *)
