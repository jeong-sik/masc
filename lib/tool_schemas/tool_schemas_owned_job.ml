type action = Start | Status | Cancel | Read_result

type definition =
  { action : action
  ; id : string
  ; schema : Masc_domain.tool_schema
  ; read_only : bool
  }

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let definitions =
  [ { action = Start; id = "start"; schema = schema_of_name "keeper_job_start"; read_only = false }
  ; { action = Status; id = "status"; schema = schema_of_name "keeper_job_status"; read_only = false }
  ; { action = Cancel; id = "cancel"; schema = schema_of_name "keeper_job_cancel"; read_only = false }
  ; { action = Read_result; id = "result"; schema = schema_of_name "keeper_job_result"; read_only = true }
  ]
;;

let schemas = List.map (fun definition -> definition.schema) definitions

let find_definition name =
  List.find_opt
    (fun definition -> String.equal definition.schema.Masc_domain.name name)
    definitions
;;
