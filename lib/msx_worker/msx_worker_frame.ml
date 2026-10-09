(* "who is at the machine": each keeper's most-recent key within a window of the
   current frame, newest first, projected from the shared ledger. The lane is one
   machine anyone may press, so this reports presence -- it does not reserve the
   slot. A turn in a turn-based game can run long, so the window is a full
   minute of machine time at the machine's frame rate. *)
let players_window_sec = 60
let players_window_frames = players_window_sec * Msx_lane.frames_per_second

let recent_players_of ~now entries =
  let last : (string, int) Hashtbl.t = Hashtbl.create 8 in
  List.iter
    (fun (e : Msx_lane.entry) ->
      Hashtbl.replace last e.Msx_lane.who e.Msx_lane.at_frame)
    entries;
  Hashtbl.fold
    (fun who f acc ->
      if now - f <= players_window_frames then (who, f) :: acc else acc)
    last []
  |> List.sort (fun (_, a) (_, b) -> compare b a)
;;

(* The lane owns immutable RGB snapshots and reuses their identity until a
   machine mutation. Cache only pixel encoding: clock and player metadata must
   remain live. One entry bounds retained memory across load/restore/eject.
   Stdlib mutex: this pure serializer also runs outside Eio in route tests;
   neither the protected lookup nor Base64 encoding performs I/O or yields. *)
let encoded_pixels_mutex = Mutex.create ()
let encoded_pixels : (string * string) option ref = ref None

let frame_rgb_base64 rgb =
  Mutex.lock encoded_pixels_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock encoded_pixels_mutex) (fun () ->
    match !encoded_pixels with
    | Some (previous, encoded) when previous == rgb -> encoded
    | None | Some _ ->
        let encoded = Base64.encode_string rgb in
        encoded_pixels := Some (rgb, encoded);
        encoded)
;;

(* Frames per poll-cadence tick (RFC-0439 §3.2). At the TUI's ~3 Hz spectator
   poll this advances ~54 frames a second, close enough to the machine's 60 Hz
   that a game reads as live without a server-side ticker. *)
let msx_tick_default_frames = 18

let clamp_tick_frames requested = max 1 (min Msx_lane.max_frames_per_call requested)

type pixel_reference = { revision : string; width : int; height : int }
type pixel_response = Full_frame | Retained_pixels of pixel_reference option

let decode_pixel_reference = function
  | `Assoc fields when List.length fields = 3 ->
      (match List.assoc_opt "revision" fields, List.assoc_opt "width" fields,
             List.assoc_opt "height" fields with
       | Some (`String revision), Some (`Int width), Some (`Int height)
         when String.length revision = 64 && width > 0 && height > 0
              && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) revision ->
           Ok { revision; width; height }
       | _ -> Error "known_pixels requires a SHA256 revision and positive width/height")
  | _ -> Error "known_pixels requires exactly revision, width and height"

let decode_tick body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error _ -> Error "tick body must be valid JSON"
  | `Assoc fields ->
      let ( let* ) = Result.bind in
      let names = List.map fst fields in
      let* () =
        if List.length names <> List.length (List.sort_uniq String.compare names)
           || List.exists (fun name -> not (List.mem name ["frames"; "pixel_response"; "known_pixels"])) names
        then Error "tick has duplicate or unknown fields" else Ok () in
      let* frames = match List.assoc_opt "frames" fields with
        | None -> Ok msx_tick_default_frames
        | Some (`Int n) -> Ok (clamp_tick_frames n)
        | Some _ -> Error "frames must be an integer" in
      let* pixels = match List.assoc_opt "pixel_response" fields, List.assoc_opt "known_pixels" fields with
        | None, None -> Ok Full_frame
        | Some (`String "retained"), None -> Ok (Retained_pixels None)
        | Some (`String "retained"), Some value ->
            Result.map (fun reference -> Retained_pixels (Some reference)) (decode_pixel_reference value)
        | _ -> Error "known_pixels requires pixel_response=retained" in
      Ok (frames, pixels)
  | _ -> Error "tick body must be an object"
