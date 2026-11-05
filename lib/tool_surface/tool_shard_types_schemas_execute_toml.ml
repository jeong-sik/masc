(** [tool_execute], read from [config/tools/tool_execute.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization. A missing file or a declaration that
    does not decode refuses the boot rather than advertising a partial execute
    surface, so a reader never has to ask whether the schema loaded.

    Six flat parameters: [argv] or [command], with [shell], [cwd],
    [timeout_sec] and [intent]. [test_execute_tool_toml_parity] pins the shape and the
    description bounds, not bytes. *)

let schema_of_name = Tool_definition_embedded.schema

let tool_execute = schema_of_name "tool_execute"
