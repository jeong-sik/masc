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

let browser_session_schema : tool_schema = Tool_schemas_misc_toml.browser_session
let browser_goto_schema : tool_schema = Tool_schemas_misc_toml.browser_goto
let browser_act_schema : tool_schema = Tool_schemas_misc_toml.browser_act
let browser_interact_schema : tool_schema = Tool_schemas_misc_toml.browser_interact
let browser_instruct_schema : tool_schema = Tool_schemas_misc_toml.browser_instruct

let browser_lane_schemas =
  [ browser_tabs_schema
  ; browser_read_schema
  ; browser_session_schema
  ; browser_goto_schema
  ; browser_act_schema
  ; browser_interact_schema
  ; browser_instruct_schema
  ]

(* [schemas] is the public misc schema set, now read from
   config/tools/masc_*.toml. Operator control and web runtime schemas use the
   dedicated projections above. *)
let lane_addon_schemas : tool_schema list =
  [ Tool_schemas_misc_toml.lane_updates
  ; Tool_schemas_misc_toml.lane_attach
  ; Tool_schemas_misc_toml.lane_declaration_read
  ; Tool_schemas_misc_toml.lane_declaration_save
  ; Tool_schemas_misc_toml.lane_inspect
  ; Tool_schemas_misc_toml.lane_observe
  ; Tool_schemas_misc_toml.lane_slice
  ; Tool_schemas_misc_toml.lane_detach
  ; Tool_schemas_misc_toml.lane_evidence
  ; Tool_schemas_misc_toml.lane_act
  ; Tool_schemas_misc_toml.lane_action_status
  ]

let schemas : tool_schema list =
  lane_addon_schemas
  @ [ Tool_schemas_misc_toml.play_room
    ; Tool_schemas_misc_toml.portrait_read
    ; Tool_schemas_misc_toml.candle_balance
    ; Tool_schemas_misc_toml.candle_catalog
    ; Tool_schemas_misc_toml.candle_purchase
    ; Tool_schemas_misc_toml.candle_equip
    ; Tool_schemas_misc_toml.candle_gift ]
  @ Tool_schemas_operator_surface.schemas

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

(* [misc_operation] is the set [Tool_misc.dispatch] routes. Registration walks
   this list, so the set advertised here and the set routed here are the same
   set. An MSX tool is one constructor carrying {!Msx_tool.t}, so the MSX names
   are written once, in [Msx_tool]. *)
type misc_operation =
  | Misc_lane_declaration_read
  | Misc_lane_declaration_save
  | Misc_lane_updates
  | Misc_lane_attach
  | Misc_lane_inspect
  | Misc_lane_observe
  | Misc_lane_slice
  | Misc_lane_detach
  | Misc_lane_evidence
  | Misc_lane_act
  | Misc_lane_action_status
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
  | Misc_browser_session
  | Misc_browser_goto
  | Misc_browser_act
  | Misc_browser_interact
  | Misc_browser_instruct
  | Misc_msx of Msx_tool.t
  | Misc_portrait_read
  | Misc_candle_balance
  | Misc_candle_catalog
  | Misc_candle_purchase
  | Misc_candle_equip
  | Misc_candle_gift
  | Misc_dos_load
  | Misc_dos_meta
  | Misc_dos_inventory
  | Misc_dos_eject
  | Misc_dos_screen
  | Misc_dos_step
  | Misc_dos_press
  | Misc_dos_click
  | Misc_dos_type
  | Misc_dos_peek
  | Misc_play_room
  | Misc_dos_pass
  | Misc_dos_save
  | Misc_dos_restore
[@@deriving enumerate]

let misc_operations = all_of_misc_operation

(* The DOS tool a misc operation runs, if any. Every operation is named, so a
   new DOS operation is mapped where it is declared. *)
let dos_tool_of_operation : misc_operation -> Machine_controller_contract.dos_tool option =
  let module C = Machine_controller_contract in
  function
  | Misc_dos_load -> Some C.Dos_load
  | Misc_dos_meta -> Some C.Dos_meta
  | Misc_dos_inventory -> Some C.Dos_inventory
  | Misc_dos_eject -> Some C.Dos_eject
  | Misc_dos_screen -> Some C.Dos_screen
  | Misc_dos_step -> Some C.Dos_step
  | Misc_dos_press -> Some C.Dos_press
  | Misc_dos_click -> Some C.Dos_click
  | Misc_dos_type -> Some C.Dos_type
  | Misc_dos_peek -> Some C.Dos_peek
  | Misc_dos_pass -> Some C.Dos_pass
  | Misc_dos_save -> Some C.Dos_save
  | Misc_dos_restore -> Some C.Dos_restore
  | Misc_lane_declaration_read | Misc_lane_declaration_save
  | Misc_lane_updates | Misc_lane_attach | Misc_lane_inspect
  | Misc_lane_observe | Misc_lane_slice | Misc_lane_detach
  | Misc_lane_evidence | Misc_lane_act | Misc_lane_action_status | Misc_ask
  | Misc_ask_status | Misc_ask_withdraw | Misc_config | Misc_dashboard
  | Misc_gc | Misc_keeper_waiting_inventory | Misc_tool_help | Misc_web_fetch
  | Misc_web_search | Misc_browser_tabs | Misc_browser_read
  | Misc_browser_session | Misc_browser_goto | Misc_browser_act
  | Misc_browser_interact | Misc_browser_instruct | Misc_msx _
  | Misc_portrait_read | Misc_candle_balance | Misc_candle_catalog
  | Misc_candle_purchase | Misc_candle_equip | Misc_candle_gift
  | Misc_play_room ->
    None

