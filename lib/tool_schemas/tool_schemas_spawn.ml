type action =
  | Start
  | Read
  | Wait
  | Stop

type definition = {
  action : action;
  schema : Masc_domain.tool_schema;
  read_only : bool;
}

(* The description travels with the declaration rather than being restated
   here: each schema is the whole tool_schema, and the file the model is handed
   is the one that should carry it. *)
let definitions : definition list =
  [ { action = Start; schema = Tool_schemas_spawn_toml.start; read_only = false }
  ; { action = Read; schema = Tool_schemas_spawn_toml.read; read_only = true }
    (* Waiting changes nothing, but it is not read-only in the sense a caller
       cares about: it blocks, and a surface that lets a read-only tool block
       for a caller-supplied bound is a surface that can be made to hang. *)
  ; { action = Wait; schema = Tool_schemas_spawn_toml.wait; read_only = false }
  ; { action = Stop; schema = Tool_schemas_spawn_toml.stop; read_only = false }
  ]
;;

let schemas : Masc_domain.tool_schema list =
  List.map (fun definition -> definition.schema) definitions
;;

let find_definition name =
  List.find_opt
    (fun definition ->
       let schema : Masc_domain.tool_schema = definition.schema in
       String.equal schema.name name)
    definitions
;;
