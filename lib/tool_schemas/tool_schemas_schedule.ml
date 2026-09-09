open Masc_domain

(* [definition] below builds the tool_schema from these parts, so each value
   here is the input_schema alone. *)
let create_schema = Tool_schemas_schedule_toml.create.input_schema
let update_schema = Tool_schemas_schedule_toml.update.input_schema
let list_schema = Tool_schemas_schedule_toml.list.input_schema
let get_schema = Tool_schemas_schedule_toml.get.input_schema
let cancel_schema = Tool_schemas_schedule_toml.cancel.input_schema

type action =
  | Create_request
  | Update_request
  | List_requests
  | Get_request
  | Cancel_request
[@@deriving enumerate]

type definition =
  { action : action
  ; id : string
  ; schema : Masc_domain.tool_schema
  ; read_only : bool
  }

let definition ~action ~id ~name ~description ~input_schema ~read_only =
  { action; id; schema = { name; description; input_schema }; read_only }
;;

(* The description travels with the declaration rather than being restated
   here: each schema below is the whole tool_schema, and [definition] takes its
   description from it. Two copies of the same sentence drift, and the file the
   model is handed is the one that should carry it. *)
let definition_for = function
  | Create_request ->
    definition ~action:Create_request ~id:"create"
      ~name:Tool_schemas_schedule_toml.create.name
      ~description:Tool_schemas_schedule_toml.create.description
      ~input_schema:create_schema ~read_only:false
  | Update_request ->
    definition ~action:Update_request ~id:"update"
      ~name:Tool_schemas_schedule_toml.update.name
      ~description:Tool_schemas_schedule_toml.update.description
      ~input_schema:update_schema ~read_only:false
  | List_requests ->
    definition ~action:List_requests ~id:"list"
      ~name:Tool_schemas_schedule_toml.list.name
      ~description:Tool_schemas_schedule_toml.list.description
      ~input_schema:list_schema ~read_only:true
  | Get_request ->
    definition ~action:Get_request ~id:"get"
      ~name:Tool_schemas_schedule_toml.get.name
      ~description:Tool_schemas_schedule_toml.get.description
      ~input_schema:get_schema ~read_only:true
  | Cancel_request ->
    definition ~action:Cancel_request ~id:"cancel"
      ~name:Tool_schemas_schedule_toml.cancel.name
      ~description:Tool_schemas_schedule_toml.cancel.description
      ~input_schema:cancel_schema ~read_only:false
;;

let definitions : definition list = List.map definition_for all_of_action

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
