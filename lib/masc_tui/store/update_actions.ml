open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

let next_theme_preset = function
  | Theme.Midnight -> Theme.Arcade_hi
  | Theme.Arcade_hi -> Theme.Paper_light
  | Theme.Paper_light -> Theme.Mono
  | Theme.Mono -> Theme.Midnight

let find_actionable_ask (m : Model.t) =
  match Work_store.selected_open_ask m.work with
  | Some ask -> Some ask
  | None -> (
      match Attention.current_triage_item m.attention with
      | Some { payload = Attention.Payload_ask ask; id; _ }
        when not (Attention.is_in_flight ~id m.attention) ->
          Some ask
      | Some
          {
            payload =
              ( Attention.Payload_ask _
              | Attention.Payload_tool_approval _
              | Attention.Payload_gate _
              | Attention.Payload_goal_confirmation _
              | Attention.Payload_quarantine _ );
            _;
          }
      | None ->
          List.find_map
            (fun (e : Attention.entry) ->
              if Attention.is_in_flight ~id:e.id m.attention then None
              else
                match e.payload with
                | Attention.Payload_ask ask -> Some ask
                | Attention.Payload_tool_approval _
                | Attention.Payload_gate _
                | Attention.Payload_goal_confirmation _
                | Attention.Payload_quarantine _ ->
                    None)
            m.attention.items)

let rec execute_slash ~now (m : Model.t) cmd =
  match cmd with
  | Slash.Pulse -> Update_nav.switch_workspace m Nav.Pulse
  | Slash.Work -> Update_nav.switch_workspace m Nav.Work
  | Slash.Knowledge -> Update_nav.switch_workspace m Nav.Knowledge
  | Slash.Keepers -> Update_nav.switch_workspace m Nav.Keepers
  | Slash.Runtime -> Update_nav.switch_workspace m Nav.Runtime
  | Slash.Infra -> Update_nav.switch_workspace m Nav.Infra
  | Slash.Keeper None -> Update_nav.open_palette m Model.Palette_keepers
  | Slash.Keeper (Some name) ->
      let m1, cmds1 = Update_nav.switch_workspace m Nav.Keepers in
      let m2, cmds2 =
        Update_nav.push_dive m1 (Nav.Dive_keeper { name; tab = Nav.Keeper_chat })
      in
      (m2, cmds1 @ cmds2)
  | Slash.Model None -> Update_nav.open_palette m Model.Palette_models
  | Slash.Model (Some runtime_id) ->
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make
             ~ko:("런타임 모델 선택됨: " ^ runtime_id)
             ~en:("Selected runtime model: " ^ runtime_id))
          m
      , [] )
  | Slash.Config None -> Update_nav.open_global_settings m
  | Slash.Config (Some query) ->
      Update_nav.open_global_settings ~search_query:query m
  | Slash.Incidents ->
      let incidents = Incidents.mark_all_read m.incidents in
      Update_nav.open_overlay { m with incidents } Nav.Incidents
  | Slash.Jump -> Update_nav.teleport_blocked ~now m
  | Slash.Voice -> Update_nav.toggle_voice ~now m
  | Slash.Btw prompt -> Update_nav.start_btw_query ~now ~prompt m
  | Slash.Queue ->
      Update_nav.open_overlay m (Nav.Queue_context Nav.Drawer_queue)
  | Slash.Context ->
      Update_nav.open_overlay m (Nav.Queue_context Nav.Drawer_context)
  | Slash.Tools None ->
      ({ m with fleet = Fleet_store.cycle_tools_mode m.fleet }, [])
  | Slash.Tools (Some mode) ->
      ({ m with fleet = Fleet_store.set_tools_mode mode m.fleet }, [])
  | Slash.Clear ->
      let drafts = Drafts.clear_current_draft m.drafts in
      let fleet = Fleet_store.reset_chat_scroll m.fleet in
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make ~ko:"현재 초안이 비워졌습니다" ~en:"Cleared current draft")
          { m with drafts; fleet }
      , [] )
  | Slash.Theme opt ->
      let preset =
        match opt with Some p -> p | None -> next_theme_preset m.theme_preset
      in
      let next =
        { m with theme_preset = preset }
        |> Model.with_toast ~now ~level:Model.Toast_info
             (Say.concat ~sep:": "
                [
                  Say.make ~ko:"테마 변경" ~en:"Theme";
                  Theme.preset_label preset;
                ])
      in
      ( next
      , [
          Cmd.Http_post
            {
              epoch = m.epoch;
              req =
                Cmd.Post_tui_preference
                  (Wire_config.Pref_theme (Some (Theme.preset_name preset)));
            };
        ] )
  | Slash.Lang opt ->
      let lang =
        match opt with
        | Some l -> l
        | None -> (
            match m.lang with
            | Say.Lang_ko -> Say.Lang_en
            | Say.Lang_en -> Say.Lang_ko)
      in
      let next =
        { m with lang }
        |> Model.with_toast ~now ~level:Model.Toast_info
             (Say.make ~ko:"언어: 한국어" ~en:"Language: English")
      in
      ( next
      , [
          Cmd.Http_post
            {
              epoch = m.epoch;
              req = Cmd.Post_tui_preference (Wire_config.Pref_language lang);
            };
        ] )
  | Slash.Help -> Update_nav.open_overlay m Nav.Help
  | Slash.Restart -> (m, [ Cmd.Restart_tui ])
  | Slash.Quit -> (m, [ Cmd.Quit Exit_reason.Quit_key ])

