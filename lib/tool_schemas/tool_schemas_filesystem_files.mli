(** Name, description and parameters for the four filesystem tools, read from
    the binary-embedded [config/tools/tool_{read,edit,write,search}_file*.toml]
    declarations (RFC prompts-and-tool-definitions-outside-ocaml §2.2).

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial filesystem surface, so a reader of these values never has to ask
    whether a schema loaded.

    [test_filesystem_tool_toml_parity] pins all four against the literals this
    module replaced. *)

val read_file : Masc_domain.tool_schema
val edit_file : Masc_domain.tool_schema
val write_file : Masc_domain.tool_schema
val search_files : Masc_domain.tool_schema
