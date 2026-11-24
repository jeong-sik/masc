open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

let active_memory_reading (m : Model.t) :
    Knowledge_store.memory_reading_entry option =
  let scope_opt =
    match Model.active_dive m with
    | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_memory }) ->
        Some (Some name)
    | Some (Nav.Dive_knowledge (Nav.Memory_diff_dive { keeper; _ })) ->
        Some keeper
    | Some
        ( Nav.Dive_keeper
            {
              tab =
                ( Nav.Keeper_chat
                | Nav.Keeper_work_candle
                | Nav.Keeper_sandbox
                | Nav.Keeper_config );
              _;
            }
        | Nav.Dive_work _
        | Nav.Dive_knowledge
            (Nav.Thread_dive _ | Nav.Wiki_dive _ | Nav.Artifact_dive _)
        | Nav.Dive_infra _ ) ->
        None
    | None -> (
        match m.nav.workspace with
        | Nav.Knowledge
          when Nav.equal_knowledge_tab m.knowledge.active_tab
                 Nav.Knowledge_memory ->
            Some m.knowledge.memory_diff_keeper
        | Nav.Keepers
          when Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_memory -> (
            match Fleet_store.selected_keeper_summary m.fleet with
            | Some k -> Some (Some k.name)
            | None -> None)
        | Nav.Pulse
        | Nav.Work
        | Nav.Keepers
        | Nav.Knowledge
        | Nav.Runtime
        | Nav.Infra ->
            None)
  in
  match scope_opt, m.knowledge.memory_reading with
  | Some keeper_opt, Some entry
    when Knowledge_store.memory_reading_matches_scope ~keeper_opt entry ->
      Some entry
  | (Some _ | None), (Some _ | None) -> None

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
                      | Wire_fleet.Role_peer _
                      | Wire_fleet.Role_system
                      | Wire_fleet.Role_tool
                      | Wire_fleet.Role_request_failure ->
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
  let direct_keeper_assignment =
    match target_keeper, Observed.to_option m0.runtime.runtime_config_raw with
    | Some keeper, Some meta ->
        let previous_runtime_id = List.assoc_opt keeper meta.assignments in
        let next =
          Model.with_toast ~now ~level:Model.Toast_info
            (Say.make
               ~ko:(Printf.sprintf "%s 런타임 변경 요청: %s" keeper runtime_id)
               ~en:(Printf.sprintf "Assigning runtime for %s -> %s" keeper runtime_id))
            m0
        in
        Some
          ( next
          , [
              Cmd.Http_post
                {
                  epoch = next.epoch;
                  req =
                    Cmd.Post_runtime_assignment
                      {
                        keeper_name = keeper;
                        runtime_id = Some runtime_id;
                        source_revision = Some meta.source_revision;
                        previous_runtime_id;
                      };
                };
            ] )
    | Some _, None | None, (Some _ | None) -> None
  in
  let staged_keeper_dry_run =
    match direct_keeper_assignment with
    | Some _ as direct -> direct
    | None -> (
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
    | Some _, (Some _ | None) | None, (Some _ | None) -> None)
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
    Option.is_none m.nav.overlay
    && m.nav.dive_stack = []
    && Nav.equal_workspace m.nav.workspace Nav.Work
    && Nav.equal_work_tab m.work.active_tab Nav.Work_inbox
  in
  if on_work_inbox && not (Attention.is_empty m.attention) then
    match
      Attention.current_filtered_item ~query:m.work.filter_query m.attention
    with
    | Some { payload = Attention.Payload_ask ask; id; _ }
      when not (Attention.is_in_flight ~id m.attention) ->
        Some ask
    | Some
        {
          payload =
            ( Attention.Payload_ask _
            | Attention.Payload_tool_approval _
            | Attention.Payload_gate _
            | Attention.Payload_goal_confirmation _ );
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
            | Attention.Payload_goal_confirmation _ );
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
                  | Attention.Payload_goal_confirmation _ ->
                      None)
              m.attention.items)

let schema_has_field_key (config : Config_store.t) key =
  match Observed.to_option config.schema with
  | None -> false
  | Some s ->
      List.exists
        (fun (sec : Wire_config.schema_section) ->
          List.exists
            (fun (f : Wire_config.schema_field) -> String.equal f.full_key key)
            sec.fields)
        s.sections

let schema_field_by_key (config : Config_store.t) key =
  match Observed.to_option config.schema with
  | None -> None
  | Some s ->
      List.find_map
        (fun (sec : Wire_config.schema_section) ->
          List.find_opt
            (fun (f : Wire_config.schema_field) -> String.equal f.full_key key)
            sec.fields)
        s.sections

let op_of_schema_field_original (f : Wire_config.schema_field) =
  match f.value with
  | Wire_config.Val_string value ->
      Some (Wire_config.Set_scalar { table = f.table; key = f.key; value })
  | Wire_config.Val_bool value ->
      Some (Wire_config.Set_bool { table = f.table; key = f.key; value })
  | Wire_config.Val_int _
  | Wire_config.Val_float _
  | Wire_config.Val_string_list _
  | Wire_config.Val_structured _
  | Wire_config.Val_secret _
  | Wire_config.Val_null ->
      None

let apply_staged_tui_pref_if_needed ~now ~key (m : Model.t)
    (config : Config_store.t) : (Model.t * Cmd.t list) option =
  if not (Config_store.is_tui_pref_key key) then None
  else
    let op_opt, was_staged =
      match Config_store.String_map.find_opt key config.dirty_fields with
      | Some op -> (Some op, true)
      | None -> (
          (* Stepping a tui.* field back to its original schema value calls
             unstage_patch, so synthesize the original value op to live-revert
             theme/language/preferences and persist via Post_tui_preference. *)
          match schema_field_by_key config key with
          | Some f -> (op_of_schema_field_original f, false)
          | None -> (None, false))
    in
    match op_opt with
    | None -> None
    | Some op ->
        let config1 =
          Config_store.apply_tui_pref_op ~observed_at:now ~full_key:key op config
        in
        let config2 =
          if (not was_staged) || schema_has_field_key config1 key then config1
          else Config_store.unstage_patch ~full_key:key config1
        in
        let m1 = { m with config = config2 } in
        let m2, cmds =
          match op with
          | Wire_config.Set_scalar { value; _ } when String.equal key "tui.theme"
            -> (
              match Theme.preset_of_name value with
              | Some preset ->
                  ( { m1 with theme_preset = preset }
                  , [
                      Cmd.Http_post
                        {
                          epoch = m.epoch;
                          req =
                            Cmd.Post_tui_preference
                              (Wire_config.Pref_theme
                                 (Some (Theme.preset_name preset)));
                        };
                    ] )
              | None -> (m1, []))
          | Wire_config.Set_scalar { value; _ }
            when String.equal key "tui.language" ->
              let lang =
                if String.equal (String.lowercase_ascii (String.trim value)) "en"
                then Say.Lang_en
                else Say.Lang_ko
              in
              ( { m1 with lang }
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_tui_preference (Wire_config.Pref_language lang);
                    };
                ] )
          | Wire_config.Set_scalar _
          | Wire_config.Set_bool _
          | Wire_config.Set_int _
          | Wire_config.Set_float _
          | Wire_config.Set_string_array _
          | Wire_config.Remove_key _ ->
              (m1, [])
        in
        Some
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:"TUI 환경설정이 적용되었습니다"
                 ~en:"TUI preference updated")
              m2
          , cmds )

let save_settings_config ~now (m : Model.t) =
  match Config_store.build_patch_request ~dry_run:false m.config with
  | Ok req ->
      let config = Config_store.mark_save_in_flight m.config in
      ( { m with config }
      , [ Cmd.Http_post { epoch = m.epoch; req = Cmd.Post_config_patch req } ] )
  | Error reason ->
      ( Model.with_toast ~now ~level:Model.Toast_warning (Say.literal reason) m
      , [] )

