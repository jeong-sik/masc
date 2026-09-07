(** HTTP route for the workspace MSX machine's frame (RFC-0439 §3.7).

    [GET /api/v1/msx/frame] returns the current native-resolution screen of
    the one machine [Msx_lane] holds, so the TUI can draw what a keeper is
    playing. Read-only and public-read like the dashboard reads the TUI polls;
    it exposes a game screen, not workspace state. When no machine is loaded
    the answer is [{loaded:false}] — an explicit "nothing to watch", never a
    silent blank.

    The frame is 256x192x3 raw RGB, base64 in the JSON and gzip-compressed on
    the wire by [json_value ~compress]. The spectator polls a few times a
    second; the machine itself only advances when a tool call steps it. *)

open Server_auth
module Http = Http_server_eio

let frame_json () : Yojson.Safe.t =
  match Msx_lane.frame () with
  | None -> `Assoc [ ("loaded", `Bool false) ]
  | Some f ->
    `Assoc
      [ ("loaded", `Bool true)
      ; ("number", `Int f.Msx_lane.number)
      ; ("width", `Int f.Msx_lane.width)
      ; ("height", `Int f.Msx_lane.height)
      ; ("mode", `String f.Msx_lane.mode)
      ; ( "cartridge"
        , match f.Msx_lane.cartridge with Some c -> `String c | None -> `Null )
      ; ("rgb_base64", `String (Base64.encode_string f.Msx_lane.rgb))
      ]
;;

let add_routes router =
  router
  |> Http.Router.get "/api/v1/msx/frame" (fun request reqd ->
       with_public_read
         (fun _state req reqd ->
           Http.Response.json_value ~compress:true ~request:req (frame_json ()) reqd)
         request reqd)
;;
