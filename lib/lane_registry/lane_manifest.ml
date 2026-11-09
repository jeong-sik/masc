let label : Lane_id.builtin -> string = function
  | Lane_id.Exact lane -> Lane_run_identity.label (Standalone_lane.run_identity lane)
  | Lane_id.Browser Browser_lane.Lane_name.Live -> "Browser Lane (live)"
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
  | Lane_id.Exact Standalone_lane.Verifier ->
    "Reviews Task completion and Goal proof evidence."
  | Lane_id.Exact Standalone_lane.Candle_appraiser ->
    "Appraises a confirmed Goal payout grade, each candidate Task's relation to the Goal, and Keeper contribution weights."
  | Lane_id.Browser Browser_lane.Lane_name.Live ->
    "Reads and drives tabs in the operator's own browser, through the browser-lane extension \
     and host."
  | Lane_id.Machine Machine_lane.Msx ->
    "The one MSX machine in the server; masc_msx_* tools put keys in and read its screen."
  | Lane_id.Machine Machine_lane.Dos ->
    "The one DOS machine in the server; masc_dos_* tools put keys in and read its screen."
;;

let browser_backends = List.map (fun lane -> Lane_id.Browser lane) Browser_lane.Lane_name.all

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
  | Tool_schemas_misc.Misc_sandbox_volume_gc
  | Tool_schemas_misc.Misc_keeper_waiting_inventory
  | Tool_schemas_misc.Misc_tool_help
  | Tool_schemas_misc.Misc_candle_balance
  | Tool_schemas_misc.Misc_candle_catalog
  | Tool_schemas_misc.Misc_candle_purchase
  | Tool_schemas_misc.Misc_candle_equip
  | Tool_schemas_misc.Misc_candle_gift
  | Tool_schemas_misc.Misc_web_fetch
  | Tool_schemas_misc.Misc_play_room
  | Tool_schemas_misc.Misc_pull_requests
  | Tool_schemas_misc.Misc_web_search -> []
  | Tool_schemas_misc.Misc_browser_tabs
  | Tool_schemas_misc.Misc_browser_read
  | Tool_schemas_misc.Misc_browser_act
  | Tool_schemas_misc.Misc_browser_interact
  | Tool_schemas_misc.Misc_browser_session
  | Tool_schemas_misc.Misc_browser_goto -> browser_backends
  | Tool_schemas_misc.Misc_msx _ -> [ Lane_id.Machine Machine_lane.Msx ]
  | Tool_schemas_misc.Misc_dos_load
  | Tool_schemas_misc.Misc_dos_meta
  | Tool_schemas_misc.Misc_dos_inventory
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
