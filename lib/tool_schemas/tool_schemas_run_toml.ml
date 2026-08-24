(** The four run tools, read from [config/tools/masc_run_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial run surface, so a reader of these values never has to ask whether a
    schema loaded.

    [test_run_tool_toml_parity] pins all four against what the list published
    before the move. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let init = schema_of_name "masc_run_init"
let plan = schema_of_name "masc_run_plan"
let get = schema_of_name "masc_run_get"
let list = schema_of_name "masc_run_list"
