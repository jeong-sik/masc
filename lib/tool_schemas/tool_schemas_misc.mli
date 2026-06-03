(** Tool_schemas_misc — Tool schemas for [Tool_misc],
    separated to break the [Config] dependency cycle.

    All 4 entries are SSOT mirrors of producer-side string
    lists.  Adding / removing values requires synchronized
    updates at the SSOT (which lives in a downstream module
    that cannot be referenced here without re-introducing the
    cycle).  Three test invariants keep the mirrors aligned:

    - [test_types.ml :: dashboard_scope_ssot] —
      {!dashboard_scope_enum_strings} vs
      [Dashboard.valid_scope_strings]
    - [test_types.ml :: config_category_ssot] —
      {!config_category_enum_strings} vs
      [Env_config_snapshot.valid_config_category_strings]
    - Issue #8546 — {!admin_section_enum_strings} vs
      [Tool_misc_admin.valid_admin_section_strings] *)

(** {1 Enum string mirrors (SSOT)} *)

val admin_section_enum_strings : string list
(** Mirror of [Tool_misc_admin.valid_admin_section_strings]
    (issue #8546).  Currently [\["auth"\]] — drift would
    re-introduce the schema-vs-handler mismatch where the
    schema advertised values the handler did not implement,
    causing [section must be one of: auth] errors for LLM
    clients following the schema.  Pinned at the contract
    seam — same cycle pattern as #8484 / #8490 / #8493. *)

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

val schemas : Masc_domain.tool_schema list
(** [schemas] is the [Masc_domain.tool_schema list] for the
    MCP-facing misc tools. Keeper-only web backend tools
    ([masc_web_search] / [masc_web_fetch]) are intentionally
    excluded from this public schema inventory. Consumed by
    {!Config.visible_tool_schemas} via {!Tools.schemas}. The
    schema [enum] fields derive from
    {!admin_section_enum_strings} /
    {!dashboard_scope_enum_strings} /
    {!config_category_enum_strings} so adding a value updates
    the schema automatically. *)

val internal_handler_schemas : Masc_domain.tool_schema list
(** [internal_handler_schemas] keeps the full generated misc schema
    set for Tool_spec/tag registration. It may contain internal backend
    tool names that are callable by keeper descriptors but absent from
    the MCP-facing [schemas] list. *)
