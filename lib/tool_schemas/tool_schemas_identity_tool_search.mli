(** The attached-service tool listing, read from
    [config/tools/keeper_tool_search.toml]
    (RFC prompts-and-tool-definitions-outside-ocaml §2.2).

    Only the fixed part is declared there: what the tool does, how to name a
    tool, and what happens to a name that is not passed. The listing itself is
    one line per tool the Keeper has attached this turn, so it is appended by
    {!Keeper_identity_tool_search} rather than written down.

    Decoded once at module initialization; a missing file or a declaration
    that fails to load raises, which the boot-time
    [Tool_definition_toml.validate_embedded] pass already turns into a refused
    boot. *)

val schema : Masc_domain.tool_schema
