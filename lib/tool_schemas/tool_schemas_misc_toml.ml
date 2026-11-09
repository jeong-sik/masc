(** [masc_web_search] and [masc_web_fetch], read from
    [config/tools/masc_web_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization; a missing or undecodable file
    refuses the boot rather than advertising a partial web surface.
    [Keeper_tool_descriptor] names each value directly rather than reaching
    them through a list. *)

let schema_of_name = Tool_definition_embedded.schema

let web_search = schema_of_name "masc_web_search"
let web_fetch = schema_of_name "masc_web_fetch"
let browser_tabs = schema_of_name "masc_browser_tabs"
let browser_read = schema_of_name "masc_browser_read"
let browser_session = schema_of_name "masc_browser_session"
let browser_goto = schema_of_name "masc_browser_goto"
let browser_act = schema_of_name "masc_browser_act"
let browser_interact = schema_of_name "masc_browser_interact"
(* Every MSX tool's definition is read here, at module initialization, so a
   tool added to [Msx_tool] without its TOML refuses the boot. The table holds
   every tool by construction, so [List.assoc] finds each one. *)
let msx_schema =
  let table = List.map (fun tool -> tool, schema_of_name (Msx_tool.name tool)) Msx_tool.all in
  fun tool -> List.assoc tool table
;;

let candle_balance = schema_of_name "keeper_candle_balance"
let candle_catalog = schema_of_name "keeper_candle_catalog"
let candle_purchase = schema_of_name "keeper_candle_purchase"
let candle_equip = schema_of_name "keeper_candle_equip"
let candle_gift = schema_of_name "keeper_candle_gift"
let pull_requests = schema_of_name "keeper_pull_requests_list"

let dos_step = schema_of_name "masc_dos_step"
let dos_press = schema_of_name "masc_dos_press"
let dos_type = schema_of_name "masc_dos_type"
let play_room = schema_of_name "masc_play_room"
let dos_pass = schema_of_name "masc_dos_pass"

(* Every DOS tool's definition is read here, at module initialization, so a
   tool added to [Machine_controller_contract.dos_tool] without its TOML
   refuses the boot. Only the four the HTTP routes name keep a value. *)
let () =
  List.iter
    (fun tool -> ignore (schema_of_name (Machine_controller_contract.dos_tool_name tool)))
    Machine_controller_contract.all_of_dos_tool
;;

let lane_attach = schema_of_name "masc_lane_attach"
let lane_declaration_read = schema_of_name "masc_lane_declaration_read"
let lane_declaration_save = schema_of_name "masc_lane_declaration_save"
let lane_inspect = schema_of_name "masc_lane_inspect"
let lane_observe = schema_of_name "masc_lane_observe"
let lane_slice = schema_of_name "masc_lane_slice"
let lane_detach = schema_of_name "masc_lane_detach"
let lane_evidence = schema_of_name "masc_lane_evidence"

let lane_act = schema_of_name "masc_lane_act"
let lane_action_status = schema_of_name "masc_lane_action_status"

let lane_updates = schema_of_name "masc_lane_updates"
