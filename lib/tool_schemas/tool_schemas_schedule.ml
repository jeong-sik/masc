open Masc_domain

let create_tool = Tool_definition_embedded.schema "masc_schedule_create"
let update_tool = Tool_definition_embedded.schema "masc_schedule_update"
let list_tool = Tool_definition_embedded.schema "masc_schedule_list"
let get_tool = Tool_definition_embedded.schema "masc_schedule_get"
let cancel_tool = Tool_definition_embedded.schema "masc_schedule_cancel"
let note_add_tool = Tool_definition_embedded.schema "masc_schedule_note_add"
let notes_list_tool = Tool_definition_embedded.schema "masc_schedule_notes_list"

type action =
  | Create_request
  | Update_request
  | List_requests
  | Get_request
  | Cancel_request
  | Add_note
  | List_notes
[@@deriving enumerate]

type definition =
  { action : action
  ; id : string
  ; schema : Masc_domain.tool_schema
  ; read_only : bool
  }

let definition ~action ~id ~schema ~read_only = { action; id; schema; read_only }

let definition_for = function
  | Create_request ->
    definition ~action:Create_request ~id:"create" ~schema:create_tool ~read_only:false
  | Update_request ->
    definition ~action:Update_request ~id:"update" ~schema:update_tool ~read_only:false
  | List_requests ->
    definition ~action:List_requests ~id:"list" ~schema:list_tool ~read_only:true
  | Get_request ->
    definition ~action:Get_request ~id:"get" ~schema:get_tool ~read_only:true
  | Cancel_request ->
    definition ~action:Cancel_request ~id:"cancel" ~schema:cancel_tool ~read_only:false
  | Add_note ->
    definition ~action:Add_note ~id:"note_add" ~schema:note_add_tool ~read_only:false
  | List_notes ->
    definition ~action:List_notes ~id:"notes_list" ~schema:notes_list_tool ~read_only:true
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
