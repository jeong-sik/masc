(* The lane retains immutable RGB strings until machine mutation. Retain one
   encoded frame by physical pixel identity and geometry; metadata is always
   captured afresh, and each caller still persists into its own vision store.
   Stdlib mutex protects only cache lookup/publication; it performs no I/O or
   encoding, and is also used by non-Eio tests. *)
let png_mutex = Mutex.create ()
let retained_png : (int * int * string * string) option ref = ref None

let cached_png (frame : Msx_lane.frame) =
  Mutex.lock png_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock png_mutex) (fun () ->
    match !retained_png with
    | Some (width, height, rgb, png)
      when width = frame.width && height = frame.height && rgb == frame.rgb ->
        Some png
    | _ -> None)

let encode_frame (frame : Msx_lane.frame) =
  match cached_png frame with
  | Some png -> Ok png
  | None ->
      (* Expensive encoding never holds the lookup lock. Concurrent misses may
         encode independently; either published entry is valid for its key. *)
      Result.map
        (fun png ->
          Mutex.lock png_mutex;
          Fun.protect ~finally:(fun () -> Mutex.unlock png_mutex) (fun () ->
            retained_png := Some (frame.width, frame.height, frame.rgb, png));
          png)
        (Rgb_png.encode ~width:frame.width ~height:frame.height ~rgb:frame.rgb)

(* Only the Keeper boundary supplies this identity, from its owned meta.name.
   Neither tool arguments nor a generic MCP caller can name a vision store. *)
let handle ~keeper_name ~tool_name ~start_time _args =
  match Msx_lane.capture () with
  | Error e -> Tool_misc_msx_lane.of_lane ~tool_name ~start_time (Error e)
  | Ok (observation, frame) ->
    let encoded =
      match cached_png frame with
      | Some png -> Ok png
      | None -> Eio_guard.run_in_systhread ~label:"msx-png" (fun () ->
          encode_frame frame)
    in
    let result = Result.bind encoded (fun bytes ->
      Result.map (fun handle -> bytes, handle)
        (Keeper_vision_tool.store_artifact
          ~dir:(Keeper_vision_tool.vision_store_dir ~keeper_name) bytes)) in
    match result with
    | Error message ->
      Tool_result.make_err ~tool_name ~class_:Tool_result.Runtime_failure
        ~start_time ("MSX image capture failed: " ^ message)
    | Ok (bytes, handle) ->
      Tool_misc_msx_lane.of_lane ~tool_name ~start_time (Ok observation)
        ~extra:[ "artifact", `String (Multimodal.Vision_artifact_store.to_string handle)
               ; "media_type", `String "image/png"
               ; "width", `Int frame.width; "height", `Int frame.height
               ; "bytes", `Int (String.length bytes) ]
;;
