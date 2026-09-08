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

let bool_field name ~default json =
  match json_field name json with Some (`Bool b) -> b | _ -> default

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
        ; ("disk", match o.Msx_lane.disk with Some d -> `String d | None -> `Null )
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
              ~sequence:(bool_field "sequence" ~default:false json)
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

(* The cartridge inventory the TUI load menu shows (RFC-0439 §3.7): the file
   names under <.masc>/msx/carts an operator filled, plus which one is plugged
   in now so the menu can mark it. Read-only; loading a game is the write
   below. [carts_available] is the same listing masc_msx_load returns when it
   is called with no cart, so the menu and a keeper see one inventory. *)
let carts_json ~base_path : Yojson.Safe.t =
  let carts = Tool_misc_msx_lane.carts_available ~base_path in
  let loaded, cartridge, disk =
    match Msx_lane.frame () with
    | None -> (false, `Null, `Null)
    | Some f ->
      ( true
      , (match f.Msx_lane.cartridge with Some c -> `String c | None -> `Null)
      , (match f.Msx_lane.disk with Some d -> `String d | None -> `Null) )
  in
  `Assoc
    [ ("carts", `List (List.map (fun c -> `String c) carts))
    ; ("loaded", `Bool loaded)
    ; ("cartridge", cartridge)
    ; ("disk", disk)
    ]
;;

let load_result_json ~ok ~message : Yojson.Safe.t =
  `Assoc [ ("ok", `Bool ok); ("message", `String message) ]
;;

(* The human at the TUI plugs a cartridge into the shared machine. The whole
   resolution — a name to its carts/ path, the BIOS inventory, a bad name's
   error message — is [Tool_misc_msx_lane.handle_load]'s, the same code a
   keeper's masc_msx_load runs, so there is one loader and one inventory. The
   route only turns its tool result into an HTTP answer; the TUI re-fetches the
   frame to start spectating. Body: {cart:"name"}. *)
let handle_load ~base_path request reqd =
  Http.Request.read_body_async reqd (fun body ->
      let respond ~status json = respond_json_value_with_cors ~status request reqd json in
      match Yojson.Safe.from_string body with
      | exception Yojson.Json_error message ->
        respond ~status:`Bad_request
          (load_result_json ~ok:false ~message:("invalid JSON: " ^ message))
      | args ->
        let result =
          (* Time_compat.now is the codebase's clock accessor the determinism
             gate accepts, the same one Tool_misc.dispatch stamps tool calls
             with; reading the wall clock any other way here would add
             non-deterministic-boundary debt. *)
          Tool_misc_msx_lane.handle_load ~tool_name:"masc_msx_load"
            ~start_time:(Time_compat.now ()) ~base_path
            ~agent_name:"operator" args
        in
        let ok = Tool_result.is_success result in
        let status = if ok then `OK else `Bad_request in
        respond ~status (load_result_json ~ok ~message:(Tool_result.message result)))
;;

(* "who is at the machine": each keeper's most-recent key within a window of the
   current frame, newest first, projected from the shared ledger. The lane is one
   machine anyone may press, so this reports presence -- it does not reserve the
   slot. A turn in a turn-based game can run to minutes, so the window is wide. *)
let players_window_frames = 3600

let recent_players ~now =
  let last : (string, int) Hashtbl.t = Hashtbl.create 8 in
  List.iter
    (fun (e : Msx_lane.entry) ->
      Hashtbl.replace last e.Msx_lane.who e.Msx_lane.at_frame)
    (Msx_lane.ledger ());
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
      ; ("disk", match f.Msx_lane.disk with Some d -> `String d | None -> `Null)
      ; ("rgb_base64", `String (frame_rgb_base64 f.Msx_lane.rgb))
      ; ( "players"
        , `List
            (List.map
               (fun (who, last) ->
                 `Assoc
                   [ ("who", `String who)
                   ; ("last_frame", `Int last)
                   ; ("frames_ago", `Int (f.Msx_lane.number - last))
                   ])
               (recent_players ~now:f.Msx_lane.number)) )
      ]
;;

(* Frames per poll-cadence tick (RFC-0439 §3.2). At the TUI's ~3 Hz spectator
   poll this advances ~54 frames a second, close enough to the machine's 60 Hz
   that a game reads as live without a server-side ticker. *)
let msx_tick_default_frames = 18

let clamp_tick_frames requested = max 1 (min Msx_lane.max_frames_per_call requested)

let decode_tick body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error _ -> Error "tick body must be valid JSON"
  | `Assoc [] -> Ok msx_tick_default_frames
  | `Assoc [ "frames", `Int frames ] -> Ok (clamp_tick_frames frames)
  | `Assoc [ "frames", _ ] -> Error "frames must be an integer"
  | `Assoc _ -> Error "tick accepts only one optional frames field"
  | _ -> Error "tick body must be an object"
;;

let tick_response ~body =
  let error status message =
    status, `Assoc [ "ok", `Bool false; "message", `String message ]
  in
  match decode_tick body with
  | Error detail -> error `Bad_request detail
  | Ok frames ->
    (* This is a mutation: the best-effort executor adapter can replay failed
       work inline. Strict submission never retries or falls back to the HTTP
       domain. The worker owns both emulation and the frame's serialization. *)
    match Executor_pool_ref.submit_strict (fun () ->
      match Msx_lane.step ~frames with
      | Ok _ | Error Msx_lane.No_machine -> `OK, frame_json ()
      | Error (Msx_lane.Invalid_request _ as e) ->
        error `Bad_request (Msx_lane.error_to_string e)
      | Error (Msx_lane.Unreadable _ as e) ->
        error `Internal_server_error (Msx_lane.error_to_string e))
    with
    | Ok response -> response
    | Error (Executor_pool_ref.Pool_unavailable | Executor_pool_ref.Caller_not_in_eio) ->
      error `Service_unavailable "MSX tick worker is unavailable"
    | Error ((Executor_pool_ref.Work_failed _ | Executor_pool_ref.Submission_failed _) as failure) ->
      Log.Http.error "MSX tick: %s" (Executor_pool_ref.strict_submit_error_to_string failure);
      error `Internal_server_error "MSX tick failed; read the current frame before retrying"
;;

(* The realtime driver (RFC-0439 §3.2, poll-cadence tick). The spectating TUI
   posts this a few times a second to advance the shared machine, so a game
   flows even when no keeper is pressing a key. Body: {frames:N}, clamped to
   1..max_frames_per_call; the answer is the advanced frame, so one call both
   steps and reads. A write, gated like press. *)
let handle_tick request reqd =
  Http.Request.read_body_async reqd (fun body ->
      let status, json = tick_response ~body in
      respond_json_value_with_cors ~status request reqd json)
;;

let checkpoint_response ~base_path ~restore ~body =
  let error status message = status, load_result_json ~ok:false ~message in
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error message -> error `Bad_request message
  | args ->
    (match Tool_misc_msx_lane.checkpoint_slot args with
     | Error message -> error `Bad_request message
     | Ok _ ->
       match Executor_pool_ref.submit_strict (fun () ->
         let tool_name = if restore then "masc_msx_restore" else "masc_msx_save" in
         let result = Tool_misc_msx_lane.handle_checkpoint ~restore ~tool_name
             ~start_time:(Time_compat.now ()) ~base_path args in
         let ok = Tool_result.is_success result in
         let status = match Tool_result.failure_class result with
           | None -> `OK
           | Some Tool_result.Workflow_rejection -> `Bad_request
           | Some _ -> `Internal_server_error in
         status,
         load_result_json ~ok ~message:(Tool_result.message result)) with
       | Ok response -> response
       | Error (Executor_pool_ref.Pool_unavailable | Executor_pool_ref.Caller_not_in_eio) ->
         error `Service_unavailable "MSX checkpoint worker is unavailable"
       | Error failure ->
         Log.Http.error "MSX checkpoint: %s" (Executor_pool_ref.strict_submit_error_to_string failure);
         error `Internal_server_error "MSX checkpoint failed; inspect the current state before retrying")
;;

let handle_change_disk ~base_path request reqd =
  Http.Request.read_body_async reqd (fun body ->
    let error status message = status, load_result_json ~ok:false ~message in
    let status, json = match Yojson.Safe.from_string body with
      | exception Yojson.Json_error message -> error `Bad_request message
      | args -> (
        match Executor_pool_ref.submit_strict (fun () ->
          let result = Tool_misc_msx_lane.handle_change_disk ~tool_name:"masc_msx_change_disk"
              ~start_time:(Time_compat.now ()) ~base_path args in
          let ok = Tool_result.is_success result in
          let status = match Tool_result.failure_class result with
            | None -> `OK | Some Tool_result.Workflow_rejection -> `Bad_request
            | Some _ -> `Internal_server_error in
          status, load_result_json ~ok ~message:(Tool_result.message result)) with
        | Ok response -> response
        | Error (Executor_pool_ref.Pool_unavailable | Executor_pool_ref.Caller_not_in_eio) ->
          error `Service_unavailable "MSX disk worker is unavailable"
        | Error failure ->
          Log.Http.error "MSX disk change: %s" (Executor_pool_ref.strict_submit_error_to_string failure);
          error `Internal_server_error "MSX disk change failed; inspect the current state before retrying") in
    respond_json_value_with_cors ~status request reqd json)
;;

let handle_checkpoint ~base_path ~restore request reqd =
  Http.Request.read_body_async reqd (fun body ->
    let status, json = checkpoint_response ~base_path ~restore ~body in
    respond_json_value_with_cors ~status request reqd json)
;;

let add_routes router =
  router
  |> Http.Router.get "/api/v1/msx/frame" (fun request reqd ->
       with_public_read
         (fun _state req reqd ->
           Http.Response.json_value ~compress:true ~request:req (frame_json ()) reqd)
         request reqd)
  |> Http.Router.get "/api/v1/msx/carts" (fun request reqd ->
       with_public_read
         (fun state req reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           Http.Response.json_value ~compress:true ~request:req
             (carts_json ~base_path) reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/press" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_msx_press"
         (fun _state _req reqd -> handle_press request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/load" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_msx_load"
         (fun state _req reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           handle_load ~base_path request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/save" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_msx_save"
         (fun state _req reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           handle_checkpoint ~base_path ~restore:false request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/restore" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_msx_restore"
         (fun state _req reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           handle_checkpoint ~base_path ~restore:true request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/disk" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_msx_change_disk"
         (fun state _req reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           handle_change_disk ~base_path request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/tick" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_msx_step"
         (fun _state _req reqd -> handle_tick request reqd)
         request reqd)
;;
