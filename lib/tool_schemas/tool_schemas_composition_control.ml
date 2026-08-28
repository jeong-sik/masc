(** See [tool_schemas_composition_control.mli]. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let status_schema = schema_of_name "keeper_composition_status"
let cancel_schema = schema_of_name "keeper_composition_cancel"
let proposal_execute_schema = schema_of_name "keeper_proposal_execute"
