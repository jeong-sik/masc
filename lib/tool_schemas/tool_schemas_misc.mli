(** Tool_schemas_misc — Tool schemas for [Tool_misc],
    separated to break the [Config] dependency cycle.

    The enum lists are SSOT mirrors of producer-side string
    lists.  Adding / removing values requires synchronized
    updates at the SSOT (which lives in a downstream module
    that cannot be referenced here without re-introducing the
    cycle).  A test invariant keeps the mirror aligned:

    - [test_types.ml :: dashboard_scope_ssot] —
      {!dashboard_scope_enum_strings} vs
      [Dashboard.valid_scope_strings]

    The [masc_config] category enum SSOT lives in
    [Tool_schemas_specs_types.config_category_enum_strings]
    (issue #15257); [test/test_tool_descriptors_gen.ml ::
    config_category_ssot] asserts it matches the producer-side
    [Env_config_snapshot.valid_config_category_strings]. *)

(** {1 Enum string mirrors (SSOT)} *)

val dashboard_scope_enum_strings : string list
(** Mirror of [Dashboard.valid_scope_strings] (issue #8592).
    Currently [\["all"; "current"\]] — adding a 3rd scope
    constructor must fail [scope_to_string] compilation AND
    the [dashboard_scope_ssot] test, instead of silently
    dropping from the JSON Schema.  Hand-mirrored because
    [Tool_schemas_misc] is upstream of [Dashboard] in the
    dependency graph. *)

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
(** Canonical control schemas used by registration. These schemas are
    intentionally excluded from {!schemas} and the Config front-door inventory. *)

val schemas : Masc_domain.tool_schema list
(** [schemas] is the generated [Masc_domain.tool_schema list] for misc tools.
    Operator controls are intentionally available only through
    {!control_schemas}; they do not enter the Config front-door inventory.
    Descriptor-owned web backend names ([masc_web_search] / [masc_web_fetch])
    are intentionally projected into {!Config.raw_all_tool_schemas} from
    [Keeper_tool_descriptor.public_descriptors] instead of duplicated here.
    Public-surface exclusion is enforced downstream by
    {!Tool_catalog.is_public_mcp} / [public_mcp_surface_tools], not by trimming
    the raw inventory. The schema [enum] fields derive from
    {!dashboard_scope_enum_strings} /
    [Tool_schemas_specs_types.config_category_enum_strings] so
    adding a value updates the schema automatically. *)
