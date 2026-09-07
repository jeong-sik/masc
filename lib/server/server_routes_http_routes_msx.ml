(** HTTP route for the workspace MSX machine's frame (RFC-0439 §3.7).

    [GET /api/v1/msx/frame] returns the current native-resolution screen of
    the one machine [Msx_lane] holds, so the TUI can draw what a keeper is
    playing. Read-only and public-read like the dashboard reads the TUI polls;
    it exposes a game screen, not workspace state. When no machine is loaded
    the answer is [{loaded:false}] — an explicit "nothing to watch", never a
    silent blank.

    The frame is 256x192x3 raw RGB, base64 in the JSON and gzip-compressed on
    the wire by [json_value ~compress]. The spectator polls a few times a
    second; the machine itself only advances when a tool call steps it.

    [POST /api/v1/msx/press] lets the human at the TUI press keys on the same
    machine a keeper is playing (RFC-0439 §3.3): [{keys:[..], hold_frames?,
    frames?}] goes to [Msx_lane.press] under the operator's identity, so its
    edges land in the shared ledger next to the keeper's. It is a write, gated
    like the mutating MSX tools. *)

open Server_auth
module Http = Http_server_eio

let json_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let int_field name ~default json =
  match json_field name json with Some (`Int n) -> n | _ -> default

let string_list_field name json =
  match json_field name json with
  | Some (`List items) ->
    List.filter_map (function `String s -> Some s | _ -> None) items
  | _ -> []

let press_result_json ~ok ?message (obs : Msx_lane.observation option) : Yojson.Safe.t =
  let base = [ ("ok", `Bool ok) ] in
  let base = match message with Some m -> base @ [ ("message", `String m) ] | None -> base in
  match obs with
  | None -> `Assoc base
  | Some o ->
    `Assoc
      (base
      @ [ ("frame", `Int o.Msx_lane.frame)
        ; ("mode", `String o.Msx_lane.mode)
        ; ( "cartridge"
          , match o.Msx_lane.cartridge with Some c -> `String c | None -> `Null )
        ])
;;

(* The keys the caller named, parsed to the lane's vocabulary; the first bad one
   fails the whole press so nothing is half-applied. *)
let parse_keys names =
  List.fold_left
    (fun acc name ->
      match acc with
      | Error _ as e -> e
      | Ok ks -> (
        match Msx_lane.key_of_string name with
        | Ok k -> Ok (ks @ [ k ])
        | Error message -> Error message))
    (Ok []) names

(* The operator's identity for the ledger. The TUI presents a token, not a
   keeper name, so its presses are recorded as the operator. *)
let presser_of request =
  let header k =
    match Httpun.Headers.get request.Httpun.Request.headers k with
    | Some s when s <> "" -> Some s
    | _ -> None
  in
  match header "x-masc-agent" with Some a -> a | None -> "operator"
;;

let handle_press request reqd =
  Http.Request.read_body_async reqd (fun body ->
      let respond ~status json = respond_json_value_with_cors ~status request reqd json in
      match Yojson.Safe.from_string body with
      | exception Yojson.Json_error message ->
        respond ~status:`Bad_request
          (press_result_json ~ok:false ~message:("invalid JSON: " ^ message) None)
      | json -> (
        match parse_keys (string_list_field "keys" json) with
        | Error message -> respond ~status:`Bad_request (press_result_json ~ok:false ~message None)
        | Ok [] ->
          respond ~status:`Bad_request
            (press_result_json ~ok:false ~message:"keys must name at least one key" None)
        | Ok keys -> (
          let result =
            Msx_lane.press ~who:(presser_of request) ~keys
              ~hold_frames:(int_field "hold_frames" ~default:5 json)
              ~step_frames:(int_field "frames" ~default:15 json)
          in
          match result with
          | Ok obs -> respond ~status:`OK (press_result_json ~ok:true (Some obs))
          | Error ((Msx_lane.No_machine | Msx_lane.Invalid_request _) as e) ->
            respond ~status:`Bad_request
              (press_result_json ~ok:false ~message:(Msx_lane.error_to_string e) None)
          | Error (Msx_lane.Unreadable _ as e) ->
            respond ~status:`Internal_server_error
              (press_result_json ~ok:false ~message:(Msx_lane.error_to_string e) None))))
;;

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
  |> Http.Router.post "/api/v1/msx/press" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_msx_press"
         (fun _state _req reqd -> handle_press request reqd)
         request reqd)
;;