let step_settings_pane_lr ~now (m : Model.t) (dir : Keymap.move_dir) =
  let two_pane = Config_store.is_two_pane_width ~cols:m.viewport.cols in
  let cfg0 =
    if not two_pane then
      Config_store.set_pane Config_store.Pane_inspector m.config
    else m.config
  in
  match cfg0.settings_pane with
  | Config_store.Pane_tree ->
      let config =
        match dir with
        | Keymap.Left -> Config_store.collapse_or_leave cfg0
        | Keymap.Right -> Config_store.expand_or_enter cfg0
        | Keymap.Up
        | Keymap.Down
        | Keymap.Page_up
        | Keymap.Page_down
        | Keymap.Home
        | Keymap.End ->
            cfg0
      in
      let nav = { m.nav with overlay = Some (Nav.Settings config.active_tab) } in
      ({ m with nav; config }, [])
  | Config_store.Pane_inspector -> (
      let delta =
        match dir with
        | Keymap.Left -> -1
        | Keymap.Right -> 1
        | Keymap.Up
        | Keymap.Down
        | Keymap.Page_up
        | Keymap.Page_down
        | Keymap.Home
        | Keymap.End ->
            0
      in
      let sel_key_opt =
        Option.map
          (fun (f : Wire_config.schema_field) -> f.full_key)
          (Config_store.selected_field cfg0)
      in
      match Config_store.step_selected_field ~delta cfg0 with
      | Ok (config, true) -> (
          let config =
            if not two_pane then { config with settings_pane = m.config.settings_pane }
            else config
          in
          match
            Option.bind sel_key_opt (fun key ->
                apply_staged_tui_pref_if_needed ~now ~key m config)
          with
          | Some res -> res
          | None -> ({ m with config }, []))
      | Ok (_, false) ->
          if Keymap.equal_move_dir dir Keymap.Left && two_pane then
            let config = Config_store.collapse_or_leave cfg0 in
            let nav =
              { m.nav with overlay = Some (Nav.Settings config.active_tab) }
            in
            ({ m with nav; config }, [])
          else
            ( Model.with_toast ~now ~level:Model.Toast_info
                (Say.make ~ko:"[Enter] 키로 텍스트 값을 편집하세요"
                   ~en:"Press [Enter] to edit text value")
                m
            , [] )
      | Error reason ->
          if Keymap.equal_move_dir dir Keymap.Left && two_pane then
            let config = Config_store.collapse_or_leave cfg0 in
            let nav =
              { m.nav with overlay = Some (Nav.Settings config.active_tab) }
            in
            ({ m with nav; config }, [])
          else
            ( Model.with_toast ~now ~level:Model.Toast_info (Say.literal reason)
                m
            , [] ))

let focus_composer_for_slash (m : Model.t) =
  let cur = (Drafts.current_draft m.drafts).text in
  let drafts =
    if String.equal (String.trim cur) "" then
      m.drafts |> Drafts.set_focus true |> Drafts.set_current_text "/"
    else Drafts.set_focus true m.drafts
  in
  ({ m with nav = { m.nav with filter_focused = false }; drafts }, [])

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
      let draft_was_empty =
        String.equal (String.trim (Drafts.current_draft m.drafts).text) ""
      in
      let drafts = Drafts.clear_current_draft m.drafts in
      let fleet = Fleet_store.reset_chat_scroll m.fleet in
      let base = { m with drafts; fleet } in
      let (cleared, cmds), msg =
        if
          draft_was_empty
          && not (String.equal (Update_nav.current_filter_query base) "")
        then
          ( Update_nav.set_active_filter_query "" base
          , Say.make ~ko:"현재 초안 및 화면 필터가 초기화되었습니다"
              ~en:"Cleared draft and active filter" )
        else
          ( (base, [])
          , Say.make ~ko:"현재 초안이 비워졌습니다" ~en:"Cleared current draft" )
      in
      (Model.with_toast ~now ~level:Model.Toast_info msg cleared, cmds)
  | Slash.Theme opt ->
      let preset =
        match opt with Some p -> p | None -> next_theme_preset m.theme_preset
      in
      let config =
        Config_store.apply_tui_pref_op ~observed_at:now ~full_key:"tui.theme"
          (Wire_config.Set_scalar
             { table = "tui"; key = "theme"; value = Theme.preset_name preset })
          m.config
      in
      let next =
        { m with theme_preset = preset; config }
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
      let lang_s = match lang with Say.Lang_ko -> "ko" | Say.Lang_en -> "en" in
      let config =
        Config_store.apply_tui_pref_op ~observed_at:now ~full_key:"tui.language"
          (Wire_config.Set_scalar
             { table = "tui"; key = "language"; value = lang_s })
          m.config
      in
      let next =
        { m with lang; config }
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

and submit_slash_text ~now (m : Model.t) trimmed =
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

and submit_composer ~now ~mode (m : Model.t) =
  let draft = Drafts.current_draft m.drafts in
  let trimmed = String.trim draft.text in
  match Update_nav.resolve_composer_popup m with
  | Update_nav.Composer_popup_slash { items; selected; _ } -> (
      match List.nth_opt items selected with
      | Some { kind = Update_nav.Popup_slash_cmd spec; _ } ->
          if Update_nav.slash_spec_requires_arg spec then
            ( {
                m with
                drafts = Drafts.set_current_text (spec.name ^ " ") m.drafts;
              }
            , [] )
          else submit_slash_text ~now m spec.name
      | Some { kind = Update_nav.Popup_slash_arg { full_text; _ }; _ } ->
          let target_text =
            if
              m.drafts.popup_selected = 0
              && List.exists
                   (fun (cand : Update_nav.popup_candidate) ->
                     String.equal
                       (String.lowercase_ascii cand.trigger)
                       (String.lowercase_ascii trimmed))
                   items
            then trimmed
            else full_text
          in
          submit_slash_text ~now m target_text
      | Some { kind = Update_nav.Popup_mention _; _ } | None -> (m, []))
  | Update_nav.Composer_popup_mention { items; selected; _ } -> (
      match List.nth_opt items selected with
      | Some cand -> (Update_nav.apply_popup_completion cand m, [])
      | None -> (m, []))
  | Update_nav.Composer_popup_none -> (
      if String.equal trimmed "" then (m, [])
      else if Char.equal trimmed.[0] '/' then submit_slash_text ~now m trimmed
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
              match
                Fleet_store.String_map.find_opt keeper m.fleet.chat_histories
              with
              | None -> []
              | Some obs -> (
                  match Observed.to_option obs with
                  | None -> []
                  | Some page ->
                      List.filter_map
                        (fun (msg : Wire_fleet.chat_message) ->
                          match msg.role with
                          | Wire_fleet.Role_user | Wire_fleet.Role_peer _ ->
                              Some msg.id
                          | Wire_fleet.Role_assistant
                          | Wire_fleet.Role_system
                          | Wire_fleet.Role_tool
                          | Wire_fleet.Role_request_failure ->
                              None)
                        page.messages)
            in
            let keeper_is_busy =
              Option.is_some (Fleet_store.active_turn_for ~keeper m.fleet)
              || Fleet_store.has_active_chat_stream ~keeper m.fleet
              || Drafts.has_active_tx_for ~keeper m.drafts
            in
            (* A busy Keeper queues the message. Of the ways to send, only a
               steer cuts a turn, and only the operation this TUI's own request
               is streaming. The interrupt key is a separate action. *)
            let effective_mode, wire_mode, steer_refusal =
              if not keeper_is_busy then
                (Drafts.Mode_direct, Wire_fleet.Follow_up, None)
              else
                match mode with
                | Drafts.Mode_steer -> (
                    match Update_nav.resolve_steer ~keeper m with
                    | Update_nav.Steer_own { control_token; operation_id } ->
                        ( Drafts.Mode_steer
                        , Wire_fleet.Steer { control_token; operation_id }
                        , None )
                    | Update_nav.Steer_refused refusal ->
                        (Drafts.Mode_follow_up, Wire_fleet.Follow_up, Some refusal))
                | Drafts.Mode_follow_up ->
                    (Drafts.Mode_follow_up, Wire_fleet.Follow_up, None)
                | Drafts.Mode_direct ->
                    (Drafts.Mode_direct, Wire_fleet.Follow_up, None)
            in
            let drafts0 = Drafts.set_active_keeper keeper m.drafts in
            match
              Drafts.enqueue_submission ~now ~keeper ~mode:effective_mode
                ~prior_user_msg_ids drafts0
            with
            | None -> (m, [])
            | Some (drafts1, tx) ->
                let drafts2 =
                  Drafts.mark_sending ~now ~request_id:tx.request_id drafts1
                in
                let fleet0 =
                  if Fleet_store.has_active_chat_stream ~keeper m.fleet then
                    m.fleet
                  else
                    Fleet_store.start_chat_stream ~keeper
                      ~request_id:tx.request_id m.fleet
                in
                let fleet = Fleet_store.reset_chat_scroll fleet0 in
                let cmd =
                  Update_nav.build_chat_submit_cmd m tx ~mode:wire_mode
                    ~is_btw:false
                in
                let sent = { m with drafts = drafts2; fleet } in
                let sent =
                  match steer_refusal with
                  | None -> sent
                  | Some Update_nav.Steer_turn_not_own ->
                      Model.with_toast ~now ~level:Model.Toast_warning
                        (Say.make
                           ~ko:"돌고 있는 턴이 내 요청이 아니라서 끊지 않고 대기열에 넣었습니다"
                           ~en:"The running turn is not yours: your message is queued, nothing was cut")
                        sent
                  | Some Update_nav.Steer_no_control_token ->
                      Model.with_toast ~now ~level:Model.Toast_warning
                        (Say.make
                           ~ko:"Steer 토큰을 아직 받지 못해서 끊지 않고 대기열에 넣었습니다"
                           ~en:"No steer token yet: your message is queued, nothing was cut")
                        sent
                in
                (sent, [ cmd ])))

