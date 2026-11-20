(** The operator-surface tools, read from the binary-embedded
    [config/tools/masc_*.toml] declarations.

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial operator surface, so a reader of these values never has to ask
    whether a schema loaded.

    [test_operator_surface_toml_parity] checks two invariants: the
    masc_config category enum matches its owner, and the Operator_only
    [pause_status] stays off the Keeper-visible list. *)

val ask : Masc_domain.tool_schema
val ask_status : Masc_domain.tool_schema
val ask_withdraw : Masc_domain.tool_schema
val broadcast : Masc_domain.tool_schema
val config : Masc_domain.tool_schema
val dashboard : Masc_domain.tool_schema
val gc : Masc_domain.tool_schema
val sandbox_volume_gc : Masc_domain.tool_schema
val keeper_waiting_inventory : Masc_domain.tool_schema
val messages : Masc_domain.tool_schema
val plan_clear_task : Masc_domain.tool_schema
val plan_get_task : Masc_domain.tool_schema
val plan_set_task : Masc_domain.tool_schema
val start : Masc_domain.tool_schema
val tool_help : Masc_domain.tool_schema

val pause_status : Masc_domain.tool_schema
(** Operator_only: absent from [schemas], reached through
    [Tool_schemas_misc.control_schema] rather than the list a Keeper model
    reads. *)

val schemas : Masc_domain.tool_schema list
(** The tools [Tool_schemas_misc] publishes: every value above except the
    Operator_only [pause_status]. *)
