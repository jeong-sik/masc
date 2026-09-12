(** [masc_web_search] and [masc_web_fetch], read from
    [config/tools/masc_web_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization; a missing or undecodable file
    refuses the boot rather than advertising a partial web surface.
    [Keeper_tool_descriptor] names each value directly rather than reaching
    them through a list. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let web_search = schema_of_name "masc_web_search"
let web_fetch = schema_of_name "masc_web_fetch"
let browser_tabs = schema_of_name "masc_browser_tabs"
let browser_read = schema_of_name "masc_browser_read"
let browser_session = schema_of_name "masc_browser_session"
let browser_goto = schema_of_name "masc_browser_goto"
let browser_act = schema_of_name "masc_browser_act"
let browser_interact = schema_of_name "masc_browser_interact"
let msx_load = schema_of_name "masc_msx_load"
let msx_eject = schema_of_name "masc_msx_eject"
let msx_save = schema_of_name "masc_msx_save"
let msx_restore = schema_of_name "masc_msx_restore"
let msx_change_disk = schema_of_name "masc_msx_change_disk"
let msx_screen = schema_of_name "masc_msx_screen"
let msx_press = schema_of_name "masc_msx_press"
let msx_step = schema_of_name "masc_msx_step"
let msx_step_until_change = schema_of_name "masc_msx_step_until_change"
let msx_peek = schema_of_name "masc_msx_peek"
let msx_ram_diff = schema_of_name "masc_msx_ram_diff"

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
