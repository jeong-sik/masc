(** The keeper_code_query tool, read from [config/tools/keeper_code_query.toml]
    (RFC prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization. A missing file or a declaration that
    does not decode refuses the boot rather than advertising a tool that cannot
    be called, so a reader of this value never has to ask whether it loaded. *)

val schema : Masc_domain.tool_schema
val schemas : Masc_domain.tool_schema list
