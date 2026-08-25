(** The two local-runtime tools, read from [config/tools/masc_runtime_*.toml]
    (RFC prompts-and-tool-definitions-outside-ocaml §2.2).

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial local-runtime surface.

    The operation vocabulary stays in OCaml: [Local_runtime_tool_policy] maps
    each operation to an execution policy and a model-exposure decision, and
    those are code rather than declarations. Only the name, description and
    parameters moved. [test_local_runtime_tool_toml_parity] pins both against
    what the list published before the move. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let verify = schema_of_name "masc_runtime_verify"
let ollama_probe = schema_of_name "masc_runtime_ollama_probe"