and confirm_palette ~now (m : Model.t) =
  match m.palette.mode with
  | Model.Palette_commands -> (
      let items = Update_nav.palette_entries m in
      match
        List.nth_opt items
          (Update_nav.clamp_index (List.length items) m.palette.selected)
      with
      | None -> ({ m with nav = { m.nav with overlay = None } }, [])
      | Some entry -> (
          let m_closed = { m with nav = { m.nav with overlay = None } } in
          match entry.action with
          | Update_nav.Pal_keymap_action act -> execute_action ~now m_closed act
          | Update_nav.Pal_switch_workspace ws ->
              Update_nav.switch_workspace m_closed ws
          | Update_nav.Pal_dive_keeper name ->
              Update_nav.push_dive m_closed
                (Nav.Dive_keeper { name; tab = Nav.Keeper_chat })
          | Update_nav.Pal_select_company company ->
              let fleet = Fleet_store.set_filter company m_closed.fleet in
              Update_nav.switch_workspace { m_closed with fleet } Nav.Keepers
          | Update_nav.Pal_dive_goal id ->
              Update_nav.push_dive m_closed (Nav.Dive_work (Nav.Goal_dive id))
          | Update_nav.Pal_dive_task id ->
              Update_nav.push_dive m_closed (Nav.Dive_work (Nav.Task_dive id))
          | Update_nav.Pal_dive_thread id ->
              Update_nav.push_dive m_closed
                (Nav.Dive_knowledge (Nav.Thread_dive id))
          | Update_nav.Pal_dive_wiki slug ->
              Update_nav.push_dive m_closed
                (Nav.Dive_knowledge (Nav.Wiki_dive slug))
          | Update_nav.Pal_dive_sandbox keeper ->
              Update_nav.push_dive m_closed
                (Nav.Dive_infra (Nav.Sandbox_dive keeper))
          | Update_nav.Pal_open_infra_sandboxes pool ->
              let infra =
                m_closed.infra
                |> Infra_store.set_tab Nav.Infra_sandboxes
                |> Infra_store.set_filter pool
              in
              Update_nav.switch_workspace { m_closed with infra } Nav.Infra
          | Update_nav.Pal_open_setting { full_key; tab } ->
              let config =
                m_closed.config
                |> Config_store.set_target Wire_config.Target_runtime
                |> Config_store.set_tab tab
                |> Config_store.set_search_query full_key
              in
              Update_nav.open_overlay { m_closed with config }
                (Nav.Settings config.active_tab)
          | Update_nav.Pal_slash_spec spec ->
              if Slash.equal_command_id spec.id Slash.Cmd_btw then
                Update_nav.open_inline_modal m_closed Nav.Btw_query
              else
                match Slash.parse spec.name with
                | Ok parsed -> execute_slash ~now m_closed parsed
                | Error _ -> (m_closed, [])))
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
          if not (Config_store.is_two_pane_width ~cols:m.viewport.cols) then
            (m, [])
          else if Config_store.is_editing_field m.config then
            let editing_key_opt = m.config.editing_field_key in
            match Config_store.commit_edit_field m.config with
            | Ok c -> (
                match
                  Option.bind editing_key_opt (fun key ->
                      apply_staged_tui_pref_if_needed ~now ~key m c)
                with
                | Some (m1, cmds) ->
                    ( { m1 with config = Config_store.toggle_pane m1.config }
                    , cmds )
                | None -> ({ m with config = Config_store.toggle_pane c }, []))
            | Error _ ->
                let cfg0 = Config_store.cancel_edit_field m.config in
                ({ m with config = Config_store.toggle_pane cfg0 }, [])
          else ({ m with config = Config_store.toggle_pane m.config }, [])
      | Some Nav.Palette ->
          let len = Update_nav.palette_len m in
          if len <= 0 then (m, [])
          else
            let delta = match dir with Keymap.Next -> 1 | Keymap.Prev -> -1 in
            let cur = Update_nav.clamp_index len m.palette.selected in
            let selected = (cur + delta + len) mod len in
            ({ m with palette = { m.palette with selected } }, [])
      | Some (Nav.Queue_context _) -> Update_nav.cycle_sub_tab m dir
      | Some (Nav.Inline_action _) -> (
          match m.inline_modal with
          | None -> (m, [])
          | Some modal ->
              let editable =
                (not modal.submitting)
                &&
                match modal.kind, m.drafts.btw with
                | Nav.Btw_query, Drafts.Btw_idle -> true
                | ( Nav.Btw_query
                  , ( Drafts.Btw_sending _
                    | Drafts.Btw_streaming _
                    | Drafts.Btw_answered _
                    | Drafts.Btw_failed _ ) ) ->
                    false
                | ( ( Nav.Gate_reject _
                    | Nav.Verification_reject _
                    | Nav.Task_cancel _
                    | Nav.Schedule_form
                    | Nav.Connector_form
                    | Nav.Repo_add_form
                    | Nav.Board_new_post )
                  , _ ) ->
                    true
              in
              if not editable then (m, [])
              else
                let delta =
                  match dir with Keymap.Next -> 1 | Keymap.Prev -> -1
                in
                ( {
                    m with
                    inline_modal = Some (Model.modal_cycle_field ~delta modal);
                  }
                , [] ))
      | Some (Nav.Help | Nav.Incidents | Nav.System_gate _) -> (m, [])
      | None ->
          let n = Model.focusable_pane_count m in
          if n <= 1 then (m, [])
          else
            let delta = match dir with Keymap.Next -> 1 | Keymap.Prev -> -1 in
            let next_pane = (m.nav.pane_index + delta + n) mod n in
            let work =
              if
                m.nav.dive_stack = []
                && Nav.equal_workspace m.nav.workspace Nav.Work
                && Nav.equal_work_tab m.work.active_tab
                     Nav.Work_tasks_schedules
              then Work_store.jump_tasks_schedules_pane ~pane_index:next_pane m.work
              else m.work
            in
            let next =
              Update_nav.clamp_for_pane
                { m with nav = { m.nav with pane_index = next_pane }; work }
            in
            (next, []))
  | Keymap.Focus_composer -> (
      if
        Model.is_too_small_viewport m.viewport
        || Model.equal_breakpoint m.breakpoint Model.Micro
      then (m, [])
      else
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
  | Keymap.Focus_filter -> (
      if
        Model.is_too_small_viewport m.viewport
        || Model.equal_breakpoint m.breakpoint Model.Micro
      then (m, [])
      else
        match m.nav.overlay with
        | Some (Nav.Settings _ | Nav.Incidents) ->
            ( {
                m with
                nav = { m.nav with filter_focused = true };
                drafts = Drafts.set_focus false m.drafts;
              }
            , [] )
        | Some
            ( Nav.Palette
            | Nav.Queue_context _
            | Nav.Inline_action _
            | Nav.Help
            | Nav.System_gate _ ) ->
            (m, [])
        | None -> (
            if Model.is_keeper_config_active m then
              ( {
                  m with
                  nav = { m.nav with filter_focused = true };
                  drafts = Drafts.set_focus false m.drafts;
                }
              , [] )
            else
              match Model.active_dive m with
              | Some
                  ( Nav.Dive_keeper _
                  | Nav.Dive_work _
                  | Nav.Dive_knowledge _
                  | Nav.Dive_infra _ ) ->
                  focus_composer_for_slash m
              | None -> (
                  match m.nav.workspace with
                  | Nav.Pulse -> focus_composer_for_slash m
                  | Nav.Work
                  | Nav.Knowledge
                  | Nav.Keepers
                  | Nav.Runtime
                  | Nav.Infra ->
                      ( {
                          m with
                          nav = { m.nav with filter_focused = true };
                          drafts = Drafts.set_focus false m.drafts;
                        }
                      , [] ))))
  | Keymap.Dive_selected -> Update_nav.dive_selected m
  | Keymap.Confirm_selected -> (
      if Option.is_none m.nav.overlay && Drafts.is_focused m.drafts then
        submit_composer ~now ~mode:Drafts.Mode_follow_up m
      else
        match m.nav.overlay with
        | Some Nav.Palette -> confirm_palette ~now m
        | Some (Nav.Inline_action _) -> Update_nav.submit_inline_modal ~now m
        | Some (Nav.Settings _) ->
            if Config_store.is_editing_field m.config then (
              let was_new_keeper =
                Config_store.is_editing_new_keeper_name m.config
              in
              let editing_key_opt = m.config.editing_field_key in
              match Config_store.commit_edit_field m.config with
              | Ok config -> (
                  match
                    Option.bind editing_key_opt (fun key ->
                        apply_staged_tui_pref_if_needed ~now ~key m config)
                  with
                  | Some res -> res
                  | None ->
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
                      ( Model.with_toast ~now ~level:Model.Toast_info msg
                          { m with config }
                      , [] ))
              | Error reason ->
                  ( Model.with_toast ~now ~level:Model.Toast_warning
                      (Say.literal reason) m
                  , [] ))
            else
              let cfg0 =
                if not (Config_store.is_two_pane_width ~cols:m.viewport.cols)
                then Config_store.set_pane Config_store.Pane_inspector m.config
                else m.config
              in
              (match cfg0.settings_pane with
              | Config_store.Pane_tree ->
                  let config = Config_store.toggle_tree_node cfg0 in
                  let nav =
                    { m.nav with overlay = Some (Nav.Settings config.active_tab) }
                  in
                  ({ m with nav; config }, [])
              | Config_store.Pane_inspector -> (
                  let sel_key_opt =
                    Option.map
                      (fun (f : Wire_config.schema_field) -> f.full_key)
                      (Config_store.selected_field cfg0)
                  in
                  match Config_store.begin_edit_selected cfg0 with
                  | Ok config -> (
                      match
                        Option.bind sel_key_opt (fun key ->
                            apply_staged_tui_pref_if_needed ~now ~key m config)
                      with
                      | Some res -> res
                      | None -> ({ m with config }, []))
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
          if not (String.equal m.config.search_query "") then
            ( {
                m with
                nav = { m.nav with filter_focused = false };
                config = Config_store.set_search_query "" m.config;
              }
            , [] )
          else
          let close_overlay_and_resync (base_m : Model.t) =
            let closed =
              {
                base_m with
                nav = { base_m.nav with overlay = None; filter_focused = false };
                config = Config_store.cancel_edit_field base_m.config;
                inline_modal = None;
              }
              |> Update_nav.sync_config_for_keeper_view
            in
            let target_changed =
              not
                (Config_store.equal_config_target base_m.config.target
                   closed.config.target)
            in
            let cmds =
              if target_changed then View_fetches.fetches_for_current_view closed
              else []
            in
            (closed, cmds)
          in
          close_overlay_and_resync m
      | Some Nav.Incidents ->
          if not (String.equal m.incidents.filter_query "") then
            ( {
                m with
                nav = { m.nav with filter_focused = false };
                incidents = Incidents.set_filter "" m.incidents;
              }
            , [] )
          else
            let closed =
              {
                m with
                nav = { m.nav with overlay = None; filter_focused = false };
                config = Config_store.cancel_edit_field m.config;
                inline_modal = None;
              }
              |> Update_nav.sync_config_for_keeper_view
            in
            let cmds =
              if
                not
                  (Config_store.equal_config_target m.config.target
                     closed.config.target)
              then View_fetches.fetches_for_current_view closed
              else []
            in
            (closed, cmds)
      | Some (Nav.Inline_action kind) ->
          let drafts =
            match kind with
            | Nav.Btw_query -> Drafts.clear_btw m.drafts
            | Nav.Gate_reject _
            | Nav.Verification_reject _
            | Nav.Task_cancel _
            | Nav.Schedule_form
            | Nav.Connector_form
            | Nav.Repo_add_form
            | Nav.Board_new_post ->
                m.drafts
          in
          let closed =
            {
              m with
              nav = { m.nav with overlay = None; filter_focused = false };
              config = Config_store.cancel_edit_field m.config;
              drafts;
              inline_modal = None;
            }
            |> Update_nav.sync_config_for_keeper_view
          in
          let cmds =
            if
              not
                (Config_store.equal_config_target m.config.target
                   closed.config.target)
            then View_fetches.fetches_for_current_view closed
            else []
          in
          (closed, cmds)
      | Some
          ( Nav.Palette
          | Nav.Queue_context _
          | Nav.Help
          | Nav.System_gate Nav.Media_viewer ) ->
          let closed =
            {
              m with
              nav = { m.nav with overlay = None; filter_focused = false };
              config = Config_store.cancel_edit_field m.config;
              inline_modal = None;
            }
            |> Update_nav.sync_config_for_keeper_view
          in
          let cmds =
            if
              not
                (Config_store.equal_config_target m.config.target
                   closed.config.target)
            then View_fetches.fetches_for_current_view closed
            else []
          in
          (closed, cmds)
      | None ->
          if m.nav.filter_focused then
            let cleared, cmds = Update_nav.set_active_filter_query "" m in
            ( { cleared with nav = { cleared.nav with filter_focused = false } },
              cmds )
          else if Drafts.is_focused m.drafts then
            match Update_nav.resolve_composer_popup m with
            | Update_nav.Composer_popup_slash _
              when String.equal (String.trim (Drafts.current_draft m.drafts).text) "/" ->
                (* Single Esc escapes a bare '/' slash-command peek cleanly:
                   clears the lone '/' and returns focus to workspace nav. *)
                let drafts =
                  m.drafts |> Drafts.clear_current_draft |> Drafts.set_focus false
                in
                ({ m with drafts }, [])
            | Update_nav.Composer_popup_slash _
            | Update_nav.Composer_popup_mention _ ->
                ({ m with drafts = Drafts.dismiss_popup m.drafts }, [])
            | Update_nav.Composer_popup_none ->
                ({ m with drafts = Drafts.set_focus false m.drafts }, [])
          else if Model.is_keeper_config_active m
                  && Config_store.is_editing_field m.config
          then ({ m with config = Config_store.cancel_edit_field m.config }, [])
          else
            let keeper_config_has_search =
              Model.is_keeper_config_active m
              && not (String.equal m.config.search_query "")
            in
            if keeper_config_has_search then
              ({ m with config = Config_store.set_search_query "" m.config }, [])
            else if Option.is_some (Memory_diagram.active_diagram m) then
              ( {
                  m with
                  knowledge = Knowledge_store.close_memory_diagram m.knowledge;
                }
              , [] )
            else if Option.is_some (active_memory_reading m) then
              ( {
                  m with
                  knowledge = Knowledge_store.close_memory_reading m.knowledge;
                }
              , [] )
            else
              let active_chat_interrupt =
                match Model.active_dive m with
                | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_chat }) ->
                    let phase = Chat_transcript.live_chat_phase ~model:m ~keeper:name in
                    if not (Chat_transcript.is_phase_interruptible phase) then None
                    else
                      let active_stream_opt =
                        match
                          Fleet_store.String_map.find_opt name m.fleet.chat_streams
                        with
                        | Some s when s.active && not s.interrupting -> Some s
                        | Some _ | None -> None
                      in
                      let interruptible_tx_opt =
                        match Drafts.active_tx_for_keeper ~keeper:name m.drafts with
                        | Some ({ state = Drafts.Sending | Drafts.Pending_processing; _ } as tx) ->
                            Some tx
                        | Some
                            {
                              state =
                                ( Drafts.Queued
                                | Drafts.Confirming_delivery
                                | Drafts.Interrupting
                                | Drafts.Delivered
                                | Drafts.Failed_retryable _ );
                              _;
                            }
                        | None ->
                            None
                      in
                      let mark_ui_interrupting stream_opt tx_opt =
                        let fleet =
                          match stream_opt with
                          | Some (s : Fleet_store.chat_stream_buffer) ->
                              Fleet_store.mark_chat_stream_interrupting
                                ~keeper:name ~request_id:s.request_id
                                ~interrupting:true m.fleet
                          | None -> m.fleet
                        in
                        let drafts =
                          match tx_opt with
                          | Some (tx : Drafts.pending_message) ->
                              Drafts.mark_interrupting ~now
                                ~request_id:tx.request_id m.drafts
                          | None -> m.drafts
                        in
                        (fleet, drafts)
                      in
                      (match
                         Fleet_store.active_turn_for ~keeper:name m.fleet
                       , active_stream_opt
                       , interruptible_tx_opt
                       with
                      | Some turn, stream_opt, tx_opt ->
                          let fleet, drafts =
                            mark_ui_interrupting stream_opt tx_opt
                          in
                          Some
                            ( name
                            , `Turn_token turn.interrupt_token
                            , fleet
                            , drafts )
                      | None, Some s, tx_opt ->
                          let op_id =
                            Option.value s.operation_id ~default:s.request_id
                          in
                          let fleet, drafts =
                            mark_ui_interrupting (Some s) tx_opt
                          in
                          Some (name, `Operation_id op_id, fleet, drafts)
                      | None, None, Some tx ->
                          let op_id =
                            Option.value tx.operation_id ~default:tx.request_id
                          in
                          let fleet, drafts =
                            mark_ui_interrupting None (Some tx)
                          in
                          Some (name, `Operation_id op_id, fleet, drafts)
                      | None, None, None -> None)
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
              | Some (keeper, target, fleet, drafts) ->
                  ( Model.with_toast ~now ~level:Model.Toast_warning
                      (Say.make
                         ~ko:("키퍼 턴 중단 요청 전송: " ^ keeper)
                         ~en:("Interrupt requested for keeper turn: " ^ keeper))
                      { m with fleet; drafts }
                  , [
                      Cmd.Http_post
                        {
                          epoch = m.epoch;
                          req =
                            Cmd.Post_keeper_turn_interrupt { keeper; target };
                        };
                    ] )
              | None -> (
                  match m.nav.dive_stack with
                  | _ :: rest ->
                      let next =
                        {
                          m with
                          nav =
                            {
                              m.nav with
                              dive_stack = rest;
                              pane_index = 0;
                              zoomed = false;
                              dive_scroll_offset = 0;
                            };
                          knowledge =
                            Knowledge_store.close_memory_diagram m.knowledge;
                        }
                        |> Update_nav.sync_config_for_keeper_view
                      in
                      (next, View_fetches.fetches_for_current_view next)
                  | [] ->
                      (* A zoomed panel advertises [Esc] as the way back to the
                         list, so Esc restores the split layout before it
                         touches the filter. *)
                      if m.nav.zoomed then
                        ({ m with nav = { m.nav with zoomed = false } }, [])
                      else if
                        Nav.equal_workspace m.nav.workspace Nav.Keepers
                        && m.nav.pane_index = 1
                        && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                             Nav.Keeper_config
                      then
                        ({ m with nav = { m.nav with pane_index = 0 } }, [])
                      else if
                        not (String.equal (Update_nav.current_filter_query m) "")
                      then Update_nav.set_active_filter_query "" m
                      else if
                        Nav.equal_workspace m.nav.workspace Nav.Work
                        && Nav.equal_work_tab m.work.active_tab
                             Nav.Work_tasks_schedules
                        && not
                             (Work_store.equal_task_status_filter
                                m.work.task_status_filter Work_store.Status_all)
                      then
                        (* The status chip narrows the list like the filter
                           does, so the last Esc returns it to All. *)
                        ( {
                            m with
                            nav = { m.nav with pane_index = 0 };
                            work =
                              Work_store.set_task_status_filter
                                Work_store.Status_all m.work;
                          }
                        , [] )
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
      let in_memory_surface =
        (not (Drafts.is_focused m.drafts))
        && (Option.is_some (Memory_diagram.active_memory_content_rect m)
           || (Option.is_none m.nav.overlay
              && Option.is_none (Model.active_dive m)
              && Nav.equal_workspace m.nav.workspace Nav.Knowledge
              && Nav.equal_knowledge_tab m.knowledge.active_tab
                   Nav.Knowledge_memory))
      in
      if in_memory_surface then
        Update_nav.open_memory_diagram ~now
          ~kind:Knowledge_store.Diagram_formation_tree m
      else ({ m with fleet = Fleet_store.cycle_tools_mode m.fleet }, [])
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
  | Keymap.Move dir -> (
      match m.nav.overlay, dir with
      | Some (Nav.Settings _), (Keymap.Left | Keymap.Right) ->
          step_settings_pane_lr ~now m dir
      | ( Some (Nav.Settings _)
        , ( Keymap.Up
          | Keymap.Down
          | Keymap.Page_up
          | Keymap.Page_down
          | Keymap.Home
          | Keymap.End ) )
      | ( ( Some
              ( Nav.Palette
              | Nav.Incidents
              | Nav.Queue_context _
              | Nav.Inline_action _
              | Nav.Help
              | Nav.System_gate _ )
          | None )
        , ( Keymap.Up
          | Keymap.Down
          | Keymap.Left
          | Keymap.Right
          | Keymap.Page_up
          | Keymap.Page_down
          | Keymap.Home
          | Keymap.End ) ) ->
          Update_nav.apply_move m dir)
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
          | Some (Nav.Dive_keeper { tab = Nav.Keeper_memory; _ }) ->
              let knowledge =
                Knowledge_store.cycle_memory_diff_window m.knowledge
              in
              let next = { m with knowledge } in
              (next, View_fetches.fetches_for_current_view next)
          | Some (Nav.Dive_infra _ | Nav.Dive_work _) ->
              ({ m with infra = Infra_store.toggle_raw_json m.infra }, [])
          | Some
              ( Nav.Dive_keeper
                  {
                    tab =
                      ( Nav.Keeper_work_candle
                      | Nav.Keeper_sandbox
                      | Nav.Keeper_config );
                    _;
                  }
              | Nav.Dive_knowledge _ ) ->
              (m, [])
          | None -> (
              match m.nav.workspace with
              | Nav.Keepers ->
                  if
                    (m.nav.pane_index = 1 || m.nav.zoomed)
                    && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                         Nav.Keeper_chat
                  then
                    ( { m with fleet = Fleet_store.toggle_turn_details m.fleet }
                    , [] )
                  else if
                    (m.nav.pane_index = 1 || m.nav.zoomed)
                    && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                         Nav.Keeper_memory
                  then
                    let knowledge =
                      Knowledge_store.cycle_memory_diff_window m.knowledge
                    in
                    let next = { m with knowledge } in
                    (next, View_fetches.fetches_for_current_view next)
                  else if m.nav.pane_index = 0 then
                    match Fleet_store.selected_keeper_summary m.fleet with
                    | Some k ->
                        ( {
                            m with
                            fleet =
                              Fleet_store.toggle_company_collapsed k.company
                                m.fleet;
                          }
                        , [] )
                    | None -> (m, [])
                  else (m, [])
              | Nav.Knowledge -> (
                  match m.knowledge.active_tab with
                  | Nav.Knowledge_board -> (
                      match Knowledge_store.board_space_effect m.knowledge with
                      | Knowledge_store.Board_space_toggle_chain root_id ->
                          ( {
                              m with
                              knowledge =
                                Knowledge_store.toggle_succession_chain ~root_id
                                  m.knowledge;
                            }
                          , [] )
                      | Knowledge_store.Board_space_toggle_signal_only ->
                          let knowledge =
                            Knowledge_store.toggle_signal_only m.knowledge
                          in
                          let next = { m with knowledge } in
                          (next, View_fetches.fetches_for_current_view next))
                  | Nav.Knowledge_wiki_artifacts ->
                      ( {
                          m with
                          nav = { m.nav with zoomed = false };
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
              | Nav.Runtime -> (
                  match m.runtime.active_tab with
                  | Nav.Runtime_failover_lanes ->
                      ( {
                          m with
                          runtime =
                            Runtime_store.toggle_outside_lane_probes m.runtime;
                        }
                      , [] )
                  | Nav.Runtime_quotas_credits
                  | Nav.Runtime_efficiency_spend
                  | Nav.Runtime_tools_connectors ->
                      (m, []))
              | Nav.Work -> (
                  match m.work.active_tab with
                  | Nav.Work_pipeline ->
                      let work = Work_store.toggle_verification_view m.work in
                      let next = { m with work } in
                      (next, View_fetches.fetches_for_current_view next)
                  | Nav.Work_tasks_schedules ->
                      let next =
                        {
                          m with
                          work = Work_store.cycle_task_status_filter m.work;
                        }
                      in
                      let max_pane =
                        Int.max 0 (Model.focusable_pane_count next - 1)
                      in
                      ( {
                          next with
                          nav =
                            {
                              next.nav with
                              pane_index = Int.min next.nav.pane_index max_pane;
                            };
                        }
                      , [] )
                  | Nav.Work_inbox | Nav.Work_candle_scorecard -> (m, []))
              | Nav.Infra -> (
                  match m.infra.active_tab with
                  | Nav.Infra_activity_logs ->
                      ( {
                          m with
                          infra = Infra_store.cycle_log_level_filter m.infra;
                        }
                      , [] )
                  | Nav.Infra_sandboxes | Nav.Infra_repos_changes -> (m, []))
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
                  | Cmd.Render_memory_diagram _
                  | Cmd.Cancel_memory_diagram
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
          match Model.active_dive m with
          | Some _ -> (m, [])
          | None -> (
              match m.nav.workspace with
              | Nav.Knowledge -> (
                  match m.knowledge.active_tab with
                  | Nav.Knowledge_board ->
                      Update_nav.open_inline_modal m Nav.Board_new_post
                  | Nav.Knowledge_wiki_artifacts | Nav.Knowledge_memory ->
                      (m, []))
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
                                secret = false;
                              };
                              {
                                key = "proposal_measure";
                                label =
                                  Say.make ~ko:"성공 기준 (Measure)"
                                    ~en:"Success measure";
                                value = "";
                                required = true;
                                secret = false;
                              };
                              {
                                key = "proposal_procedure";
                                label =
                                  Say.make ~ko:"검증 절차 (Procedure)"
                                    ~en:"Verification procedure";
                                value = "";
                                required = false;
                                secret = false;
                              };
                              {
                                key = "proposal_priority";
                                label =
                                  Say.make ~ko:"우선순위 (1-5)"
                                    ~en:"Priority (1-5)";
                                value = "2";
                                required = false;
                                secret = false;
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
                               "Press [n] on Pipeline to post a #goals proposal \
                                or Tasks/Schedules to add a schedule")
                          m
                      , [] ))
              | Nav.Runtime -> (
                  match m.runtime.active_tab with
                  | Nav.Runtime_tools_connectors ->
                      Update_nav.open_inline_modal m Nav.Connector_form
                  | Nav.Runtime_quotas_credits
                  | Nav.Runtime_efficiency_spend
                  | Nav.Runtime_failover_lanes ->
                      (m, []))
              | Nav.Infra -> (
                  match m.infra.active_tab with
                  | Nav.Infra_repos_changes ->
                      Update_nav.open_inline_modal m Nav.Repo_add_form
                  | Nav.Infra_sandboxes | Nav.Infra_activity_logs -> (m, []))
              | Nav.Keepers ->
                  let config =
                    m.config
                    |> Config_store.set_target Wire_config.Target_keeper_create
                    |> Config_store.set_tab Nav.Settings_keepers_companies
                    |> Config_store.begin_edit_new_keeper_name
                  in
                  Update_nav.open_overlay { m with config }
                    (Nav.Settings Nav.Settings_keepers_companies)
              | Nav.Pulse -> Update_nav.open_inline_modal m Nav.Board_new_post)))
  | Keymap.Refresh ->
      let needs_handshake =
        m.freshness.server_offline
        || Option.equal Nav.equal_overlay m.nav.overlay
             (Some (Nav.System_gate Nav.Auth_gate))
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
        let next, diagram_cmds =
          if Option.is_some (Memory_diagram.active_diagram next) then
            Update_nav.refresh_open_memory_diagram ~now next
          else (next, [])
        in
        ( Model.with_toast ~now ~level:Model.Toast_info
            (Say.make ~ko:"현재 화면 새로고침 중" ~en:"Refreshing active view")
            next
        , view_cmds @ probe_cmd @ diagram_cmds )
  | Keymap.Copy_selected -> (
      let text_opt =
        match m.nav.overlay with
        | Some (Nav.System_gate Nav.Media_viewer) ->
            Option.map
              (fun (a : Wire_knowledge.artifact_entry) -> a.body.sha256)
              (Knowledge_store.selected_artifact m.knowledge)
        | Some
            ( Nav.Palette
            | Nav.Settings _
            | Nav.Incidents
            | Nav.Queue_context _
            | Nav.Inline_action _
            | Nav.Help
            | Nav.System_gate
                (Nav.Micro_viewport | Nav.Auth_gate | Nav.Server_offline) ) ->
            None
        | None -> (
            let diagram_copy_opt =
              match Memory_diagram.active_diagram m with
              | Some d when not (String.equal (String.trim d.copy_source) "") ->
                  Some d.copy_source
              | Some _ | None -> None
            in
            let reading_copy_opt =
              match diagram_copy_opt with
              | Some _ as txt -> txt
              | None -> (
                  match active_memory_reading m with
              | None -> None
              | Some (Knowledge_store.Reading_activity { event; _ }) ->
                  let claims =
                    List.filter_map
                      (fun (f : Wire_knowledge.memory_activity_fact) -> f.claim)
                      (event.after @ event.before)
                  in
                  let parts =
                    claims
                    @
                    match event.reason with
                    | Some r when not (String.equal (String.trim r) "") -> [ r ]
                    | Some _ | None -> []
                  in
                  if parts <> [] then Some (String.concat "\n" parts)
                  else Some event.identity
              | Some (Knowledge_store.Reading_ordinary_fact { fact; _ }) ->
                  Some fact.claim
              | Some (Knowledge_store.Reading_source_fact { fact; _ }) ->
                  Some (fact.path ^ "\n" ^ fact.claim)
              | Some
                  (Knowledge_store.Reading_source_invalidation
                     { invalidation; _ }) ->
                  Some invalidation.source_path
              | Some (Knowledge_store.Reading_diff_item { item; _ }) -> (
                  match item with
                  | Knowledge_store.Keeper_added f -> Some f.text
                  | Knowledge_store.Keeper_updated u ->
                      Some ("- " ^ u.before.text ^ "\n+ " ^ u.after.text)
                  | Knowledge_store.Keeper_retracted r -> Some r.text
                  | Knowledge_store.Keeper_invalidated inv -> Some inv.text
                  | Knowledge_store.World_added e
                  | Knowledge_store.World_retracted e ->
                      Some e.summary
                  | Knowledge_store.World_updated u -> Some u.summary))
            in
            match reading_copy_opt with
            | Some txt -> Some txt
            | None -> (
            match Model.active_dive m with
            | Some (Nav.Dive_keeper { name; tab }) -> (
                match tab with
                | Nav.Keeper_chat -> (
                    match latest_keeper_reply_text m with
                    | Some (_, reply) -> Some reply
                    | None -> Some name)
                | Nav.Keeper_memory
                | Nav.Keeper_work_candle
                | Nav.Keeper_sandbox
                | Nav.Keeper_config ->
                    Some name)
            | Some (Nav.Dive_work wd) -> (
                match wd with
                | Nav.Goal_dive id -> (
                    match
                      List.find_opt
                        (fun (g : Wire_work.goal) -> String.equal g.id id)
                        (Work_store.goals m.work)
                    with
                    | Some g -> Some g.title
                    | None -> Some id)
                | Nav.Task_dive id -> (
                    match
                      List.find_opt
                        (fun (tk : Wire_work.task) -> String.equal tk.id id)
                        (Work_store.tasks m.work)
                    with
                    | Some tk -> Some tk.title
                    | None -> Some id)
                | Nav.Verification_dive id -> (
                    match
                      List.find_opt
                        (fun (v : Wire_work.verification_request) ->
                          String.equal v.request_id id)
                        (Work_store.verifications_list m.work)
                    with
                    | Some v -> Some v.task_title
                    | None -> Some id))
            | Some (Nav.Dive_knowledge kd) -> (
                match kd with
                | Nav.Thread_dive id -> (
                    match
                      List.find_opt
                        (fun (p : Wire_knowledge.board_post) ->
                          String.equal p.id id)
                        (Knowledge_store.filtered_posts m.knowledge)
                    with
                    | Some p -> Some p.body
                    | None -> Some id)
                | Nav.Wiki_dive slug -> (
                    match Observed.to_option m.knowledge.wiki_page with
                    | Some detail
                      when String.equal detail.slug slug
                           && not (String.equal (String.trim detail.body_markdown) "")
                      ->
                        Some detail.body_markdown
                    | Some _ | None -> Some slug)
                | Nav.Artifact_dive id -> (
                    match Knowledge_store.artifact_by_id m.knowledge id with
                    | Some a -> Some a.body.sha256
                    | None -> Some id)
                | Nav.Memory_diff_dive _ -> (
                    match Observed.to_option m.knowledge.world_memory with
                    | Some wm -> wm.briefing.text
                    | None -> None))
            | Some (Nav.Dive_infra idive) -> (
                match idive with
                | Nav.Sandbox_dive keeper -> Some keeper
                | Nav.Lane_dive lane_id -> Some lane_id
                | Nav.Incident_dive id -> Some (Int.to_string id))
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
                            match Knowledge_store.selected_wiki_page m.knowledge with
                            | None -> None
                            | Some sel -> (
                                match Observed.to_option m.knowledge.wiki_page with
                                | Some detail
                                  when String.equal detail.slug sel.slug
                                       && not
                                            (String.equal
                                               (String.trim detail.body_markdown)
                                               "") ->
                                    Some detail.body_markdown
                                | Some _ | None -> Some sel.slug))
                        | `Artifacts ->
                            Option.map
                              (fun (a : Wire_knowledge.artifact_entry) ->
                                a.body.sha256)
                              (Knowledge_store.selected_artifact m.knowledge))
                    | Nav.Knowledge_memory -> (
                        match Observed.to_option m.knowledge.world_memory with
                        | Some wm -> (
                            match wm.briefing.text with
                            | Some txt -> Some txt
                            | None -> (
                                match wm.claims with
                                | c :: _ -> Some c.claim
                                | [] -> None))
                        | None -> None))
                | Nav.Infra -> (
                    match m.infra.active_tab with
                    | Nav.Infra_sandboxes ->
                        Infra_store.selected_sandbox_keeper m.infra
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
                      Nav.equal_workspace m.nav.workspace Nav.Keepers
                      && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                           Nav.Keeper_chat
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
                        match m.nav.pane_index with
                        | 1 when Model.work_pipeline_has_linked_card m ->
                            Option.map
                              (fun (v : Wire_work.verification_request) ->
                                v.task_title)
                              (Work_store.selected_verification m.work)
                        | _ ->
                            Option.map
                              (fun (g : Wire_work.goal) -> g.title)
                              (Work_store.selected_goal m.work))
                    | Nav.Work_tasks_schedules -> (
                        match Work_store.selected_task m.work with
                        | Some task -> Some task.title
                        | None ->
                            Option.map
                              (fun (s : Wire_work.schedule_row) ->
                                s.schedule_id)
                              (Work_store.selected_schedule m.work))
                    | Nav.Work_inbox -> (
                        if
                          Attention.filtered_items ~query:m.work.filter_query
                            m.attention
                          <> []
                        then
                          match
                            Attention.current_filtered_item
                              ~query:m.work.filter_query m.attention
                          with
                          | Some { payload = Attention.Payload_ask a; _ } ->
                              Some a.ask_id
                          | Some
                              {
                                payload =
                                  ( Attention.Payload_tool_approval _
                                  | Attention.Payload_gate _
                                  | Attention.Payload_goal_confirmation _ );
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
                        let rows = Work_store.filtered_candle_balances m.work in
                        match List.nth_opt rows m.work.selected_index with
                        | Some row -> Some row.keeper
                        | None -> None))
                | Nav.Runtime ->
                    Option.map
                      (fun (l : Wire_runtime.failover_lane) -> l.id)
                      (Runtime_store.selected_lane m.runtime))))
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
              (Nav.Micro_viewport | Nav.Auth_gate | Nav.Server_offline) ) ->
          (m, [])
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
          let wiki_external_url ~expected_slug () =
            match Observed.to_option m.knowledge.wiki_page with
            | Some detail when String.equal detail.slug expected_slug -> (
                match
                  List.find_map
                    (fun (lnk : Wire_knowledge.wiki_outgoing_link) ->
                      match lnk.target with
                      | Wire_knowledge.Link_external url -> Some url
                      | Wire_knowledge.Link_page _
                      | Wire_knowledge.Link_own_file _
                      | Wire_knowledge.Link_invalid_name _
                      | Wire_knowledge.Link_unsupported _ ->
                          None)
                    detail.outgoing_links
                with
                | Some u -> Some u
                | None -> extract_first_http_url detail.body_markdown)
            | Some _ | None -> None
          in
          match Model.active_dive m with
          | Some (Nav.Dive_knowledge (Nav.Artifact_dive _)) ->
              Update_nav.open_overlay m (Nav.System_gate Nav.Media_viewer)
          | Some (Nav.Dive_knowledge (Nav.Wiki_dive slug)) ->
              open_url_or_notice (wiki_external_url ~expected_slug:slug ())
          | Some (Nav.Dive_knowledge (Nav.Thread_dive id)) ->
              let url_opt =
                Option.bind
                  (List.find_opt
                     (fun (p : Wire_knowledge.board_post) ->
                       String.equal p.id id)
                     (Knowledge_store.filtered_posts m.knowledge))
                  (fun (p : Wire_knowledge.board_post) ->
                    extract_first_http_url p.body)
              in
              open_url_or_notice url_opt
          | Some (Nav.Dive_knowledge (Nav.Memory_diff_dive _)) ->
              open_url_or_notice None
          | Some (Nav.Dive_keeper { tab = Nav.Keeper_chat; _ }) ->
              let url_opt =
                Option.bind (latest_keeper_reply_text m) (fun (_, txt) ->
                    extract_first_http_url txt)
              in
              open_url_or_notice url_opt
          | Some
              (Nav.Dive_keeper
                 {
                   tab =
                     ( Nav.Keeper_memory
                     | Nav.Keeper_work_candle
                     | Nav.Keeper_sandbox
                     | Nav.Keeper_config );
                   _;
                 }) ->
              (m, [])
          | Some (Nav.Dive_work (Nav.Goal_dive id)) ->
              let url_opt =
                Option.bind
                  (List.find_opt
                     (fun (g : Wire_work.goal) -> String.equal g.id id)
                     (Work_store.goals m.work))
                  (fun (g : Wire_work.goal) ->
                    match extract_first_http_url g.procedure with
                    | Some u -> Some u
                    | None -> extract_first_http_url g.measure)
              in
              open_url_or_notice url_opt
          | Some (Nav.Dive_work (Nav.Task_dive id)) ->
              let url_opt =
                Option.bind
                  (List.find_opt
                     (fun (tk : Wire_work.task) -> String.equal tk.id id)
                     (Work_store.tasks m.work))
                  (fun (tk : Wire_work.task) ->
                    Option.bind tk.description extract_first_http_url)
              in
              open_url_or_notice url_opt
          | Some (Nav.Dive_work (Nav.Verification_dive _)) -> (m, [])
          | Some
              (Nav.Dive_infra
                 (Nav.Sandbox_dive _ | Nav.Lane_dive _ | Nav.Incident_dive _))
            ->
              (m, [])
          | None -> (
              match m.nav.workspace with
              | Nav.Infra -> (
                  match m.infra.active_tab with
                  | Nav.Infra_repos_changes -> (
                      match Infra_store.selected_repository m.infra with
                      | Some repo -> (m, [ Cmd.Open_external_url repo.url ])
                      | None -> open_url_or_notice None)
                  | Nav.Infra_sandboxes | Nav.Infra_activity_logs -> (m, []))
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
                      | `Wiki -> (
                          match Knowledge_store.selected_wiki_page m.knowledge with
                          | Some sel ->
                              open_url_or_notice
                                (wiki_external_url ~expected_slug:sel.slug ())
                          | None -> open_url_or_notice None))
                  | Nav.Knowledge_board ->
                      let url_opt =
                        Option.bind
                          (Knowledge_store.selected_post m.knowledge)
                          (fun (p : Wire_knowledge.board_post) ->
                            extract_first_http_url p.body)
                      in
                      open_url_or_notice url_opt
                  | Nav.Knowledge_memory -> open_url_or_notice None)
              | Nav.Work -> (
                  match m.work.active_tab with
                  | Nav.Work_pipeline ->
                      let url_opt =
                        Option.bind (Work_store.selected_goal m.work)
                          (fun (g : Wire_work.goal) ->
                            match extract_first_http_url g.procedure with
                            | Some u -> Some u
                            | None -> extract_first_http_url g.measure)
                      in
                      open_url_or_notice url_opt
                  | Nav.Work_tasks_schedules ->
                      let url_opt =
                        Option.bind (Work_store.selected_task m.work)
                          (fun (t : Wire_work.task) ->
                            Option.bind t.description extract_first_http_url)
                      in
                      open_url_or_notice url_opt
                  | Nav.Work_inbox | Nav.Work_candle_scorecard -> (m, []))
              | Nav.Keepers ->
                  let url_opt =
                    Option.bind (latest_keeper_reply_text m) (fun (_, txt) ->
                        extract_first_http_url txt)
                  in
                  open_url_or_notice url_opt
              | Nav.Pulse | Nav.Runtime -> (m, []))))
  | Keymap.Toggle_zoom ->
      if not (Model.can_zoom_current_view m) then
        if m.nav.zoomed then ({ m with nav = { m.nav with zoomed = false } }, [])
        else (m, [])
      else
        let zoomed = not m.nav.zoomed in
        let pane_index = if zoomed then 0 else m.nav.pane_index in
        let next = { m with nav = { m.nav with zoomed; pane_index } } in
        if Option.is_some (Memory_diagram.active_diagram next) then
          Update_nav.refresh_open_memory_diagram ~now next
        else (next, [])
  | Keymap.Cycle_memory_view ->
      let in_memory =
        Option.is_none m.nav.overlay
        &&
        match Model.active_dive m with
        | Some (Nav.Dive_keeper { tab = Nav.Keeper_memory; _ }) -> true
        | Some
            ( Nav.Dive_keeper
                {
                  tab =
                    ( Nav.Keeper_chat
                    | Nav.Keeper_work_candle
                    | Nav.Keeper_sandbox
                    | Nav.Keeper_config );
                  _;
                }
            | Nav.Dive_work _
            | Nav.Dive_knowledge _
            | Nav.Dive_infra _ ) ->
            false
        | None -> (
            match m.nav.workspace with
            | Nav.Knowledge ->
                Nav.equal_knowledge_tab m.knowledge.active_tab
                  Nav.Knowledge_memory
            | Nav.Keepers ->
                Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_memory
            | Nav.Pulse | Nav.Work | Nav.Runtime | Nav.Infra -> false)
      in
      if not in_memory then (m, [])
      else
        let knowledge =
          Knowledge_store.cycle_memory_view_mode m.knowledge
        in
        let next =
          {
            m with
            nav = { m.nav with dive_scroll_offset = 0 };
            knowledge;
          }
        in
        (next, View_fetches.fetches_for_current_view next)
  | Keymap.Toggle_memory_sort ->
      let in_memory =
        Option.is_none m.nav.overlay
        &&
        match Model.active_dive m with
        | Some (Nav.Dive_keeper { tab = Nav.Keeper_memory; _ }) -> true
        | Some
            ( Nav.Dive_keeper
                {
                  tab =
                    ( Nav.Keeper_chat
                    | Nav.Keeper_work_candle
                    | Nav.Keeper_sandbox
                    | Nav.Keeper_config );
                  _;
                }
            | Nav.Dive_work _
            | Nav.Dive_knowledge _
            | Nav.Dive_infra _ ) ->
            false
        | None -> (
            match m.nav.workspace with
            | Nav.Knowledge ->
                Nav.equal_knowledge_tab m.knowledge.active_tab
                  Nav.Knowledge_memory
            | Nav.Keepers ->
                Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_memory
            | Nav.Pulse | Nav.Work | Nav.Runtime | Nav.Infra -> false)
      in
      if not in_memory then (m, [])
      else
        ( {
            m with
            knowledge = Knowledge_store.toggle_memory_facts_sort m.knowledge;
          }
        , [] )
  | Keymap.Quit_app -> (m, [ Cmd.Quit Exit_reason.Quit_key ])
