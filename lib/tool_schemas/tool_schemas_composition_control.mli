(** The two async-composition request-control tools, read from
    [config/tools/keeper_composition_status.toml] and
    [config/tools/keeper_composition_cancel.toml]
    (RFC prompts-and-tool-definitions-outside-ocaml §2.2).

    Both take one [request_id] string and their descriptions are fixed
    sentences — schema and prose belong in the TOML with every other tool,
    not in OCaml. Decoded once at module initialization; a missing file or a
    declaration that fails to load raises, which the boot-time
    [Tool_definition_toml.validate_embedded] pass already turns into a refused
    boot. *)

val status_schema : Masc_domain.tool_schema
val cancel_schema : Masc_domain.tool_schema
val proposal_execute_schema : Masc_domain.tool_schema
