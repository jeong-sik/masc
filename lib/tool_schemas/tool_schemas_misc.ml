(** Tool schemas for Tool_misc — separated to break Config dependency cycle *)

open Masc_domain

type control_operation =
  | Pause
  | Resume
  | Pause_status
[@@deriving enumerate]

let control_operations = all_of_control_operation

let control_operation_id = function
  | Pause -> "pause"
  | Resume -> "resume"
  | Pause_status -> "pause_status"
;;

let control_schema = function
  | Pause -> Tool_schemas_operator_surface.pause
  | Resume -> Tool_schemas_operator_surface.resume
  | Pause_status -> Tool_schemas_operator_surface.pause_status
;;

let control_schemas = List.map control_schema control_operations

let web_search_schema : tool_schema = Tool_schemas_misc_toml.web_search
let web_fetch_schema : tool_schema = Tool_schemas_misc_toml.web_fetch

let web_schemas = [ web_search_schema; web_fetch_schema ]

let browser_tabs_schema : tool_schema = Tool_schemas_misc_toml.browser_tabs
let browser_read_schema : tool_schema = Tool_schemas_misc_toml.browser_read

let browser_lane_schemas = [ browser_tabs_schema; browser_read_schema ]

(* [schemas] is the public misc schema set, now read from
   config/tools/masc_*.toml. Operator control and web runtime schemas use the
   dedicated projections above. *)
let schemas : tool_schema list = Tool_schemas_operator_surface.schemas

type mcp_runtime_operation =
  | Start
  | Broadcast
  | Messages
  | Ask
  | Ask_status
  | Ask_withdraw
[@@deriving enumerate]

let mcp_runtime_operations = all_of_mcp_runtime_operation

let mcp_runtime_tool_name = function
  | Start -> "masc_start"
  | Broadcast -> "masc_broadcast"
  | Messages -> "masc_messages"
  | Ask -> "masc_ask"
  | Ask_status -> "masc_ask_status"
  | Ask_withdraw -> "masc_ask_withdraw"
;;

let mcp_runtime_operation_of_tool_name value =
  List.find_opt
    (fun operation -> String.equal value (mcp_runtime_tool_name operation))
    mcp_runtime_operations
;;

let mcp_runtime_schema operation =
  let name = mcp_runtime_tool_name operation in
  match
    List.find_opt
      (fun (schema : tool_schema) -> String.equal schema.name name)
      schemas
  with
  | Some schema -> schema
  | None -> invalid_arg ("missing MCP runtime schema: " ^ name)
;;

let mcp_runtime_schemas = List.map mcp_runtime_schema mcp_runtime_operations

(* [misc_operation] is the set [Tool_misc.dispatch] routes.

   The facade used to register the whole [schemas] list under [Mod_misc] while
   routing only part of it. masc_broadcast, masc_messages, masc_start and the
   three masc_plan_* names were registered there without a route and answered
   correctly only because Tool_plan and Mcp_tool_runtime link later and
   overwrite the module tag -- [Tool_dispatch.register_module_tag] is a map
   insert, so the last registrar wins. Registration now walks this list, so the
   set advertised here and the set routed here are the same set. *)
type misc_operation =
  | Misc_ask
  | Misc_ask_status
  | Misc_ask_withdraw
  | Misc_config
  | Misc_dashboard
  | Misc_gc
  | Misc_keeper_waiting_inventory
  | Misc_tool_help
  | Misc_web_fetch
  | Misc_web_search
  | Misc_browser_tabs
  | Misc_browser_read
[@@deriving enumerate]

let misc_operations = all_of_misc_operation

let misc_tool_name = function
  | Misc_ask -> "masc_ask"
  | Misc_ask_status -> "masc_ask_status"
  | Misc_ask_withdraw -> "masc_ask_withdraw"
  | Misc_config -> "masc_config"
  | Misc_dashboard -> "masc_dashboard"
  | Misc_gc -> "masc_gc"
  | Misc_keeper_waiting_inventory -> "masc_keeper_waiting_inventory"
  | Misc_tool_help -> "masc_tool_help"
  | Misc_web_fetch -> "masc_web_fetch"
  | Misc_web_search -> "masc_web_search"
  | Misc_browser_tabs -> "masc_browser_tabs"
  | Misc_browser_read -> "masc_browser_read"
;;

let misc_operation_of_tool_name value =
  List.find_opt
    (fun operation -> String.equal value (misc_tool_name operation))
    misc_operations
;;

(* [None] marks a name the facade routes but must not advertise: the two web
   tools reach the inventory through [Config.raw_all_tool_schemas] and take
   their module tag from their keeper descriptor. A name whose declaration is
   missing refuses the boot rather than registering a partial surface. *)
let misc_registered_schema operation : tool_schema option =
  match operation with
  | Misc_web_fetch | Misc_web_search | Misc_browser_tabs | Misc_browser_read -> None
  | Misc_ask
  | Misc_ask_status
  | Misc_ask_withdraw
  | Misc_config
  | Misc_dashboard
  | Misc_gc
  | Misc_keeper_waiting_inventory
  | Misc_tool_help ->
    let name = misc_tool_name operation in
    (match
       List.find_opt (fun (schema : tool_schema) -> String.equal schema.name name) schemas
     with
     | Some schema -> Some schema
     | None -> invalid_arg ("missing misc schema: " ^ name))
;;

(* [plan_operation] is the set [Tool_plan] routes and registers. It replaced
   three hand-written string lists in that module -- the dispatcher's arms, the
   [is_plan] filter that picked plan names out of [schemas], and a read-only
   membership list -- which could disagree without the compiler noticing. *)
type plan_operation =
  | Plan_clear_task
  | Plan_get_task
  | Plan_set_task
[@@deriving enumerate]

let plan_operations = all_of_plan_operation

let plan_tool_name = function
  | Plan_clear_task -> "masc_plan_clear_task"
  | Plan_get_task -> "masc_plan_get_task"
  | Plan_set_task -> "masc_plan_set_task"
;;

let plan_operation_of_tool_name value =
  List.find_opt
    (fun operation -> String.equal value (plan_tool_name operation))
    plan_operations
;;

let plan_schema operation =
  let name = plan_tool_name operation in
  match
    List.find_opt (fun (schema : tool_schema) -> String.equal schema.name name) schemas
  with
  | Some schema -> schema
  | None -> invalid_arg ("missing plan schema: " ^ name)
;;
