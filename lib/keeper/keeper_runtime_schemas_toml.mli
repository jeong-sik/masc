(** The keeper runtime tool declarations that moved to [config/tools/*.toml]
    (RFC prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization. A missing file or a declaration that
    does not decode refuses the boot rather than advertising a partial runtime
    surface. [Keeper_tool_runtime_schemas] is the only consumer; the three
    tools still there are explained in the implementation. *)

val fusion : Masc_domain.tool_schema
val fusion_status : Masc_domain.tool_schema
val artifact_read : Masc_domain.tool_schema
val analyze_image : Masc_domain.tool_schema

val skill : Masc_domain.tool_schema
(** keeper_skill's declaration. Its [description] is the static half only:
    [Keeper_tool_composition_surface] appends the skills this keeper carries,
    which are workspace state and have no place in a shipped file. *)
