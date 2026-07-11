(** Capability_registry — canonical tool/capability SSOT.

    Public MCP tools and internal agent-facing tool surfaces are
    projections over one capability inventory. Some surfaces
    intentionally reuse the same tool name with a narrower schema
    (e.g. local worker projections).

    Implementation helpers remain hidden; callers consume the typed
    projections, result-returning constructors, and schema/snapshot accessors
    below. *)

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
  | Managed_agent_mcp
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
  capability_id : Tool_capability_id.t;
  risk_class : risk_class;
  audiences : audience list;
  supports_audit_evidence : bool;
  supports_direct_user_discovery : bool;
  projections : projection list;
}

type capability_seed = {
  capability_id : Tool_capability_id.t;
  risk_class : risk_class;
  audiences : audience list;
  supports_audit_evidence : bool;
  supports_direct_user_discovery : bool;
  projection : projection;
}

type projection_error =
  | Conflicting_surface_projection of
      { surface : surface
      ; tool_name : string
      ; capability_ids : Tool_capability_id.t list
      }
  | Multiple_keeper_model_names of
      { capability_id : Tool_capability_id.t
      ; tool_names : string list
      }

val projection_error_kind : projection_error -> string
val projection_error_to_json : projection_error -> Yojson.Safe.t

(** {1 Seed / capability builders} *)

val all_projection_seeds_from :
  Masc_domain.tool_schema list -> capability_seed list
(** Combine public, local-worker-internal, and keeper seeds into one
    flat list keyed off [public_tool_source_schemas] (the canonical
    public schema list owned by [Tool_help_registry]). *)

val validate_projection_seeds :
  capability_seed list -> (unit, projection_error list) result
(** Reject conflicting names within one surface and more than one active
    Keeper model name for a semantic capability. *)

val all_projection_seeds_from_result :
  Masc_domain.tool_schema list ->
  (capability_seed list, projection_error list) result
(** Typed projection constructor. The non-result convenience function emits
    bounded error telemetry and fails explicitly on this error. *)

val all_capabilities_from :
  Masc_domain.tool_schema list -> capability_def list
(** Group {!all_projection_seeds_from} by [capability_id] into a
    deduplicated capability inventory. The aggregated [risk_class]
    is the max over the seeds; [audiences] / [projections] are
    union'd preserving order. *)

val surface_tool_schemas_from :
  Masc_domain.tool_schema list -> surface -> Masc_domain.tool_schema list
(** Exact schema projection for one typed surface. *)

val surface_tool_names_from :
  Masc_domain.tool_schema list -> surface -> string list
(** Names from {!surface_tool_schemas_from}, preserving projection order. *)

(** {1 Public surface accessors} *)

val public_tool_schemas_from :
  Masc_domain.tool_schema list -> Masc_domain.tool_schema list
(** Canonicalised + deduped front-door source schemas. *)

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

val privileged_keeper_tool_names : string list
(** The hardcoded set of keeper tools that route to the privileged
    executor surface ([tool_execute] / [tool_edit_file] / [tool_write_file]). *)

val keeper_privileged_tool_names : string list
(** Alias for {!privileged_keeper_tool_names} kept for callers that
    read the registry through the public API. *)

val keeper_safe_tool_names : string list
(** Keeper tools that are NOT in {!privileged_keeper_tool_names},
    deduped while preserving the [Tool_shard.keeper_model_tools]
    order. Exposed for the registry test that pins the
    safe / privileged partition. *)

(** {1 Snapshot} *)

val surface_snapshot_json : Masc_domain.tool_schema list -> Yojson.Safe.t
(** Per-surface tool counts and exact projected name lists. Used by the
    dashboard's capability inventory pane. Invalid projections are logged,
    counted, and raised explicitly rather than encoded into this stable map
    shape. *)
