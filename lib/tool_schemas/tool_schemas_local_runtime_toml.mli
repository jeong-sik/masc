(** The two local-runtime tool declarations that moved to
    [config/tools/masc_runtime_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization; a missing or undecodable file
    refuses the boot rather than advertising a partial local-runtime surface.

    The operation vocabulary stays in OCaml: [Local_runtime_tool_policy] maps
    each operation to an execution policy and a model-exposure decision, and
    those are code rather than declarations. [Tool_schemas_local_runtime] is
    the only consumer. *)

val verify : Masc_domain.tool_schema
val ollama_probe : Masc_domain.tool_schema
