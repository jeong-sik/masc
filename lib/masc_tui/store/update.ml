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
      | Cmd.Render_memory_diagram _
      | Cmd.Cancel_memory_diagram
      | Cmd.Fetch_artifact_and_copy _
      | Cmd.Export_artifact _
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

let reconcile_memory_diagram ~(before : Model.t) ~(after : Model.t) cmds =
  match before.knowledge.memory_diagram, after.knowledge.memory_diagram with
  | Some _, None -> cmds @ [ Cmd.Cancel_memory_diagram ]
  | (Some _ | None), Some _ | None, None -> cmds

let apply_resize ~now (m : Model.t) ~cols ~rows =
  let viewport = { Model.cols = max 0 cols; rows = max 0 rows } in
  let breakpoint = Model.classify_viewport viewport in
  let next0 = { m with viewport; breakpoint } in
  (* When shrinking across the docking threshold while the sidebar was not
     focused, drop an explicit docked-open pin so an unfocused floating drawer
     cannot cover the narrowed body. *)
  let was_docked = Model.sidebar_docked m in
  let is_docked = Model.sidebar_docked next0 in
  let sidebar_open =
    if was_docked && (not is_docked) && not m.nav.sidebar_focused then
      match next0.nav.sidebar_open with
      | Some true -> None
      | (Some false | None) as v -> v
    else next0.nav.sidebar_open
  in
  let next1 = { next0 with nav = { next0.nav with sidebar_open } } in
  (* Clear sidebar focus if shrinking hid the sidebar so keyboard focus can
     never remain trapped on an invisible surface. *)
  let sidebar_focused =
    if Model.sidebar_visible next1 then next1.nav.sidebar_focused else false
  in
  let next2 = { next1 with nav = { next1.nav with sidebar_focused } } in
  (* Clamp pane_index to the resized layout's focusable pane count so focus can
     never linger on a pane that collapsed away. *)
  let max_pane = max 0 (Model.focusable_pane_count next2 - 1) in
  let pane_index = max 0 (min max_pane next2.nav.pane_index) in
  (* Entering Micro (<80x24) or too-small (<40x12) locks text surfaces so hidden
     Composer/Filter/Settings edits cannot silently absorb keystrokes. *)
  let micro_locked =
    Model.is_too_small_viewport next2.viewport
    || Model.equal_breakpoint next2.breakpoint Model.Micro
  in
  let drafts =
    if micro_locked && Drafts.is_focused next2.drafts then
      Drafts.set_focus false next2.drafts
    else next2.drafts
  in
  let filter_focused =
    if micro_locked then false else next2.nav.filter_focused
  in
  let config =
    if micro_locked && Config_store.is_editing_field next2.config then
      Config_store.cancel_edit_field next2.config
    else next2.config
  in
  let next =
    {
      next2 with
      drafts;
      config;
      nav = { next2.nav with pane_index; filter_focused };
    }
  in
  (* Never clobber [m.nav.overlay] or [m.inline_modal]; [Micro_viewport] gating
     is evaluated dynamically from [Model.is_too_small_viewport] / [Micro]. *)
  match
    Memory_diagram.active_diagram next,
    Memory_diagram.active_memory_content_rect next
  with
  | Some d, Some (_, content_rect) ->
      let prev_w =
        Option.map
          (fun (_, (r : Rect.t)) -> r.w)
          (Memory_diagram.active_memory_content_rect m)
      in
      if
        (not (Option.equal Int.equal prev_w (Some content_rect.w)))
        && not (Memory_diagram.can_render_png_in_rect ~content_rect d)
      then Update_nav.refresh_open_memory_diagram ~now next
      else (next, [])
  | (Some _ | None), (Some _ | None) -> (next, [])

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
  | Msg.Resize { cols; rows } -> apply_resize ~now m ~cols ~rows
  | Msg.Tick { wall_unix } ->
      (* Zero idle HTTP polling: ticks only record wall time, expire toasts,
         update voice recording elapsed seconds, and advance bounded rechecks
         for already-closed Confirming_delivery transmissions. *)
      let wall_advanced =
        Float.is_finite wall_unix && wall_unix > m.freshness.last_wall_unix
      in
      let freshness, fleet =
        if wall_advanced then
          ( { m.freshness with last_wall_unix = wall_unix }
          , Fleet_store.set_wall_unix wall_unix m.fleet )
        else (m.freshness, m.fleet)
      in
      let drafts0 = Drafts.voice_tick_elapsed ~now m.drafts in
      let drafts, keepers_to_recheck =
        List.fold_left
          (fun (acc, keepers) (tx : Drafts.pending_message) ->
            match tx.state with
            | Drafts.Confirming_delivery ->
                let elapsed =
                  Clock.Mono.seconds_since now ~since:tx.updated_at
                in
                if elapsed < 2.0 then (acc, keepers)
                else if tx.recheck_count >= 3 then
                  let acc' =
                    if tx.user_persisted then
                      Drafts.mark_delivered ~now ~request_id:tx.request_id
                        ~keeper:tx.keeper ~body:tx.body acc
                    else
                      Drafts.mark_failed_retryable ~now
                        ~request_id:tx.request_id
                        ~reason:"Delivery confirmation timed out" acc
                  in
                  (acc', keepers)
                else
                  let acc' =
                    Drafts.mark_confirming ~now ~request_id:tx.request_id acc
                  in
                  let keepers' =
                    if List.exists (String.equal tx.keeper) keepers then keepers
                    else tx.keeper :: keepers
                  in
                  (acc', keepers')
            | Drafts.Queued
            | Drafts.Sending
            | Drafts.Pending_processing
            | Drafts.Interrupting
            | Drafts.Delivered
            | Drafts.Failed_retryable _ ->
                (acc, keepers))
          (drafts0, []) drafts0.pending_txs
      in
      let recheck_cmds =
        List.rev_map
          (fun keeper ->
            Cmd.Http_get
              {
                epoch = m.epoch;
                req =
                  Cmd.Get_chat_history
                    { keeper; limit = Some 80; cursor = None };
              })
          keepers_to_recheck
      in
      let next =
        let m' =
          { m with freshness; fleet; drafts } |> Model.expire_toast ~now
        in
        if wall_advanced then Model.sync_effective_scorecard ~now m' else m'
      in
      (next, recheck_cmds)
  | Msg.Server_health_result { epoch; result } ->
      if not (Epoch.is_current ~current:m.epoch ~reply:epoch) then (m, [])
      else apply_server_health ~now m result
  | Msg.Server_start_result (Ok ()) ->
      let next_epoch = Epoch.next m.epoch in
      let next =
        {
          m with
          epoch = next_epoch;
          infra = Infra_store.forget_log_cursor m.infra;
        }
      in
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
  | Msg.Chat_stream_decode_warning { epoch; keeper; request_id; reason } ->
      if not (Epoch.is_current ~current:m.epoch ~reply:epoch) then (m, [])
      else
        Update_sse.apply_chat_stream_decode_warning ~now ~keeper ~request_id
          ~reason m
  | Msg.Chat_stream_done { epoch; keeper; request_id; is_btw; result } ->
      if not (Epoch.is_current ~current:m.epoch ~reply:epoch) then (m, [])
      else
        Update_sse.apply_chat_stream_done ~now ~keeper ~request_id ~is_btw
          ~result m
  | Msg.Memory_diagram_rendered
      { epoch; request_id; keeper; event_identity; kind; mode; result } ->
      if not (Epoch.is_current ~current:m.epoch ~reply:epoch) then (m, [])
      else
        let knowledge =
          Knowledge_store.apply_memory_diagram_result ~observed_at:now
            ~request_id ~keeper ~event_identity ~kind ~mode result m.knowledge
        in
        ({ m with knowledge }, [])
  | Msg.Voice_event ev -> apply_voice_event ~now m ev
  | Msg.Stream_gap dropped -> Update_sse.apply_stream_gap ~now dropped m
  | Msg.Github_login_chunk { epoch; keeper; text } ->
      if not (Epoch.is_current ~current:m.epoch ~reply:epoch) then (m, [])
      else
        let keeper_context =
          Keeper_context_store.append_github_login_output ~keeper ~line:text
            m.keeper_context
        in
        ({ m with keeper_context }, [])
  | Msg.Github_login_done { epoch; keeper; observation; error } ->
      if not (Epoch.is_current ~current:m.epoch ~reply:epoch) then (m, [])
      else
        let kc0 =
          Keeper_context_store.finish_github_login ~keeper ~error
            m.keeper_context
        in
        let keeper_context =
          match observation with
          | Some obs ->
              Keeper_context_store.apply_github_identity ~observed_at:now
                ~keeper obs kc0
          | None -> kc0
        in
        let m1 = { m with keeper_context } in
        let next =
          match error with
          | Some err ->
              Model.with_toast ~now ~level:Model.Toast_warning
                (Say.make ~ko:("GitHub 로그인 실패: " ^ err)
                   ~en:("GitHub login failed: " ^ err))
                m1
          | None ->
              Model.with_toast ~now ~level:Model.Toast_success
                (Say.make ~ko:"GitHub 로그인 완료" ~en:"GitHub login complete")
                m1
        in
        ( next
        , [
            Cmd.Http_get
              { epoch = m.epoch; req = Cmd.Get_github_identity { keeper } };
          ] )

(* A new epoch is a new handshake, and the server behind it may be another
   process. Every path that moves the epoch returns through [step], so what
   only the previous process could answer is dropped here once.
   - A new process numbers its log lines from zero again, so the next log
     stream opens without the old cursor and the server answers with a reset
     frame.
   - Chat stream frames carry the epoch they were sent in, and the guard
     drops them from now on. Each open chat request waits for the history
     instead, the way a stream that closed without a terminal does. *)
let leave_old_epoch ~now ~(before : Model.t) (after : Model.t) =
  if Epoch.equal before.epoch after.epoch then after
  else
    {
      after with
      infra = Infra_store.forget_log_cursor after.infra;
      fleet = Fleet_store.detach_chat_streams after.fleet;
      drafts = Drafts.detach_streams ~now after.drafts;
    }

let step ~now m msg =
  let next0, cmds = step_raw ~now m msg in
  let next0 = leave_old_epoch ~now ~before:m next0 in
  let view_stream_changed =
    not
      (Option.equal Subscriptions.equal_stream_kind
         (Subscriptions.view_scoped_stream m)
         (Subscriptions.view_scoped_stream next0))
  in
  let next1 =
    if view_stream_changed && Option.is_some next0.freshness.view_stream then
      { next0 with freshness = { next0.freshness with view_stream = None } }
    else next0
  in
  let last_mono = Clock.Mono.max next1.freshness.last_mono now in
  let next =
    if Clock.Mono.equal last_mono next1.freshness.last_mono then next1
    else { next1 with freshness = { next1.freshness with last_mono } }
  in
  let final_cmds =
    cmds
    |> reconcile_streams ~before:m ~after:next
    |> reconcile_memory_diagram ~before:m ~after:next
  in
  (next, final_cmds)
