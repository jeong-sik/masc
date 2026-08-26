(** The 19 tools RFC-0057's codegen owned, read from the binary-embedded
    [config/tools/masc_*.toml] declarations (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2, migration item 5).

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial operator surface, so a reader of these values never has to ask
    whether a schema loaded.

    [test_operator_surface_toml_parity] pins all 19 against the literals the
    generator emitted, reaching them through the values below rather than by
    filename so that a value bound to the wrong declaration fails there. It
    also carries the three invariants that suite held which had nothing to do
    with code generation: the masc_config category enum matching its owner,
    keeper_spawn staying unpublished, and the Operator_only control trio staying
    off the Keeper-visible list. *)

val ask : Masc_domain.tool_schema
val ask_status : Masc_domain.tool_schema
val broadcast : Masc_domain.tool_schema
val config : Masc_domain.tool_schema
val dashboard : Masc_domain.tool_schema
val deliver : Masc_domain.tool_schema
val gc : Masc_domain.tool_schema
val keeper_waiting_inventory : Masc_domain.tool_schema
val messages : Masc_domain.tool_schema
val note_add : Masc_domain.tool_schema
val plan_clear_task : Masc_domain.tool_schema
val plan_get : Masc_domain.tool_schema
val plan_get_task : Masc_domain.tool_schema
val plan_init : Masc_domain.tool_schema
val plan_set_task : Masc_domain.tool_schema
val plan_update : Masc_domain.tool_schema
val start : Masc_domain.tool_schema
val tool_help : Masc_domain.tool_schema

val pause : Masc_domain.tool_schema
(** Operator_only: absent from [schemas], reached through
    [Tool_schemas_misc.control_schema] rather than the list a Keeper model
    reads. *)

val resume : Masc_domain.tool_schema
(** Operator_only. See [pause]. *)

val pause_status : Masc_domain.tool_schema
(** Operator_only. See [pause]. *)

val schemas : Masc_domain.tool_schema list
(** The 16 tools [Tool_schemas_misc] publishes: every value above except the
    Operator_only trio. *)
