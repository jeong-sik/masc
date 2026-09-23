(** HTTP route for the workspace DOS machine's frame (#38424).

    [GET /api/v1/dos/frame] returns the current screen of the one machine
    [Dos_lane] holds, so an operator at the TUI can watch Keepers play a DOS
    game the way the MSX spectator watches the MSX machine. Public-read like
    the MSX frame: it exposes a game screen, not workspace state.

    It is a read and nothing else. DOS time moves only through the tool calls
    ([Dos_lane.step], [press], [click], [type_text]); this route calls
    [Dos_lane.capture_with_identity], which reads the machine under its lock
    and never advances it. Unlike the MSX spectator, watching a DOS game does
    not make it run.

    When no machine is loaded the answer is [{loaded:false}] with 200, the
    same explicit "nothing to watch" the MSX frame gives.

    A DOS frame is 640x400 or 640x480 RGB, about 1.2 MB once base64-encoded,
    and it changes only when time moves. So the spectator names the frame it
    already holds with [?incarnation=<id>&steps=<n>]. When the machine is
    still that incarnation at that step count, the answer carries
    [pixels:"unchanged"] and no [rgb_base64]; the metadata (controller above
    all, which [masc_dos_pass] changes without moving time) is always fresh.
    Otherwise [pixels:"inline"] with the whole frame. A new load is a new
    incarnation, so a reload at the same step count is never mistaken for the
    old screen. *)

open Server_auth
module Http = Http_server_eio

type known_frame = { incarnation : string; steps : int }

(* The frame a spectator says it holds. Both query parameters or neither: one
   without the other names no frame, and the caller is told so rather than
   sent a full frame it did not ask for. *)
let decode_known ~incarnation ~steps : (known_frame option, string) result =
  match incarnation, steps with
  | None, None -> Ok None
  | Some incarnation, Some steps -> (
    match int_of_string_opt steps with
    | Some steps when steps >= 0 && String.length incarnation > 0 ->
      Ok (Some { incarnation; steps })
    | Some _ | None -> Error "steps must be a non-negative integer and incarnation non-empty")
  | Some _, None | None, Some _ -> Error "incarnation and steps name a frame together"
;;

let string_or_null = function Some s -> `String s | None -> `Null

(* Pure over the capture so the route test can drive it with a real machine
   and without an HTTP server. *)
let frame_json ~(known : known_frame option) (capture : Dos_lane.identified_capture) :
    Yojson.Safe.t =
  let o = capture.observation in
  let unchanged =
    match known with
    | Some k -> String.equal k.incarnation capture.incarnation && k.steps = o.Dos_lane.steps
    | None -> false
  in
  let pixels =
    if unchanged then [ ("pixels", `String "unchanged") ]
    else
      [ ("pixels", `String "inline")
      ; ("rgb_base64", `String (Base64.encode_string capture.frame.Dos_lane.rgb))
      ]
  in
  `Assoc
    ([ ("loaded", `Bool true)
     ; ("incarnation", `String capture.incarnation)
     ; ("steps", `Int o.Dos_lane.steps)
     ; ("program", string_or_null o.Dos_lane.program)
     ; ("controller", string_or_null o.Dos_lane.controller)
     ; ("video_mode", `Int o.Dos_lane.video_mode)
     ; ("width", `Int capture.frame.Dos_lane.width)
     ; ("height", `Int capture.frame.Dos_lane.height)
     ]
    @ pixels)
;;

let error_json message : Yojson.Safe.t =
  `Assoc [ ("ok", `Bool false); ("message", `String message) ]
;;

let frame_response ~incarnation ~steps =
  match decode_known ~incarnation ~steps with
  | Error message -> `Bad_request, error_json message
  | Ok known -> (
    match Dos_lane.capture_with_identity () with
    | Ok capture -> `OK, frame_json ~known capture
    | Error Dos_lane.No_machine -> `OK, `Assoc [ ("loaded", `Bool false) ]
    | Error ((Dos_lane.Invalid_request _ | Dos_lane.Unreadable _ | Dos_lane.Held_by _) as e) ->
      `Internal_server_error, error_json (Dos_lane.error_to_string e))
;;

let add_routes router =
  router
  |> Http.Router.get "/api/v1/dos/frame" (fun request reqd ->
       with_public_read
         (fun _state req reqd ->
           let status, json =
             frame_response
               ~incarnation:(Server_utils.query_param req "incarnation")
               ~steps:(Server_utils.query_param req "steps")
           in
           Http.Response.json_value_on_cpu ~status ~compress:true ~request:req json reqd)
         request reqd)
;;
