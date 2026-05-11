(** Tool_misc_admin — auth, config, tool inventory, and feature
    flag handlers.

    Extracted from {!Tool_misc} to reduce god-file size.  Contains
    administrative tool handlers for the dashboard:

    - {!handle_config} (auth config snapshot for the operator UI)
    - {!handle_tool_admin_snapshot} (tool inventory + permissions)
    - {!handle_tool_admin_update} (write a section's auth config)
    - {!handle_feature_flags} (feature flag inventory)
    - {!tool_inventory_json} (catalog-driven schema list)

    @since 2.187.0 — God file decomposition Phase 1.

    Internal: \[U\] (Yojson.Safe.Util alias), \[json_string_option\],
    \[bool_arg_opt\], \[int_arg_opt\] (3 local args helpers
    duplicated from Tool_misc to avoid circular deps),
    \[permission_to_json\], \[auth_snapshot_json\],
    \[enforcement_summary_json\], \[handle_feature_flags\] stay
    private — none are referenced outside this file. *)

(** {1 Types} *)

type tool_result = Tool_result.t

type context = {
  config : Coord.config;
  agent_name : string;
}
(** Per-call context.  Concrete record because callers
    (notably {!Tool_misc}) construct it field-by-field. *)

(** {1 SSOT} *)

val valid_admin_section_strings : string list
(** \[\["auth"\]\] — canonical section values accepted by
    [masc_tool_admin_update].

    Adding a new section requires {b three} synchronised changes:
    + A new branch in {!handle_tool_admin_update}.
    + This list gains the new string.
    + {!Tool_schemas_misc.admin_section_enum_strings} mirror.

    Sync test in [test_types.ml :: admin_section_ssot] catches
    drift between the three.

    {b History}: schema once advertised
    \[\["auth"; "unit_policy"\]\] but the handler only implemented
    [auth] (#8546) — fictional sections were removed and pinned
    here. *)

(** {1 Read-only inventory} *)

val tool_inventory_json :
  _ ->
  include_hidden:bool ->
  include_deprecated:bool ->
  Yojson.Safe.t
(** [tool_inventory_json _ctx ~include_hidden ~include_deprecated]
    returns the tool catalog snapshot.

    [enabled_in_current_mode] is reported as [false] because this
    is the dashboard context (no keeper) — pinned at the contract
    seam to prevent operator dashboards from incorrectly showing
    keeper-only tools as active. *)

(** {1 Tool handlers}

    All four handlers take [args : Yojson.Safe.t] (the JSON-RPC
    [params] object) and return {!tool_result}.  [ctx] is required
    for the snapshot/update handlers because they read from the
    base path. *)

val handle_feature_flags : tool_name:string -> start_time:float -> Yojson.Safe.t -> tool_result
(** [handle_feature_flags ~tool_name ~start_time args] returns the
    feature flag inventory filtered by optional [args.category] and
    [args.only_overridden]. *)

val handle_config : tool_name:string -> start_time:float -> Yojson.Safe.t -> tool_result
(** [handle_config ~tool_name ~start_time args] returns the auth-config
    snapshot filtered by [args.category] (optional string).  Read-only. *)

val handle_tool_admin_snapshot : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> tool_result
(** [handle_tool_admin_snapshot ~tool_name ~start_time ctx args] returns the tool
    inventory + auth config + feature-flag summary for the admin
    dashboard.  Optional args:

    - [include_hidden] (bool, default [true]).
    - [include_deprecated] (bool, default [true]). *)

val handle_tool_admin_update :
  tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> tool_result
(** [handle_tool_admin_update ~tool_name ~start_time ctx args] writes a new auth config.
    Required args:

    - [section] (string) — must be in {!valid_admin_section_strings}.
    - [updates] (object) — section-specific payload.

    Returns [Tool_result.error] with "section must be one of: auth" when the
    section is invalid.  The "must be one of" message is
    operator-actionable and pinned at the contract seam — drift
    breaks the admin UI's error-handling. *)