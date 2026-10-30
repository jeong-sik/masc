(** The keeper_skill tool, read from [config/tools/keeper_skill.toml]
    (RFC prompts-and-tool-definitions-outside-ocaml §2.2).

    The tool this describes is built per workspace, because the list of
    instruction skills it can read is whatever the catalog found. Only that
    list is assembled at runtime; the sentence telling a Keeper when to reach
    for the tool, and the shape of its one argument, are fixed and belong in
    the TOML with every other tool definition.

    Decoded once at module initialization. A missing file or a declaration that
    does not decode refuses the boot rather than advertising a tool that cannot
    be called. *)

val schema : Masc_domain.tool_schema
