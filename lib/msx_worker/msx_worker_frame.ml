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

type prepared_pixels = { rgb : string; encoded : string; reference : Msx_wire.pixel_reference }
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
            revision = Agent_core_sha256.(to_hex (digest_string frame.rgb)) } } in
      Mutex.protect tick_pixels_mutex (fun () -> tick_pixels := Some pixels);
      pixels

let tick_frame_json pixel_response (frame : Msx_lane.frame) entries
    (mark : Msx_lane.change_mark) =
  let pixel_fields = match pixel_response with
    | Msx_wire.Full_frame -> ["rgb_base64", `String (frame_rgb_base64 frame.rgb)]
    | Msx_wire.Retained_pixels known ->
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
  let tool_name = Msx_tool.name Msx_tool.Step and start_time = Tool_timing.start () in
  let fields = match arguments with `Assoc fields -> fields | _ -> [] in
  let fields = List.remove_assoc "include_frame" fields in
  match Msx_wire.decode_tick (`Assoc fields) with
  | Error message -> Tool_result.make_err ~tool_name ~start_time
      ~class_:Tool_result.Workflow_rejection ~effect_disposition:Tool_result.Proven_pre_effect message
  | Ok { frames; pixel_response } ->
      (* The lane refuses a count outside 1..max_frames_per_call. This path
         used to clamp it, so a count the plain step refuses ran here. *)
      let frames = Option.value frames ~default:Msx_machine_tools.default_step_frames in
      match Msx_lane.step_frame ~frames with
      | Ok (frame, entries, mark) ->
          (* The frames were run, so declare the progress the sibling step path
             declares: without it the repeat guard reads five identical
             include_frame steps as a repeated input and defers the reply. *)
          Tool_result.make_ok ~tool_name ~start_time
            ~metadata:Msx_machine_tools.moved_the_machine
            ~data:(tick_frame_json pixel_response frame entries mark) ()
      (* No machine is the same pre-effect refusal the sibling step path
         answers: requesting a frame must not turn a failed advance into a
         successful one. *)
      | Error error -> Msx_machine_tools.of_lane ~tool_name ~start_time (Error error)
