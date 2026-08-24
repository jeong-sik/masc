open Masc_domain

(* [definition] below builds the tool_schema from these parts, so each value
   here is the input_schema alone. *)
let create_schema = Tool_schemas_schedule_toml.create.input_schema
let list_schema = Tool_schemas_schedule_toml.list.input_schema
let get_schema = Tool_schemas_schedule_toml.get.input_schema
let cancel_schema = Tool_schemas_schedule_toml.cancel.input_schema

type action =
  | Create_request
  | List_requests
  | Get_request
  | Cancel_request

type definition =
  { action : action
  ; id : string
  ; schema : Masc_domain.tool_schema
  ; read_only : bool
  }

let definition ~action ~id ~name ~description ~input_schema ~read_only =
  { action; id; schema = { name; description; input_schema }; read_only }
;;

let definitions : definition list =
  [ definition ~action:Create_request ~id:"create" ~name:"masc_schedule_create"
      ~description:
        "Create a durable Keeper wake request. For 'every day at 09:00 KST', use recurrence_kind=daily, recurrence_hour=9, recurrence_minute=0, recurrence_timezone=Asia/Seoul. For compact calendar rules, use recurrence_kind=cron with a 5-field recurrence_cron such as '0 9 * * 1-5'. The due request wakes its Keeper; it does not authorize later effects. When the creating turn has a routable continuation, the runtime records that exact route as the result destination; otherwise it records an explicit no-delivery policy."
      ~input_schema:create_schema ~read_only:false
  ; definition ~action:List_requests ~id:"list" ~name:"masc_schedule_list"
      ~description:"List durable scheduled internal automation requests."
      ~input_schema:list_schema ~read_only:true
  ; definition ~action:Get_request ~id:"get" ~name:"masc_schedule_get"
      ~description:
        "Read the current durable scheduled request by schedule_id. A recurring request may already point at its next occurrence."
      ~input_schema:get_schema ~read_only:true
  ; definition ~action:Cancel_request ~id:"cancel" ~name:"masc_schedule_cancel"
      ~description:
        "Cancel a scheduled or due request before execution."
      ~input_schema:cancel_schema ~read_only:false
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