;;

type prepared_pixels = { rgb : string; encoded : string; reference : pixel_reference }
let tick_pixels_mutex = Mutex.create ()
let tick_pixels : prepared_pixels option ref = ref None

let prepare_tick_pixels (frame : Msx_lane.frame) =
  let previous = Mutex.protect tick_pixels_mutex (fun () -> !tick_pixels) in
  match previous with
  | Some pixels when pixels.reference.width = frame.width
                     && pixels.reference.height = frame.height
                     && String.equal pixels.rgb frame.rgb -> pixels
  | Some _ | None ->
      (* Advance invalidates the lane's RGB object even for identical pixels.
         Compare bytes before hashing/encoding; CPU work never holds this lock. *)
      let pixels =
        { rgb = frame.rgb; encoded = Base64.encode_string frame.rgb;
          reference = { width = frame.width; height = frame.height;
            revision = Digestif.SHA256.(to_hex (digest_string frame.rgb)) } } in
      Mutex.protect tick_pixels_mutex (fun () -> tick_pixels := Some pixels);
      pixels

let tick_frame_json pixel_response (frame : Msx_lane.frame) entries
    (mark : Msx_lane.change_mark) =
  let pixel_fields = match pixel_response with
    | Full_frame -> ["rgb_base64", `String (frame_rgb_base64 frame.rgb)]
    | Retained_pixels known ->
        let pixels = prepare_tick_pixels frame in
        let retained = known = Some pixels.reference in
        let fields =
          ["kind", `String (if retained then "retained" else "inline");
           "revision", `String pixels.reference.revision;
           "width", `Int frame.width; "height", `Int frame.height] in
        ["pixels", `Assoc (if retained then fields
           else fields @ ["rgb_base64", `String pixels.encoded])] in
  `Assoc
    (["loaded", `Bool true; "number", `Int frame.number;
      "change_count", `Int mark.count; "incarnation", `String mark.incarnation;
      "width", `Int frame.width; "height", `Int frame.height;
      "mode", `String frame.mode;
      "cartridge", (match frame.cartridge with Some s -> `String s | None -> `Null);
      "disk", (match frame.disk with Some s -> `String s | None -> `Null);
      "players", `List (List.map (fun (who, last) ->
        `Assoc ["who", `String who; "last_frame", `Int last;
                "frames_ago", `Int (frame.number - last)])
          (recent_players_of ~now:frame.number entries))] @ pixel_fields)

let step ~arguments =
  let tool_name = "masc_msx_step" and start_time = Tool_timing.start () in
  let fields = match arguments with `Assoc fields -> fields | _ -> [] in
  let fields = List.remove_assoc "include_frame" fields in
  let fields = if List.mem_assoc "frames" fields then fields
    else ("frames", `Int 60) :: fields in
  match decode_tick (Yojson.Safe.to_string (`Assoc fields)) with
  | Error message -> Tool_result.make_err ~tool_name ~start_time
      ~class_:Tool_result.Workflow_rejection ~effect_disposition:Tool_result.Proven_pre_effect message
  | Ok (frames, pixel_response) ->
      match Msx_lane.step_frame ~frames with
      | Ok (frame, entries, mark) ->
          (* The frames were run, so declare the progress the sibling step path
             declares: without it the repeat guard reads five identical
             include_frame steps as a repeated input and defers the reply. *)
          Tool_result.make_ok ~tool_name ~start_time
            ~metadata:Msx_machine_tools.moved_the_machine
            ~data:(tick_frame_json pixel_response frame entries mark) ()
      | Error Msx_lane.No_machine ->
          Tool_result.make_ok ~tool_name ~start_time ~data:(`Assoc ["loaded", `Bool false]) ()
      | Error error -> Msx_machine_tools.of_lane ~tool_name ~start_time (Error error)
