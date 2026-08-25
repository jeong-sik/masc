(** Tool_schemas_misc — Tool schemas for [Tool_misc],
    separated to break the [Config] dependency cycle.

    The enum lists are SSOT mirrors of producer-side string
    lists.  Adding / removing values requires synchronized
    updates at the SSOT (which lives in a downstream module
    that cannot be referenced here without re-introducing the
    cycle).

    The [masc_config] category enum SSOT lives in
    [Tool_schemas_specs_types.config_category_enum_strings]
    (issue #15257); [test/test_operator_surface_toml_parity.ml ::
    the config category enum matches its owner] asserts it matches the producer-side
    [Env_config_snapshot.valid_config_category_strings]. *)

(** {1 Enum string mirrors (SSOT)} *)

(** {1 Tool schema list} *)

type control_operation =
  | Pause
  | Resume
  | Pause_status
(** Closed set of operator control tools. *)

val control_operations : control_operation list
(** Exhaustive typed projection of operator control operations. *)

val control_operation_id : control_operation -> string
(** Stable descriptor identifier suffix for a control operation. *)

val control_schema : control_operation -> Masc_domain.tool_schema
(** Canonical generated schema for a control operation. *)

val control_schemas : Masc_domain.tool_schema list
(** Canonical control schemas used by registration. *)

val web_search_schema : Masc_domain.tool_schema
val web_fetch_schema : Masc_domain.tool_schema
val web_schemas : Masc_domain.tool_schema list
(** Canonical input schemas owned by the Tool_misc web handlers. *)

val schemas : Masc_domain.tool_schema list
(** [schemas] is the generated [Masc_domain.tool_schema list] for misc tools.
    Operator controls are available through {!control_schemas}. Public-surface
    exclusion is enforced downstream by {!Tool_catalog.is_public_mcp} and
    [public_mcp_surface_tools]. The schema [enum] fields derive from
    [Tool_schemas_specs_types.config_category_enum_strings] so
    adding a value updates the schema automatically.

    This also named [dashboard_scope_enum_strings], which is not in the tree;
    [config_category_enum_strings] is the only [*_enum_strings] that module
    exports. *)

type mcp_runtime_operation =
  | Start
  | Broadcast
  | Messages
  | Ask
(** Closed vocabulary dispatched by [Mcp_tool_runtime]. *)

val mcp_runtime_operations : mcp_runtime_operation list
(** Exhaustive stable-order projection of MCP runtime operations. *)

val mcp_runtime_tool_name : mcp_runtime_operation -> string
(** Canonical wire name for an MCP runtime operation. *)

val mcp_runtime_operation_of_tool_name : string -> mcp_runtime_operation option
(** Parse a canonical MCP runtime wire name at the dispatch boundary. *)

val mcp_runtime_schema : mcp_runtime_operation -> Masc_domain.tool_schema
(** Canonical generated schema for an MCP runtime operation. *)

val mcp_runtime_schemas : Masc_domain.tool_schema list
(** Canonical schemas projected from {!mcp_runtime_operations}. *)
