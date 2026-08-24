(** The twelve keeper tools whose declarations moved to
    [config/tools/masc_keeper_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial keeper surface, so a reader of these values never has to ask
    whether a schema loaded.

    [Keeper_schema.schemas] is the only consumer; it keeps the three tools that
    derive values from an owner module. [test_keeper_schema_toml_parity] pins
    all fifteen against what the list published before any of this moved. *)

val sandbox_start : Masc_domain.tool_schema
val sandbox_stop : Masc_domain.tool_schema
val status : Masc_domain.tool_schema
val audit : Masc_domain.tool_schema
val up : Masc_domain.tool_schema
val delegate : Masc_domain.tool_schema
val delegate_status : Masc_domain.tool_schema
val delegate_cancel : Masc_domain.tool_schema
val delegate_list : Masc_domain.tool_schema
val down : Masc_domain.tool_schema
val list : Masc_domain.tool_schema
val reset : Masc_domain.tool_schema
val compact : Masc_domain.tool_schema
val msg : Masc_domain.tool_schema
val clear : Masc_domain.tool_schema
