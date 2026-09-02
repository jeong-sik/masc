(** [tool_execute], read from [config/tools/tool_execute.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization. A missing file or a declaration that
    does not decode refuses the boot rather than advertising a partial execute
    surface, so a reader never has to ask whether the schema loaded.

    Five flat parameters: [argv] or [script], with [shell], [cwd] and
    [timeout_sec]. [test_execute_tool_toml_parity] pins the shape and the
    description bounds, not bytes. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let tool_execute = schema_of_name "tool_execute"
