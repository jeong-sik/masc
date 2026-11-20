module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Admission = Masc_tui_transport.Workspace_admission
module Chat_notice = Masc_tui_collab_queue.Chat_notice
module Chat_media = Masc_tui_chat_media
module Words = Masc_tui_words
module Image_payload = Masc_tui_image_payload
module Attachment_action = Masc_tui_attachment_action

let prepare_listen_media ~host ~port (media : Chat_media.playable) =
  let open Result.Syntax in
  let* bytes = match media.Chat_media.source with
    | `Server_path path ->
        Masc_tui_http.get_workspace_bytes
          ~max_body_bytes:Tool_blob_store.max_served_bytes ~host ~port ~path
    | `Data payload ->
        Eio_guard.run_in_systhread ~label:"tui-listen-decode" (fun () ->
          Image_payload.decode_wire payload)
    | `Local_path path ->
        Eio_guard.run_in_systhread ~label:"tui-listen-file" (fun () ->
          try
            let descriptor = Unix.openfile path [Unix.O_RDONLY; Unix.O_NONBLOCK] 0 in
            let channel = Unix.in_channel_of_descr descriptor in
            Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
              let stats = Unix.fstat (Unix.descr_of_in_channel channel) in
              if stats.Unix.st_kind <> Unix.S_REG then Error "audio source is not a regular file"
              else if stats.Unix.st_size > Tool_blob_store.max_served_bytes then
                Error "file is larger than the attachment limit"
              else Ok (really_input_string channel stats.Unix.st_size))
          with
          | Sys_error detail -> Error detail
          | End_of_file -> Error "audio source changed while reading"
          | Unix.Unix_error (code, _, _) -> Error (Unix.error_message code)) in
  Eio_guard.run_in_systhread ~label:"tui-listen-prepare" (fun () ->
    let sha256 = Agent_core_sha256.(to_hex (digest_string bytes)) in
    let attachment : T.board_attachment =
      { T.ba_kind=(match media.Chat_media.kind with `Audio -> T.Ak_audio | `Midi -> T.Ak_midi);
        ba_source=T.As_artifact {sha256; bytes=String.length bytes}; ba_name=Some media.Chat_media.name } in
    Attachment_action.prepare ~fetch:(fun ~sha256:_ -> Ok bytes) attachment
    |> Result.map_error Attachment_action.describe_outcome)

let listen_newest_media ?(destination=T.Listen_player) (state : T.state) ~mailbox ~(media : Chat_media.t list) =
  let notice = Chat_notice.chat_notice state ~keeper_name:state.T.msg_target_keeper_name in
  let media = match destination with
    | T.Listen_player -> Chat_media.newest_playable media
    | T.Listen_music_editor -> Chat_media.newest_midi media in
  let command = match destination with
    | T.Listen_player -> "/listen" | T.Listen_music_editor -> "/music midi" in
  match state.T.msg_target_keeper_name, media with
  | None, _ | Some _, None ->
      notice ~kind:Chat_notice.Notice_reply (command ^ ": no readable "
        ^ (match destination with T.Listen_player -> "audio or MIDI" | T.Listen_music_editor -> "MIDI")
        ^ " attachment in this conversation")
  | Some keeper, Some media ->
      if not (T.server_authority_ready state) then
        notice ~kind:Chat_notice.Notice_failure
          (let ko = state.T.ui_language = T.Lang_ko in
           Words.kept_back ~ko ~request:(Words.Kept_request.Command command)
             (Words.workspace_identity_unconfirmed ~ko) Words.Nothing_kept)
      else begin
        let request = T.begin_chat_listen ~destination state ~keeper media in
        let host = Admission.server_peer_host and port = state.T.port in
        notice ~kind:Chat_notice.Notice_reply (command ^ ": preparing " ^ media.Chat_media.name);
        Admission.launch_json_read state ~mailbox
          ~boundary_error:(fun cause -> T.Request_failed cause)
          ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
          ~deliver:(fun result -> P.Listen_prepared (request, result))
          (fun () -> Result.map_error (fun cause -> T.Request_failed cause)
            (prepare_listen_media ~host ~port request.T.lr_media))
      end

let withdraw_pending_music_editor (state : T.state) =
  T.withdraw_chat_music_editor state |> Option.iter (fun request ->
    let message =
      "/music midi: opening cancelled while terminal input was pending; run /music midi again when ready" in
    Chat_notice.chat_notice state ~keeper_name:(Some request.T.lr_keeper) ~kind:Chat_notice.Notice_reply
      message;
    Masc_tui_loader.report_action state "system" message)
