open Masc_tui_core
open Masc_tui_protocol

let execute_action = Update_actions.execute_action
let execute_slash = Update_actions.execute_slash
let fetches_for_current_view = View_fetches.fetches_for_current_view

let has_explicit_sync_streams cmds =
  List.exists
    (function
      | Cmd.Sync_streams _ -> true
      | Cmd.Batch _
      | Cmd.Http_get _
      | Cmd.Http_post _
      | Cmd.Http_put _
      | Cmd.Http_post_stream _
      | Cmd.Update_workspace_guard _
      | Cmd.Voice_cmd _
      | Cmd.Copy_clipboard _
      | Cmd.Open_external_url _
      | Cmd.Open_editor_escape_hatch _
      | Cmd.Start_local_server
      | Cmd.Restart_tui
      | Cmd.Quit _ ->
          false)
    (Cmd.flatten cmds)

let reconcile_streams ~(before : Model.t) ~(after : Model.t) cmds =
  let old_plan = Subscriptions.plan before in
  let new_plan = Subscriptions.plan after in
  let both_empty =
    match old_plan, new_plan with
    | [], [] -> true
    | [], _ :: _ | _ :: _, [] | _ :: _, _ :: _ -> false
  in
  if
    has_explicit_sync_streams cmds
    || both_empty
    || (Epoch.equal before.epoch after.epoch
       && Subscriptions.equal_plan old_plan new_plan)
  then cmds
  else cmds @ [ Cmd.Sync_streams { epoch = after.epoch; streams = new_plan } ]

let apply_resize (m : Model.t) ~cols ~rows =
  let viewport = { Model.cols = max 0 cols; rows = max 0 rows } in
  let breakpoint = Model.classify_viewport viewport in
  (* Never clobber [m.nav.overlay] or [m.inline_modal]; [Micro_viewport] gating
     is evaluated dynamically from [Model.is_too_small_viewport m.viewport]. *)
  ({ m with viewport; breakpoint }, [])

let apply_server_health ~now (m : Model.t)
    (result : (Wire_common.server_health, Msg.http_error) result) =
  match result with
  | Ok health ->
      let workspace =
        match health.scope with
        | Wire_common.Public_health -> None
        | Wire_common.Full_health ws -> Some ws
      in
      let instance_id, workspace_sha256 =
        match workspace with
        | Some ws -> (ws.instance_id, ws.workspace_sha256)
        | None -> (None, None)
      in
      let server_identity =
        {
          m.server_identity with
          health = Some health;
          workspace;
          mismatch_state = Model.Mismatch_none;
        }
      in
      let freshness = { m.freshness with server_offline = false } in
      let overlay =
        match m.nav.overlay with
        | Some (Nav.System_gate (Nav.Server_offline | Nav.Auth_gate)) -> None
        | Some
            ( Nav.System_gate (Nav.Micro_viewport | Nav.Media_viewer)
            | Nav.Palette
            | Nav.Settings _
            | Nav.Incidents
            | Nav.Queue_context _
            | Nav.Inline_action _
            | Nav.Help )
        | None ->
            m.nav.overlay
      in
      let next =
        { m with server_identity; freshness; nav = { m.nav with overlay } }
      in
      let guard_cmd =
        Cmd.Update_workspace_guard { instance_id; workspace_sha256 }
      in
      let sync_cmd =
        Cmd.Sync_streams { epoch = next.epoch; streams = Subscriptions.plan next }
      in
      let boot_cmds = View_fetches.bootstrap_fetches next in
      (next, (guard_cmd :: sync_cmd :: boot_cmds))
  | Error (Msg.Workspace_mismatch { expected_instance; observed_instance; message; _ }) ->
      Update_http.handle_workspace_mismatch ~now ~expected:expected_instance
        ~observed:observed_instance ~message m
  | Error (Msg.Transport Health.Connect_refused as err) ->
      let freshness = { m.freshness with server_offline = true } in
      let nav =
        {
          m.nav with
          overlay = Some (Nav.System_gate Nav.Server_offline);
          filter_focused = false;
        }
      in
      let m1, _ =
        Update_http.record_http_incident ~now ~source:Health.Source_client_http
          ~context:(Say.make ~ko:"서버 헬스 확인" ~en:"Server health check")
          err { m with freshness; nav; inline_modal = None }
      in
      if not m1.server_identity.autostart_attempted then
        let server_identity =
          { m1.server_identity with autostart_attempted = true }
        in
        ({ m1 with server_identity }, [ Cmd.Start_local_server ])
      else (m1, [])
  | Error
      (( Msg.Transport
           ( Health.Timeout
           | Health.Http_status _
           | Health.Stream_eof
           | Health.Protocol_error _
           | Health.Other_io _ )
       | Msg.Http_error _
       | Msg.Decode_error _ ) as err) ->
      Update_http.record_http_incident ~now ~source:Health.Source_client_http
        ~context:(Say.make ~ko:"서버 헬스 확인" ~en:"Server health check")
        err m