type dos_controller_need = Machine_controller_contract.controller_need =
  | Takes_controller
  | Hands_controller
  | No_controller

let dos_controller_need operation =
  match dos_tool_of_operation operation with
  | Some tool -> Machine_controller_contract.controller_need tool
  | None -> No_controller

let misc_tool_name = function
  | Misc_lane_declaration_read -> "masc_lane_declaration_read"
  | Misc_lane_declaration_save -> "masc_lane_declaration_save"
  | Misc_lane_updates -> "masc_lane_updates"
  | Misc_lane_attach -> "masc_lane_attach"
  | Misc_lane_inspect -> "masc_lane_inspect"
  | Misc_lane_observe -> "masc_lane_observe"
  | Misc_lane_slice -> "masc_lane_slice"
  | Misc_lane_detach -> "masc_lane_detach"
  | Misc_lane_evidence -> "masc_lane_evidence"
  | Misc_lane_act -> "masc_lane_act"
  | Misc_lane_action_status -> "masc_lane_action_status"
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
  | Misc_browser_session -> "masc_browser_session"
  | Misc_browser_goto -> "masc_browser_goto"
  | Misc_browser_act -> "masc_browser_act"
  | Misc_browser_interact -> "masc_browser_interact"
  | Misc_browser_instruct -> "masc_browser_instruct"
  | Misc_msx tool -> Msx_tool.name tool
  | Misc_portrait_read -> "keeper_portrait_read"
  | Misc_candle_balance -> "keeper_candle_balance"
  | Misc_candle_catalog -> "keeper_candle_catalog"
  | Misc_candle_purchase -> "keeper_candle_purchase"
  | Misc_candle_equip -> "keeper_candle_equip"
  | Misc_candle_gift -> "keeper_candle_gift"
  | Misc_dos_load ->
    Machine_controller_contract.(dos_tool_name Dos_load)
  | Misc_dos_meta ->
    Machine_controller_contract.(dos_tool_name Dos_meta)
  | Misc_dos_inventory ->
    Machine_controller_contract.(dos_tool_name Dos_inventory)
  | Misc_dos_eject ->
    Machine_controller_contract.(dos_tool_name Dos_eject)
  | Misc_dos_screen ->
    Machine_controller_contract.(dos_tool_name Dos_screen)
  | Misc_dos_step ->
    Machine_controller_contract.(dos_tool_name Dos_step)
  | Misc_dos_press ->
    Machine_controller_contract.(dos_tool_name Dos_press)
  | Misc_dos_click ->
    Machine_controller_contract.(dos_tool_name Dos_click)
  | Misc_dos_type ->
    Machine_controller_contract.(dos_tool_name Dos_type)
  | Misc_dos_peek ->
    Machine_controller_contract.(dos_tool_name Dos_peek)
  | Misc_play_room -> "masc_play_room"
  | Misc_dos_pass ->
    Machine_controller_contract.(dos_tool_name Dos_pass)
  | Misc_dos_save ->
    Machine_controller_contract.(dos_tool_name Dos_save)
  | Misc_dos_restore ->
    Machine_controller_contract.(dos_tool_name Dos_restore)
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
  | Misc_msx _
  | Misc_dos_load
  | Misc_dos_meta
  | Misc_dos_inventory
  | Misc_dos_eject
  | Misc_dos_screen
  | Misc_dos_step
  | Misc_dos_press
  | Misc_dos_click
  | Misc_dos_type
  | Misc_dos_peek
  | Misc_play_room
  | Misc_dos_pass
  | Misc_dos_save
  | Misc_dos_restore
  | Misc_web_fetch
  | Misc_web_search
  | Misc_browser_tabs
  | Misc_browser_read
  | Misc_browser_session
  | Misc_browser_goto | Misc_browser_act | Misc_browser_interact | Misc_browser_instruct -> None
  | Misc_lane_declaration_read
  | Misc_lane_declaration_save
  | Misc_lane_updates
  | Misc_lane_attach
  | Misc_lane_inspect
  | Misc_lane_observe
  | Misc_lane_slice
  | Misc_lane_detach
  | Misc_lane_evidence
  | Misc_lane_act
  | Misc_lane_action_status
  | Misc_portrait_read
  | Misc_candle_balance
  | Misc_candle_catalog
  | Misc_candle_purchase
  | Misc_candle_equip
  | Misc_candle_gift
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
