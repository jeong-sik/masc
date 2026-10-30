(** Composition request and draft control schemas, read from
    [config/tools/keeper_composition_status.toml] and
    [config/tools/keeper_composition_cancel.toml]
    (RFC prompts-and-tool-definitions-outside-ocaml §2.2).

    Status/cancel take a [request_id]; prepare/run author a bound draft. Their descriptions are fixed
    sentences — schema and prose belong in the TOML with every other tool,
    not in OCaml. Decoded once at module initialization; a missing file or a
    declaration that fails to load raises, which the boot-time
    [Tool_definition_toml.validate_embedded] pass already turns into a refused
    boot. *)

val status_schema : Masc_domain.tool_schema
val cancel_schema : Masc_domain.tool_schema
val prepare_schema : Masc_domain.tool_schema
val run_schema : Masc_domain.tool_schema
val result_schema : Masc_domain.tool_schema
