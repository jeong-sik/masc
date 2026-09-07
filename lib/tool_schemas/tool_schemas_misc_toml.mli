(** [masc_web_search] and [masc_web_fetch] declarations, moved to
    [config/tools/masc_web_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization; a missing or undecodable file
    refuses the boot. [Tool_schemas_misc] is the only consumer. *)

val web_search : Masc_domain.tool_schema
val web_fetch : Masc_domain.tool_schema
val browser_tabs : Masc_domain.tool_schema
val browser_read : Masc_domain.tool_schema
val browser_session : Masc_domain.tool_schema
val browser_goto : Masc_domain.tool_schema
