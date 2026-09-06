(** The three provider Files tools, read from
    [config/tools/masc_file_*.toml] (RFC-0430 Phase 3).

    Same decode-once-refuse-the-boot shape as {!Tool_schemas_run_toml}: a
    missing file or a declaration that does not decode stops the boot rather
    than advertising a partial files surface. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let upload = schema_of_name "masc_file_upload"
let delete = schema_of_name "masc_file_delete"
let list = schema_of_name "masc_file_list"
let schemas = [ upload; delete; list ]