and submit_composer ~now ~mode (m : Model.t) =
  let draft = Drafts.current_draft m.drafts in
  let trimmed = String.trim draft.text in
  if String.equal trimmed "" then (m, [])
  else if Char.equal trimmed.[0] '/' then
    match Slash.parse trimmed with
    | Ok parsed ->
        let m_cleared =
          {
            m with
            drafts =
              m.drafts |> Drafts.clear_current_draft |> Drafts.set_focus false;
          }
        in
        execute_slash ~now m_cleared parsed
    | Error err ->
        let msg =
          match err with
          | Slash.Not_a_slash_command | Slash.Empty_command ->
              Say.make ~ko:"슬래시 명령어를 입력하세요" ~en:"Enter a slash command"
          | Slash.Unknown_command name ->
              Say.make
                ~ko:("알 수 없는 명령어: " ^ name)
                ~en:("Unknown command: " ^ name)
          | Slash.Unexpected_argument { command; arg } ->
              Say.make
                ~ko:(Printf.sprintf "%s 명령은 인자(%s)를 받지 않습니다" command arg)
                ~en:(Printf.sprintf "%s takes no argument (%s)" command arg)
          | Slash.Invalid_argument { command; expected; got } ->
              Say.make
                ~ko:
                  (Printf.sprintf "%s 잘못된 인자 %s (기대: %s)" command got
                     expected.ko)
                ~en:
                  (Printf.sprintf "Invalid %s argument %s (expected: %s)" command
                     got expected.en)
        in
        (Model.with_toast ~now ~level:Model.Toast_warning msg m, [])
  else
    match Update_nav.resolve_target_keeper m with
    | None ->
        ( Model.with_toast ~now ~level:Model.Toast_warning
            (Say.make ~ko:"대상 키퍼를 먼저 선택하세요"
               ~en:"Select a target keeper first")
            m
        , [] )
    | Some keeper -> (
        let prior_user_msg_ids =
          match Fleet_store.String_map.find_opt keeper m.fleet.chat_histories with
          | None -> []
          | Some obs -> (
              match Observed.to_option obs with
              | None -> []
              | Some page ->
                  List.filter_map
                    (fun (msg : Wire_fleet.chat_message) ->
                      match msg.role with
                      | Wire_fleet.Role_user -> Some msg.id
                      | Wire_fleet.Role_assistant
                      | Wire_fleet.Role_system
                      | Wire_fleet.Role_tool ->
                          None)
                    page.messages)
        in
        let drafts0 = Drafts.set_active_keeper keeper m.drafts in
        match
          Drafts.enqueue_submission ~now ~keeper ~mode ~prior_user_msg_ids
            drafts0
        with
        | None -> (m, [])
        | Some (drafts1, tx) ->
            let drafts2 =
              Drafts.mark_sending ~now ~request_id:tx.request_id drafts1
            in
            let fleet =
              Fleet_store.start_chat_stream ~keeper ~request_id:tx.request_id
                m.fleet
            in
            let cmd = Update_nav.build_chat_submit_cmd m tx ~is_btw:false in
            ({ m with drafts = drafts2; fleet }, [ cmd ]))

