open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

let next_theme_preset = function
  | Theme.Midnight -> Theme.Arcade_hi
  | Theme.Arcade_hi -> Theme.Paper_light
  | Theme.Paper_light -> Theme.Mono
  | Theme.Mono -> Theme.Midnight

let extract_first_http_url (text : string) : string option =
  let len = String.length text in
  let is_url_char = function
    | ' ' | '\t' | '\n' | '\r' | '"' | '\'' | '<' | '>' | ')' | ']' | ',' | ';' ->
        false
    | _ -> true
  in
  let has_prefix pos prefix =
    let plen = String.length prefix in
    pos + plen <= len && String.equal (String.sub text pos plen) prefix
  in
  let rec scan i =
    if i >= len then None
    else if has_prefix i "https://" || has_prefix i "http://" then (
      let rec find_end j =
        if j < len && is_url_char text.[j] then find_end (j + 1) else j
      in
      let stop = find_end i in
      let url = String.sub text i (stop - i) in
      if String.length url > 8 then Some url else scan (stop + 1))
    else scan (i + 1)
  in
  scan 0

let latest_keeper_reply_text (m : Model.t) : (string * string) option =
  let keeper_opt =
    match Model.active_dive m with
    | Some (Nav.Dive_keeper { name; _ }) -> Some name
    | Some (Nav.Dive_work _ | Nav.Dive_knowledge _ | Nav.Dive_infra _) | None -> (
        match m.nav.workspace with
        | Nav.Keepers ->
            Option.map
              (fun (k : Wire_fleet.keeper_summary) -> k.name)
              (Fleet_store.selected_keeper_summary m.fleet)
        | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Runtime | Nav.Infra -> None)
  in
  match keeper_opt with
  | None -> None
  | Some keeper -> (
      let stream_text =
        match Fleet_store.String_map.find_opt keeper m.fleet.chat_streams with
        | Some s when s.active && not (String.equal (String.trim s.text) "") ->
            Some s.text
        | Some _ | None -> None
      in
      match stream_text with
      | Some txt -> Some (keeper, txt)
      | None -> (
          match
            Fleet_store.String_map.find_opt keeper m.fleet.chat_histories
          with
          | None -> None
          | Some obs -> (
              match Observed.to_option obs with
              | None -> None
              | Some page ->
                  List.find_map
                    (fun (msg : Wire_fleet.chat_message) ->
                      match msg.role with
                      | Wire_fleet.Role_assistant
                        when not (String.equal (String.trim msg.content) "") ->
                          Some (keeper, msg.content)
                      | Wire_fleet.Role_assistant
                      | Wire_fleet.Role_user
                      | Wire_fleet.Role_system
                      | Wire_fleet.Role_tool ->
                          None)
                    (List.rev page.messages))))

let find_writable_runtime_field (schema : Wire_config.config_schema) =
  List.find_map
    (fun (sec : Wire_config.schema_section) ->
      List.find_map
        (fun (f : Wire_config.schema_field) ->
          let is_runtime_key =
            String.equal f.key "runtime"
            || String.equal f.key "runtime_id"
            || String.equal f.key "model"
            || String.equal f.key "default_route"
          in
          let is_string_like =
            match f.kind with
            | Wire_config.Field_string | Wire_config.Field_enum _ -> true
            | Wire_config.Field_bool
            | Wire_config.Field_int _
            | Wire_config.Field_float _
            | Wire_config.Field_string_list
            | Wire_config.Field_structured
            | Wire_config.Field_secret ->
                false
          in
          if f.writable && is_runtime_key && is_string_like then Some f
          else None)
        sec.fields)
    schema.sections

