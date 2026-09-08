(* Bridge from an MSX observation to the caller's vision store.

   A tool result is text on the wire, so [image = true] puts the PNG frame
   into the caller's vision store and the observation JSON carries the
   artifact handle — the path a browser screenshot takes (RFC-0414), which
   the keeper then reads with analyze_image. The keeper-side call lives in
   this plain module and not in the tool handler because the generic tool
   surface must not reference the keeper subsystem (RFC-0194): keeper
   depends on tools, never the reverse.

   A refused store keeps the rest of the observation and says why in
   image_error — the machine itself is unaffected. *)

let fields ~agent_name (o : Msx_lane.observation) : (string * Yojson.Safe.t) list =
  match o.image_png with
  | None -> []
  | Some png -> (
    let dir = Keeper_vision_tool.vision_store_dir ~keeper_name:agent_name in
    match Keeper_vision_tool.validate_image_size png with
    | Error message ->
      Log.MsxLog.warn "msx frame image rejected by the vision size limit: %s" message;
      [ ("image_error", `String message) ]
    | Ok () -> (
      match Keeper_vision_tool.store_artifact ~dir png with
      | Error message ->
        Log.MsxLog.warn "msx frame image store refused: %s" message;
        [ ("image_error", `String message) ]
      | Ok handle ->
        [ ( "image_artifact"
          , `String (Multimodal.Vision_artifact_store.to_string handle) )
        ; ("image_media_type", `String "image/png")
        ; ("image_bytes", `Int (String.length png))
        ]))