and confirm_palette ~now (m : Model.t) =
  match m.palette.mode with
  | Model.Palette_commands -> (
      let items = Update_nav.palette_filtered_commands m in
      match
        List.nth_opt items
          (Update_nav.clamp_index (List.length items) m.palette.selected)
      with
      | None -> ({ m with nav = { m.nav with overlay = None } }, [])
      | Some cmd ->
          let m_closed = { m with nav = { m.nav with overlay = None } } in
          execute_action ~now m_closed cmd.action)
  | Model.Palette_keepers -> (
      let items = Update_nav.palette_filtered_keepers m in
      match
        List.nth_opt items
          (Update_nav.clamp_index (List.length items) m.palette.selected)
      with
      | None -> ({ m with nav = { m.nav with overlay = None } }, [])
      | Some k ->
          let m_closed = { m with nav = { m.nav with overlay = None } } in
          Update_nav.push_dive m_closed
            (Nav.Dive_keeper { name = k.name; tab = Nav.Keeper_chat }))
  | Model.Palette_models -> (
      let items = Update_nav.palette_filtered_models m in
      match
        List.nth_opt items
          (Update_nav.clamp_index (List.length items) m.palette.selected)
      with
      | None -> ({ m with nav = { m.nav with overlay = None } }, [])
      | Some r ->
          let m_closed =
            { m with nav = { m.nav with overlay = None } }
            |> Model.with_toast ~now ~level:Model.Toast_info
                 (Say.make
                    ~ko:("선택된 런타임: " ^ r.id)
                    ~en:("Selected runtime: " ^ r.id))
          in
          (m_closed, []))

