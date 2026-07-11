(** Tool_schemas_misc — Tool schemas for [Tool_misc],
    separated to break the [Config] dependency cycle.

    The enum lists are SSOT mirrors of producer-side string
    lists.  Adding / removing values requires synchronized
    updates at the SSOT (which lives in a downstream module
    that cannot be referenced here without re-introducing the
    cycle).  Three test invariants keep the mirrors aligned:

    - [test_types.ml :: dashboard_scope_ssot] —
      {!dashboard_scope_enum_strings} vs
      [Dashboard.valid_scope_strings]
    - [test_types.ml :: config_category_ssot] —
      {!config_category_enum_strings} vs
      [Env_config_snapshot.valid_config_category_strings] *)

(** {1 Enum string mirrors (SSOT)} *)

val dashboard_scope_enum_strings : string list
(** Mirror of [Dashboard.valid_scope_strings] (issue #8592).
    Currently [\["all"; "current"\]] — adding a 3rd scope
    constructor must fail [scope_to_string] compilation AND
    the [dashboard_scope_ssot] test, instead of silently
    dropping from the JSON Schema.  Hand-mirrored because
    [Tool_schemas_misc] is upstream of [Dashboard] in the
    dependency graph. *)

val config_category_enum_strings : string list
(** Mirror of [Env_config_snapshot.valid_config_category_strings]
    (issue #8493) excluding runtime-owner-specific categories.
    Hand-mirrored because [Tool_schemas_misc]
    depends only on [masc_types] — adding [masc_config] as a
    direct dep would reintroduce the cycle this split avoids.
    The [config_category_ssot] test keeps this aligned with
    the producer-side SSOT. *)

(** {1 Tool schema list} *)

type control_operation =
  | Pause
  | Resume
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
    {!dashboard_scope_enum_strings} / {!config_category_enum_strings} so
    adding a value updates the schema automatically. *)
