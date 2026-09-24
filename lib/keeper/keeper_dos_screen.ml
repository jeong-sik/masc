(* masc_dos_screen for a Keeper: the observation plus a PNG of the same frame
   in the Keeper's vision store, the way Keeper_msx_screen does it for the MSX
   machine. A DOS game in a VGA mode draws its menus as pixels -- 삼국지3's
   Korean menus are glyphs from its own font -- so frame_ascii shows where
   something is drawn but not what it says.

   There is no retained-PNG cache here. Keeper_msx_screen keys its cache on
   the physical identity of the lane's retained RGB string; Dos_machine
   renders a fresh string on every read, so that key would never hit. *)

(* Only the Keeper boundary supplies this identity, from its owned meta.name.
   Neither tool arguments nor a generic MCP caller can name a vision store. *)
let handle ~keeper_name ~tool_name ~start_time _args =
  match Dos_lane.capture () with
  | Error e -> Tool_misc_dos_lane.of_lane ~tool_name ~start_time (Error e)
  | Ok (observation, frame) ->
    let result =
      Result.bind
        (Eio_guard.run_in_systhread ~label:"dos-png" (fun () ->
           Rgb_png.encode ~width:frame.width ~height:frame.height ~rgb:frame.rgb))
        (fun bytes ->
          Result.map
            (fun handle -> (bytes, handle))
            (Keeper_vision_tool.store_artifact
               ~dir:(Keeper_vision_tool.vision_store_dir ~keeper_name)
               bytes))
    in
    (match result with
     | Error message ->
       Tool_result.make_err ~tool_name ~class_:Tool_result.Runtime_failure ~start_time
         ("DOS image capture failed: " ^ message)
     | Ok (bytes, handle) ->
       Tool_misc_dos_lane.of_lane ~tool_name ~start_time (Ok observation)
         ~extra:
           [ ("artifact", `String (Multimodal.Vision_artifact_store.to_string handle))
           ; ("media_type", `String "image/png")
           ; ("width", `Int frame.width)
           ; ("height", `Int frame.height)
           ; ("bytes", `Int (String.length bytes))
           ])
;;