and execute_action ~now (m : Model.t) action =
  match action with
  | Keymap.Switch_workspace ws -> Update_nav.switch_workspace m ws
  | Keymap.Sub_tab dir -> Update_nav.cycle_sub_tab m dir
  | Keymap.Cycle_focus_pane dir -> (
      match m.nav.overlay with
      | Some (Nav.Settings _) ->
          ({ m with config = Config_store.toggle_pane m.config }, [])
      | Some
          ( Nav.Palette
          | Nav.Incidents
          | Nav.Queue_context _
          | Nav.Inline_action _
          | Nav.Help
          | Nav.System_gate _ )
      | None ->
          let delta = match dir with Keymap.Next -> 1 | Keymap.Prev -> -1 in
          let next_pane = (m.nav.pane_index + delta + 3) mod 3 in
          ({ m with nav = { m.nav with pane_index = next_pane } }, []))
  | Keymap.Focus_composer -> (
      match m.nav.overlay with
      | Some
          (Nav.System_gate
             (Nav.Micro_viewport | Nav.Auth_gate | Nav.Server_offline)) ->
          (m, [])
      | Some
          ( Nav.Help
          | Nav.Palette
          | Nav.Settings _
          | Nav.Incidents
          | Nav.Queue_context _
          | Nav.Inline_action _
          | Nav.System_gate Nav.Media_viewer )
      | None ->
          let nav = { m.nav with overlay = None; filter_focused = false } in
          ( {
              m with
              nav;
              inline_modal = None;
              drafts = Drafts.set_focus true m.drafts;
            }
          , [] ))
  | Keymap.Focus_filter ->
      ( {
          m with
          nav = { m.nav with filter_focused = true };
          drafts = Drafts.set_focus false m.drafts;
        }
      , [] )
  | Keymap.Dive_selected -> Update_nav.dive_selected m
  | Keymap.Confirm_selected -> (
      if Drafts.is_focused m.drafts then
        submit_composer ~now ~mode:Drafts.Mode_steer m
      else
        match m.nav.overlay with
        | Some Nav.Palette -> confirm_palette ~now m
        | Some (Nav.Inline_action _) -> Update_nav.submit_inline_modal ~now m
        | Some (Nav.Settings _) ->
            if Config_store.is_editing_field m.config then
              match Config_store.commit_edit_field m.config with
              | Ok config ->
                  ( Model.with_toast ~now ~level:Model.Toast_info
                      (Say.make ~ko:"변경값이 스테이징됨 (Space: 미리보기)"
                         ~en:"Staged field change (Space: dry-run diff)")
                      { m with config }
                  , [] )
              | Error reason ->
                  ( Model.with_toast ~now ~level:Model.Toast_warning
                      (Say.literal reason) m
                  , [] )
            else (
              match m.config.settings_pane with
              | Config_store.Pane_tree ->
                  let config = Config_store.toggle_tree_node m.config in
                  let nav =
                    { m.nav with overlay = Some (Nav.Settings config.active_tab) }
                  in
                  ({ m with nav; config }, [])
              | Config_store.Pane_inspector -> (
                  match Config_store.begin_edit_selected m.config with
                  | Ok config -> ({ m with config }, [])
                  | Error reason ->
                      ( Model.with_toast ~now ~level:Model.Toast_info
                          (Say.literal reason) m
                      , [] )))
        | Some Nav.Incidents -> (
            match Incidents.selected_entry m.incidents with
            | Some inc ->
                Update_nav.push_dive m (Nav.Dive_infra (Nav.Incident_dive inc.id))
            | None -> (m, []))
        | Some (Nav.Queue_context _ | Nav.Help | Nav.System_gate _) -> (m, [])
        | None -> Update_nav.dive_selected m)
  | Keymap.Pop_back_or_close -> (
      match m.nav.overlay with
      | Some (Nav.Settings _) when Config_store.is_editing_field m.config ->
          ({ m with config = Config_store.cancel_edit_field m.config }, [])
      | Some
          (Nav.System_gate
             (Nav.Micro_viewport | Nav.Auth_gate | Nav.Server_offline)) ->
          (m, [])
      | Some (Nav.Settings _) ->
          let closed =
            {
              m with
              nav = { m.nav with overlay = None; filter_focused = false };
              inline_modal = None;
            }
            |> Update_nav.sync_config_for_keeper_view
          in
          let target_changed =
            not
              (Config_store.equal_config_target m.config.target
                 closed.config.target)
          in
          let cmds =
            if target_changed then View_fetches.fetches_for_current_view closed
            else []
          in
          (closed, cmds)
      | Some
          ( Nav.Palette
          | Nav.Incidents
          | Nav.Queue_context _
          | Nav.Inline_action _
          | Nav.Help
          | Nav.System_gate Nav.Media_viewer ) ->
          ( {
              m with
              nav = { m.nav with overlay = None; filter_focused = false };
              inline_modal = None;
            }
          , [] )
      | None ->
          if m.nav.filter_focused then
            ({ m with nav = { m.nav with filter_focused = false } }, [])
          else if Drafts.is_focused m.drafts then
            ({ m with drafts = Drafts.set_focus false m.drafts }, [])
          else (
            match m.nav.dive_stack with
            | _ :: rest ->
                let next =
                  { m with nav = { m.nav with dive_stack = rest } }
                  |> Update_nav.sync_config_for_keeper_view
                in
                (next, View_fetches.fetches_for_current_view next)
            | [] ->
                if not (String.equal (Update_nav.current_filter_query m) "") then
                  (Update_nav.set_active_filter_query "" m, [])
                else (m, [])))
  | Keymap.Open_settings -> Update_nav.open_global_settings m
  | Keymap.Teleport_blocked -> Update_nav.teleport_blocked ~now m
  | Keymap.Open_incidents ->
      let incidents = Incidents.mark_all_read m.incidents in
      Update_nav.open_overlay { m with incidents } Nav.Incidents
  | Keymap.Voice_ptt_toggle -> Update_nav.toggle_voice ~now m
  | Keymap.Fast_approve_top -> Update_nav.fast_approve_top ~now m
  | Keymap.Fast_deny_top -> Update_nav.fast_deny_top ~now m
  | Keymap.Ask_select_choice choice_1based -> (
      match find_actionable_ask m with
      | Some ask -> Update_nav.submit_ask_choice ~now ask ~choice_1based m
      | None -> (m, []))
  | Keymap.Open_help -> (
      match m.nav.overlay with
      | Some Nav.Help -> ({ m with nav = { m.nav with overlay = None } }, [])
      | Some
          ( Nav.Palette
          | Nav.Settings _
          | Nav.Incidents
          | Nav.Queue_context _
          | Nav.Inline_action _
          | Nav.System_gate _ )
      | None ->
          Update_nav.open_overlay m Nav.Help)
  | Keymap.Open_palette -> Update_nav.open_palette m Model.Palette_commands
  | Keymap.Open_keeper_switcher -> Update_nav.open_palette m Model.Palette_keepers
  | Keymap.Open_model_switcher -> Update_nav.open_palette m Model.Palette_models
  | Keymap.Toggle_tool_details ->
      ({ m with fleet = Fleet_store.cycle_tools_mode m.fleet }, [])
  | Keymap.Open_queue_context -> (
      match m.nav.overlay with
      | Some (Nav.Queue_context _) ->
          ({ m with nav = { m.nav with overlay = None } }, [])
      | Some
          ( Nav.Palette
          | Nav.Settings _
          | Nav.Incidents
          | Nav.Inline_action _
          | Nav.Help
          | Nav.System_gate _ )
      | None ->
          Update_nav.open_overlay m (Nav.Queue_context Nav.Drawer_queue))
  | Keymap.Toggle_thinking ->
      ({ m with fleet = Fleet_store.cycle_thinking_mode m.fleet }, [])
  | Keymap.Cycle_origin_mode ->
      ({ m with fleet = Fleet_store.cycle_origin_mode m.fleet }, [])
  | Keymap.Composer_kill_word ->
      ({ m with drafts = Drafts.kill_word m.drafts }, [])
  | Keymap.Composer_newline ->
      ({ m with drafts = Drafts.insert_newline m.drafts }, [])
  | Keymap.Submit_steer -> submit_composer ~now ~mode:Drafts.Mode_steer m
  | Keymap.Submit_followup -> submit_composer ~now ~mode:Drafts.Mode_follow_up m
  | Keymap.Move dir -> Update_nav.apply_move m dir
  | Keymap.Toggle_expand -> (
      match m.nav.overlay with
      | Some (Nav.Settings _) -> (
          match Config_store.build_patch_request ~dry_run:true m.config with
          | Ok req ->
              let config = Config_store.mark_dry_run_loading m.config in
              ( { m with config }
              , [
                  Cmd.Http_post
                    { epoch = m.epoch; req = Cmd.Post_config_patch req };
                ] )
          | Error reason ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.literal reason) m
              , [] ))
      | Some Nav.Incidents ->
          ( { m with incidents = Incidents.toggle_show_dismissed m.incidents }
          , [] )
      | Some
          ( Nav.Palette
          | Nav.Queue_context _
          | Nav.Inline_action _
          | Nav.Help
          | Nav.System_gate _ ) ->
          (m, [])
      | None -> (
          match Model.active_dive m with
          | Some (Nav.Dive_keeper { tab = Nav.Keeper_chat; _ }) ->
              ({ m with fleet = Fleet_store.toggle_turn_details m.fleet }, [])
          | Some (Nav.Dive_infra _) ->
              ({ m with infra = Infra_store.toggle_raw_json m.infra }, [])
          | Some
              ( Nav.Dive_keeper
                  {
                    tab =
                      ( Nav.Keeper_memory
                      | Nav.Keeper_work_candle
                      | Nav.Keeper_sandbox
                      | Nav.Keeper_config );
                    _;
                  }
              | Nav.Dive_work _
              | Nav.Dive_knowledge _ )
          | None -> (
              match m.nav.workspace with
              | Nav.Keepers -> (
                  match Fleet_store.selected_keeper_summary m.fleet with
                  | Some k ->
                      ( {
                          m with
                          fleet =
                            Fleet_store.toggle_company_collapsed k.company
                              m.fleet;
                        }
                      , [] )
                  | None -> (m, []))
              | Nav.Knowledge -> (
                  match m.knowledge.active_tab with
                  | Nav.Knowledge_board -> (
                      match Knowledge_store.selected_post m.knowledge with
                      | Some { succession_chain_root_id = Some root_id; _ } ->
                          ( {
                              m with
                              knowledge =
                                Knowledge_store.toggle_succession_chain ~root_id
                                  m.knowledge;
                            }
                          , [] )
                      | Some { succession_chain_root_id = None; _ } | None ->
                          let knowledge =
                            Knowledge_store.toggle_signal_only m.knowledge
                          in
                          let next = { m with knowledge } in
                          (next, View_fetches.fetches_for_current_view next))
                  | Nav.Knowledge_wiki_artifacts ->
                      ( {
                          m with
                          knowledge =
                            Knowledge_store.toggle_wiki_artifacts_submode
                              m.knowledge;
                        }
                      , [] )
                  | Nav.Knowledge_memory ->
                      let knowledge =
                        Knowledge_store.cycle_memory_diff_window m.knowledge
                      in
                      let next = { m with knowledge } in
                      (next, View_fetches.fetches_for_current_view next))
              | Nav.Runtime ->
                  ( {
                      m with
                      runtime =
                        Runtime_store.toggle_outside_lane_probes m.runtime;
                    }
                  , [] )
              | Nav.Work ->
                  let work = Work_store.toggle_verification_view m.work in
                  let next = { m with work } in
                  (next, View_fetches.fetches_for_current_view next)
              | Nav.Infra ->
                  ( {
                      m with
                      infra = Infra_store.cycle_log_level_filter m.infra;
                    }
                  , [] )
              | Nav.Pulse -> (m, []))))
  | Keymap.Create_new -> (
      match m.nav.overlay with
      | Some (Nav.Settings _) -> (
          match Config_store.build_patch_request ~dry_run:false m.config with
          | Ok req ->
              let config = Config_store.mark_save_in_flight m.config in
              ( { m with config }
              , [
                  Cmd.Http_post
                    { epoch = m.epoch; req = Cmd.Post_config_patch req };
                ] )
          | Error reason ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.literal reason) m
              , [] ))
      | Some
          ( Nav.Palette
          | Nav.Incidents
          | Nav.Queue_context _
          | Nav.Inline_action _
          | Nav.Help
          | Nav.System_gate _ ) ->
          (m, [])
      | None -> (
          match m.nav.workspace with
          | Nav.Knowledge -> Update_nav.open_inline_modal m Nav.Board_new_post
          | Nav.Work -> Update_nav.open_inline_modal m Nav.Schedule_form
          | Nav.Runtime -> Update_nav.open_inline_modal m Nav.Connector_form
          | Nav.Infra -> Update_nav.open_inline_modal m Nav.Repo_add_form
          | Nav.Keepers ->
              let config =
                Config_store.set_target Wire_config.Target_keeper_create m.config
              in
              Update_nav.open_overlay { m with config }
                (Nav.Settings Nav.Settings_keepers_companies)
          | Nav.Pulse -> Update_nav.open_inline_modal m Nav.Board_new_post))
  | Keymap.Refresh ->
      let needs_handshake =
        m.freshness.server_offline
        ||
        match m.server_identity.mismatch_state with
        | Model.Mismatch_halted -> true
        | Model.Mismatch_none | Model.Mismatch_recovering -> false
      in
      if needs_handshake then
        let next_epoch = Epoch.next m.epoch in
        let server_identity =
          {
            m.server_identity with
            mismatch_state =
              (match m.server_identity.mismatch_state with
              | Model.Mismatch_halted -> Model.Mismatch_recovering
              | Model.Mismatch_none | Model.Mismatch_recovering ->
                  m.server_identity.mismatch_state);
          }
        in
        let next =
          { m with epoch = next_epoch; server_identity }
          |> Model.mark_all_domains_stale
          |> Model.with_toast ~now ~level:Model.Toast_info
               (Say.make ~ko:"서버 핸드셰이크 재시도 중"
                  ~en:"Retrying server handshake")
        in
        ( next
        , [
            Cmd.Update_workspace_guard
              { instance_id = None; workspace_sha256 = None };
            Cmd.Http_get { epoch = next_epoch; req = Cmd.Get_health };
          ] )
      else
        let next = Model.mark_all_domains_stale m in
        let view_cmds = View_fetches.fetches_for_current_view ~force:true next in
        let probe_cmd =
          match next.nav.workspace, next.runtime.active_tab with
          | Nav.Runtime, Nav.Runtime_failover_lanes ->
              [
                Cmd.Http_get
                  {
                    epoch = next.epoch;
                    req = Cmd.Get_runtime_probe { force = true };
                  };
              ]
          | ( ( Nav.Pulse
              | Nav.Work
              | Nav.Knowledge
              | Nav.Keepers
              | Nav.Infra )
            , _ )
          | ( Nav.Runtime
            , ( Nav.Runtime_quotas_credits
              | Nav.Runtime_efficiency_spend
              | Nav.Runtime_tools_connectors ) ) ->
              []
        in
        ( Model.with_toast ~now ~level:Model.Toast_info
            (Say.make ~ko:"현재 화면 새로고침 중" ~en:"Refreshing active view")
            next
        , view_cmds @ probe_cmd )
  | Keymap.Copy_selected -> (
      let text_opt =
        match m.nav.workspace with
        | Nav.Knowledge -> (
            match m.knowledge.active_tab with
            | Nav.Knowledge_board ->
                Option.map
                  (fun (p : Wire_knowledge.board_post) -> p.body)
                  (Knowledge_store.selected_post m.knowledge)
            | Nav.Knowledge_wiki_artifacts -> (
                match m.knowledge.wiki_artifacts_submode with
                | `Wiki ->
                    Option.map
                      (fun (p : Wire_knowledge.wiki_page_summary) -> p.slug)
                      (Knowledge_store.selected_wiki_page m.knowledge)
                | `Artifacts ->
                    Option.map
                      (fun (a : Wire_knowledge.artifact_entry) -> a.sha256)
                      (Knowledge_store.selected_artifact m.knowledge))
            | Nav.Knowledge_memory -> (
                match Observed.to_option m.knowledge.world_memory with
                | Some wm -> (
                    match wm.briefing.text with
                    | Some txt -> Some txt
                    | None -> (
                        match wm.claims with c :: _ -> Some c.claim | [] -> None))
                | None -> None))
        | Nav.Infra -> (
            match m.infra.active_tab with
            | Nav.Infra_sandboxes -> Infra_store.selected_sandbox_keeper m.infra
            | Nav.Infra_repos_changes ->
                Option.map
                  (fun (r : Wire_infra.repository) -> r.url)
                  (Infra_store.selected_repository m.infra)
            | Nav.Infra_activity_logs ->
                Option.map
                  (fun (e : Wire_infra.system_log_entry) -> e.message)
                  (Infra_store.selected_log m.infra))
        | Nav.Keepers | Nav.Pulse ->
            Option.map
              (fun (k : Wire_fleet.keeper_summary) -> k.name)
              (Fleet_store.selected_keeper_summary m.fleet)
        | Nav.Work -> (
            match m.work.active_tab with
            | Nav.Work_pipeline -> (
                match Work_store.selected_goal m.work with
                | Some g -> Some g.title
                | None ->
                    Option.map
                      (fun (v : Wire_work.verification_request) -> v.task_title)
                      (Work_store.selected_verification m.work))
            | Nav.Work_tasks_schedules -> (
                match Work_store.selected_task m.work with
                | Some task -> Some task.title
                | None ->
                    Option.map
                      (fun (s : Wire_work.schedule_row) -> s.schedule_id)
                      (Work_store.selected_schedule m.work))
            | Nav.Work_inbox -> (
                match Work_store.selected_open_ask m.work with
                | Some a -> Some a.ask_id
                | None ->
                    Option.map
                      (fun (e : Attention.entry) -> e.summary)
                      (Attention.current_triage_item m.attention))
            | Nav.Work_candle_scorecard -> (
                match Observed.to_option m.work.candle_ledger with
                | Some l -> (
                    match List.nth_opt l.balances m.work.selected_index with
                    | Some row -> Some row.keeper
                    | None -> None)
                | None -> None))
        | Nav.Runtime ->
            Option.map
              (fun (l : Wire_runtime.failover_lane) -> l.id)
              (Runtime_store.selected_lane m.runtime)
      in
      match text_opt with
      | Some txt ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:"클립보드에 복사됨" ~en:"Copied to clipboard")
              m
          , [ Cmd.Copy_clipboard txt ] )
      | None -> (m, []))
  | Keymap.Open_external -> (
      match m.nav.overlay with
      | Some (Nav.Settings _) -> (
          match m.config.target with
          | Wire_config.Target_runtime ->
              (m, [ Cmd.Open_editor_escape_hatch Cmd.Edit_runtime_toml ])
          | Wire_config.Target_keeper name ->
              (m, [ Cmd.Open_editor_escape_hatch (Cmd.Edit_keeper_toml name) ])
          | Wire_config.Target_keeper_create ->
              ( Model.with_toast ~now ~level:Model.Toast_warning
                  (Say.make
                     ~ko:"새 키퍼 생성은 TUI 설정 화면에서 제출하세요 ($EDITOR 미지원)"
                     ~en:"Create new keepers in Settings UI ($EDITOR escape hatch unavailable for new keepers)")
                  m
              , [] ))
      | Some
          ( Nav.Palette
          | Nav.Incidents
          | Nav.Queue_context _
          | Nav.Inline_action _
          | Nav.Help
          | Nav.System_gate _ )
      | None -> (
          match m.nav.workspace with
          | Nav.Infra -> (
              match Infra_store.selected_repository m.infra with
              | Some repo -> (m, [ Cmd.Open_external_url repo.url ])
              | None -> (m, []))
          | Nav.Pulse
          | Nav.Work
          | Nav.Knowledge
          | Nav.Keepers
          | Nav.Runtime ->
              (m, [])))
  | Keymap.Toggle_zoom ->
      ({ m with nav = { m.nav with zoomed = not m.nav.zoomed } }, [])
  | Keymap.Quit_app -> (m, [ Cmd.Quit Exit_reason.Quit_key ])
