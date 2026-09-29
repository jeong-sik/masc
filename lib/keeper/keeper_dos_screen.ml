(* masc_dos_screen for a Keeper: the observation plus a PNG of the same frame
   in the Keeper's vision store, the way Keeper_msx_screen does it for the MSX
   machine. The capture is Tool_misc_dos_lane.capture_png, which every DOS
   image surface shares.

   There is no retained-PNG cache here. Keeper_msx_screen keys its cache on
   the physical identity of the lane's retained RGB string; Dos_machine
   renders a fresh string on every read, so that key would never hit. *)

(* Only the Keeper boundary supplies this identity, from its owned meta.name.
   Neither tool arguments nor a generic MCP caller can name a vision store. *)
let handle ~keeper_name ~base_path ~tool_name ~start_time _args =
  match Tool_misc_dos_lane.capture_png () with
  | Error (Tool_misc_dos_lane.Lane e) ->
    Tool_misc_dos_lane.of_lane ~base_path ~tool_name ~start_time (Error e)
  | Error (Tool_misc_dos_lane.Encode message) ->
    Tool_misc_dos_lane.image_capture_failed ~tool_name ~start_time message
  | Ok { Tool_misc_dos_lane.observation; width; height; png } ->
    (match Keeper_vision_tool.store_frame ~keeper_name png with
     | Error message -> Tool_misc_dos_lane.image_capture_failed ~tool_name ~start_time message
     | Ok handle ->
       Tool_misc_dos_lane.of_lane ~base_path ~tool_name ~start_time (Ok observation)
         ~extra:
           ((( "artifact"
             , `String (Multimodal.Vision_artifact_store.to_string handle) )
             :: Tool_misc_dos_lane.png_fields ~width ~height ~png)
            @ [ Tool_misc_dos_lane.core_field ]))
;;
