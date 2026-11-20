module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Admission = Masc_tui_transport.Workspace_admission
module Request_notice = Masc_tui_transport.Request_notice
module Preset_requests = Masc_tui_surface_requests.Prompt_preset_requests
module Play_room = Masc_tui_play_room
module Machine_live = Masc_tui_machine_live
module Words = Masc_tui_words

let room_workspace_ready (state : T.state) =
  match state.T.workspace_identity, T.workspace_input_identity_of_server state.T.server_identity with
  | T.Workspace_identity_match, Some _ -> true
  | (T.Workspace_identity_unread | T.Workspace_identity_match_unconfirmed _ | T.Workspace_identity_mismatch _), _
  | T.Workspace_identity_match, None -> false

let launch_play_room (state : T.state) ~mailbox request =
  if room_workspace_ready state then begin
  let credential = Masc_tui_http.bind_credential () in
  Option.iter (fun expected_workspace ->
  Preset_requests.launch_preset_call state ~mailbox
    ~call:(fun ~host ~port ->
      let fields = match Play_room.request_json request with
        | `Assoc fields -> fields | _ -> assert false in
      let body = `Assoc (Masc_tui_http.expected_workspace_field expected_workspace :: fields) in
      Masc_tui_http.post_json_bound ~credential ~host ~port ~path:"/api/v1/play/room"
        ~body:(Yojson.Safe.to_string body)
      |> fun result -> Result.bind result Masc.Play_room.view_of_json)
    ~wrap:(fun result -> P.Play_msg (P.Play_room_received (request, result)))) state.T.server_identity
  end

let poll_play_room (state : T.state) ~mailbox =
  if room_workspace_ready state then begin
  let watching = state.T.msx_open && not state.T.msx_menu_open in
  if watching && Option.is_some (T.workspace_input_identity_of_server state.T.server_identity)
    && Option.is_none state.T.play_room
  then state.T.play_room <- Some (Play_room.create ());
  Option.iter (fun room ->
    let room = Play_room.active room watching in
    let room, request =
      Play_room.poll room ~now:(Masc_tui_wake.Mono.now ()) ~machine:state.T.machine_source
    in
    state.T.play_room <- Some room;
    Option.iter (launch_play_room state ~mailbox) request) state.T.play_room
  end

let send_play_room (state : T.state) ~mailbox =
  if room_workspace_ready state then
  Option.iter (fun room ->
    let room, request =
      Play_room.send ~ko:(state.T.ui_language = T.Lang_ko) room ~machine:state.T.machine_source in
    state.T.play_room <- Some room;
    Option.iter (launch_play_room state ~mailbox) request) state.T.play_room

(* A live read names no mode, media or players. Keep the last tick metadata
   only within the same incarnation, so a keypress does not briefly erase the
   title while a replacement machine never inherits its predecessor's name. *)
let msx_frame_of_live ~previous_live ~previous_frame
    (view : Machine_live.view) =
  match view with
  | Machine_live.Showing ({ Machine_live.time = Machine_live.Frame number; _ } as p) ->
      let meta =
        match previous_live, previous_frame with
        | Machine_live.Showing old, Some frame
          when String.equal old.Machine_live.mark.Machine_live.incarnation p.Machine_live.mark.Machine_live.incarnation ->
            frame.T.msx_meta
        | ( ( Machine_live.Showing _ | Machine_live.Unread
            | Machine_live.Not_loaded | Machine_live.Failed _
            | Machine_live.Kept_back _ ),
            _ ) -> None
      in
      (view, Some { T.msx_number = number; msx_width = p.Machine_live.width;
                    msx_height = p.Machine_live.height; msx_rgb = p.Machine_live.rgb; msx_meta = meta })
  | Machine_live.Showing { Machine_live.time = Machine_live.Untimed; _ } ->
      (Machine_live.Failed "an MSX answer carried no frame number", None)
  | Machine_live.Unread | Machine_live.Not_loaded
  | Machine_live.Failed _ | Machine_live.Kept_back _ -> (view, None)

(* A live read the workspace guard stopped was never sent, so the screen
   says it was kept back and not that the machine could not be read (RFC §2). *)
let advance_machine_live (state : T.state) ~request (view : Machine_live.view) = function
  | Ok answer -> Machine_live.advance view (Ok answer)
  | Error (T.Request_failed detail) -> Machine_live.advance view (Error detail)
  | Error (T.Request_withdrawn refusal) ->
      Some (Machine_live.Kept_back
        (T.workspace_refusal_text ~ko:(state.T.ui_language = T.Lang_ko) ~request refusal))

(* A read of the MSX screen through the live route, asked with the counter
   of the picture drawn from the last one. An unchanged answer leaves the
   frame alone. Admission before the read and rejection after its attempt
   preserve different facts. *)
let with_msx_observation (state : T.state) ~mailbox ~request read apply =
  let check = Admission.capture_admission state ~mailbox in
  let kept_back refusal =
    state.T.msx_notice <-
      Some (T.workspace_refusal_text ~ko:(state.T.ui_language = T.Lang_ko) ~request refusal) in
  match check () with
  | Error refusal -> kept_back refusal
  | Ok () ->
      let result = read () in
      (match check () with
       | Error refusal ->
           state.T.msx_notice <- Some (Request_notice.workspace_response_refusal_text state ~request refusal)
       | Ok () -> apply result)

let observe_msx_carts (state : T.state) ~mailbox =
  with_msx_observation state ~mailbox ~request:Words.Kept_request.Msx_carts_read
    (fun () -> Masc_tui_http.fetch_msx_carts ~host:Admission.server_peer_host ~port:state.T.port)
    (fun carts -> state.T.msx_carts <- carts)