let apply_model_selection ~now ~runtime_id (m : Model.t) =
  let m0 = { m with nav = { m.nav with overlay = None } } in
  let target_keeper =
    match Model.active_dive m0 with
    | Some (Nav.Dive_keeper { name; _ }) -> Some name
    | Some (Nav.Dive_work _ | Nav.Dive_knowledge _ | Nav.Dive_infra _) | None ->
        None
  in
  let staged_keeper_dry_run =
    match target_keeper, Observed.to_option m0.config.schema with
    | Some keeper, Some schema
      when Config_store.equal_config_target schema.target
             (Wire_config.Target_keeper keeper) -> (
        match find_writable_runtime_field schema with
        | None -> None
        | Some fld -> (
            let config =
              m0.config
              |> Config_store.set_target (Wire_config.Target_keeper keeper)
              |> Config_store.set_tab Nav.Settings_keepers_companies
              |> Config_store.stage_patch ~full_key:fld.full_key
                   (Wire_config.Set_scalar
                      { table = fld.table; key = fld.key; value = runtime_id })
            in
            match Config_store.build_patch_request ~dry_run:true config with
            | Error _ -> None
            | Ok req ->
                let config = Config_store.mark_dry_run_loading config in
                let nav =
                  {
                    m0.nav with
                    overlay =
                      Some (Nav.Settings Nav.Settings_keepers_companies);
                    filter_focused = false;
                  }
                in
                let next =
                  { m0 with nav; config }
                  |> Model.with_toast ~now ~level:Model.Toast_info
                       (Say.make
                          ~ko:
                            (Printf.sprintf
                               "%s 런타임 변경 미리보기: %s (Ctrl+S 저장)"
                               keeper runtime_id)
                          ~en:
                            (Printf.sprintf
                               "Dry-run runtime switch for %s -> %s (Ctrl+S to \
                                save)"
                               keeper runtime_id))
                in
                Some
                  ( next
                  , [
                      Cmd.Http_post
                        { epoch = next.epoch; req = Cmd.Post_config_patch req };
                    ] )))
    | Some _, (Some _ | None) | None, (Some _ | None) -> None
  in
  match staged_keeper_dry_run with
  | Some res -> res
  | None ->
      let config =
        m0.config
        |> Config_store.set_target Wire_config.Target_runtime
        |> Config_store.set_tab Nav.Settings_providers_models
        |> Config_store.set_search_query runtime_id
      in
      let next, view_cmds =
        Update_nav.open_overlay { m0 with config }
          (Nav.Settings Nav.Settings_providers_models)
      in
      let cmds =
        match view_cmds with
        | [] ->
            [
              Cmd.Http_get
                {
                  epoch = next.epoch;
                  req = Cmd.Get_config_schema Wire_config.Target_runtime;
                };
            ]
        | _ -> view_cmds
      in
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make
             ~ko:("설정에서 런타임 확인/변경: " ^ runtime_id)
             ~en:("Inspect/edit runtime in Settings: " ^ runtime_id))
          next
      , cmds )

