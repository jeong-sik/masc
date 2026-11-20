module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Tui_decode = Masc.Tui_decode
module Terminal_text = Masc_tui_ansi.Terminal_text
module Play_pending = Masc_tui_play_pending

let decode_play_mutation decode = function
  | Masc_tui_http.Post_answered json -> P.Play_answered (decode json)
  | Masc_tui_http.Post_refused detail -> P.Play_refused detail
  | Masc_tui_http.Post_unanswered detail -> P.Play_unanswered detail

let update_collab (state : T.state) owner update =
  match state.T.collab with
  | Some view when Masc_tui_collab.owner view == owner -> state.T.collab <- Some (update view)
  | Some _ | None -> ()

let collab_notice state owner ~kind text =
  update_collab state owner (fun view -> Masc_tui_collab.notice view text);
  Masc_tui_loader.report_action state
    (match kind with
     | Chat_notice.Notice_reply -> "play"
     | Chat_notice.Notice_failure -> "error")
    (Terminal_text.single_line text)

let play_notice state ~sink ~kind text =
  match sink with
  | P.Play_chat keeper_name -> Chat_notice.chat_notice state ~keeper_name ~kind text
  | P.Play_collab {owner; _} -> collab_notice state owner ~kind text

let settle_play_mutation state = function
  | P.Play_chat _ -> ()
  | P.Play_collab {owner; mutation} ->
      update_collab state owner (fun view -> Masc_tui_collab.settled view mutation)

let sync_collab_access (state : T.state) =
  state.T.collab <- Option.map (fun view ->
    Masc_tui_collab.write_access view (T.play_change_access state)) state.T.collab

let refresh_collab (state : T.state) ~mailbox owner =
  match state.T.collab with
  | Some view when Masc_tui_collab.owner view == owner ->
      let view, read = Masc_tui_collab.loading view in
      state.T.collab <- Some view;
      let expected_workspace = state.T.server_identity in
      Masc_tui_surface_requests.Prompt_preset_requests.launch_preset_call state ~mailbox
        ~call:(Masc_tui_http.list_play_invites ~expected_workspace)
        ~wrap:(fun result -> P.Play_msg (P.Play_invites_listed (P.Play_collab_list read,
          Result.bind result (fun json ->
            Result.map_error (fun detail -> T.Request_failed detail)
              (Tui_decode.decode_play_invites json)))))
  | Some _ | None -> ()

let refresh_current_collab (state : T.state) ~mailbox =
  Option.iter (fun view -> refresh_collab state ~mailbox (Masc_tui_collab.owner view)) state.T.collab

let open_collab (state : T.state) ~mailbox =
  let view = Masc_tui_collab.write_access (Masc_tui_collab.create ())
    (T.play_change_access state) in
  state.T.collab <- Some view;
  refresh_collab state ~mailbox (Masc_tui_collab.owner view)

let play_request_failure state request detail =
  if T.play_change_dispatched state request then P.Play_unanswered detail
  else P.Play_not_dispatched detail

let launch_play_issue state ~mailbox ~sink ~name ~hours =
  match T.begin_play_change state (Play_pending.Issue_invite name) with
  | Error detail ->
      settle_play_mutation state sink;
      play_notice state ~sink ~kind:Chat_notice.Notice_failure detail;
      false
  | Ok request ->
      sync_collab_access state;
      Masc_tui_surface_requests.Prompt_preset_requests.launch_preset_call state ~mailbox
        ~call:(fun ~host ~port ->
          match T.workspace_change_origin state with
          | Ok origin when origin = request.T.change_workspace
              && T.dispatch_play_change state request ->
              Ok (Masc_tui_http.issue_play_invite
                ~expected_base_path:request.T.change_workspace.T.wi_base_path
                ~expected_masc_root:request.T.change_workspace.T.wi_masc_root ~host ~port ~name ~hours)
          | Ok _ | Error _ -> Ok (Masc_tui_http.Post_refused "Local workspace authority changed before dispatch"))
        ~wrap:(fun result -> P.Play_msg (P.Play_invite_issued (request, sink,
          match result with
          | Ok outcome -> decode_play_mutation Tui_decode.decode_play_invite_issued outcome
          | Error (T.Request_withdrawn refusal) -> P.Play_kept_back refusal
          | Error (T.Request_failed detail) -> play_request_failure state request detail)));
      true

let launch_play_revoke state ~mailbox ~sink ~name =
  match T.begin_play_change state (Play_pending.Revoke_invite name) with
  | Error detail ->
      settle_play_mutation state sink;
      play_notice state ~sink ~kind:Chat_notice.Notice_failure detail;
      false
  | Ok request ->
      sync_collab_access state;
      Masc_tui_surface_requests.Prompt_preset_requests.launch_preset_call state ~mailbox
        ~call:(fun ~host ~port ->
          match T.workspace_change_origin state with
          | Ok origin when origin = request.T.change_workspace
              && T.dispatch_play_change state request ->
              Ok (Masc_tui_http.revoke_play_invite
                ~expected_base_path:request.T.change_workspace.T.wi_base_path
                ~expected_masc_root:request.T.change_workspace.T.wi_masc_root ~host ~port ~name)
          | Ok _ | Error _ -> Ok (Masc_tui_http.Revoke_other
              (Masc_tui_http.Post_refused "Local workspace authority changed before dispatch")))
        ~wrap:(fun result -> P.Play_msg (P.Play_invite_revoked (request, sink, name,
          match result with
          | Ok Masc_tui_http.Revoke_absent -> P.Play_revoke_absent
          | Ok (Masc_tui_http.Revoke_release_failed detail) -> P.Play_revoke_release_failed detail
          | Ok (Masc_tui_http.Revoke_other outcome) ->
              P.Play_revoke_result (decode_play_mutation Tui_decode.decode_play_invite_revoked outcome)
          | Error (T.Request_withdrawn refusal) -> P.Play_revoke_result (P.Play_kept_back refusal)
          | Error (T.Request_failed detail) ->
              P.Play_revoke_result (play_request_failure state request detail))));
      true
