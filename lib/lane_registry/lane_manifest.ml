let label : Lane_id.builtin -> string = function
  | Lane_id.Exact Standalone_lane.Board_attention -> "Board Attention"
  | Lane_id.Exact Standalone_lane.Hitl_auto_judge -> "HITL Auto Judge"
  | Lane_id.Exact Standalone_lane.Librarian -> "Librarian"
  | Lane_id.Exact Standalone_lane.Workspace_curator -> "Workspace Curator"
  | Lane_id.Exact Standalone_lane.Verifier -> "Verifier"
  | Lane_id.Exact Standalone_lane.Browser_stagehand -> "Browser Stagehand"
  | Lane_id.Exact Standalone_lane.Candle_appraiser -> "Candle Appraiser"
  | Lane_id.Browser Browser_lane.Lane_name.Live -> "Browser Lane (live)"
  | Lane_id.Browser Browser_lane.Lane_name.Automation -> "Browser Lane (automation)"
  | Lane_id.Browser Browser_lane.Lane_name.Stagehand -> "Browser Lane (stagehand)"
  | Lane_id.Machine Machine_lane.Msx -> "MSX"
  | Lane_id.Machine Machine_lane.Dos -> "DOS"
;;

let purpose : Lane_id.builtin -> string = function
  | Lane_id.Exact Standalone_lane.Board_attention ->
    "Judges one durable Board candidate for Keeper attention."
  | Lane_id.Exact Standalone_lane.Hitl_auto_judge ->
    "Produces the structured judgment for one held approval."
  | Lane_id.Exact Standalone_lane.Librarian ->
    "Selects the next Memory OS snapshot from immutable Keeper history."
  | Lane_id.Exact Standalone_lane.Workspace_curator ->
    "Synthesizes attributed proposals after committed workspace memory changes; semantic \
     verification is not performed."
  | Lane_id.Exact Standalone_lane.Verifier ->
    "Reviews Task completion and Goal proof evidence."
  | Lane_id.Exact Standalone_lane.Browser_stagehand ->
    "Answers structured model requests from the Stagehand browser lane; run records are not \
     retained yet."
  | Lane_id.Exact Standalone_lane.Candle_appraiser ->
    "Appraises a confirmed Goal payout grade, each candidate Task's relation to the Goal, and Keeper contribution weights."
  | Lane_id.Browser Browser_lane.Lane_name.Live ->
    "Reads and drives tabs in the operator's own browser, through the browser-lane extension \
     and host."
  | Lane_id.Browser Browser_lane.Lane_name.Automation ->
    "Drives a Firefox the server starts through geckodriver."
  | Lane_id.Browser Browser_lane.Lane_name.Stagehand ->
    "Drives a Chromium the server starts with the Stagehand extension; sentence verbs are \
     answered there."
  | Lane_id.Machine Machine_lane.Msx ->
    "The one MSX machine in the server; masc_msx_* tools put keys in and read its screen."
  | Lane_id.Machine Machine_lane.Dos ->
    "The one DOS machine in the server; masc_dos_* tools put keys in and read its screen."
;;

let browser_backends = List.map (fun lane -> Lane_id.Browser lane) Browser_lane.Lane_name.all

(* Sessions and navigation belong to the backends whose browser the server
   owns; [Browser_lane.server_lane_of_name] is where that is decided. *)
let server_browser_backends =
  List.filter_map
    (fun lane ->
       Option.map
         (fun (_ : Browser_lane.server_lane) -> Lane_id.Browser lane)
         (Browser_lane.server_lane_of_name lane))
    Browser_lane.Lane_name.all
;;

let lanes_of_misc_operation : Tool_schemas_misc.misc_operation -> Lane_id.builtin list =
  function
  | Tool_schemas_misc.Misc_lane_declaration_read
  | Tool_schemas_misc.Misc_lane_declaration_save
  | Tool_schemas_misc.Misc_lane_updates
  | Tool_schemas_misc.Misc_lane_attach
  | Tool_schemas_misc.Misc_lane_inspect
  | Tool_schemas_misc.Misc_lane_observe
  | Tool_schemas_misc.Misc_lane_slice
  | Tool_schemas_misc.Misc_lane_detach
  | Tool_schemas_misc.Misc_lane_evidence
  | Tool_schemas_misc.Misc_lane_act
  | Tool_schemas_misc.Misc_lane_action_status -> []
  | Tool_schemas_misc.Misc_ask
  | Tool_schemas_misc.Misc_ask_status
  | Tool_schemas_misc.Misc_ask_withdraw
  | Tool_schemas_misc.Misc_config
  | Tool_schemas_misc.Misc_dashboard
  | Tool_schemas_misc.Misc_gc
  | Tool_schemas_misc.Misc_keeper_waiting_inventory
  | Tool_schemas_misc.Misc_tool_help
  | Tool_schemas_misc.Misc_portrait_read
  | Tool_schemas_misc.Misc_candle_balance
  | Tool_schemas_misc.Misc_candle_catalog
  | Tool_schemas_misc.Misc_candle_purchase
  | Tool_schemas_misc.Misc_candle_equip
  | Tool_schemas_misc.Misc_web_fetch
  | Tool_schemas_misc.Misc_web_search -> []
  | Tool_schemas_misc.Misc_browser_tabs
  | Tool_schemas_misc.Misc_browser_read
  | Tool_schemas_misc.Misc_browser_act
  | Tool_schemas_misc.Misc_browser_interact -> browser_backends
  | Tool_schemas_misc.Misc_browser_session | Tool_schemas_misc.Misc_browser_goto ->
    server_browser_backends
  | Tool_schemas_misc.Misc_browser_instruct -> [ Lane_id.Browser Browser_lane.Lane_name.Stagehand ]
  | Tool_schemas_misc.Misc_msx_load
  | Tool_schemas_misc.Misc_msx_eject
  | Tool_schemas_misc.Misc_msx_save
  | Tool_schemas_misc.Misc_msx_restore
  | Tool_schemas_misc.Misc_msx_change_disk
  | Tool_schemas_misc.Misc_msx_screen
  | Tool_schemas_misc.Misc_msx_press
  | Tool_schemas_misc.Misc_msx_step
  | Tool_schemas_misc.Misc_msx_step_until_change
  | Tool_schemas_misc.Misc_msx_peek
  | Tool_schemas_misc.Misc_msx_ram_diff -> [ Lane_id.Machine Machine_lane.Msx ]
  | Tool_schemas_misc.Misc_dos_load
  | Tool_schemas_misc.Misc_dos_eject
  | Tool_schemas_misc.Misc_dos_screen
  | Tool_schemas_misc.Misc_dos_step
  | Tool_schemas_misc.Misc_dos_press
  | Tool_schemas_misc.Misc_dos_click
  | Tool_schemas_misc.Misc_dos_type
  | Tool_schemas_misc.Misc_dos_peek
  | Tool_schemas_misc.Misc_dos_pass
  | Tool_schemas_misc.Misc_dos_save
  | Tool_schemas_misc.Misc_dos_restore -> [ Lane_id.Machine Machine_lane.Dos ]
;;

let tools builtin =
  List.filter
    (fun operation ->
       List.exists (Lane_id.equal_builtin builtin) (lanes_of_misc_operation operation))
    Tool_schemas_misc.misc_operations
;;