let find_actionable_ask (m : Model.t) =
  let on_work_inbox =
    Nav.equal_workspace m.nav.workspace Nav.Work
    && Nav.equal_work_tab m.work.active_tab Nav.Work_inbox
  in
  if on_work_inbox && not (Attention.is_empty m.attention) then
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
        None
  else
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
    | None -> (
        match Work_store.selected_open_ask m.work with
        | Some ask -> Some ask
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
  | Slash.Model (Some runtime_id) -> apply_model_selection ~now ~runtime_id m
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
      | Some r -> apply_model_selection ~now ~runtime_id:r.id m)

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
          let next =
            Update_nav.clamp_for_pane
              { m with nav = { m.nav with pane_index = next_pane } }
          in
          (next, []))
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
            if Config_store.is_editing_field m.config then (
              let was_new_keeper =
                Config_store.is_editing_new_keeper_name m.config
              in
              match Config_store.commit_edit_field m.config with
              | Ok config ->
                  let msg =
                    if was_new_keeper then
                      Say.make
                        ~ko:
                          ("새 키퍼 이름 설정됨: " ^ config.new_keeper_name
                         ^ " (Ctrl+S 저장)")
                        ~en:
                          ("New keeper name set: " ^ config.new_keeper_name
                         ^ " (Ctrl+S to save)")
                    else
                      Say.make ~ko:"변경값이 스테이징됨 (Space: 미리보기)"
                        ~en:"Staged field change (Space: dry-run diff)"
                  in
                  (Model.with_toast ~now ~level:Model.Toast_info msg { m with config }, [])
              | Error reason ->
                  ( Model.with_toast ~now ~level:Model.Toast_warning
                      (Say.literal reason) m
                  , [] ))
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
          else
            let active_chat_interrupt =
              match Model.active_dive m with
              | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_chat }) -> (
                  let active_stream_opt =
                    match
                      Fleet_store.String_map.find_opt name m.fleet.chat_streams
                    with
                    | Some s when s.active -> Some s
                    | Some _ | None -> None
                  in
                  match
                    Fleet_store.active_turn_for ~keeper:name m.fleet
                  , active_stream_opt
                  with
                  | Some turn, stream_opt ->
                      let fleet =
                        match stream_opt with
                        | Some s ->
                            Fleet_store.finish_chat_stream ~keeper:name
                              ~request_id:s.request_id
                              ~error:(Some "Interrupted by operator") m.fleet
                        | None -> m.fleet
                      in
                      Some (name, turn.interrupt_token, fleet)
                  | None, Some s ->
                      let token =
                        Option.value s.operation_id ~default:s.request_id
                      in
                      let fleet =
                        Fleet_store.finish_chat_stream ~keeper:name
                          ~request_id:s.request_id
                          ~error:(Some "Interrupted by operator") m.fleet
                      in
                      Some (name, token, fleet)
                  | None, None -> None)
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
                  | Nav.Dive_knowledge _
                  | Nav.Dive_infra _ )
              | None ->
                  None
            in
            match active_chat_interrupt with
            | Some (keeper, interrupt_token, fleet) ->
                ( Model.with_toast ~now ~level:Model.Toast_warning
                    (Say.make
                       ~ko:("키퍼 턴 중단 요청 전송: " ^ keeper)
                       ~en:("Interrupt requested for keeper turn: " ^ keeper))
                    { m with fleet }
                , [
                    Cmd.Http_post
                      {
                        epoch = m.epoch;
                        req =
                          Cmd.Post_keeper_turn_interrupt
                            { keeper; interrupt_token };
                      };
                  ] )
            | None -> (
                match m.nav.dive_stack with
                | _ :: rest ->
                    let next =
                      { m with nav = { m.nav with dive_stack = rest } }
                      |> Update_nav.sync_config_for_keeper_view
                    in
                    (next, View_fetches.fetches_for_current_view next)
                | [] ->
                    if not (String.equal (Update_nav.current_filter_query m) "")
                    then (Update_nav.set_active_filter_query "" m, [])
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
          | Some (Nav.Dive_infra _ | Nav.Dive_work _) ->
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
      | Some (Nav.Settings _) ->
          (* P1-11: NEVER trigger Save on bare [n] in Settings — Save is
             strictly Ctrl+S. On Keepers tab or Target_keeper_create, [n]
             starts typing the new keeper name; elsewhere it reminds the
             operator to use Ctrl+S. *)
          if
            Config_store.equal_config_target m.config.target
              Wire_config.Target_keeper_create
            || Nav.equal_settings_tab m.config.active_tab
                 Nav.Settings_keepers_companies
          then
            let config =
              m.config
              |> Config_store.set_target Wire_config.Target_keeper_create
              |> Config_store.set_tab Nav.Settings_keepers_companies
              |> Config_store.begin_edit_new_keeper_name
            in
            let nav =
              {
                m.nav with
                overlay = Some (Nav.Settings Nav.Settings_keepers_companies);
              }
            in
            let next =
              { m with nav; config }
              |> Model.with_toast ~now ~level:Model.Toast_info
                   (Say.make ~ko:"새 키퍼 이름을 입력하고 Enter 를 누르세요"
                      ~en:"Type new keeper name and press Enter")
            in
            let view_cmds = View_fetches.fetches_for_current_view next in
            let create_schema_path =
              Wire_config.config_schema_path Wire_config.Target_keeper_create
            in
            let has_create_schema =
              List.exists
                (function
                  | Cmd.Http_get { req; _ } ->
                      String.equal (Cmd.get_request_path req) create_schema_path
                  | Cmd.Batch _
                  | Cmd.Http_post _
                  | Cmd.Http_put _
                  | Cmd.Http_post_stream _
                  | Cmd.Sync_streams _
                  | Cmd.Update_workspace_guard _
                  | Cmd.Voice_cmd _
                  | Cmd.Copy_clipboard _
                  | Cmd.Open_external_url _
                  | Cmd.Open_editor_escape_hatch _
                  | Cmd.Start_local_server
                  | Cmd.Restart_tui
                  | Cmd.Quit _ ->
                      false)
                (Cmd.flatten view_cmds)
            in
            let cmds =
              if has_create_schema then view_cmds
              else
                Cmd.Http_get
                  {
                    epoch = next.epoch;
                    req = Cmd.Get_config_schema Wire_config.Target_keeper_create;
                  }
                :: view_cmds
            in
            (next, cmds)
          else
            ( Model.with_toast ~now ~level:Model.Toast_info
                (Say.make ~ko:"설정 저장은 Ctrl+S 를 사용하세요"
                   ~en:"Use Ctrl+S to save config changes")
                m
            , [] )
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
          | Nav.Work -> (
              match m.work.active_tab with
              | Nav.Work_pipeline ->
                  let modal : Model.inline_modal_state =
                    {
                      kind = Nav.Board_new_post;
                      fields =
                        [
                          {
                            key = "proposal_title";
                            label =
                              Say.make ~ko:"#goals 제안 제목"
                                ~en:"Proposal title (#goals)";
                            value = "";
                            required = true;
                          };
                          {
                            key = "proposal_measure";
                            label =
                              Say.make ~ko:"성공 기준 (Measure)"
                                ~en:"Success measure";
                            value = "";
                            required = true;
                          };
                          {
                            key = "proposal_procedure";
                            label =
                              Say.make ~ko:"검증 절차 (Procedure)"
                                ~en:"Verification procedure";
                            value = "";
                            required = false;
                          };
                          {
                            key = "proposal_priority";
                            label =
                              Say.make ~ko:"우선순위 (1-5)" ~en:"Priority (1-5)";
                            value = "2";
                            required = false;
                          };
                        ];
                      active_field = 0;
                      submitting = false;
                      error = None;
                    }
                  in
                  let nav =
                    {
                      m.nav with
                      overlay = Some (Nav.Inline_action Nav.Board_new_post);
                      filter_focused = false;
                    }
                  in
                  let drafts = Drafts.set_focus false m.drafts in
                  ({ m with nav; drafts; inline_modal = Some modal }, [])
              | Nav.Work_tasks_schedules ->
                  Update_nav.open_inline_modal m Nav.Schedule_form
              | Nav.Work_inbox | Nav.Work_candle_scorecard ->
                  ( Model.with_toast ~now ~level:Model.Toast_info
                      (Say.make
                         ~ko:
                           "#goals 보드 제안은 Pipeline 탭, 스케줄 생성은 Tasks/Schedules 탭에서 [n]을 누르세요"
                         ~en:
                           "Press [n] on Pipeline to post a #goals proposal or \
                            Tasks/Schedules to add a schedule")
                      m
                  , [] ))
          | Nav.Runtime -> Update_nav.open_inline_modal m Nav.Connector_form
          | Nav.Infra -> Update_nav.open_inline_modal m Nav.Repo_add_form
          | Nav.Keepers ->
              let config =
                m.config
                |> Config_store.set_target Wire_config.Target_keeper_create
                |> Config_store.set_tab Nav.Settings_keepers_companies
                |> Config_store.begin_edit_new_keeper_name
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
          | Nav.Runtime, (Nav.Runtime_failover_lanes | Nav.Runtime_quotas_credits) ->
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
            , ( Nav.Runtime_efficiency_spend
              | Nav.Runtime_tools_connectors ) ) ->
              []
        in
        ( Model.with_toast ~now ~level:Model.Toast_info
            (Say.make ~ko:"현재 화면 새로고침 중" ~en:"Refreshing active view")
            next
        , view_cmds @ probe_cmd )
  | Keymap.Copy_selected -> (
      let text_opt =
        match m.nav.overlay with
        | Some (Nav.System_gate Nav.Media_viewer) ->
            Option.map
              (fun (a : Wire_knowledge.artifact_entry) -> a.sha256)
              (Knowledge_store.selected_artifact m.knowledge)
        | Some
            ( Nav.Palette
            | Nav.Settings _
            | Nav.Incidents
            | Nav.Queue_context _
            | Nav.Inline_action _
            | Nav.Help
            | Nav.System_gate
                (Nav.Micro_viewport | Nav.Auth_gate | Nav.Server_offline) )
        | None -> (
            match m.nav.workspace with
        | Nav.Knowledge -> (
            match m.knowledge.active_tab with
            | Nav.Knowledge_board ->
                Option.map
                  (fun (p : Wire_knowledge.board_post) -> p.body)
                  (Knowledge_store.selected_post m.knowledge)
            | Nav.Knowledge_wiki_artifacts -> (
                match m.knowledge.wiki_artifacts_submode with
                | `Wiki -> (
                    match Observed.to_option m.knowledge.wiki_page with
                    | Some detail
                      when not (String.equal (String.trim detail.body_markdown) "") ->
                        Some detail.body_markdown
                    | Some _ | None ->
                        Option.map
                          (fun (p : Wire_knowledge.wiki_page_summary) -> p.slug)
                          (Knowledge_store.selected_wiki_page m.knowledge))
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
        | Nav.Keepers | Nav.Pulse -> (
            let in_chat =
              Model.is_in_keeper_chat m
              || (Nav.equal_workspace m.nav.workspace Nav.Keepers
                  && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                       Nav.Keeper_chat)
            in
            match if in_chat then latest_keeper_reply_text m else None with
            | Some (_, reply) -> Some reply
            | None ->
                Option.map
                  (fun (k : Wire_fleet.keeper_summary) -> k.name)
                  (Fleet_store.selected_keeper_summary m.fleet))
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
                if not (Attention.is_empty m.attention) then
                  match Attention.current_triage_item m.attention with
                  | Some { payload = Attention.Payload_ask a; _ } ->
                      Some a.ask_id
                  | Some
                      {
                        payload =
                          ( Attention.Payload_tool_approval _
                          | Attention.Payload_gate _
                          | Attention.Payload_goal_confirmation _
                          | Attention.Payload_quarantine _ );
                        summary;
                        _;
                      } ->
                      Some summary
                  | None -> None
                else
                  Option.map
                    (fun (a : Wire_work.ask_row) -> a.ask_id)
                    (Work_store.selected_open_ask m.work))
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
              (Runtime_store.selected_lane m.runtime))
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
      | Some (Nav.System_gate Nav.Media_viewer) ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:"아티팩트 뷰어가 열려 있습니다 ([Esc] 닫기)"
                 ~en:"Artifact viewer is already open ([Esc] to close)")
              m
          , [] )
      | Some
          ( Nav.Palette
          | Nav.Incidents
          | Nav.Queue_context _
          | Nav.Inline_action _
          | Nav.Help
          | Nav.System_gate
              (Nav.Micro_viewport | Nav.Auth_gate | Nav.Server_offline) )
      | None -> (
          let open_url_or_notice url_opt =
            match url_opt with
            | Some url -> (m, [ Cmd.Open_external_url url ])
            | None ->
                ( Model.with_toast ~now ~level:Model.Toast_info
                    (Say.make ~ko:"열 수 있는 외부 URL 이 없습니다"
                       ~en:"No external http(s) URL on selected item")
                    m
                , [] )
          in
          let wiki_external_url () =
            match Observed.to_option m.knowledge.wiki_page with
            | None -> None
            | Some detail -> (
                match
                  List.find_map
                    (fun (lnk : Wire_knowledge.wiki_outgoing_link) ->
                      extract_first_http_url lnk.target)
                    detail.outgoing_links
                with
                | Some u -> Some u
                | None -> extract_first_http_url detail.body_markdown)
          in
          match Model.active_dive m with
          | Some (Nav.Dive_knowledge (Nav.Artifact_dive _)) ->
              Update_nav.open_overlay m (Nav.System_gate Nav.Media_viewer)
          | Some (Nav.Dive_knowledge (Nav.Wiki_dive _)) ->
              open_url_or_notice (wiki_external_url ())
          | Some
              ( Nav.Dive_keeper _
              | Nav.Dive_work _
              | Nav.Dive_knowledge (Nav.Thread_dive _ | Nav.Memory_diff_dive _)
              | Nav.Dive_infra _ )
          | None -> (
              match m.nav.workspace with
              | Nav.Infra -> (
                  match Infra_store.selected_repository m.infra with
                  | Some repo -> (m, [ Cmd.Open_external_url repo.url ])
                  | None -> open_url_or_notice None)
              | Nav.Knowledge -> (
                  match m.knowledge.active_tab with
                  | Nav.Knowledge_wiki_artifacts -> (
                      match m.knowledge.wiki_artifacts_submode with
                      | `Artifacts -> (
                          match Knowledge_store.selected_artifact m.knowledge with
                          | Some _ ->
                              Update_nav.open_overlay m
                                (Nav.System_gate Nav.Media_viewer)
                          | None -> open_url_or_notice None)
                      | `Wiki -> open_url_or_notice (wiki_external_url ()))
                  | Nav.Knowledge_board ->
                      let url_opt =
                        Option.bind
                          (Knowledge_store.selected_post m.knowledge)
                          (fun (p : Wire_knowledge.board_post) ->
                            extract_first_http_url p.body)
                      in
                      open_url_or_notice url_opt
                  | Nav.Knowledge_memory -> open_url_or_notice None)
              | Nav.Work ->
                  let url_opt =
                    match Work_store.selected_goal m.work with
                    | Some g -> (
                        match extract_first_http_url g.procedure with
                        | Some u -> Some u
                        | None -> extract_first_http_url g.measure)
                    | None ->
                        Option.bind (Work_store.selected_task m.work)
                          (fun (t : Wire_work.task) ->
                            Option.bind t.description extract_first_http_url)
                  in
                  open_url_or_notice url_opt
              | Nav.Keepers ->
                  let url_opt =
                    Option.bind (latest_keeper_reply_text m) (fun (_, txt) ->
                        extract_first_http_url txt)
                  in
                  open_url_or_notice url_opt
              | Nav.Pulse | Nav.Runtime -> (m, []))))
  | Keymap.Toggle_zoom ->
      ({ m with nav = { m.nav with zoomed = not m.nav.zoomed } }, [])
  | Keymap.Quit_app -> (m, [ Cmd.Quit Exit_reason.Quit_key ])