let apply_voice_event ~now (m : Model.t) = function
  | Msg.Voice_started ->
      ({ m with drafts = Drafts.voice_start_recording ~now m.drafts }, [])
  | Msg.Voice_level lvl ->
      ({ m with drafts = Drafts.voice_push_level lvl m.drafts }, [])
  | Msg.Voice_transcribing ->
      ({ m with drafts = Drafts.voice_set_transcribing m.drafts }, [])
  | Msg.Voice_speaking ->
      ({ m with drafts = Drafts.voice_set_speaking m.drafts }, [])
  | Msg.Voice_idle -> ({ m with drafts = Drafts.voice_set_off m.drafts }, [])
  | Msg.Voice_transcript text ->
      let drafts =
        m.drafts
        |> Drafts.voice_apply_transcript text
        |> Drafts.set_focus true
      in
      ({ m with drafts }, [])
  | Msg.Voice_capabilities caps ->
      ({ m with drafts = Drafts.set_voice_capabilities caps m.drafts }, [])
  | Msg.Voice_failed reason ->
      let drafts = Drafts.voice_set_error reason m.drafts in
      let incidents, _ =
        Incidents.push ~occurred_at_unix:m.freshness.last_wall_unix
          ~source:Health.Source_client_http
          ~summary:(Say.make ~ko:"음성 입력 오류" ~en:"Voice input error")
          ~detail:reason ~status:Health.Resolved m.incidents
      in
      let next =
        { m with drafts; incidents }
        |> Model.with_toast ~now ~level:Model.Toast_warning
             (Say.make ~ko:("음성 오류: " ^ reason) ~en:("Voice error: " ^ reason))
      in
      (next, [])

let step_raw ~now (m : Model.t) = function
  | Msg.Boot ->
      ( m
      , [
          Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_health };
          Cmd.Voice_cmd Cmd.Probe_capabilities;
        ] )
  | Msg.Key_event ev -> Update_input.apply_key_event ~now m ev
  | Msg.Paste_text text -> Update_input.apply_paste ~now m text
  | Msg.Mouse_event ev -> Update_input.apply_mouse ~now m ev
  | Msg.Resize { cols; rows } -> apply_resize m ~cols ~rows
  | Msg.Tick { wall_unix } ->
      (* Zero idle HTTP polling: ticks only record wall time, expire toasts,
         and update voice recording elapsed seconds. *)
      let freshness =
        if wall_unix > m.freshness.last_wall_unix then
          { m.freshness with last_wall_unix = wall_unix }
        else m.freshness
      in
      let next =
        { m with freshness; drafts = Drafts.voice_tick_elapsed ~now m.drafts }
        |> Model.expire_toast ~now
      in
      (next, [])
  | Msg.Server_health_result { epoch; result } ->
      if not (Epoch.is_current ~current:m.epoch ~reply:epoch) then (m, [])
      else apply_server_health ~now m result
  | Msg.Server_start_result (Ok ()) ->
      let next_epoch = Epoch.next m.epoch in
      let next = { m with epoch = next_epoch } in
      (next, [ Cmd.Http_get { epoch = next_epoch; req = Cmd.Get_health } ])
  | Msg.Server_start_result (Error reason) ->
      let incidents, _ =
        Incidents.push ~occurred_at_unix:m.freshness.last_wall_unix
          ~source:Health.Source_client_http
          ~summary:(Say.make ~ko:"로컬 서버 자동 시작 실패" ~en:"Local server start failed")
          ~detail:reason ~status:Health.Resolved m.incidents
      in
      let next =
        { m with incidents }
        |> Model.with_toast ~now ~level:Model.Toast_error
             (Say.make ~ko:("서버 시작 실패: " ^ reason) ~en:("Server start failed: " ^ reason))
      in
      (next, [])
  | Msg.Http_reply { epoch; reply } ->
      if not (Epoch.is_current ~current:m.epoch ~reply:epoch) then (m, [])
      else Update_http.apply_http_reply ~now m reply
  | Msg.Sse_event { epoch; event } ->
      if not (Epoch.is_current ~current:m.epoch ~reply:epoch) then (m, [])
      else Update_sse.apply_sse_event ~now m event
  | Msg.Sse_freshness { epoch; stream; freshness } ->
      if not (Epoch.is_current ~current:m.epoch ~reply:epoch) then (m, [])
      else Update_sse.apply_sse_freshness ~now ~stream ~freshness m
  | Msg.Chat_stream_chunk { epoch; keeper; request_id; is_btw; chunk } ->
      if not (Epoch.is_current ~current:m.epoch ~reply:epoch) then (m, [])
      else
        Update_sse.apply_chat_stream_chunk ~now ~keeper ~request_id ~is_btw
          ~chunk m
  | Msg.Chat_stream_done { epoch; keeper; request_id; is_btw; result } ->
      if not (Epoch.is_current ~current:m.epoch ~reply:epoch) then (m, [])
      else
        Update_sse.apply_chat_stream_done ~now ~keeper ~request_id ~is_btw
          ~result m
  | Msg.Voice_event ev -> apply_voice_event ~now m ev
  | Msg.Stream_gap dropped -> Update_sse.apply_stream_gap ~now dropped m

let step ~now m msg =
  let next, cmds = step_raw ~now m msg in
  let final_cmds = reconcile_streams ~before:m ~after:next cmds in
  (next, final_cmds)
