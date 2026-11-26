open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

let active_memory_reading (m : Model.t) :
    Knowledge_store.memory_reading_entry option =
  let scope_opt =
    match Model.active_inspector m with
    | Some _ -> None
    | None -> (
        match m.nav.workspace with
        | Nav.Knowledge
          when Nav.equal_knowledge_tab m.knowledge.active_tab
                 Nav.Knowledge_memory ->
            Some m.knowledge.memory_diff_keeper
        | Nav.Keepers
          when Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_memory ->
            Option.map (fun name -> Some name) (Model.selected_keeper_name m)
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
  | Theme.Mono -> Theme.Muted
  | Theme.Muted -> Theme.Muted_warm
  | Theme.Muted_warm -> Theme.Muted_green
  | Theme.Muted_green -> Theme.Muted_dusk
  | Theme.Muted_dusk -> Theme.Muted_graphite
  | Theme.Muted_graphite -> Theme.Solarized_dark
  | Theme.Solarized_dark -> Theme.Nord
  | Theme.Nord -> Theme.Dracula
  | Theme.Dracula -> Theme.Gruvbox_dark
  | Theme.Gruvbox_dark -> Theme.Catppuccin_mocha
  | Theme.Catppuccin_mocha -> Theme.Midnight

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

(* The keeper whose conversation is on screen: the selected row of the Keepers
   workspace (whether in split view or zoomed Focus Mode). *)
let viewed_keeper_name (m : Model.t) : string option =
  match Model.active_inspector m with
  | Some _ -> None
  | None -> (
      match m.nav.workspace with
      | Nav.Keepers -> Model.selected_keeper_name m
      | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Runtime | Nav.Infra -> None)

let latest_keeper_reply_text (m : Model.t) : (string * string) option =
  match viewed_keeper_name m with
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

(* Closed alphaTex blocks of the loaded conversation on screen, newest first.
   [None] when no keeper conversation is on screen. *)
let loaded_alphatex_sources (m : Model.t) : string list option =
  Option.map
    (fun keeper ->
      match Fleet_store.String_map.find_opt keeper m.fleet.chat_histories with
      | None -> []
      | Some observed -> (
          match Observed.to_option observed with
          | None -> []
          | Some page ->
              List.rev
                (List.concat_map
                   (fun (msg : Wire_fleet.chat_message) ->
                     Alphatex_fences.of_text msg.content)
                   page.messages)))
    (viewed_keeper_name m)

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
    match Model.active_inspector m0 with
    | Some _ -> None
    | None ->
        if
          Nav.equal_workspace m0.nav.workspace Nav.Keepers
          && (m0.nav.pane_index >= 1 || m0.nav.zoomed)
        then Model.selected_keeper_name m0
        else None
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
    && Option.is_none m.nav.inspector
    && Nav.equal_workspace m.nav.workspace Nav.Work
    && Nav.equal_work_tab m.work.active_tab Nav.Work_inbox
  in
  if on_work_inbox then
    if
      Work_store.equal_inbox_subview m.work.inbox_subview
        Work_store.Inbox_queue
      && (not (Attention.is_empty m.attention)
         || Option.is_some m.attention.selected_id)
    then
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
    else None
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
        } ->
        None
    | None when Option.is_some m.attention.selected_id -> None
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
             theme/language/board_sort and persist via Post_tui_preference. *)
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
        let m1 = { m with config = config1 } in
        let m2, cmds =
          match op with
          | Wire_config.Set_scalar { value; _ } when String.equal key "tui.theme"
            -> (
              match Theme.preset_of_name value with
              | Some preset ->
                  ( { m1 with theme_preset = preset; cli_theme_override = false }
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
              ( { m1 with lang; cli_lang_override = false }
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_tui_preference (Wire_config.Pref_language lang);
                    };
                ] )
          | Wire_config.Set_scalar { value; _ }
            when String.equal key "tui.board_sort" ->
              let norm = String.lowercase_ascii (String.trim value) in
              if
                List.exists (String.equal norm)
                  Config_store.valid_board_sort_values
              then
                ( {
                    m1 with
                    knowledge =
                      Knowledge_store.set_board_sort norm m1.knowledge;
                  }
                , [
                    Cmd.Http_post
                      {
                        epoch = m.epoch;
                        req =
                          Cmd.Post_tui_preference
                            (Wire_config.Pref_board_sort norm);
                      };
                  ] )
              else (m1, [])
          | Wire_config.Set_scalar _
          | Wire_config.Set_bool _
          | Wire_config.Set_int _
          | Wire_config.Set_float _
          | Wire_config.Set_string_array _
          | Wire_config.Remove_key _ ->
              (m1, [])
        in
        let persisted_live = cmds <> [] in
        let config2 =
          if persisted_live then
            (* Live Post_tui_preference updates are already persisted (and their
               in-memory schema value was updated by apply_tui_pref_op), so
               unstage them to prevent a false Esc discard trap. *)
            if was_staged then Config_store.unstage_patch ~full_key:key m2.config
            else m2.config
          else if (not was_staged) || schema_has_field_key m2.config key then
            m2.config
          else Config_store.unstage_patch ~full_key:key m2.config
        in
        Some
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:"TUI 환경설정이 적용되었습니다"
                 ~en:"TUI preference updated")
              { m2 with config = config2 }
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

let dry_run_settings_config ~now (m : Model.t) =
  match Config_store.build_patch_request ~dry_run:true m.config with
  | Ok req ->
      let config = Config_store.mark_dry_run_loading m.config in
      ( { m with config }
      , [ Cmd.Http_post { epoch = m.epoch; req = Cmd.Post_config_patch req } ] )
  | Error reason ->
      ( Model.with_toast ~now ~level:Model.Toast_info (Say.literal reason) m
      , [] )

let step_artifact_revision ~now ~delta (m : Model.t) =
  match Knowledge_store.artifact_revision_step ~delta m.knowledge with
  | Some (id, rev) ->
      let knowledge =
        Knowledge_store.set_pending_artifact_revision (Some (id, Some rev))
          m.knowledge
      in
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make
             ~ko:(Printf.sprintf "산출물 리비전 r%d 불러오는 중..." rev)
             ~en:(Printf.sprintf "Loading artifact revision r%d..." rev))
          { m with knowledge }
      , [
          Cmd.Http_get
            {
              epoch = m.epoch;
              req = Cmd.Get_artifact_detail { id; revision = Some rev };
            };
          Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_artifact_checks };
        ] )
  | None -> (m, [])

let sync_settings_live_tui (m : Model.t) (cfg : Config_store.t) =
  Config_store.sync_live_tui_values ~theme_preset:m.theme_preset ~lang:m.lang
    ~board_sort:m.knowledge.board_sort_by cfg

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
      let cfg0 = sync_settings_live_tui m cfg0 in
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
          match
            Option.bind sel_key_opt (fun key ->
                apply_staged_tui_pref_if_needed ~now ~key m config)
          with
          | Some res -> res
          | None -> ({ m with config }, []))
      | Ok (_, false) ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make
                 ~ko:"[Enter] 키로 텍스트 편집 · [Tab] 트리로 이동"
                 ~en:"Press [Enter] to edit text · [Tab] for tree")
              { m with config = cfg0 }
          , [] )
      | Error reason ->
          ( Model.with_toast ~now ~level:Model.Toast_info (Say.literal reason)
              { m with config = cfg0 }
          , [] ))

let open_custom_inline_modal ~(kind : Nav.inline_action_kind) (m : Model.t)
    (fields : Model.modal_form_field list) =
  let modal : Model.inline_modal_state =
    {
      kind;
      fields;
      active_field = 0;
      submitting = false;
      submission_id = 0;
      note_prefill_id = None;
      error = None;
    }
  in
  let nav =
    {
      m.nav with
      overlay = Some (Nav.Inline_action kind);
      return_overlay = None;
      filter_focused = false;
      sidebar_focused = false;
      modal_edit_cursor = String.length (Model.modal_active_field_value modal);
    }
  in
  let drafts =
    m.drafts |> Drafts.set_focus false |> Update_nav.clear_btw_if_leaving m
  in
  let config = Config_store.cancel_edit_field m.config in
  ({ m with nav; drafts; config; inline_modal = Some modal }, [])

let open_goal_confirmation_proof_modal (m : Model.t) ~(goal_id : string)
    ~(criterion_revision : string) =
  let m, cmds =
    open_custom_inline_modal ~kind:Nav.Goal_confirmation_proof m
    [
      {
        key = "confirm_goal_id";
        label = Say.make ~ko:"목표 ID" ~en:"Goal ID";
        value = goal_id;
        required = true;
        secret = false;
      };
      {
        key = "confirm_criterion_revision";
        label = Say.make ~ko:"기준 리비전 (criterion_revision)" ~en:"Criterion revision";
        value = criterion_revision;
        required = true;
        secret = false;
      };
      {
        key = "confirm_request_id";
        label =
          Say.make ~ko:"서버 발급 request_id (GET /goals/confirmation)"
            ~en:"Server-issued request_id (GET /goals/confirmation)";
        value = "";
        required = true;
        secret = false;
      };
      {
        key = "confirm_verification_run_id";
        label =
          Say.make ~ko:"서버 발급 verification_run_id"
            ~en:"Server-issued verification_run_id";
        value = "";
        required = true;
        secret = false;
      };
      {
        key = "confirm_operator_id";
        label =
          Say.make ~ko:"운영자 ID (expected_operator_id)"
            ~en:"Operator ID (expected_operator_id)";
        value = "";
        required = true;
        secret = false;
      };
    ]
  in
  (* The manual fields stay for operators who prefer typing the proof, but
     the authoritative values already live on the server: fetch them and let
     the reply fill the blanks, so the common path is Enter-to-confirm. *)
  let fetch =
    Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_goal_confirmation { goal_id } }
  in
  (m, cmds @ [ fetch ])

(* The route refuses a Goal transition that does not name the workspace the
   operator saw. Until [/health] has named it there is nothing true to name,
   so the key posts nothing and says why. *)
let request_goal_transition ~now (m : Model.t) ~level ~toast
    (g : Wire_work.goal) action =
  match Update_nav.expected_workspace_of m with
  | Some expected_workspace ->
      ( Model.with_toast ~now ~level toast m
      , [
          Cmd.Http_post
            {
              epoch = m.epoch;
              req =
                Cmd.Post_goal_transition
                  { goal_id = g.id; action; note = None; expected_workspace };
            };
        ] )
  | None ->
      ( Model.with_toast ~now ~level:Model.Toast_warning
          (Say.make
             ~ko:"목표 상태를 바꾸려면 서버 워크스페이스 정보가 필요합니다"
             ~en:"Goal transitions need the server workspace identity")
          m
      , [] )

let goal_action_on_approve ~now (m : Model.t) (g : Wire_work.goal) =
  match g.phase with
  | Wire_work.Awaiting_confirmation -> (
      let rev_opt =
        match g.criterion_revision with
        | Some r when not (String.equal (String.trim r) "") -> Some (String.trim r)
        | Some _ | None -> None
      in
      let ws_opt = m.server_identity.workspace in
      let inst_opt =
        match m.server_identity.observer_instance_id with
        | Some id when not (String.equal (String.trim id) "") ->
            Some (String.trim id)
        | Some _ | None -> None
      in
      match rev_opt, ws_opt, inst_opt with
      | Some criterion_revision, Some _, Some _ ->
          open_goal_confirmation_proof_modal m ~goal_id:g.id ~criterion_revision
      | _ ->
          ( Model.with_toast ~now ~level:Model.Toast_warning
              (Say.make
                 ~ko:
                   "완료 확정에는 서버 발급 증명(criterion_revision / 워크스페이스 \
                    / 런타임 인스턴스)이 필요합니다"
                 ~en:
                   "Goal confirmation requires loaded server identity \
                    (criterion_revision / workspace / runtime instance)")
              m
          , [] ))
  | Wire_work.Executing ->
      request_goal_transition ~now m ~level:Model.Toast_info
        ~toast:
          (Say.make
             ~ko:("목표 완료 검증 요청: " ^ g.title)
             ~en:("Requesting goal completion verification: " ^ g.title))
        g Wire_work.Request_complete
  | Wire_work.Verifying ->
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make ~ko:"목표가 현재 검증 진행 중입니다"
             ~en:"Goal is already verifying")
          m
      , [] )
  | Wire_work.Paused _ ->
      request_goal_transition ~now m ~level:Model.Toast_info
        ~toast:
          (Say.make ~ko:("목표 재개 요청: " ^ g.title) ~en:("Resuming goal: " ^ g.title))
        g Wire_work.Resume
  | Wire_work.Blocked _ ->
      request_goal_transition ~now m ~level:Model.Toast_info
        ~toast:
          (Say.make ~ko:("목표 차단 해제: " ^ g.title) ~en:("Unblocking goal: " ^ g.title))
        g Wire_work.Unblock
  | Wire_work.Completed | Wire_work.Dropped ->
      request_goal_transition ~now m ~level:Model.Toast_info
        ~toast:
          (Say.make ~ko:("목표 재개(Reopen): " ^ g.title) ~en:("Reopening goal: " ^ g.title))
        g Wire_work.Reopen

let goal_action_on_stop ~now (m : Model.t) (g : Wire_work.goal) =
  match g.phase with
  | Wire_work.Paused _ ->
      Update_nav.open_inline_modal m (Nav.Goal_drop g.id)
  | Wire_work.Executing
  | Wire_work.Verifying
  | Wire_work.Awaiting_confirmation
  | Wire_work.Blocked _ ->
      request_goal_transition ~now m ~level:Model.Toast_info
        ~toast:
          (Say.make ~ko:("목표 일시정지 요청: " ^ g.title) ~en:("Pausing goal: " ^ g.title))
        g Wire_work.Pause
  | Wire_work.Completed | Wire_work.Dropped ->
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make ~ko:"이미 종료된 목표입니다 ([a] 재개)"
             ~en:"Goal is already terminal ([a] to reopen)")
          m
      , [] )

let resolve_memory_act_keeper (m : Model.t) =
  let keeper_tab_active =
    Option.is_none (Model.active_inspector m)
    && Nav.equal_workspace m.nav.workspace Nav.Keepers
    && (m.nav.pane_index >= 1 || m.nav.zoomed)
    && Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_memory
  in
  match if keeper_tab_active then Model.selected_keeper_name m else None with
  | Some name -> Some name
  | None -> (
      match m.knowledge.memory_diff_keeper with
      | Some k when not (String.equal (String.trim k) "") -> Some k
      | Some _ | None -> (
          match Observed.to_option m.knowledge.world_memory with
          | Some wm -> (
              match wm.librarian_writers with
              | Wire_knowledge.Writers_running { keepers; _ } -> (
                  match
                    List.find_opt
                      (fun (w : Wire_knowledge.librarian_writer_row) ->
                        match w.state with
                        | Wire_knowledge.Writer_stopped _
                        | Wire_knowledge.Writer_refused_at_bottom ->
                            true
                        | Wire_knowledge.Writer_open
                        | Wire_knowledge.Writer_idle
                        | Wire_knowledge.Writer_asking
                        | Wire_knowledge.Writer_resting
                        | Wire_knowledge.Writer_booting
                        | Wire_knowledge.Writer_retired
                        | Wire_knowledge.Writer_no_writer ->
                            w.available_act_tokens <> [])
                      keepers
                  with
                  | Some w -> Some w.keeper
                  | None -> (
                      match keepers with
                      | first :: _ -> Some first.keeper
                      | [] -> Update_nav.resolve_target_keeper m))
              | Wire_knowledge.Writers_none_in_process ->
                  Update_nav.resolve_target_keeper m)
          | None -> Update_nav.resolve_target_keeper m))

let open_memory_act_modal (m : Model.t) ~(keeper_default : string) =
  open_custom_inline_modal ~kind:Nav.Memory_act_form m
    [
      {
        key = "memory_keeper";
        label = Say.make ~ko:"대상 키퍼" ~en:"Target keeper";
        value = keeper_default;
        required = true;
        secret = false;
      };
      {
        key = "memory_act";
        label =
          Say.make ~ko:"복구 액션 (resume|adopt|restart_reading|skip_item|skip_line)"
            ~en:"Recovery act (resume|adopt|restart_reading|skip_item|skip_line)";
        value = "resume";
        required = true;
        secret = false;
      };
      {
        key = "memory_arg";
        label =
          Say.make ~ko:"인자 (observed / turn_log:line / offset)"
            ~en:"Argument (observed / turn_log:line / offset)";
        value = "";
        required = false;
        secret = false;
      };
    ]

(* The form opens only on a page held fresh: right after a save the slot
   still holds the previous revision, marked stale, until the page is read
   again. The page it opens on becomes the edit's base, so the save names the
   revision the form's text came from. *)
let open_wiki_edit_modal ~now (m : Model.t) ~(slug : string) =
  match Knowledge_store.wiki_page_for ~slug m.knowledge with
  | Observed.Value { data = d; stale = false; _ } ->
      (Model.open_wiki_edit_modal_for_detail d m, [])
  | Observed.Value _ | Observed.Loading _ | Observed.Absent
  | Observed.Unreported | Observed.Failed _ ->
      let m =
        {
          m with
          knowledge = Knowledge_store.request_wiki_edit ~slug m.knowledge;
        }
      in
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make
             ~ko:
               ("위키 본문을 불러오는 중입니다 (" ^ slug
              ^ ") — 불러오면 편집 창이 자동으로 열립니다")
             ~en:
               ("Loading wiki page body (" ^ slug
              ^ ") — edit modal will open once loaded"))
          m
      , [
          Cmd.Http_get
            { epoch = m.epoch; req = Cmd.Get_wiki_page { page = slug } };
        ] )

let open_fusion_launch_modal (m : Model.t) =
  let draft = m.runtime.fusion_launch_draft in
  let keeper_default =
    match draft.keeper with
    | Some k when not (String.equal (String.trim k) "") -> k
    | Some _ | None ->
        Option.value (Update_nav.resolve_target_keeper m) ~default:""
  in
  let topo_default =
    match draft.topology with
    | Some t -> Wire_runtime.fusion_topology_to_string t
    | None -> ""
  in
  let preset_default =
    match draft.preset with
    | Some p when not (String.equal (String.trim p) "") -> p
    | Some _ | None -> (
        match Observed.to_option m.runtime.fusion_config with
        | Some cfg when not (String.equal (String.trim cfg.default_preset) "")
          ->
            cfg.default_preset
        | Some { presets = first :: _; _ } -> first.name
        | Some { presets = []; _ } | None -> "")
  in
  open_custom_inline_modal ~kind:Nav.Fusion_launch_form m
    [
      {
        key = "fusion_keeper";
        label = Say.make ~ko:"실행 키퍼" ~en:"Keeper";
        value = keeper_default;
        required = true;
        secret = false;
      };
      {
        key = "fusion_prompt";
        label = Say.make ~ko:"Fusion 프롬프트" ~en:"Fusion prompt";
        value = draft.prompt;
        required = true;
        secret = false;
      };
      {
        key = "fusion_topology";
        label =
          Say.make ~ko:"토폴로지 (선택: simple|refine|conditional|judge_of_judges)"
            ~en:"Topology (optional: simple|refine|conditional|judge_of_judges)";
        value = topo_default;
        required = false;
        secret = false;
      };
      {
        key = "fusion_preset";
        label =
          Say.make ~ko:"프리셋 (선택 · [←→] 순환)" ~en:"Preset (optional · [←→] cycle)";
        value = preset_default;
        required = false;
        secret = false;
      };
    ]

let runtime_config_revision_opt (m : Model.t) : string option =
  Option.map
    (fun (meta : Wire_runtime.runtime_config_raw_meta) -> meta.source_revision)
    (Observed.to_option m.runtime.runtime_config_raw)

let selected_lane_for_crud (m : Model.t) : Wire_runtime.failover_lane option =
  match Model.active_inspector m with
  | Some _ -> None
  | None ->
      if
        Nav.equal_workspace m.nav.workspace Nav.Runtime
        && Nav.equal_runtime_tab m.runtime.active_tab Nav.Runtime_failover_lanes
      then Runtime_store.selected_lane m.runtime
      else None

let open_runtime_lane_create_modal (m : Model.t) =
  let m1, cmds1 = Update_nav.open_inline_modal m Nav.Runtime_lane_create in
  let rev_cmds =
    match runtime_config_revision_opt m1 with
    | Some _ -> []
    | None ->
        [ Cmd.Http_get { epoch = m1.epoch; req = Cmd.Get_runtime_config_raw } ]
  in
  (m1, cmds1 @ rev_cmds)

let open_runtime_lane_edit_modal ~now (m : Model.t)
    (lane : Wire_runtime.failover_lane) =
  if String.equal lane.id "default" then
    let next, cmds = Update_nav.open_inline_modal m Nav.Default_route_edit in
    let value = String.concat ", " lane.runtime_ids in
    let inline_modal = Option.map
      (fun (modal : Model.inline_modal_state) ->
        { modal with fields = List.map
            (fun (field : Model.modal_form_field) -> { field with value }) modal.fields })
      next.inline_modal
    in
    ({ next with nav = { next.nav with modal_edit_cursor = String.length value }; inline_modal }, cmds)
  else (
  let exact_output, bare_id =
    match Wire_runtime.classify_routing_lane lane.id with
    | Wire_runtime.Route_exact bare -> (true, bare)
    | Wire_runtime.Route_default | Wire_runtime.Route_media_failover
    | Wire_runtime.Route_named _ ->
        (false, lane.id)
  in
  let opened_revision = runtime_config_revision_opt m in
  let kind =
    Nav.Runtime_lane_edit { lane_id = bare_id; exact_output; opened_revision }
  in
  let modal0 = Model.inline_modal_for kind in
  let seeded = String.concat ", " lane.runtime_ids in
  let fields =
    List.map
      (fun (f : Model.modal_form_field) ->
        if String.equal f.key "lane_candidates" then { f with value = seeded }
        else f)
      modal0.fields
  in
  let modal = { modal0 with fields } in
  let nav =
    {
      m.nav with
      overlay = Some (Nav.Inline_action kind);
      return_overlay = None;
      filter_focused = false;
      sidebar_focused = false;
      modal_edit_cursor = String.length (Model.modal_active_field_value modal);
    }
  in
  let drafts = Drafts.set_focus false m.drafts in
  let config = Config_store.cancel_edit_field m.config in
  let rev_cmds =
    match opened_revision with
    | Some _ -> []
    | None ->
        [ Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_runtime_config_raw } ]
  in
  let ask_modal =
    if Model.has_preserved_ask_return nav then m.ask_modal else None
  in
  ({ m with nav; drafts; config; inline_modal = Some modal; ask_modal }, rev_cmds))

let open_named_lane_delete_modal (m : Model.t) lane_id =
  let opened_revision = runtime_config_revision_opt m in
  let kind = Nav.Runtime_lane_delete { lane_id; opened_revision } in
  let next, cmds = Update_nav.open_inline_modal m kind in
  let revision_cmds = match opened_revision with
    | Some _ -> []
    | None -> [ Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_runtime_config_raw } ]
  in
  (next, cmds @ revision_cmds)

let open_runtime_lane_delete_modal ~now (m : Model.t)
    (lane : Wire_runtime.failover_lane) =
  if (not lane.declared) || not (Wire_runtime.is_named_routing_lane lane.id)
  then
    ( Model.with_toast ~now ~level:Model.Toast_warning
        (Say.make
           ~ko:"선언된 페일오버 레인만 삭제할 수 있습니다 (합성·예약 레인은 삭제 불가)"
           ~en:"Only declared failover lanes can be deleted (synthesized/reserved routes cannot be removed)")
        m
    , [] )
  else open_named_lane_delete_modal m lane.id

let default_task_transition_action (tk : Wire_work.task) =
  match tk.status with
  | Wire_work.Todo -> "claim"
  | Wire_work.Claimed _ -> "start"
  | Wire_work.InProgress _ -> "submit_for_verification"
  | Wire_work.AwaitingVerification _ | Wire_work.Done _ | Wire_work.Cancelled _
    ->
      "release"

let open_task_transition_modal ~now (m : Model.t) (tk : Wire_work.task) =
  match tk.status with
  | Wire_work.Done _ | Wire_work.Cancelled _ ->
      ( Model.with_toast ~now ~level:Model.Toast_warning
          (Say.make
             ~ko:"완료·취소된 작업은 상태를 전환할 수 없습니다"
             ~en:"Finished or cancelled tasks cannot be transitioned")
          m
      , [] )
  | Wire_work.Todo
  | Wire_work.Claimed _
  | Wire_work.InProgress _
  | Wire_work.AwaitingVerification _ ->
      let kind = Nav.Task_transition_form { task_id = tk.id } in
      let modal0 = Model.inline_modal_for kind in
      let def_act = default_task_transition_action tk in
      let fields =
        List.map
          (fun (f : Model.modal_form_field) ->
            if String.equal f.key "task_action" then { f with value = def_act }
            else f)
          modal0.fields
      in
      let modal = { modal0 with fields } in
      let nav =
        {
          m.nav with
          overlay = Some (Nav.Inline_action kind);
          return_overlay = None;
          filter_focused = false;
          sidebar_focused = false;
          modal_edit_cursor = String.length (Model.modal_active_field_value modal);
        }
      in
      let drafts = Drafts.set_focus false m.drafts in
      let config = Config_store.cancel_edit_field m.config in
      let ask_modal =
        if Model.has_preserved_ask_return nav then m.ask_modal else None
      in
      ( { m with nav; drafts; config; inline_modal = Some modal; ask_modal }
      , [] )

let open_task_link_goal_modal ~now (m : Model.t) (tk : Wire_work.task) =
  match tk.status with
  | Wire_work.Done _ | Wire_work.Cancelled _ ->
      ( Model.with_toast ~now ~level:Model.Toast_warning
          (Say.make ~ko:"완료·취소된 작업은 목표에 연결할 수 없습니다"
             ~en:"Finished or cancelled tasks cannot be linked to a goal")
          m
      , [] )
  | Wire_work.Todo
  | Wire_work.Claimed _
  | Wire_work.InProgress _
  | Wire_work.AwaitingVerification _ -> (
      match Wire_work.check_goal_link_assignable tk with
      | Error detail ->
          ( Model.with_toast ~now ~level:Model.Toast_warning
              (Say.make
                 ~ko:("이미 목표에 연결된 작업입니다 (미연결 작업만 연결 가능): " ^ detail)
                 ~en:("Goalless tasks only: " ^ detail))
              m
          , [] )
      | Ok () ->
          Update_nav.open_inline_modal m (Nav.Task_link_goal { task_id = tk.id }))

let open_goal_upsert_modal (m : Model.t) ?(goal : Wire_work.goal option) () =
  let id_opt = Option.map (fun (g : Wire_work.goal) -> g.id) goal in
  let kind = Nav.Goal_upsert_form id_opt in
  let modal0 = Model.inline_modal_for kind in
  let modal =
    match goal with
    | None -> modal0
    | Some g ->
        let fields =
          List.map
            (fun (f : Model.modal_form_field) ->
              match f.key with
              | "goal_title" -> { f with value = g.title }
              | "goal_procedure" -> { f with value = g.procedure }
              | "goal_priority" -> { f with value = string_of_int g.priority }
              | "goal_due_date" ->
                  { f with value = Option.value g.due_date ~default:"" }
              | _ -> f)
            modal0.fields
        in
        { modal0 with fields }
  in
  let nav =
    {
      m.nav with
      overlay = Some (Nav.Inline_action kind);
      return_overlay = None;
      filter_focused = false;
      sidebar_focused = false;
      modal_edit_cursor = String.length (Model.modal_active_field_value modal);
    }
  in
  let drafts = Drafts.set_focus false m.drafts in
  let config = Config_store.cancel_edit_field m.config in
  let ask_modal =
    if Model.has_preserved_ask_return nav then m.ask_modal else None
  in
  ({ m with nav; drafts; config; inline_modal = Some modal; ask_modal }, [])

let reset_knowledge_zoom_transient (k : Knowledge_store.t) =
  k |> Knowledge_store.reset_thread_view |> Knowledge_store.clear_armed_vote
  |> Knowledge_store.clear_pending_wiki_edit
  |> Knowledge_store.set_artifact_search ""

let selected_board_post_for_crud (m : Model.t) : Wire_knowledge.board_post option =
  match Model.active_inspector m with
  | Some _ -> None
  | None ->
      if
        Nav.equal_workspace m.nav.workspace Nav.Knowledge
        && Nav.equal_knowledge_tab m.knowledge.active_tab Nav.Knowledge_board
      then Knowledge_store.board_detail_post m.knowledge
      else None

let open_board_comment_for_selected (m : Model.t) =
  match selected_board_post_for_crud m with
  | None -> (m, [])
  | Some p ->
      if
        Model.is_board_detail_active m
        && m.knowledge.thread_view = Knowledge_store.Thread_comments
      then
        match Knowledge_store.selected_thread_comment ~post_id:p.id m.knowledge with
        | Some tc ->
            Update_nav.open_inline_modal m
              (Nav.Board_comment
                 { post_id = p.id; parent_id = Some tc.comment.id })
        | None -> (m, [])
      else
        Update_nav.open_inline_modal m
          (Nav.Board_comment { post_id = p.id; parent_id = None })

let thread_vote_target ~post_id (knowledge : Knowledge_store.t) =
  match knowledge.thread_view with
  | Knowledge_store.Thread_post -> Some (Knowledge_store.Vote_post post_id)
  | Knowledge_store.Thread_comments ->
      Option.map
        (fun (tc : Knowledge_store.threaded_comment) ->
          Knowledge_store.Vote_comment { post_id; comment_id = tc.comment.id })
        (Knowledge_store.selected_thread_comment ~post_id knowledge)

let upvote_board_target ~now (m : Model.t) =
  match selected_board_post_for_crud m with
  | None -> (m, [])
  | Some p ->
      if
        Model.is_board_detail_active m
        && m.knowledge.thread_view = Knowledge_store.Thread_comments
      then
        match thread_vote_target ~post_id:p.id m.knowledge with
        | Some (Knowledge_store.Vote_comment { post_id; comment_id }) ->
            ( Model.with_toast ~now ~level:Model.Toast_info
                (Say.make ~ko:"추천 전송 중..." ~en:"Submitting upvote...")
                m
            , [
                Cmd.Http_post
                  {
                    epoch = m.epoch;
                    req =
                      Cmd.Post_board_comment_vote
                        { post_id; comment_id; direction = `Up };
                  };
              ] )
        | Some (Knowledge_store.Vote_post post_id) ->
            ( Model.with_toast ~now ~level:Model.Toast_info
                (Say.make ~ko:("추천 전송: " ^ p.title) ~en:("Upvoting: " ^ p.title))
                m
            , [
                Cmd.Http_post
                  {
                    epoch = m.epoch;
                    req = Cmd.Post_board_vote { post_id; direction = `Up };
                  };
              ] )
        | None -> (m, [])
      else
        ( Model.with_toast ~now ~level:Model.Toast_info
            (Say.make ~ko:("추천 전송: " ^ p.title) ~en:("Upvoting: " ^ p.title))
            m
        , [
            Cmd.Http_post
              {
                epoch = m.epoch;
                req = Cmd.Post_board_vote { post_id = p.id; direction = `Up };
              };
          ] )

let toggle_board_pin ~now (m : Model.t) =
  match selected_board_post_for_crud m with
  | Some p ->
      let next_pinned = not p.pinned in
      let toast =
        if next_pinned then
          Say.make ~ko:("게시글 고정 요청: " ^ p.title)
            ~en:("Pinning post: " ^ p.title)
        else
          Say.make ~ko:("게시글 고정 해제 요청: " ^ p.title)
            ~en:("Unpinning post: " ^ p.title)
      in
      ( Model.with_toast ~now ~level:Model.Toast_info toast m
      , [
          Cmd.Http_post
            {
              epoch = m.epoch;
              req = Cmd.Post_board_pin { post_id = p.id; pinned = next_pinned };
            };
        ] )
  | None -> (m, [])

let keeper_is_offline = function
  | Wire_fleet.Keeper_offline -> true
  | Keeper_healthy | Keeper_working | Keeper_idle | Keeper_degraded
  | Keeper_recovering | Keeper_failing | Keeper_paused | Keeper_booting -> false

let selected_keeper_for_lifecycle (m : Model.t) :
    Wire_fleet.keeper_summary option =
  match Model.active_inspector m with
  | Some _ -> None
  | None ->
      if Nav.equal_workspace m.nav.workspace Nav.Keepers then
        Fleet_store.selected_keeper_summary m.fleet
      else None

let selected_keeper_name_for_lifecycle (m : Model.t) : string option =
  match Model.active_inspector m with
  | Some _ -> None
  | None ->
      if Nav.equal_workspace m.nav.workspace Nav.Keepers then
        Model.selected_keeper_name m
      else None

let open_keeper_lifecycle_modal (m : Model.t) ~keeper ~default_action =
  let kind = Nav.Keeper_lifecycle_form { keeper } in
  let modal0 = Model.inline_modal_for kind in
  let fields =
    List.map
      (fun (f : Model.modal_form_field) ->
        if String.equal f.key "lifecycle_action" then
          { f with value = default_action }
        else f)
      modal0.fields
  in
  let modal = { modal0 with fields } in
  let nav =
    {
      m.nav with
      overlay = Some (Nav.Inline_action kind);
      return_overlay = None;
      filter_focused = false;
      sidebar_focused = false;
      modal_edit_cursor = String.length (Model.modal_active_field_value modal);
    }
  in
  let drafts = Drafts.set_focus false m.drafts in
  let config = Config_store.cancel_edit_field m.config in
  let ask_modal =
    if Model.has_preserved_ask_return nav then m.ask_modal else None
  in
  ({ m with nav; drafts; config; inline_modal = Some modal; ask_modal }, [])

let open_addon_attach_modal ?manifest_path ?run_id (m : Model.t) =
  let kind = Nav.Addon_attach_form in
  let modal0 = Model.inline_modal_for kind in
  let manifest_path =
    match manifest_path with
    | Some _ -> manifest_path
    | None when m.runtime.addon_catalog_mode -> (
        match Runtime_store.selected_addon_catalog_entry m.runtime with
        | Some (Wire_runtime.Catalog_package { manifest_path; _ }) -> Some manifest_path
        | Some (Wire_runtime.Catalog_folder _ | Wire_runtime.Catalog_issue _) | None -> None)
    | None -> None
  in
  let fields =
    List.map
      (fun (field : Model.modal_form_field) ->
        match field.key, manifest_path, run_id with
        | "addon_manifest_path", Some value, _ | "addon_run_id", _, Some value ->
            { field with value }
        | _ -> field)
      modal0.fields
  in
  let modal = { modal0 with fields } in
  let nav =
    {
      m.nav with
      overlay = Some (Nav.Inline_action kind);
      return_overlay = None;
      filter_focused = false;
      sidebar_focused = false;
      modal_edit_cursor = String.length (Model.modal_active_field_value modal);
    }
  in
  let drafts = Drafts.set_focus false m.drafts in
  let config = Config_store.cancel_edit_field m.config in
  let ask_modal =
    if Model.has_preserved_ask_return nav then m.ask_modal else None
  in
  ({ m with nav; drafts; config; inline_modal = Some modal; ask_modal }, [])

let open_addon_ask_modal ~now (m : Model.t) =
  let open_asks = Runtime_store.open_lane_addon_asks m.runtime in
  let selected_decl_opt =
    Option.bind (Runtime_store.selected_addon_instance m.runtime)
      (fun (inst : Wire_runtime.addon_instance) -> inst.config_declaration_id)
  in
  let chosen =
    match selected_decl_opt with
    | Some decl_id -> (
        match
          List.find_opt
            (fun (a : Wire_runtime.lane_addon_ask_row) ->
              String.equal a.declaration_id decl_id)
            open_asks
        with
        | Some a -> Some a
        | None -> List.nth_opt open_asks 0)
    | None -> List.nth_opt open_asks 0
  in
  match chosen with
  | None ->
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make ~ko:"열린 애드온 질문(Ask)이 없습니다"
             ~en:"No open lane-addon asks")
          m
      , [ Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_lane_addon_asks { include_resolved = false } } ] )
  | Some ask_row ->
      let ask_modal = Model.ask_modal_for_lane_addon ask_row in
      let nav =
        {
          m.nav with
          overlay = Some Nav.Ask_answer;
          return_overlay = None;
          filter_focused = false;
          sidebar_focused = false;
        }
      in
      let drafts = Drafts.set_focus false m.drafts in
      let config = Config_store.cancel_edit_field m.config in
      ( { m with nav; drafts; config; inline_modal = None; ask_modal = Some ask_modal }
      , [] )

let open_harness_overrule_for_selected ~verdict ~now (m : Model.t) =
  Update_nav.open_harness_overrule_for_context ~verdict ~now m

let open_connector_form_populated (m : Model.t) =
  let connector_default =
    match Runtime_store.selected_connector m.runtime with
    | Some c -> c.connector_id
    | None -> (
        match Runtime_store.filtered_connectors m.runtime with
        | c :: _ -> c.connector_id
        | [] -> "")
  in
  let channel_default =
    if String.equal connector_default "" then ""
    else
      match
        Runtime_store.connector_channel_names ~connector_id:connector_default
          m.runtime
      with
      | first :: _ -> first.id
      | [] -> ""
  in
  let keeper_default =
    Option.value (Update_nav.resolve_target_keeper m) ~default:""
  in
  let modal0 = Model.inline_modal_for Nav.Connector_form in
  let fields =
    List.map
      (fun (f : Model.modal_form_field) ->
        if String.equal f.key "connector" then { f with value = connector_default }
        else if String.equal f.key "channel" || String.equal f.key "channel_id" then
          { f with value = channel_default }
        else if String.equal f.key "keeper" || String.equal f.key "keeper_name" then
          { f with value = keeper_default }
        else f)
      modal0.fields
  in
  let modal = { modal0 with fields } in
  let nav =
    {
      m.nav with
      overlay = Some (Nav.Inline_action Nav.Connector_form);
      return_overlay = None;
      filter_focused = false;
      sidebar_focused = false;
      modal_edit_cursor = String.length (Model.modal_active_field_value modal);
    }
  in
  let drafts =
    m.drafts |> Drafts.set_focus false |> Update_nav.clear_btw_if_leaving m
  in
  let config = Config_store.cancel_edit_field m.config in
  let cmds =
    if
      (not (String.equal connector_default ""))
      && not
           (Runtime_store.String_map.mem connector_default
              m.runtime.connector_names)
    then
      [
        Cmd.Http_get
          {
            epoch = m.epoch;
            req =
              Cmd.Get_connector_names
                { connector = connector_default; scope = "channel" };
          };
      ]
    else []
  in
  ({ m with nav; drafts; config; inline_modal = Some modal }, cmds)

let active_keeper_for_tab target_tab (m : Model.t) =
  if Option.is_some m.nav.overlay then None
  else
    match Model.active_inspector m with
    | Some _ -> None
    | None ->
        if
          Nav.equal_workspace m.nav.workspace Nav.Keepers
          && (m.nav.pane_index >= 1 || m.nav.zoomed)
          && Nav.equal_keeper_tab m.fleet.keeper_dive_tab target_tab
        then Model.selected_keeper_name m
        else None

let available_code_scopes (m : Model.t) : Wire_infra.workspace_scope list =
  let repo_scopes =
    List.map
      (fun (r : Wire_infra.repository) -> Wire_infra.Ws_repo r.id)
      (Infra_store.filtered_repositories m.infra)
  in
  let keeper_scopes =
    match Observed.to_option m.fleet.keepers with
    | Some ks ->
        List.map
          (fun (k : Wire_fleet.keeper_summary) -> Wire_infra.Ws_keeper k.name)
          ks
    | None -> []
  in
  Wire_infra.Ws_project :: (repo_scopes @ keeper_scopes)

let next_code_scope (m : Model.t) : Wire_infra.workspace_scope =
  let scopes = available_code_scopes m in
  let cur = m.infra.code.scope in
  let rec find = function
    | [] -> Wire_infra.Ws_project
    | [ _ ] -> (match scopes with s :: _ -> s | [] -> Wire_infra.Ws_project)
    | x :: y :: rest ->
        if Wire_infra.equal_workspace_scope x cur then y else find (y :: rest)
  in
  find scopes

let open_runtime_assign_modal (m : Model.t) ?(keeper_default = "")
    ?(runtime_default = "") () =
  open_custom_inline_modal ~kind:Nav.Runtime_assign_form m
    [
      {
        key = "assign_keeper";
        label =
          Say.make ~ko:"대상 키퍼 (비우거나 default 입력 시 기본 경로 변경)"
            ~en:"Target keeper (blank or 'default' sets default route)";
        value = keeper_default;
        required = false;
        secret = false;
      };
      {
        key = "assign_runtime_id";
        label =
          Say.make ~ko:"런타임 또는 레인 ID (키퍼 배정 해제 시 비움)"
            ~en:"Runtime or lane ID (leave blank to clear keeper assignment)";
        value = runtime_default;
        required = false;
        secret = false;
      };
    ]

let open_setup_account_key_modal (m : Model.t) ?(integration_default = "") () =
  open_custom_inline_modal ~kind:Nav.Setup_account_key_form m
    [
      {
        key = "setup_key_integration";
        label =
          Say.make ~ko:"프로바이더/통합 ID (예: anthropic, openai, gemini)"
            ~en:"Integration ID (e.g. anthropic, openai, gemini)";
        value = integration_default;
        required = true;
        secret = false;
      };
      {
        key = "setup_key_secret";
        label = Say.make ~ko:"API 키" ~en:"API key";
        value = "";
        required = true;
        secret = true;
      };
    ]

let open_setup_login_modal (m : Model.t) ?(integration_default = "") () =
  open_custom_inline_modal ~kind:Nav.Setup_login_start_form m
    [
      {
        key = "setup_login_integration";
        label =
          Say.make
            ~ko:"로그인 통합 ID (예: claude-code, codex, vibe_acp, kimi_acp)"
            ~en:"Login integration ID (e.g. claude-code, codex, vibe_acp, kimi_acp)";
        value = integration_default;
        required = true;
        secret = false;
      };
      {
        key = "setup_login_account_ref";
        label =
          Say.make ~ko:"기존 계정 참조 (선택, 새 로그인 시 비움)"
            ~en:"Existing account_ref (optional, blank for new login)";
        value = "";
        required = false;
        secret = false;
      };
    ]

let dismiss_keeper_chat_errors ~now ~keeper (m : Model.t) =
  let drafts, removed = Drafts.dismiss_notices_for_keeper ~keeper m.drafts in
  let had_err_stream =
    match Fleet_store.String_map.find_opt keeper m.fleet.chat_streams with
    | Some b -> (not b.active) && Option.is_some b.last_error
    | None -> false
  in
  let fleet = Fleet_store.clear_inactive_chat_stream_error ~keeper m.fleet in
  if removed > 0 || had_err_stream then
    let count = Int.max 1 removed in
    ( Model.with_toast ~now ~level:Model.Toast_info
        (Say.make
           ~ko:(Printf.sprintf "전송 알림 %d건 닫힘" count)
           ~en:(Printf.sprintf "Dismissed %d transmission notice(s)" count))
        { m with drafts; fleet }
    , [] )
  else (m, [])

let active_artifact_target (m : Model.t) =
  match m.nav.overlay with
  | Some (Nav.System_gate Nav.Media_viewer) ->
      Model.focused_artifact m
  | Some
      ( Nav.Palette
      | Nav.Settings _
      | Nav.Incidents
      | Nav.Queue_context _
      | Nav.Inline_action _
      | Nav.Ask_answer
      | Nav.Help
      | Nav.System_gate
          (Nav.Micro_viewport | Nav.Auth_gate | Nav.Server_offline) ) ->
      None
  | None -> (
      match Model.active_inspector m with
      | Some _ -> None
      | None ->
          if
            Nav.equal_workspace m.nav.workspace Nav.Knowledge
            && Nav.equal_knowledge_tab m.knowledge.active_tab
                 Nav.Knowledge_artifacts
          then Knowledge_store.selected_artifact m.knowledge
          else None)

let active_keeper_for_context (m : Model.t) =
  match m.nav.overlay with
  | Some (Nav.Queue_context Nav.Drawer_context) -> (
      match Drafts.target_keeper_key m.drafts with
      | k
        when (not (String.equal (String.trim k) ""))
             && not (String.equal k "fleet") ->
          Some k
      | _ -> Model.selected_keeper_name m)
  | Some
      ( Nav.Palette
      | Nav.Settings _
      | Nav.Incidents
      | Nav.Queue_context (Nav.Drawer_queue | Nav.Drawer_schedules)
      | Nav.Inline_action _
      | Nav.Ask_answer
      | Nav.Help
      | Nav.System_gate _ ) ->
      None
  | None -> (
      match Model.active_inspector m with
      | Some _ -> None
      | None ->
          if
            Nav.equal_workspace m.nav.workspace Nav.Keepers
            && Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_trace
            && (m.nav.pane_index >= 1 || m.nav.zoomed)
          then
            match Model.selected_keeper_name m with
            | Some name ->
                let ks =
                  Keeper_context_store.get_keeper ~keeper:name m.keeper_context
                in
                if
                  Keeper_context_store.equal_trace_section ks.trace_section
                    Keeper_context_store.Trace_context
                then Some name
                else None
            | None -> None
          else None)

let artifact_search_match_lines (m : Model.t) (a : Wire_knowledge.artifact_entry) =
  let q = String.trim m.knowledge.artifact_search_query in
  if String.equal q "" then []
  else
    let detail_opt = Knowledge_store.artifact_detail_for_entry a m.knowledge in
    let raw_opt =
      match detail_opt with
      | Some d when not (String.equal d.content "") -> Some d.content
      | Some _ | None -> None
    in
    match raw_opt with
    | None -> []
    | Some raw -> (
        let theme = Theme.of_preset m.theme_preset in
        let bp =
          match m.breakpoint with
          | Model.Wide -> Masc_tui_ui.Layout.Wide
          | Model.Standard -> Masc_tui_ui.Layout.Standard
          | Model.Compact -> Masc_tui_ui.Layout.Compact
          | Model.Micro -> Masc_tui_ui.Layout.Micro
        in
        let br =
          Rect.make ~x:0 ~y:0 ~w:(Model.inner_body_width m)
            ~h:(Model.inner_body_height m)
        in
        let body_after_bar =
          match
            Masc_tui_ui.Layout.split_v br
              [ Masc_tui_ui.Layout.Fixed 1; Masc_tui_ui.Layout.Flex 1 ]
          with
          | [ _; b ] -> b
          | _ -> br
        in
        let right_rect =
          if m.nav.zoomed then body_after_bar
          else
            snd
              (Masc_tui_ui.Layout.adaptive_split_2 ~stack_on_compact:true
                 ~left_ratio:0.44 ~top_ratio:0.48 bp body_after_bar)
        in
        let inner_w = max 0 (right_rect.w - 2) in
        let pad_x = Masc_tui_ui.Layout.card_pad_x bp in
        let width = max 1 (inner_w - (2 * pad_x)) in
        let is_json = Knowledge_store.is_json_artifact a in
        match
          (m.knowledge.artifact_view_mode, Wire_knowledge.artifact_format_of_entry a)
        with
        | `Document, `Html ->
            Masc_tui_ui.Html_doc.search_match_lines ~theme ~width ~lang:m.lang
              ~query:q raw
        | `Document, `Markdown when is_json ->
            let pretty =
              match Yojson.Safe.from_string raw with
              | j -> Yojson.Safe.pretty_to_string j
              | exception Yojson.Json_error _ -> raw
            in
            let lines = String.split_on_char '\n' pretty in
            let needle = String.lowercase_ascii q in
            let acc = ref [] in
            List.iteri
              (fun i ln ->
                if Store_scroll.contains_ci ~needle ln then acc := i :: !acc)
              lines;
            List.rev !acc
        | `Document, `Markdown ->
            let lines = Masc_tui_ui.Markdown.render_lines ~width ~theme raw in
            let needle = String.lowercase_ascii q in
            let acc = ref [] in
            List.iteri
              (fun i (ln : Masc_tui_ui.Markdown.rendered_line) ->
                let txt =
                  ln.spans
                  |> List.map (fun (s : Masc_tui_ui.Markdown.styled_span) ->
                         s.text)
                  |> String.concat ""
                in
                if Store_scroll.contains_ci ~needle txt then acc := i :: !acc)
              lines;
            List.rev !acc
        | `Raw_source, (`Html | `Markdown) ->
            let lines = String.split_on_char '\n' raw in
            let needle = String.lowercase_ascii q in
            let acc = ref [] in
            List.iteri
              (fun i ln ->
                if Store_scroll.contains_ci ~needle ln then acc := i :: !acc)
              lines;
            List.rev !acc)

let step_artifact_search ~now ~delta (m : Model.t) =
  match active_artifact_target m with
  | None -> (m, [])
  | Some art -> (
      let matches = artifact_search_match_lines m art in
      match matches with
      | [] ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:"검색 결과가 없습니다" ~en:"No search matches")
              m
          , [] )
      | _ ->
          let knowledge0 =
            Knowledge_store.step_artifact_search_match ~delta
              ~match_count:(List.length matches) m.knowledge
          in
          let line_idx =
            Option.value ~default:0
              (List.nth_opt matches knowledge0.artifact_search_match_idx)
          in
          let max_scroll = Update_nav.knowledge_detail_max_scroll m in
          let detail_scroll_offset =
            Store_scroll.clamp_scroll ~max_scroll line_idx
          in
          let knowledge = { knowledge0 with detail_scroll_offset } in
          ({ m with knowledge }, []))

let focus_composer_for_slash (m : Model.t) =
  let cur = (Drafts.current_draft m.drafts).text in
  let drafts =
    if String.equal (String.trim cur) "" then
      m.drafts |> Drafts.set_focus true |> Drafts.set_current_text "/"
    else Drafts.set_focus true m.drafts
  in
  ({ m with nav = { m.nav with filter_focused = false }; drafts }, [])

let board_work_keeper (m : Model.t) =
  if Model.sidebar_has_focus m then None else active_keeper_for_tab Nav.Keeper_work_sandbox m

let board_recovery_keeper (m : Model.t) =
  Option.bind (board_work_keeper m) (fun keeper ->
    if Board_recovery.shown ~keeper m.knowledge.board_recovery then Some keeper else None)

let set_board_recovery (m : Model.t) board_recovery =
  { m with knowledge = { m.knowledge with board_recovery } }

let request_keeper_interrupt ?(from_escape = false) ~now ~keeper ~target
    (m : Model.t) =
  let fleet0, drafts =
    match target with
    | `Turn_token interrupt_token ->
        (Fleet_store.mark_turn_interrupting ~keeper ~interrupt_token m.fleet, m.drafts)
    | `Operation_id operation_id ->
        ( Fleet_store.set_operation_interrupting ~keeper ~operation_id
            ~interrupting:true m.fleet
        , Drafts.set_operation_interrupting ~now ~keeper ~operation_id
            ~interrupting:true m.drafts )
  in
  let fleet =
    if not from_escape then fleet0
    else
      match target with
      | `Turn_token interrupt_token ->
          Fleet_store.mark_esc_interrupt_attempted_turn ~keeper ~interrupt_token
            fleet0
      | `Operation_id operation_id ->
          Fleet_store.mark_esc_interrupt_attempted_op ~keeper ~operation_id
            fleet0
  in
  ( Model.with_toast ~now ~level:Model.Toast_warning
      (Say.make
         ~ko:("키퍼 턴 중단 요청 전송: " ^ keeper)
         ~en:("Interrupt requested for keeper turn: " ^ keeper))
      { m with fleet; drafts }
  , [
      Cmd.Http_post
        {
          epoch = m.epoch;
          req = Cmd.Post_keeper_turn_interrupt { keeper; target };
        };
    ] )

let expected_ws_pair (m : Model.t) =
  Option.map
    (fun (ws : Wire_work.expected_workspace) -> (ws.base_path, ws.masc_root))
    (Update_nav.expected_workspace_of m)

let dispatch_keeper_lifecycle ~now ~op ~toast ~include_expected_workspace
    (m : Model.t) keeper =
  let expected_workspace =
    if include_expected_workspace then expected_ws_pair m else None
  in
  let req_seq, m1 = Model.next_keeper_lifecycle_seq m in
  ( Model.with_toast ~now ~level:Model.Toast_info toast m1
  , [
      Cmd.Http_post
        {
          epoch = m1.epoch;
          req =
            Cmd.Post_keeper_lifecycle
              {
                keeper;
                op;
                expected_workspace;
                req_seq;
                modal_submission_id = None;
              };
        };
    ] )

let dispatch_keeper_boot ~now ~name (m : Model.t) =
  dispatch_keeper_lifecycle ~now ~op:Wire_fleet.Keeper_boot
    ~toast:
      (Say.make
         ~ko:(Printf.sprintf "%s 온라인 부팅 요청 전송..." name)
         ~en:(Printf.sprintf "Booting %s online..." name))
    ~include_expected_workspace:true m name

let dispatch_keeper_wakeup ~now ~name (m : Model.t) =
  dispatch_keeper_lifecycle ~now ~op:Wire_fleet.Keeper_wakeup
    ~toast:
      (Say.make
         ~ko:(Printf.sprintf "%s 깨우기 요청 전송..." name)
         ~en:(Printf.sprintf "Waking %s..." name))
    ~include_expected_workspace:true m name

let dispatch_keeper_pause ~now ~name (m : Model.t) =
  dispatch_keeper_lifecycle ~now ~op:Wire_fleet.Keeper_pause
    ~toast:
      (Say.make
         ~ko:(Printf.sprintf "%s 일시정지 요청 전송..." name)
         ~en:(Printf.sprintf "Pausing %s..." name))
    ~include_expected_workspace:true m name

let dispatch_keeper_resume ~now ~name (m : Model.t) =
  let operator_operation_id, m1 =
    Model.get_or_create_resume_op_id ~keeper:name m
  in
  dispatch_keeper_lifecycle ~now
    ~op:(Wire_fleet.Keeper_resume { operator_operation_id })
    ~toast:
      (Say.make
         ~ko:(Printf.sprintf "%s 재개(온라인) 요청 전송..." name)
         ~en:(Printf.sprintf "Resuming %s online..." name))
    ~include_expected_workspace:true m1 name

let dispatch_keeper_shutdown ~now ~name (m : Model.t) =
  let m_cleared = { m with keeper_stop_armed = None } in
  dispatch_keeper_lifecycle ~now ~op:Wire_fleet.Keeper_shutdown
    ~toast:
      (Say.make
         ~ko:(Printf.sprintf "%s 중지(오프라인) 요청 전송..." name)
         ~en:(Printf.sprintf "Shutting down %s..." name))
    ~include_expected_workspace:true m_cleared name

let dispatch_keeper_smart_wake ~now ~name (m : Model.t) =
  match Fleet_store.find_keeper ~name m.fleet with
  | Some k when k.paused -> dispatch_keeper_resume ~now ~name m
  | Some k when not k.keepalive_running -> dispatch_keeper_boot ~now ~name m
  | Some _ -> dispatch_keeper_wakeup ~now ~name m
  | None -> dispatch_keeper_boot ~now ~name m

let dispatch_keeper_up ~now ~name (m : Model.t) =
  match Fleet_store.find_keeper ~name m.fleet with
  | Some k when k.paused -> dispatch_keeper_resume ~now ~name m
  | Some _ | None -> dispatch_keeper_boot ~now ~name m

let resolve_slash_lifecycle_keeper (m : Model.t) (arg : string option) =
  match arg with
  | Some raw ->
      let trimmed = String.trim raw in
      if String.equal trimmed "" then Model.target_keeper_for_lifecycle m
      else Some trimmed
  | None -> Model.target_keeper_for_lifecycle m

let missing_lifecycle_keeper_usage ~now ~cmd (m : Model.t) =
  ( Model.with_toast ~now ~level:Model.Toast_warning
      (Say.make
         ~ko:
           (Printf.sprintf
              "사용법: %s <keeper> (또는 키퍼를 선택한 뒤 실행)" cmd)
         ~en:(Printf.sprintf "Usage: %s <keeper> (or select a Keeper first)" cmd))
      m
  , [] )

let tools_mode_toast = function
  | Slash.Tools_compact ->
      Say.make ~ko:"도구: 축약" ~en:"Tools: compact"
  | Slash.Tools_results ->
      Say.make ~ko:"도구: 결과 펼침" ~en:"Tools: results"
  | Slash.Tools_full ->
      Say.make ~ko:"도구: 전체 펼침" ~en:"Tools: full"

let finalize_tools_mode_change ~now ~prev_mode (m : Model.t) =
  let allow_next_page =
    Slash.equal_tools_mode prev_mode Slash.Tools_results
    && Slash.equal_tools_mode m.fleet.chat_tools_mode Slash.Tools_full
  in
  let m =
    Model.with_toast ~now ~level:Model.Toast_info
      (tools_mode_toast m.fleet.chat_tools_mode) m
  in
  View_fetches.hydrate_chat_tool_results ~allow_next_page m

let apply_slash_tools ~now mode_opt (m : Model.t) =
  let prev_mode = m.fleet.chat_tools_mode in
  let fleet =
    match mode_opt with
    | None -> Fleet_store.cycle_tools_mode m.fleet
    | Some mode -> Fleet_store.set_tools_mode mode m.fleet
  in
  finalize_tools_mode_change ~now ~prev_mode { m with fleet }

let apply_toggle_turn_details ~now (m : Model.t) =
  let prev_mode = m.fleet.chat_tools_mode in
  let fleet = Fleet_store.toggle_turn_details m.fleet in
  finalize_tools_mode_change ~now ~prev_mode { m with fleet }

let rec execute_slash ~now (m : Model.t) cmd =
  match cmd with
  | Slash.Discord_reply ->
      let warn ~ko ~en =
        (Model.with_toast ~now ~level:Model.Toast_warning (Say.make ~ko ~en) m, [])
      in
      (match (viewed_keeper_name m, Update_nav.expected_workspace_of m) with
       | Some keeper, Some workspace when Model.is_in_keeper_chat m ->
           let sources = Update_nav.discord_sources_in_history ~keeper m in
           if sources = [] then
             warn ~ko:"불러온 채팅에 답장할 수 있는 Discord 원본이 없습니다"
               ~en:"No replyable Discord messages in loaded history"
           else
             Update_nav.open_palette m
               (Model.Palette_discord_replies { epoch = m.epoch; workspace; sources })
       | Some _, None when Model.is_in_keeper_chat m ->
           warn ~ko:"워크스페이스를 확인하는 중입니다" ~en:"Waiting for workspace identity"
       | _ ->
           warn ~ko:"Keeper 채팅에서 /discord-reply를 실행하세요"
             ~en:"Run /discord-reply in Keeper chat")
  | Slash.Pulse -> Update_nav.switch_workspace m Nav.Pulse
  | Slash.Work -> Update_nav.switch_workspace m Nav.Work
  | Slash.Knowledge -> Update_nav.switch_workspace m Nav.Knowledge
  | Slash.Keepers -> Update_nav.switch_workspace m Nav.Keepers
  | Slash.Runtime -> Update_nav.switch_workspace m Nav.Runtime
  | Slash.Infra -> Update_nav.switch_workspace m Nav.Infra
  | Slash.Keeper None -> Update_nav.open_palette m Model.Palette_keepers
  | Slash.Keeper (Some name) ->
      Update_nav.jump_to_keeper ~preserve_return:false ~tab:Nav.Keeper_chat m
        name
  | Slash.Model None -> Update_nav.open_palette m Model.Palette_models
  | Slash.Model (Some runtime_id) -> apply_model_selection ~now ~runtime_id m
  | Slash.Config None -> Update_nav.open_global_settings m
  | Slash.Config (Some query) ->
      Update_nav.open_global_settings ~search_query:query m
  | Slash.Incidents ->
      let incidents =
        m.incidents |> Incidents.reset_view |> Incidents.mark_all_read
      in
      Update_nav.open_overlay { m with incidents } Nav.Incidents
  | Slash.Jump -> Update_nav.teleport_blocked ~now m
  | Slash.Voice -> Update_nav.toggle_voice ~now m
  | Slash.Btw prompt -> Update_nav.start_btw_query ~now ~prompt m
  | Slash.Wake arg -> (
      match resolve_slash_lifecycle_keeper m arg with
      | Some name -> dispatch_keeper_smart_wake ~now ~name m
      | None -> missing_lifecycle_keeper_usage ~now ~cmd:"/wake" m)
  | Slash.Up arg -> (
      match resolve_slash_lifecycle_keeper m arg with
      | Some name -> dispatch_keeper_up ~now ~name m
      | None -> missing_lifecycle_keeper_usage ~now ~cmd:"/up" m)
  | Slash.Resume arg -> (
      match resolve_slash_lifecycle_keeper m arg with
      | Some name -> dispatch_keeper_resume ~now ~name m
      | None -> missing_lifecycle_keeper_usage ~now ~cmd:"/resume" m)
  | Slash.Pause arg -> (
      match resolve_slash_lifecycle_keeper m arg with
      | Some name -> dispatch_keeper_pause ~now ~name m
      | None -> missing_lifecycle_keeper_usage ~now ~cmd:"/pause" m)
  | Slash.Down arg -> (
      match resolve_slash_lifecycle_keeper m arg with
      | Some name -> dispatch_keeper_shutdown ~now ~name m
      | None -> missing_lifecycle_keeper_usage ~now ~cmd:"/down" m)
  | Slash.Queue ->
      Update_nav.open_overlay m (Nav.Queue_context Nav.Drawer_queue)
  | Slash.Context ->
      Update_nav.open_overlay m (Nav.Queue_context Nav.Drawer_context)
  | Slash.Ctl { action; target } -> (
      let resolve_keeper () =
        match target with
        | Some t when not (String.equal (String.trim t) "") ->
            Some (String.trim t)
        | Some _ | None -> Model.target_keeper m
      in
      let expected_ws () =
        Option.map
          (fun (ws : Wire_common.workspace_identity) ->
            {
              Wire_work.base_path = ws.base_path;
              masc_root = ws.masc_root;
            })
          m.server_identity.workspace
      in
      let no_keeper () =
        ( Model.with_toast ~now ~level:Model.Toast_warning
            (Say.make ~ko:"대상 키퍼를 먼저 선택하거나 이름을 입력하세요"
               ~en:"Select a target keeper or pass keeper name")
            m
        , [] )
      in
      let no_workspace () =
        ( Model.with_toast ~now ~level:Model.Toast_warning
            (Say.make ~ko:"서버 워크스페이스 정보가 아직 로드되지 않았습니다"
               ~en:"Server workspace identity not loaded yet")
            m
        , [] )
      in
      match action with
      | Slash.Ctl_boot -> (
          match resolve_keeper () with
          | None -> no_keeper ()
          | Some keeper ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make ~ko:("키퍼 부팅 요청 중: " ^ keeper)
                     ~en:("Booting keeper: " ^ keeper))
                  m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_keeper_control_lifecycle
                          { keeper; action = `Boot; expected_workspace = None };
                    };
                ] ))
      | Slash.Ctl_up -> (
          match resolve_keeper () with
          | None -> no_keeper ()
          | Some keeper ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make ~ko:("키퍼 시작(up) 요청 중: " ^ keeper)
                     ~en:("Starting keeper (up): " ^ keeper))
                  m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_keeper_control_lifecycle
                          {
                            keeper;
                            action = `Up;
                            expected_workspace = expected_ws ();
                          };
                    };
                ] ))
      | Slash.Ctl_shutdown -> (
          match resolve_keeper () with
          | None -> no_keeper ()
          | Some keeper ->
              Update_nav.open_inline_modal m
                (Nav.Keeper_control_confirm
                   { keeper; action = Nav.Keeper_act_shutdown }))
      | Slash.Ctl_reset -> (
          match resolve_keeper () with
          | None -> no_keeper ()
          | Some keeper ->
              Update_nav.open_inline_modal m
                (Nav.Keeper_control_confirm
                   { keeper; action = Nav.Keeper_act_reset }))
      | Slash.Ctl_clear -> (
          match resolve_keeper () with
          | None -> no_keeper ()
          | Some keeper ->
              Update_nav.open_inline_modal m (Nav.Keeper_clear_form keeper))
      | Slash.Ctl_pause -> (
          match (resolve_keeper (), expected_ws ()) with
          | None, _ -> no_keeper ()
          | Some _, None -> no_workspace ()
          | Some keeper, Some expected_workspace ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make ~ko:("키퍼 일시 정지 요청 중: " ^ keeper)
                     ~en:("Pausing keeper: " ^ keeper))
                  m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_keeper_directive
                          {
                            keeper;
                            directive = Wire_keeper_context.Directive_pause;
                            expected_workspace;
                          };
                    };
                ] ))
      | Slash.Ctl_wakeup -> (
          match (resolve_keeper (), expected_ws ()) with
          | None, _ -> no_keeper ()
          | Some _, None -> no_workspace ()
          | Some keeper, Some expected_workspace ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make ~ko:("키퍼 기상 요청 중: " ^ keeper)
                     ~en:("Waking keeper: " ^ keeper))
                  m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_keeper_directive
                          {
                            keeper;
                            directive = Wire_keeper_context.Directive_wakeup;
                            expected_workspace;
                          };
                    };
                ] ))
      | Slash.Ctl_resume -> (
          match (resolve_keeper (), expected_ws ()) with
          | None, _ -> no_keeper ()
          | Some _, None -> no_workspace ()
          | Some keeper, Some expected_workspace ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make ~ko:("키퍼 재개 요청 중: " ^ keeper)
                     ~en:("Resuming keeper: " ^ keeper))
                  m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_keeper_directive
                          {
                            keeper;
                            directive =
                              Wire_keeper_context.Directive_resume
                                { operator_operation_id = Random_id.uuid_v7 () };
                            expected_workspace;
                          };
                    };
                ] ))
      | Slash.Ctl_checkpoints -> (
          match resolve_keeper () with
          | None -> no_keeper ()
          | Some keeper ->
              let keeper_context =
                Keeper_context_store.set_subtab ~keeper
                  Keeper_context_store.Ctx_flow m.keeper_context
              in
              let m1, cmds1 =
                Update_nav.jump_to_keeper ~preserve_return:true
                  ~tab:Nav.Keeper_trace
                  ~trace_section:Keeper_context_store.Trace_context
                  { m with keeper_context } keeper
              in
              ( m1
              , cmds1
                @ [
                    Cmd.Http_get
                      {
                        epoch = m1.epoch;
                        req = Cmd.Get_keeper_checkpoints { keeper };
                      };
                  ] ))
      | Slash.Ctl_purge_preview -> (
          match resolve_keeper () with
          | None -> no_keeper ()
          | Some keeper ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make ~ko:("체크포인트 정리 미리보기 계산 중: " ^ keeper)
                     ~en:("Previewing checkpoint purge: " ^ keeper))
                  m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_keeper_checkpoints
                          { keeper; action = `Preview_purge };
                    };
                ] ))
      | Slash.Ctl_purge_apply -> (
          match resolve_keeper () with
          | None -> no_keeper ()
          | Some keeper ->
              Update_nav.open_inline_modal m
                (Nav.Keeper_control_confirm
                   { keeper; action = Nav.Keeper_act_apply_purge }))
      | Slash.Ctl_delete_history -> (
          match resolve_keeper () with
          | None -> no_keeper ()
          | Some keeper ->
              Update_nav.open_inline_modal m
                (Nav.Keeper_control_confirm
                   { keeper; action = Nav.Keeper_act_delete_history }))
      | Slash.Ctl_note -> (
          match Model.target_keeper m with
          | None -> no_keeper ()
          | Some keeper -> (
              match target with
              | Some txt when not (String.equal (String.trim txt) "") ->
                  let text = String.trim txt in
                  if String.length text > 4096 then
                    ( Model.with_toast ~now ~level:Model.Toast_warning
                        (Say.make ~ko:"운영자 노트는 4096바이트를 초과할 수 없습니다"
                           ~en:"Operator note cannot exceed 4096 bytes")
                        m
                    , [] )
                  else
                    Model.with_toast ~now ~level:Model.Toast_info
                        (Say.make ~ko:("운영자 노트 저장 중: " ^ keeper)
                           ~en:("Saving operator note for " ^ keeper))
                        m
                    |> Update_nav.post_keeper_operator_note ~keeper ~text ~modal_submission_id:None
              | Some _ | None ->
                  let m_open, cmds =
                    Update_nav.open_inline_modal m
                      (Nav.Keeper_operator_note_form keeper)
                  in
                  let read_id, m_open = Model.next_modal_submission_id m_open in
                  let inline_modal =
                    Option.map
                      (fun (modal : Model.inline_modal_state) ->
                        { modal with note_prefill_id = Some read_id })
                      m_open.inline_modal
                  in
                  ( { m_open with inline_modal }
                  , cmds
                    @ [
                        Cmd.Http_get
                          {
                            epoch = m.epoch;
                            req =
                              Cmd.Get_keeper_operator_note
                                { keeper; modal_prefill_id = Some read_id };
                          };
                      ] )))
      | Slash.Ctl_run_next -> (
          match Model.target_keeper m with
          | None -> no_keeper ()
          | Some keeper -> (
              let req_id_opt =
                match target with
                | Some rid when not (String.equal (String.trim rid) "") ->
                    Some (String.trim rid)
                | Some _ | None ->
                    Drafts.pending_txs_for_keeper ~keeper m.drafts
                    |> List.find_map (fun (tx : Drafts.pending_message) ->
                           match tx.state with
                           | Drafts.Queued -> tx.operation_id
                           | Drafts.Sending
                           | Drafts.Pending_processing
                           | Drafts.Confirming_delivery
                           | Drafts.Interrupting
                           | Drafts.Delivered
                           | Drafts.No_operation_record
                           | Drafts.Failed_retryable _ ->
                               None)
              in
              match req_id_opt with
              | None ->
                  ( Model.with_toast ~now ~level:Model.Toast_warning
                      (Say.make
                         ~ko:"우선 실행할 서버 대기 요청 ID가 없습니다 (/ctl run-next <operation_id>)"
                         ~en:"No server-queued operation found (pass /ctl run-next <operation_id>)")
                      m
                  , [] )
              | Some request_id ->
                  let interrupt_token =
                    Option.map
                      (fun (t : Wire_fleet.active_turn) -> t.interrupt_token)
                      (Fleet_store.active_turn_for ~keeper m.fleet)
                  in
                  ( Model.with_toast ~now ~level:Model.Toast_info
                      (Say.make
                         ~ko:("우선 실행(run-next) 요청 중: " ^ request_id)
                         ~en:("Prioritizing queued message: " ^ request_id))
                      m
                  , [
                      Cmd.Http_post
                        {
                          epoch = m.epoch;
                          req =
                            Cmd.Post_keeper_run_next
                              { keeper; request_id; interrupt_token };
                        };
                    ] ))))
  | Slash.Gate gate_act -> (
      let ws_opt =
        Option.map
          (fun (w : Wire_common.workspace_identity) : Wire_work.expected_workspace
            -> { base_path = w.base_path; masc_root = w.masc_root })
          m.server_identity.workspace
      in
      let parse_mode_or_err raw ~external_lane =
        match Wire_work.gate_mode_of_string raw with
        | None ->
            ( Model.with_toast ~now ~level:Model.Toast_error
                (Say.make
                   ~ko:("잘못된 Gate 모드: " ^ raw ^ " (manual|auto_judge|always_allow)")
                   ~en:("Invalid Gate mode: " ^ raw ^ " (manual|auto_judge|always_allow)"))
                m
            , [] )
        | Some mode ->
            let work =
              { m.work with gate_snapshot = Observed.mark_stale m.work.gate_snapshot }
            in
            ( Model.with_toast ~now ~level:Model.Toast_info
                (Say.make
                   ~ko:(Printf.sprintf "%s Gate 모드 변경 중: %s"
                          (if external_lane then "외부 서비스" else "워크스페이스")
                          (Wire_work.gate_mode_to_string mode))
                   ~en:(Printf.sprintf "Updating %s Gate mode: %s"
                          (if external_lane then "external" else "workspace")
                          (Wire_work.gate_mode_to_string mode)))
                { m with work }
            , [
                Cmd.Http_post
                  {
                    epoch = m.epoch;
                    req = Cmd.Post_gate_mode { external_lane; mode };
                  };
              ] )
      in
      match gate_act with
      | Slash.Gate_mode_set raw -> parse_mode_or_err raw ~external_lane:false
      | Slash.Gate_external_mode_set raw ->
          parse_mode_or_err raw ~external_lane:true
      | Slash.Gate_rule_delete id ->
          let work =
            { m.work with gate_snapshot = Observed.mark_stale m.work.gate_snapshot }
          in
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:("Always-Approve 규칙 삭제 중: " ^ id)
                 ~en:("Deleting Always-Approve rule: " ^ id))
              { m with work }
          , [
              Cmd.Http_post
                { epoch = m.epoch; req = Cmd.Post_gate_rule_delete { id } };
            ] )
      | Slash.Gate_approve_always id ->
          let work =
            { m.work with gate_snapshot = Observed.mark_stale m.work.gate_snapshot }
          in
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:("게이트 승인 + Always-Approve 규칙 저장 중: " ^ id)
                 ~en:("Approving & saving Always-Approve rule: " ^ id))
              { m with work }
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req =
                    Cmd.Post_gate_resolution_policy
                      {
                        id;
                        approved = true;
                        reason = None;
                        remember_rule = true;
                        rule_expires_at = None;
                        expected_workspace = ws_opt;
                      };
                };
            ] )
      | Slash.Gate_retry id -> (
          match Work_store.retry_meta_for_id ~id m.work with
          | None ->
              ( Model.with_toast ~now ~level:Model.Toast_warning
                  (Say.make
                     ~ko:("재시도 메타데이터가 없는 승인 ID입니다 (먼저 수신함 새로고침): " ^ id)
                     ~en:("No retry metadata for approval ID (refresh Inbox first): " ^ id))
                  m
              , [ Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_gate_pending } ] )
          | Some meta ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make ~ko:("Auto-Judge 재시도 요청 중: " ^ id)
                     ~en:("Retrying Auto-Judge for " ^ id))
                  m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_gate_retry { meta; expected_workspace = ws_opt };
                    };
                ] ))
      | Slash.Gate_keeper_mode_set { keeper; mode = raw_mode } -> (
          match Wire_work.keeper_tool_approval_mode_of_string raw_mode with
          | None ->
              ( Model.with_toast ~now ~level:Model.Toast_error
                  (Say.make
                     ~ko:("잘못된 키퍼 승인 모드: " ^ raw_mode ^ " (auto|yolo)")
                     ~en:("Invalid keeper approval mode: " ^ raw_mode ^ " (auto|yolo)"))
                  m
              , [] )
          | Some mode ->
              let work =
                {
                  m.work with
                  tool_approval_modes =
                    Observed.mark_stale m.work.tool_approval_modes;
                }
              in
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:(Printf.sprintf "키퍼 승인 모드 설정 중: %s=%s" keeper
                            (Wire_work.keeper_tool_approval_mode_to_string mode))
                     ~en:(Printf.sprintf "Setting keeper approval mode: %s=%s"
                            keeper
                            (Wire_work.keeper_tool_approval_mode_to_string mode)))
                  { m with work }
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req = Cmd.Post_keeper_tool_approval_mode { keeper; mode };
                    };
                ] ))
      | Slash.Gate_ack_uncertain { keeper; consume_id } ->
          let work =
            {
              m.work with
              late_approval_attempts =
                Observed.mark_stale m.work.late_approval_attempts;
            }
          in
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:("불확실 늦은 승인 확인 요청 중: " ^ consume_id)
                 ~en:("Acknowledging uncertain late approval: " ^ consume_id))
              { m with work }
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req = Cmd.Post_hitl_ack_uncertain { keeper; consume_id };
                };
            ] )
      | Slash.Gate_restore_late ->
          let work =
            {
              m.work with
              late_approval_attempts =
                Observed.mark_stale m.work.late_approval_attempts;
            }
          in
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:"늦은 승인 저널 복원 요청 중…"
                 ~en:"Restoring late-approval journal…")
              { m with work }
          , [
              Cmd.Http_post
                { epoch = m.epoch; req = Cmd.Post_hitl_late_approval_restore };
            ] ))
  | Slash.Exec { tool_name; args_json } -> (
      let raw_args =
        match args_json with
        | Some s when not (String.equal (String.trim s) "") -> String.trim s
        | Some _ | None -> "{}"
      in
      match Yojson.Safe.from_string raw_args with
      | `Assoc _ as arguments ->
          let runtime, rpc_id = Runtime_store.next_mcp_rpc_id m.runtime in
          let runtime =
            { runtime with mcp_call_result = Observed.loading ~since_ns:now }
          in
          let m_exec = { m with runtime } in
          let insp = Nav.Tool_inspector tool_name in
          let m_dive, dive_cmds =
            if Option.equal Nav.equal_inspector (Model.active_inspector m_exec) (Some insp)
            then (m_exec, [])
            else Update_nav.open_inspector m_exec insp
          in
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:("MCP 도구 실행 중: " ^ tool_name)
                 ~en:("Executing MCP tool: " ^ tool_name))
              m_dive
          , dive_cmds
            @ [
                Cmd.Http_post
                  {
                    epoch = m.epoch;
                    req =
                      Cmd.Post_mcp_tools_call { rpc_id; tool_name; arguments };
                  };
              ] )
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
          ( Model.with_toast ~now ~level:Model.Toast_error
              (Say.make
                 ~ko:"/exec 인자는 JSON 객체({ ... })여야 합니다"
                 ~en:"/exec arguments must be a JSON object ({ ... })")
              m
          , [] )
      | exception Yojson.Json_error msg ->
          ( Model.with_toast ~now ~level:Model.Toast_error
              (Say.make
                 ~ko:("/exec JSON 파싱 오류: " ^ msg)
                 ~en:("/exec JSON parse error: " ^ msg))
              m
          , [] ))
  | Slash.Skill act -> (
      let prefill_field ~key ~value (m_in : Model.t) =
        match m_in.inline_modal with
        | None -> m_in
        | Some modal ->
            let fields =
              List.map
                (fun (f : Model.modal_form_field) ->
                  if String.equal f.key key then { f with value } else f)
                modal.fields
            in
            { m_in with inline_modal = Some { modal with fields } }
      in
      match act with
      | Slash.Skill_refresh ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:"스킬 카탈로그 새로고침 중…"
                 ~en:"Refreshing skill catalog…")
              m
          , [ Cmd.Http_post { epoch = m.epoch; req = Cmd.Post_skills_refresh } ]
          )
      | Slash.Skill_new ->
          let m1, cmds = Update_nav.open_inline_modal m Nav.Skill_create_form in
          let m2 =
            match Observed.to_option m.runtime.skill_editor_sources with
            | Some (first :: _) -> prefill_field ~key:"source_id" ~value:first m1
            | Some [] | None -> m1
          in
          (m2, cmds)
      | Slash.Skill_read ref_s ->
          Update_nav.open_inspector m (Nav.Skill_inspector ref_s)
      | Slash.Skill_edit ref_s -> (
          match Runtime_store.skill_mutation_target ~reference:ref_s m.runtime with
          | Some (Runtime_store.Loaded_skill { access = Wire_runtime.Skill_read_only; _ }) ->
              ( Model.with_toast ~now ~level:Model.Toast_warning
                  (Say.make
                     ~ko:("읽기 전용 스킬 소스입니다 — 편집할 수 없습니다: " ^ ref_s)
                     ~en:("Skill source is read-only — cannot edit: " ^ ref_s))
                  m
              , [] )
          | Some (Runtime_store.Loaded_skill ({ access = Wire_runtime.Skill_read_write; _ } as loaded)) ->
              let m1, cmds =
                Update_nav.open_inline_modal m
                  (Nav.Skill_edit_form { reference = loaded.reference })
              in
              ( prefill_field ~key:"source_text"
                  ~value:loaded.source_text m1
              , cmds )
          | Some (Runtime_store.Catalog_skill _) | None ->
              let m1, cmds =
                Update_nav.open_inspector m (Nav.Skill_inspector ref_s)
              in
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:"스킬 원문 로드 중 — 로드 후 [e]로 편집하세요"
                     ~en:"Loading skill source — press [e] once loaded to edit")
                  m1
              , cmds ))
      | Slash.Skill_delete ref_s -> (
          match Runtime_store.skill_mutation_target ~reference:ref_s m.runtime with
          | Some (Runtime_store.Loaded_skill { access = Wire_runtime.Skill_read_only; _ }) ->
              ( Model.with_toast ~now ~level:Model.Toast_warning
                  (Say.make
                     ~ko:("읽기 전용 스킬 소스입니다 — 삭제할 수 없습니다: " ^ ref_s)
                     ~en:("Skill source is read-only — cannot delete: " ^ ref_s))
                  m
              , [] )
          | Some (Runtime_store.Loaded_skill { access = Wire_runtime.Skill_read_write; _ }
                 | Runtime_store.Catalog_skill _) | None ->
              Update_nav.open_inline_modal m
                (Nav.Skill_delete_confirm { reference = ref_s })))
  | Slash.Prompt act -> (
      let prefill_field ~key ~value (m_in : Model.t) =
        match m_in.inline_modal with
        | None -> m_in
        | Some modal ->
            let fields =
              List.map
                (fun (f : Model.modal_form_field) ->
                  if String.equal f.key key then { f with value } else f)
                modal.fields
            in
            { m_in with inline_modal = Some { modal with fields } }
      in
      match act with
      | Slash.Prompt_set { key; value = None } ->
          let m1, cmds =
            Update_nav.open_inline_modal m (Nav.Prompt_override_form { key })
          in
          let current_val =
            match Observed.to_option m.runtime.prompts_catalog with
            | Some cat -> (
                match
                  List.find_opt
                    (fun (p : Wire_runtime.prompt_item) ->
                      String.equal p.key key)
                    cat.prompts
                with
                | Some p -> Some p.effective
                | None -> None)
            | None -> None
          in
          let m2 =
            match current_val with
            | Some v ->
                prefill_field ~key:"value" ~value:v m1
            | None -> m1
          in
          (m2, cmds)
      | Slash.Prompt_set { key; value = Some v } ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:("프롬프트 오버라이드 저장 중: " ^ key)
                 ~en:("Saving prompt override: " ^ key))
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req = Cmd.Post_prompt_override { key; value = Some v };
                };
            ] )
      | Slash.Prompt_clear key ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:("프롬프트 오버라이드 해제 중: " ^ key)
                 ~en:("Clearing prompt override: " ^ key))
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req = Cmd.Post_prompt_override { key; value = None };
                };
            ] )
      | Slash.Param_set { key; value_raw = None } ->
          let m1, cmds =
            Update_nav.open_inline_modal m
              (Nav.Runtime_param_set_form { param_key = key })
          in
          let cur_val =
            match Observed.to_option m.runtime.runtime_params with
            | Some rp -> (
                match
                  List.find_opt
                    (fun (p : Wire_runtime.runtime_param_item) ->
                      String.equal p.key key)
                    rp.parameters
                with
                | Some p -> Some (Yojson.Safe.to_string p.current)
                | None -> None)
            | None -> None
          in
          let m2 =
            match cur_val with
            | Some v -> prefill_field ~key:"value" ~value:v m1
            | None -> m1
          in
          (m2, cmds)
      | Slash.Param_set { key; value_raw = Some raw } ->
          let value =
            try Yojson.Safe.from_string (String.trim raw)
            with Yojson.Json_error _ -> `String raw
          in
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:("런타임 파라미터 설정 중: " ^ key)
                 ~en:("Setting runtime param: " ^ key))
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req = Cmd.Post_runtime_param_set { param_key = key; value };
                };
            ] )
      | Slash.Param_clear key ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:("런타임 파라미터 기본값 복원 중: " ^ key)
                 ~en:("Clearing runtime param: " ^ key))
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req = Cmd.Post_runtime_param_clear { param_key = key };
                };
            ] ))
  | Slash.Preset act -> (
      let jump_to_presets (m_in : Model.t) =
        let nav =
          {
            m_in.nav with
            workspace = Nav.Runtime;
            inspector = None;
            inspector_return = None;
            workspace_return_stack = [];
            overlay = None;
            pane_index = 0;
            pre_zoom_pane_index = None;
            zoomed = false;
            inspector_scroll_offset = 0;
            keeper_detail_scroll_offset = 0;
            json_scroll_offset = 0;
          }
        in
        let runtime =
          m_in.runtime
          |> Runtime_store.set_tab Nav.Runtime_tools_usage
          |> Runtime_store.set_tools_subview Runtime_store.Tools_prompts_presets
          |> Runtime_store.set_prompts_presets_section Runtime_store.Sec_presets
        in
        let next = { m_in with nav; runtime; ask_modal = None } in
        (next, View_fetches.fetches_for_current_view next)
      in
      match act with
      | Slash.Preset_list -> jump_to_presets m
      | Slash.Preset_show name ->
          let nav =
            {
              m.nav with
              workspace = Nav.Runtime;
              inspector = None;
              inspector_return = None;
              workspace_return_stack = [];
              overlay = None;
              pane_index = 0;
              pre_zoom_pane_index = None;
              zoomed = false;
              inspector_scroll_offset = 0;
              keeper_detail_scroll_offset = 0;
              json_scroll_offset = 0;
            }
          in
          let runtime =
            m.runtime
            |> Runtime_store.set_tab Nav.Runtime_tools_usage
            |> Runtime_store.set_tools_subview
                 Runtime_store.Tools_prompts_presets
            |> Runtime_store.select_preset_by_name name
          in
          let next = { m with nav; runtime; ask_modal = None } in
          let vf = View_fetches.fetches_for_current_view next in
          let target_path = Wire_runtime.preset_show_path ~name in
          let already_fetching =
            List.exists
              (function
                | Cmd.Http_get { req; _ } ->
                    String.equal (Cmd.get_request_path req) target_path
                | Cmd.Http_post _
                | Cmd.Http_put _
                | Cmd.Http_delete _
                | Cmd.Http_post_stream _
                | Cmd.Batch _
                | Cmd.Sync_streams _
                | Cmd.Update_workspace_guard _
                | Cmd.Voice_cmd _
                | Cmd.Copy_clipboard _
                | Cmd.Render_memory_diagram _
                | Cmd.Cancel_memory_diagram
                | Cmd.Fetch_artifact_and_copy _
                | Cmd.Export_artifact _
                | Cmd.Open_dos_screen _
                | Cmd.Open_external_url _
                | Cmd.Open_editor_escape_hatch _
                | Cmd.Open_terminal_program _
                | Cmd.Start_local_server
                | Cmd.Restart_tui
                | Cmd.Quit _ ->
                    false)
              vf
          in
          let extra =
            if already_fetching then []
            else
              [ Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_preset_show { name } } ]
          in
          (next, vf @ extra)
      | Slash.Preset_save { name; description } ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:("프리셋 저장 중: " ^ name)
                 ~en:("Saving preset: " ^ name))
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req = Cmd.Post_preset_save { name; description };
                };
            ] )
      | Slash.Preset_create { name = None; _ } ->
          Update_nav.open_inline_modal m Nav.Preset_create_form
      | Slash.Preset_create { name = Some name; description } ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:("프리셋 생성 중: " ^ name)
                 ~en:("Creating preset: " ^ name))
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req = Cmd.Post_preset_create { name; description };
                };
            ] )
      | Slash.Preset_restore name ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:("프리셋 복원 중: " ^ name)
                 ~en:("Restoring preset: " ^ name))
              m
          , [
              Cmd.Http_post
                { epoch = m.epoch; req = Cmd.Post_preset_restore { name } };
            ] )
      | Slash.Preset_delete name ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:("프리셋 삭제 중: " ^ name)
                 ~en:("Deleting preset: " ^ name))
              m
          , [
              Cmd.Http_post
                { epoch = m.epoch; req = Cmd.Post_preset_delete { name } };
            ] ))
  | Slash.Lane act -> (
      match act with
      | Slash.Lane_create { lane; runtime_ids } ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:("레인 생성 중: " ^ lane) ~en:("Creating lane: " ^ lane))
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req =
                    Cmd.Post_runtime_routing_action
                      {
                        action = Wire_runtime.Route_create { lane; runtime_ids };
                        label =
                          Say.make ~ko:("레인 생성 완료: " ^ lane)
                            ~en:("Lane created: " ^ lane);
                      };
                };
            ] )
      | Slash.Lane_remove lane ->
          if Wire_runtime.is_named_routing_lane lane then
            open_named_lane_delete_modal m lane
          else
            (Model.with_toast ~now ~level:Model.Toast_warning
               (Say.make ~ko:"이 라우트는 삭제할 수 없습니다" ~en:"Only named lanes can be removed") m, [])
      | Slash.Lane_rename { lane; to_lane } ->
          if not (Wire_runtime.is_named_routing_lane lane && Wire_runtime.is_named_routing_lane to_lane) then
            (Model.with_toast ~now ~level:Model.Toast_warning
               (Say.make ~ko:"일반 레인 이름만 변경할 수 있습니다"
                  ~en:"Renaming requires two named lane IDs") m, [])
          else
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make
                 ~ko:(Printf.sprintf "레인 이름 변경 중: %s -> %s" lane to_lane)
                 ~en:(Printf.sprintf "Renaming lane: %s -> %s" lane to_lane))
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req =
                    Cmd.Post_runtime_routing_action
                      {
                        action = Wire_runtime.Route_rename { lane; to_lane };
                        label =
                          Say.make
                            ~ko:(Printf.sprintf "레인 이름 변경: %s -> %s" lane to_lane)
                            ~en:(Printf.sprintf "Lane renamed: %s -> %s" lane to_lane);
                      };
                };
            ] )
      | Slash.Lane_set { lane; runtime_ids } ->
          let expected_source_revision =
            match Observed.to_option m.runtime.runtime_config_raw with
            | Some meta -> Some meta.source_revision
            | None -> None
          in
          (match Wire_runtime.set_routing_action ~lane ~runtime_ids ~expected_source_revision with
          | Error detail -> (Model.with_toast ~now ~level:Model.Toast_warning (Say.literal detail) m, [])
          | Ok action ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:("레인 후보 업데이트 중: " ^ lane)
                 ~en:("Updating lane candidates: " ^ lane))
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req =
                    Cmd.Post_runtime_routing_action
                      {
                        action;
                        label =
                          Say.make ~ko:("레인 후보 업데이트: " ^ lane)
                            ~en:("Lane updated: " ^ lane);
                      };
                };
            ] ))
      | Slash.Lane_exact_append { lane_id; runtime_id } ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make
                 ~ko:(Printf.sprintf "Exact 슬롯 추가 중: %s + %s" lane_id runtime_id)
                 ~en:(Printf.sprintf "Appending exact slot: %s + %s" lane_id runtime_id))
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req =
                    Cmd.Post_runtime_routing_action
                      {
                        action =
                          Wire_runtime.Route_exact_append { lane_id; runtime_id };
                        label =
                          Say.make
                            ~ko:(Printf.sprintf "Exact 슬롯 추가: %s + %s" lane_id runtime_id)
                            ~en:(Printf.sprintf "Exact slot appended: %s + %s" lane_id runtime_id);
                      };
                };
            ] )
      | Slash.Lane_exact_drop { lane_id; runtime_id } ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make
                 ~ko:(Printf.sprintf "Exact 슬롯 제거 중: %s - %s" lane_id runtime_id)
                 ~en:(Printf.sprintf "Dropping exact slot: %s - %s" lane_id runtime_id))
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req =
                    Cmd.Post_runtime_routing_action
                      {
                        action =
                          Wire_runtime.Route_exact_drop { lane_id; runtime_id };
                        label =
                          Say.make
                            ~ko:(Printf.sprintf "Exact 슬롯 제거: %s - %s" lane_id runtime_id)
                            ~en:(Printf.sprintf "Exact slot dropped: %s - %s" lane_id runtime_id);
                      };
                };
            ] )
      | Slash.Lane_exact_move { lane_id; runtime_id; direction } ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make
                 ~ko:(Printf.sprintf "Exact 슬롯 이동 중: %s (%s)" lane_id runtime_id)
                 ~en:(Printf.sprintf "Moving exact slot: %s (%s)" lane_id runtime_id))
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req =
                    Cmd.Post_runtime_routing_action
                      {
                        action =
                          Wire_runtime.Route_exact_move
                            { lane_id; runtime_id; direction };
                        label =
                          Say.make
                            ~ko:(Printf.sprintf "Exact 슬롯 재정렬: %s (%s)" lane_id runtime_id)
                            ~en:(Printf.sprintf "Exact slot reordered: %s (%s)" lane_id runtime_id);
                      };
                };
            ] )
      | Slash.Lane_exact_replace { lane_id; runtime_id; replacement } ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make
                 ~ko:(Printf.sprintf "Exact 슬롯 교체 중: %s (%s -> %s)" lane_id runtime_id replacement)
                 ~en:(Printf.sprintf "Replacing exact slot: %s (%s -> %s)" lane_id runtime_id replacement))
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req =
                    Cmd.Post_runtime_routing_action
                      {
                        action =
                          Wire_runtime.Route_exact_replace
                            {
                              lane_id;
                              runtime_id;
                              replacement_runtime_id = replacement;
                            };
                        label =
                          Say.make
                            ~ko:(Printf.sprintf "Exact 슬롯 교체: %s (%s -> %s)" lane_id runtime_id replacement)
                            ~en:(Printf.sprintf "Exact slot replaced: %s (%s -> %s)" lane_id runtime_id replacement);
                      };
                };
            ] )
      | Slash.Lane_run_inspect run_id ->
          Update_nav.open_inspector m (Nav.Exact_run_inspector run_id)
      | Slash.Lane_quarantines keeper ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:("보드 주목 격리 조회 중: @" ^ keeper)
                 ~en:("Fetching board-attention quarantines: @" ^ keeper))
              m
          , [
              Cmd.Http_get
                {
                  epoch = m.epoch;
                  req = Cmd.Get_keeper_board_attention_quarantines { keeper };
                };
            ] )
      | Slash.Lane_quarantine_recover
          { keeper; partition_id; candidate_id; quarantine_id } ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make
                 ~ko:(Printf.sprintf "@%s 격리 복구 요청 중 (%s)…" keeper partition_id)
                 ~en:(Printf.sprintf "Recovering @%s quarantine (%s)…" keeper partition_id))
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req =
                    Cmd.Post_board_attention_quarantine_recovery
                      {
                        keeper;
                        partition_id;
                        candidate_id;
                        expected_quarantine_id = quarantine_id;
                      };
                };
            ] )
      | Slash.Lane_raw_preview -> (
          match Observed.to_option m.runtime.runtime_config_raw with
          | Some { source_text = Some source_text; _ } ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make ~ko:"runtime.toml 검증 미리보기 실행 중…"
                     ~en:"Validating runtime.toml preview…")
                  m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req = Cmd.Post_runtime_config_raw_preview { source_text };
                    };
                ] )
          | Some { source_text = None; _ } | None ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:"runtime.toml 원문 로드 중 — 로드 후 다시 /lane raw-preview를 실행하세요"
                     ~en:"Loading runtime.toml — run /lane raw-preview again once loaded")
                  m
              , [ Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_runtime_config_raw } ] )))
  | Slash.Addon act -> (
      match act with
      | Slash.Addon_attach { manifest_path; run_id; binding_json = None } ->
          open_addon_attach_modal ~manifest_path ~run_id m
      | Slash.Addon_attach
          { manifest_path; run_id; binding_json = Some raw_binding } -> (
          match Yojson.Safe.from_string raw_binding with
          | `Assoc _ as binding ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make ~ko:("애드온 연결 중: " ^ manifest_path)
                     ~en:("Attaching addon: " ^ manifest_path))
                  m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_lane_addon_attach
                          { manifest_path; run_id; binding; from_modal = false };
                    };
                ] )
          | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _
          | `List _ ->
              ( Model.with_toast ~now ~level:Model.Toast_error
                  (Say.make ~ko:"binding 인자는 JSON 객체여야 합니다"
                     ~en:"binding argument must be a JSON object")
                  m
              , [] )
          | exception Yojson.Json_error msg ->
              let clean = Chat_transcript.scrub_secrets_in_text msg in
              ( Model.with_toast ~now ~level:Model.Toast_error
                  (Say.make ~ko:("binding JSON 오류: " ^ clean)
                     ~en:("binding JSON error: " ^ clean))
                  m
              , [] ))
      | Slash.Addon_detach instance_id ->
          Update_nav.open_inline_modal m
            (Nav.Addon_detach_confirm { instance_id; title = instance_id })
      | Slash.Addon_observe instance_id ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:("애드온 관측 중: " ^ instance_id)
                 ~en:("Observing addon: " ^ instance_id))
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req = Cmd.Post_lane_addon_observe { instance_id };
                };
            ] )
      | Slash.Addon_retain instance_id ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:("애드온 리소스 인수 중: " ^ instance_id)
                 ~en:("Retaining addon: " ^ instance_id))
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req = Cmd.Post_lane_addon_retain { instance_id };
                };
            ] )
      | Slash.Addon_act { instance_id; action_json = None } ->
          Update_nav.open_inline_modal m
            (Nav.Addon_act_form
               { instance_id; expected_incarnation = instance_id })
      | Slash.Addon_act { instance_id; action_json = Some raw } -> (
          match Yojson.Safe.from_string raw with
          | `Assoc _ as action ->
              let runtime, request_id =
                Runtime_store.next_addon_request_id m.runtime
              in
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make ~ko:("애드온 액션 실행 중: " ^ instance_id)
                     ~en:("Running addon action: " ^ instance_id))
                  { m with runtime }
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_lane_addon_act
                          {
                            instance_id;
                            expected_incarnation = instance_id;
                            request_id;
                            action;
                          };
                    };
                ] )
          | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _
          | `List _ ->
              ( Model.with_toast ~now ~level:Model.Toast_error
                  (Say.make ~ko:"action은 JSON 객체여야 합니다"
                     ~en:"action must be a JSON object")
                  m
              , [] )
          | exception Yojson.Json_error msg ->
              let clean = Chat_transcript.scrub_secrets_in_text msg in
              ( Model.with_toast ~now ~level:Model.Toast_error
                  (Say.make ~ko:("action JSON 오류: " ^ clean)
                     ~en:("action JSON error: " ^ clean))
                  m
              , [] ))
      | Slash.Addon_evidence { instance_id; row_ids; keeper_name } ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:("애드온 증거 보존/전달 중: " ^ instance_id)
                 ~en:("Submitting addon evidence: " ^ instance_id))
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req =
                    Cmd.Post_lane_addon_evidence
                      {
                        instance_id;
                        row_ids;
                        keeper_name;
                        broadcast = false;
                        request_id = None;
                      };
                };
            ] )
      | Slash.Addon_decl_read source_path ->
          let runtime =
            { m.runtime with pending_addon_decl_path = Some source_path }
          in
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:("애드온 선언 읽는 중: " ^ source_path)
                 ~en:("Reading addon declaration: " ^ source_path))
              { m with runtime }
          , [
              Cmd.Http_get
                {
                  epoch = m.epoch;
                  req = Cmd.Get_lane_addon_declaration { source_path };
                };
            ] )
      | Slash.Addon_decl_new file_name ->
          Update_nav.open_inline_modal m
            (Nav.Addon_decl_form
               {
                 file_name;
                 mode = `Create;
                 expected_source_revision = None;
               })
      | Slash.Addon_slice { run_id; lane_id } ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:"애드온 슬라이스 조회 중…" ~en:"Fetching addon slice…")
              m
          , [
              Cmd.Http_get
                {
                  epoch = m.epoch;
                  req = Cmd.Get_lane_addon_slice { run_id; lane_id };
                };
            ] )
      | Slash.Addon_asks { include_resolved } ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:"애드온 질문 목록 조회 중…"
                 ~en:"Fetching addon asks…")
              m
          , [
              Cmd.Http_get
                {
                  epoch = m.epoch;
                  req = Cmd.Get_lane_addon_asks { include_resolved };
                };
            ] )
      | Slash.Addon_ask_answer { declaration_id; ask_id; answers_json } -> (
          let decoded =
            match Yojson.Safe.from_string answers_json with
            | json -> Wire_work.decode_ask_answers json
            | exception Yojson.Json_error error -> Error error
          in
          match decoded with
          | Ok answers ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make ~ko:("애드온 질문 응답 전송 중: " ^ ask_id)
                     ~en:("Submitting addon ask answer: " ^ ask_id))
                  m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_lane_addon_ask_answer
                          { declaration_id; ask_id; answers };
                    };
                ] )
          | Error msg ->
              let clean = Chat_transcript.scrub_secrets_in_text msg in
              ( Model.with_toast ~now ~level:Model.Toast_error
                  (Say.make ~ko:("answers JSON 오류: " ^ clean)
                     ~en:("answers JSON error: " ^ clean))
                  m
              , [] ))
      | Slash.Addon_operator { instance_id; args_json = None } ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:("애드온 운영자 스키마 조회 중: " ^ instance_id)
                 ~en:("Describing addon operator control: " ^ instance_id))
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req =
                    Cmd.Post_lane_addon_operator
                      {
                        instance_id;
                        expected_incarnation = instance_id;
                        mode = Wire_runtime.Operator_describe;
                      };
                };
            ] )
      | Slash.Addon_operator { instance_id; args_json = Some raw } -> (
          match Yojson.Safe.from_string raw with
          | `Assoc _ as args ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make ~ko:("애드온 운영자 호출 중: " ^ instance_id)
                     ~en:("Invoking addon operator control: " ^ instance_id))
                  m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_lane_addon_operator
                          {
                            instance_id;
                            expected_incarnation = instance_id;
                            mode = Wire_runtime.Operator_invoke args;
                          };
                    };
                ] )
          | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _
          | `List _ ->
              ( Model.with_toast ~now ~level:Model.Toast_error
                  (Say.make ~ko:"operator 인자는 JSON 객체여야 합니다"
                     ~en:"operator arguments must be a JSON object")
                  m
              , [] )
          | exception Yojson.Json_error msg ->
              let clean = Chat_transcript.scrub_secrets_in_text msg in
              ( Model.with_toast ~now ~level:Model.Toast_error
                  (Say.make ~ko:("operator JSON 오류: " ^ clean)
                     ~en:("operator JSON error: " ^ clean))
                  m
              , [] )))
  | Slash.Browser act -> (
      let resolve_client_and_tab ~client_opt ~tab_opt =
        let cid =
          match client_opt with
          | Some c -> Some c
          | None ->
              Option.map
                (fun (cl : Wire_runtime.browser_client_row) -> cl.client_id)
                (Runtime_store.selected_browser_client m.runtime)
        in
        let tid, url_opt =
          match tab_opt with
          | Some t ->
              let found_url =
                match cid with
                | None -> None
                | Some c -> (
                    match
                      Observed.to_option
                        (Runtime_store.browser_tabs_for ~client_id:c m.runtime)
                    with
                    | Some resp -> (
                        match
                          List.find_opt
                            (fun (tb : Wire_runtime.browser_tab_row) ->
                              Int.equal tb.id t)
                            resp.tabs
                        with
                        | Some tb -> Some tb.url
                        | None -> None)
                    | None -> None)
              in
              (Some t, found_url)
          | None -> (
              match Runtime_store.selected_browser_tab m.runtime with
              | Some tb -> (Some tb.id, Some tb.url)
              | None -> (None, None))
        in
        (cid, tid, url_opt)
      in
      match act with
      | Slash.Browser_scene { client_id; tab_id; view } -> (
          match resolve_client_and_tab ~client_opt:client_id ~tab_opt:tab_id with
          | Some cid, Some tid, _ ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:(Printf.sprintf "브라우저 장면 조회 중 (#%d)…" tid)
                     ~en:(Printf.sprintf "Fetching browser scene (#%d)…" tid))
                  m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_browser_scene
                          { client_id = cid; tab_id = tid; view };
                    };
                ] )
          | _ ->
              ( Model.with_toast ~now ~level:Model.Toast_warning
                  (Say.make
                     ~ko:"브라우저 클라이언트와 탭을 먼저 선택하세요 (Runtime > Addons & Browser)"
                     ~en:"Select a browser client and tab first (Runtime > Addons & Browser)")
                  m
              , [] ))
      | Slash.Browser_screenshot { client_id; tab_id } -> (
          match resolve_client_and_tab ~client_opt:client_id ~tab_opt:tab_id with
          | Some cid, Some tid, _ ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:(Printf.sprintf "브라우저 스크린샷 캡처 중 (#%d)…" tid)
                     ~en:(Printf.sprintf "Capturing browser screenshot (#%d)…" tid))
                  m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_browser_screenshot
                          { client_id = cid; tab_id = tid };
                    };
                ] )
          | _ ->
              ( Model.with_toast ~now ~level:Model.Toast_warning
                  (Say.make
                     ~ko:"브라우저 클라이언트와 탭을 먼저 선택하세요"
                     ~en:"Select a browser client and tab first")
                  m
              , [] ))
      | Slash.Browser_interact { client_id; tab_id; action = None; _ } -> (
          match resolve_client_and_tab ~client_opt:client_id ~tab_opt:tab_id with
          | Some cid, Some tid, expected_url ->
              Update_nav.open_inline_modal m
                (Nav.Browser_interact_form
                   { client_id = cid; tab_id = tid; expected_url })
          | _ ->
              ( Model.with_toast ~now ~level:Model.Toast_warning
                  (Say.make
                     ~ko:"브라우저 클라이언트와 탭을 먼저 선택하세요"
                     ~en:"Select a browser client and tab first")
                  m
              , [] ))
      | Slash.Browser_interact
          { client_id; tab_id; action = Some action; selector; text } -> (
          match resolve_client_and_tab ~client_opt:client_id ~tab_opt:tab_id with
          | Some cid, Some tid, expected_url ->
              let y =
                if String.equal action "scroll" then
                  Option.bind selector int_of_string_opt
                else None
              in
              let sel =
                if String.equal action "scroll" then None else selector
              in
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:(Printf.sprintf "브라우저 인터랙션 실행 중 (%s · #%d)…" action tid)
                     ~en:(Printf.sprintf "Running browser interact (%s · #%d)…" action tid))
                  m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_browser_interact
                          {
                            client_id = cid;
                            tab_id = tid;
                            expected_url;
                            action;
                            selector = sel;
                            text;
                            x = None;
                            y;
                          };
                    };
                ] )
          | _ ->
              ( Model.with_toast ~now ~level:Model.Toast_warning
                  (Say.make
                     ~ko:"브라우저 클라이언트와 탭을 먼저 선택하세요"
                     ~en:"Select a browser client and tab first")
                  m
              , [] ))
      | Slash.Browser_command raw -> (
          match Yojson.Safe.from_string raw with
          | `Assoc _ as arguments ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make ~ko:"브라우저 명령 전송 중…" ~en:"Sending browser command…")
                  m
              , [
                  Cmd.Http_post
                    { epoch = m.epoch; req = Cmd.Post_browser_command { arguments } };
                ] )
          | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _
          | `List _ ->
              ( Model.with_toast ~now ~level:Model.Toast_error
                  (Say.make ~ko:"/browser command 인자는 JSON 객체여야 합니다"
                     ~en:"/browser command argument must be a JSON object")
                  m
              , [] )
          | exception Yojson.Json_error msg ->
              let clean = Chat_transcript.scrub_secrets_in_text msg in
              ( Model.with_toast ~now ~level:Model.Toast_error
                  (Say.make ~ko:("/browser command JSON 오류: " ^ clean)
                     ~en:("/browser command JSON error: " ^ clean))
                  m
              , [] )))
  | Slash.Tools None -> apply_slash_tools ~now None m
  | Slash.Tools (Some mode) -> apply_slash_tools ~now (Some mode) m
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
        m.config
        |> Config_store.apply_tui_pref_op ~observed_at:now ~full_key:"tui.theme"
             (Wire_config.Set_scalar
                { table = "tui"; key = "theme"; value = Theme.preset_name preset })
        |> Config_store.unstage_patch ~full_key:"tui.theme"
      in
      let next =
        { m with theme_preset = preset; cli_theme_override = false; config }
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
        m.config
        |> Config_store.apply_tui_pref_op ~observed_at:now
             ~full_key:"tui.language"
             (Wire_config.Set_scalar
                { table = "tui"; key = "language"; value = lang_s })
        |> Config_store.unstage_patch ~full_key:"tui.language"
      in
      let next =
        { m with lang; cli_lang_override = false; config }
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
  | Slash.Music action ->
      let program =
        match action with
        | Slash.Music_workbench -> Cmd.Music_workbench
        | Slash.Music_import_midi path -> Cmd.Music_import_midi path
      in
      (m, [ Cmd.Open_terminal_program program ])
  | Slash.Score index -> (
      match loaded_alphatex_sources m with
      | None ->
          ( Model.with_toast ~now ~level:Model.Toast_warning
              (Say.make ~ko:"/score: 열린 키퍼 대화가 없습니다"
                 ~en:"/score: no keeper conversation is open")
              m,
            [] )
      | Some sources ->
          let count = List.length sources in
          if index > count then
            ( Model.with_toast ~now ~level:Model.Toast_warning
                (Say.make
                   ~ko:
                     (Printf.sprintf
                        "/score: 불러온 대화에 닫힌 alphaTex 코드 블록이 %d개 있습니다"
                        count)
                   ~en:
                     (Printf.sprintf
                        "/score: this loaded conversation has %d closed alphaTex block%s"
                        count
                        (if count = 1 then "" else "s")))
                m,
              [] )
          else
            ( m,
              [ Cmd.Open_terminal_program (Cmd.Score_view { sources; index }) ]
            ))

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
  | Update_nav.Composer_popup_slash { query; items; selected } -> (
      match List.nth_opt items selected with
      | Some { kind = Update_nav.Popup_slash_cmd spec; _ } ->
          if Update_nav.slash_spec_requires_arg spec then
            ( {
                m with
                drafts = Drafts.set_current_text (spec.name ^ " ") m.drafts;
              }
            , [] )
          else submit_slash_text ~now m spec.name
      | Some { kind = Update_nav.Popup_slash_arg { spec; full_text; _ }; _ } ->
          let keep_bare_optional_arg =
            String.equal (String.trim query) ""
            && (not m.drafts.popup_navigated)
            &&
            match spec.id with
            | Slash.Cmd_wake
            | Slash.Cmd_up
            | Slash.Cmd_resume
            | Slash.Cmd_pause
            | Slash.Cmd_down ->
                true
            | Slash.Cmd_pulse
            | Slash.Cmd_work
            | Slash.Cmd_knowledge
            | Slash.Cmd_keepers
            | Slash.Cmd_runtime
            | Slash.Cmd_infra
            | Slash.Cmd_keeper
            | Slash.Cmd_model
            | Slash.Cmd_config
            | Slash.Cmd_incidents
            | Slash.Cmd_jump
            | Slash.Cmd_voice
            | Slash.Cmd_btw
            | Slash.Cmd_discord_reply
            | Slash.Cmd_queue
            | Slash.Cmd_context
            | Slash.Cmd_ctl
            | Slash.Cmd_gate
            | Slash.Cmd_exec
            | Slash.Cmd_skill
            | Slash.Cmd_prompt
            | Slash.Cmd_preset
            | Slash.Cmd_lane
            | Slash.Cmd_addon
            | Slash.Cmd_browser
            | Slash.Cmd_tools
            | Slash.Cmd_clear
            | Slash.Cmd_theme
            | Slash.Cmd_lang
            | Slash.Cmd_help
            | Slash.Cmd_restart
            | Slash.Cmd_quit ->
                false
          in
          let target_text =
            if keep_bare_optional_arg then trimmed
            else if
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
        let leading_mention_opt =
          if Char.equal trimmed.[0] '@' then
            let len = String.length trimmed in
            let sp_idx =
              let rec scan i =
                if i >= len then len
                else if
                  Char.equal trimmed.[i] ' '
                  || Char.equal trimmed.[i] '\t'
                  || Char.equal trimmed.[i] '\n'
                then i
                else scan (i + 1)
              in
              scan 1
            in
            let candidate = String.sub trimmed 1 (sp_idx - 1) in
            let rest =
              if sp_idx < len then
                String.trim (String.sub trimmed sp_idx (len - sp_idx))
              else ""
            in
            match Fleet_store.find_keeper ~name:candidate m.fleet with
            | Some k -> Some (k.name, rest)
            | None -> None
          else None
        in
        match leading_mention_opt with
        | Some (mentioned_keeper, "") ->
            let drafts =
              m.drafts
              |> Drafts.clear_current_draft
              |> Drafts.set_active_keeper mentioned_keeper
            in
            ( Model.with_toast ~now ~level:Model.Toast_info
                (Say.make
                   ~ko:("대상 키퍼 전환됨: @" ^ mentioned_keeper)
                   ~en:("Target keeper switched to @" ^ mentioned_keeper))
                { m with drafts }
            , [] )
        | Some (mentioned_keeper, rest) -> (
            (* [@keeper msg] sends [rest] through the mentioned Keeper's
               composer slot. That slot may already hold an unsent draft the
               operator typed earlier; the submission consumes the slot, so
               the earlier draft is put back once [rest] has left. The earlier
               draft is read after the current slot is cleared, so mentioning
               the Keeper whose composer holds the text does not bring the
               sent text back. *)
            let drafts_cleared = Drafts.clear_current_draft m.drafts in
            let prior =
              Drafts.draft_for ~keeper:mentioned_keeper drafts_cleared
            in
            let drafts_switched =
              drafts_cleared
              |> Drafts.set_active_keeper mentioned_keeper
              |> Drafts.set_current_text rest
            in
            let sent, cmds =
              submit_composer ~now ~mode { m with drafts = drafts_switched }
            in
            let consumed =
              String.equal
                (Drafts.draft_for ~keeper:mentioned_keeper sent.drafts).text ""
            in
            match (String.equal prior.text "", consumed) with
            | true, (true | false) | false, false -> (sent, cmds)
            | false, true ->
                let restore_into_current drafts =
                  Drafts.set_current_text_and_cursor ~text:prior.text
                    ~cursor:prior.cursor drafts
                in
                let drafts =
                  match sent.drafts.Drafts.active_keeper with
                  | Some target when not (String.equal target mentioned_keeper)
                    ->
                      (* A nested [@a @b msg] moved the target on to [b]: the
                         earlier draft goes back into [a]'s own slot and [b]
                         stays the target. *)
                      sent.drafts
                      |> Drafts.set_active_keeper mentioned_keeper
                      |> restore_into_current
                      |> Drafts.set_active_keeper target
                  | Some _ | None -> restore_into_current sent.drafts
                in
                ({ sent with drafts }, cmds))
        | None ->
        match Update_nav.resolve_target_keeper m with
        | None ->
            let opened, cmds =
              Update_nav.open_palette m Model.Palette_keepers
            in
            ( Model.with_toast ~now ~level:Model.Toast_warning
                (Say.make ~ko:"대상 키퍼를 먼저 선택하세요"
                   ~en:"Select a target keeper first")
                opened
            , cmds )
        | Some keeper -> (
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
                drafts0
            with
            | None -> (m, [])
            | Some (drafts1, tx) ->
                let drafts2 =
                  Drafts.mark_sending ~now ~request_id:tx.request_id drafts1
                in
                let fleet0 =
                  if keeper_is_busy then m.fleet
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
          | Update_nav.Pal_keeper_lifecycle { keeper; op } -> (
              match op with
              | Update_nav.Op_wake_or_online ->
                  dispatch_keeper_smart_wake ~now ~name:keeper m_closed
              | Update_nav.Op_pause ->
                  dispatch_keeper_pause ~now ~name:keeper m_closed
              | Update_nav.Op_resume ->
                  dispatch_keeper_resume ~now ~name:keeper m_closed
              | Update_nav.Op_shutdown ->
                  open_keeper_lifecycle_modal m_closed ~keeper
                    ~default_action:"shutdown")
          | Update_nav.Pal_menu_target target ->
              Update_nav.navigate_menu_target m_closed target
          | Update_nav.Pal_dive_keeper name ->
              Update_nav.jump_to_keeper ~preserve_return:true
                ~tab:Nav.Keeper_chat m_closed name
          | Update_nav.Pal_select_company company ->
              let fleet = Fleet_store.set_filter company m_closed.fleet in
              Update_nav.switch_workspace { m_closed with fleet } Nav.Keepers
          | Update_nav.Pal_dive_goal id ->
              Update_nav.jump_to_goal ~zoomed:true ~return_from:m_closed m_closed
                id
          | Update_nav.Pal_dive_task id ->
              Update_nav.jump_to_task ~zoomed:true ~return_from:m_closed m_closed
                id
          | Update_nav.Pal_dive_thread id ->
              Update_nav.jump_to_knowledge_thread ~return_from:m_closed m_closed
                id
          | Update_nav.Pal_dive_wiki slug ->
              Update_nav.jump_to_knowledge_wiki ~return_from:m_closed m_closed
                slug
          | Update_nav.Pal_dive_sandbox keeper ->
              let infra =
                m_closed.infra
                |> Infra_store.set_tab Nav.Infra_sandboxes
                |> Infra_store.select_sandbox_by_keeper keeper
              in
              let m' = { m_closed with infra } in
              let zoomed =
                not
                  (Model.detail_visible
                     {
                       m' with
                       nav =
                         {
                           m'.nav with
                           workspace = Nav.Infra;
                           inspector = None;
                           inspector_return = None;
                           overlay = None;
                           zoomed = false;
                         };
                     })
              in
              Update_nav.jump_to_workspace ~pane_index:1 ~zoomed
                ~return_from:m_closed m' Nav.Infra
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
              else if Slash.equal_command_id spec.id Slash.Cmd_ctl then
                let drafts =
                  m_closed.drafts |> Drafts.set_current_text "/ctl "
                  |> Drafts.set_focus true
                in
                ({ m_closed with drafts }, [])
              else if Slash.equal_command_id spec.id Slash.Cmd_gate then
                let drafts =
                  m_closed.drafts |> Drafts.set_current_text "/gate "
                  |> Drafts.set_focus true
                in
                ({ m_closed with drafts }, [])
              else if Slash.equal_command_id spec.id Slash.Cmd_exec then
                Update_nav.open_inline_modal m_closed
                  (Nav.Tool_execute_form
                     { tool_name = None; args_json = "{}" })
              else if Slash.equal_command_id spec.id Slash.Cmd_skill then
                let drafts =
                  m_closed.drafts |> Drafts.set_current_text "/skill "
                  |> Drafts.set_focus true
                in
                ({ m_closed with drafts }, [])
              else if Slash.equal_command_id spec.id Slash.Cmd_prompt then
                let drafts =
                  m_closed.drafts |> Drafts.set_current_text "/prompt "
                  |> Drafts.set_focus true
                in
                ({ m_closed with drafts }, [])
              else if Slash.equal_command_id spec.id Slash.Cmd_preset then
                execute_slash ~now m_closed (Slash.Preset Slash.Preset_list)
              else if Slash.equal_command_id spec.id Slash.Cmd_lane then
                let drafts =
                  m_closed.drafts |> Drafts.set_current_text "/lane "
                  |> Drafts.set_focus true
                in
                ({ m_closed with drafts }, [])
              else if Slash.equal_command_id spec.id Slash.Cmd_addon then
                let drafts =
                  m_closed.drafts |> Drafts.set_current_text "/addon "
                  |> Drafts.set_focus true
                in
                ({ m_closed with drafts }, [])
              else if Slash.equal_command_id spec.id Slash.Cmd_browser then
                let drafts =
                  m_closed.drafts |> Drafts.set_current_text "/browser "
                  |> Drafts.set_focus true
                in
                ({ m_closed with drafts }, [])
              else
                match Slash.parse spec.name with
                | Ok parsed -> execute_slash ~now m_closed parsed
                | Error _ -> (m_closed, [])))
  | Model.Palette_discord_replies { workspace; _ } ->
      let sources = Update_nav.palette_discord_sources m in
      (match List.nth_opt sources m.palette.selected with
       | Some { target = { keeper; chat_id; origin }; _ } ->
           Update_nav.open_inline_modal m
             (Nav.Discord_reply_form
                { keeper; chat_id; guild_id = origin.guild_id;
                  channel_id = origin.channel_id; message_id = origin.original_message_id;
                  workspace_base_path = workspace.base_path;
                  workspace_masc_root = workspace.masc_root })
       | None -> (m, []))
  | Model.Palette_keepers -> (
      let items = Update_nav.palette_filtered_keepers m in
      match
        List.nth_opt items
          (Update_nav.clamp_index (List.length items) m.palette.selected)
      with
      | None -> ({ m with nav = { m.nav with overlay = None } }, [])
      | Some k ->
          let m_closed = { m with nav = { m.nav with overlay = None } } in
          Update_nav.jump_to_keeper ~preserve_return:true ~tab:Nav.Keeper_chat
            m_closed k.name)
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
  | Keymap.Toggle_sidebar ->
      if
        Model.is_too_small_viewport m.viewport
        || Model.equal_breakpoint m.breakpoint Model.Micro
      then (m, [])
      else
        let leaving_focus = Model.keeper_dive_focused m in
        let restored =
          if leaving_focus then
            let m0 =
              {
                m with
                nav = { m.nav with zoomed = false; pre_zoom_pane_index = None };
              }
            in
            let max_pane = max 0 (Model.focusable_pane_count m0 - 1) in
            let restored_pane =
              match m.nav.pre_zoom_pane_index with
              | Some p -> max 0 (min max_pane p)
              | None -> max 0 (min max_pane m0.nav.pane_index)
            in
            { m0 with nav = { m0.nav with pane_index = restored_pane } }
          else m
        in
        let next =
          if not (Model.sidebar_visible restored) then
            Update_nav.enter_sidebar_focus
              { restored with nav = { restored.nav with sidebar_open = Some true } }
          else if not (Model.sidebar_has_focus restored) then
            Update_nav.enter_sidebar_focus restored
          else
            {
              restored with
              nav =
                {
                  restored.nav with
                  sidebar_open = Some false;
                  sidebar_focused = false;
                };
            }
        in
        if
          leaving_focus
          && not (Int.equal (Model.inner_body_width next) (Model.inner_body_width m))
        then Update_nav.refresh_open_memory_diagram ~now next
        else (next, [])
  | Keymap.Sub_tab dir ->
      if Model.sidebar_has_focus m then (m, [])
      else Update_nav.cycle_sub_tab m dir
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
            | Error reason ->
                ( Model.with_toast ~now ~level:Model.Toast_warning
                    (Say.literal reason) m
                , [] )
          else ({ m with config = Config_store.toggle_pane m.config }, [])
      | Some Nav.Palette ->
          let len = Update_nav.palette_len m in
          if len <= 0 then (m, [])
          else
            let delta = match dir with Keymap.Next -> 1 | Keymap.Prev -> -1 in
            let cur = Update_nav.clamp_index len m.palette.selected in
            let selected = (cur + delta + len) mod len in
            let list_h =
              let modal_h = min (max 0 (m.viewport.rows - 4)) 22 in
              let inner_h = max 0 (modal_h - 2) in
              max 1 (inner_h - 3)
            in
            let palette_scroll_offset, _ =
              Masc_tui_ui.Table.compute_viewport ~total_rows:(max 1 len)
                ~viewport_rows:list_h ~scroll:m.nav.palette_scroll_offset
                ~selected:(Some selected)
            in
            ( {
                m with
                palette = { m.palette with selected };
                nav = { m.nav with palette_scroll_offset };
              }
            , [] )
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
                    | Nav.Harness_overrule _
                    | Nav.Task_cancel _
                    | Nav.Goal_drop _
                    | Nav.Schedule_form
                    | Nav.Connector_form
                    | Nav.Repo_add_form
                    | Nav.Board_new_post
                    | Nav.Board_goal_proposal
                    | Nav.Goal_confirmation_proof
                    | Nav.Memory_act_form
                    | Nav.Wiki_edit_form
                    | Nav.Fusion_launch_form
                    | Nav.Runtime_assign_form
                    | Nav.Setup_account_key_form
                    | Nav.Setup_login_start_form
                    | Nav.Board_comment _
                    | Nav.Github_token_form _
                    | Nav.Code_finder_form
                    | Nav.Code_search_form
                    | Nav.Keeper_control_confirm _
                    | Nav.Keeper_clear_form _
                    | Nav.Keeper_operator_note_form _
                    | Nav.Discord_reply_form _
                    | Nav.Tool_execute_form _
                    | Nav.Skill_create_form
                    | Nav.Skill_edit_form _
                    | Nav.Skill_delete_confirm _
                    | Nav.Prompt_override_form _
                    | Nav.Preset_create_form
                    | Nav.Runtime_param_set_form _
                    | Nav.Default_route_edit
                    | Nav.Lane_rename_form _
                    | Nav.Addon_decl_form _
                    | Nav.Addon_act_form _
                    | Nav.Browser_interact_form _
                    | Nav.Runtime_lane_create
                    | Nav.Runtime_lane_edit _
                    | Nav.Runtime_lane_delete _
                    | Nav.Task_create_form
                    | Nav.Task_transition_form _
                    | Nav.Task_link_goal _
                    | Nav.Goal_upsert_form _
                    | Nav.Board_delete_post _
                    | Nav.Keeper_lifecycle_form _
                    | Nav.Keeper_purge_confirm _
                    | Nav.Addon_attach_form
                    | Nav.Addon_detach_confirm _
                    | Nav.Addon_invoke_action _
                    | Nav.Setup_login_input_form _ )
                  , _ ) ->
                    true
              in
              if not editable then (m, [])
              else
                let delta =
                  match dir with Keymap.Next -> 1 | Keymap.Prev -> -1
                in
                let next_modal = Model.modal_cycle_field ~delta modal in
                let modal_edit_cursor =
                  String.length (Model.modal_active_field_value next_modal)
                in
                ( {
                    m with
                    inline_modal = Some next_modal;
                    nav = { m.nav with modal_edit_cursor };
                  }
                , [] ))
      | Some Nav.Ask_answer -> (
          match m.ask_modal with
          | None -> (m, [])
          | Some modal ->
              let delta = match dir with Keymap.Next -> 1 | Keymap.Prev -> -1 in
              let next_modal =
                modal
                |> Model.ask_modal_set_editing_free_text false
                |> Model.ask_modal_step_question ~delta
              in
              ({ m with ask_modal = Some next_modal }, []))
      | Some (Nav.Help | Nav.Incidents | Nav.System_gate _) -> (m, [])
      | None ->
          let n = Model.focusable_pane_count m in
          let sync_pane (base : Model.t) next_pane =
            Update_nav.clamp_for_pane
              { base with nav = { base.nav with pane_index = next_pane } }
          in
          if Model.sidebar_has_focus m then
            let base = Update_nav.exit_sidebar_focus m in
            let target_pane =
              match dir with
              | Keymap.Next -> 0
              | Keymap.Prev -> Int.max 0 (Model.focusable_pane_count base - 1)
            in
            (sync_pane base target_pane, [])
          else (
            let cur =
              if n <= 0 then 0 else Int.max 0 (Int.min (n - 1) m.nav.pane_index)
            in
            let out_of_range = m.nav.pane_index >= n || m.nav.pane_index < 0 in
            match dir with
            | Keymap.Next ->
                if out_of_range then (sync_pane m 0, [])
                else if cur + 1 < n then (sync_pane m (cur + 1), [])
                else if Model.sidebar_visible m then
                  (Update_nav.enter_sidebar_focus m, [])
                else if n <= 1 then (m, [])
                else (sync_pane m 0, [])
            | Keymap.Prev ->
                if out_of_range then (sync_pane m (Int.max 0 (n - 1)), [])
                else if cur > 0 then (sync_pane m (cur - 1), [])
                else if Model.sidebar_visible m then
                  (Update_nav.enter_sidebar_focus m, [])
                else if n <= 1 then (m, [])
                else (sync_pane m (n - 1), [])))
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
            | Nav.Ask_answer
            | Nav.System_gate Nav.Media_viewer )
        | None ->
            let m0 = Update_nav.exit_sidebar_focus m in
            let nav = { m0.nav with overlay = None; filter_focused = false } in
            ( {
                m0 with
                nav;
                inline_modal = None;
                ask_modal =
                  (if Model.has_preserved_ask_return nav then m0.ask_modal
                   else None);
                drafts =
                  m0.drafts
                  |> Update_nav.clear_btw_if_leaving m0
                  |> Drafts.set_focus true;
              }
            , [] ))
  | Keymap.Focus_filter -> (
      if Model.is_too_small_viewport m.viewport then (m, [])
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
            | Nav.Ask_answer
            | Nav.Help
            | Nav.System_gate _ ) ->
            (m, [])
        | None ->
            if Model.equal_breakpoint m.breakpoint Model.Micro then (m, [])
            else
              let m = Update_nav.exit_sidebar_focus m in
            (
            if Model.is_keeper_config_active m then
              ( {
                  m with
                  nav = { m.nav with filter_focused = true };
                  drafts = Drafts.set_focus false m.drafts;
                }
              , [] )
            else
              match Model.active_inspector m with
              | Some _ ->
                  focus_composer_for_slash m
              | None -> (
                  match m.nav.workspace with
                  | Nav.Pulse -> focus_composer_for_slash m
                  | Nav.Keepers
                    when Model.is_in_keeper_chat m
                         || (m.nav.zoomed && Model.can_zoom_current_view m) ->
                      focus_composer_for_slash m
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
  | Keymap.Dive_selected ->
      if Model.sidebar_has_focus m then
        Update_nav.activate_sidebar_cursor m
      else Update_nav.dive_selected m
  | Keymap.Confirm_selected -> (
      if Model.sidebar_has_focus m then
        Update_nav.activate_sidebar_cursor m
      else if Option.is_none m.nav.overlay && Drafts.is_focused m.drafts then
        submit_composer ~now ~mode:Drafts.Mode_follow_up m
      else
        match m.nav.overlay with
        | Some Nav.Palette -> confirm_palette ~now m
        | Some (Nav.Inline_action Nav.Btw_query) -> (
            match m.drafts.btw with
            | Drafts.Btw_answered _ | Drafts.Btw_failed _ ->
                ( {
                    m with
                    nav =
                      {
                        m.nav with
                        overlay = None;
                        filter_focused = false;
                        btw_scroll_offset = 0;
                      };
                    drafts = Drafts.clear_btw m.drafts;
                    inline_modal = None;
                  }
                , [] )
            | Drafts.Btw_idle | Drafts.Btw_sending _ | Drafts.Btw_streaming _ ->
                Update_nav.submit_inline_modal ~now m)
        | Some
            (Nav.Inline_action
               ( Nav.Gate_reject _
               | Nav.Verification_reject _
               | Nav.Harness_overrule _
               | Nav.Task_cancel _
               | Nav.Goal_drop _
               | Nav.Schedule_form
               | Nav.Connector_form
               | Nav.Repo_add_form
               | Nav.Board_new_post
               | Nav.Board_goal_proposal
               | Nav.Goal_confirmation_proof
               | Nav.Memory_act_form
               | Nav.Wiki_edit_form
               | Nav.Fusion_launch_form
               | Nav.Runtime_assign_form
               | Nav.Setup_account_key_form
               | Nav.Setup_login_start_form
               | Nav.Board_comment _
               | Nav.Github_token_form _
               | Nav.Code_finder_form
               | Nav.Code_search_form
               | Nav.Keeper_control_confirm _
               | Nav.Keeper_clear_form _
               | Nav.Keeper_operator_note_form _
               | Nav.Discord_reply_form _
               | Nav.Tool_execute_form _
               | Nav.Skill_create_form
               | Nav.Skill_edit_form _
               | Nav.Skill_delete_confirm _
               | Nav.Prompt_override_form _
               | Nav.Preset_create_form
               | Nav.Runtime_param_set_form _
               | Nav.Default_route_edit
               | Nav.Lane_rename_form _
               | Nav.Addon_decl_form _
               | Nav.Addon_act_form _
               | Nav.Browser_interact_form _
               | Nav.Runtime_lane_create
               | Nav.Runtime_lane_edit _
               | Nav.Runtime_lane_delete _
               | Nav.Task_create_form
               | Nav.Task_transition_form _
               | Nav.Task_link_goal _
               | Nav.Goal_upsert_form _
               | Nav.Board_delete_post _
               | Nav.Keeper_lifecycle_form _
               | Nav.Keeper_purge_confirm _
               | Nav.Addon_attach_form
               | Nav.Addon_detach_confirm _
               | Nav.Addon_invoke_action _
               | Nav.Setup_login_input_form _ )) ->
            Update_nav.submit_inline_modal ~now m
        | Some Nav.Ask_answer -> (
            match m.ask_modal with
            | None -> (m, [])
            | Some modal -> (
                let advance_or_submit (m_next : Model.t) =
                  match m_next.ask_modal with
                  | None -> (m_next, [])
                  | Some md -> (
                      match Model.ask_modal_build_answers md with
                      | Ok _ -> Update_nav.submit_ask_modal ~now m_next
                      | Error next_unanswered ->
                          ( {
                              m_next with
                              ask_modal =
                                Some
                                  (Model.ask_modal_select_question
                                     next_unanswered md);
                            }
                          , [] ))
                in
                if modal.editing_free_text then
                  let md1, has_text = Model.ask_modal_confirm_free_text modal in
                  let m1 = { m with ask_modal = Some md1 } in
                  if has_text then advance_or_submit m1
                  else
                    ( Model.with_toast ~now ~level:Model.Toast_info
                        (Say.make ~ko:"직접 입력 내용이 비어 있습니다"
                           ~en:"Free-text input is empty")
                        m1
                    , [] )
                else
                  match
                    ( Model.ask_modal_current_question modal
                    , Model.ask_modal_current_row modal )
                  with
                  | Some q, Some (Model.Ask_row_choice (idx, _)) -> (
                      match q.mode with
                      | Wire_work.Ask_single ->
                          let md1 =
                            Model.ask_modal_toggle_or_select_choice idx modal
                          in
                          advance_or_submit { m with ask_modal = Some md1 }
                      | Wire_work.Ask_multi ->
                          let d = Model.ask_question_draft_for modal q in
                          if
                            Model.equal_ask_answer_mode d.mode
                              Model.Ask_mode_choices
                            && d.choice_ids <> []
                          then advance_or_submit m
                          else
                            let md1 =
                              Model.ask_modal_toggle_or_select_choice idx modal
                            in
                            ({ m with ask_modal = Some md1 }, []))
                  | Some q, Some Model.Ask_row_free_text ->
                      if q.allow_free_text then
                        ( {
                            m with
                            ask_modal =
                              Some (Model.ask_modal_enter_free_text modal);
                          }
                        , [] )
                      else (m, [])
                  | Some _, Some Model.Ask_row_skip ->
                      let md1 = Model.ask_modal_set_skipped modal in
                      advance_or_submit { m with ask_modal = Some md1 }
                  | None, _ | Some _, None -> (m, [])))
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
                          Say.make ~ko:"변경값이 스테이징됨 (d: 미리보기 · Ctrl+S: 저장)"
                            ~en:"Staged field change (d: dry-run diff · Ctrl+S: save)"
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
                  let cfg0 = sync_settings_live_tui m cfg0 in
                  let sel_key_opt =
                    Option.map
                      (fun (f : Wire_config.schema_field) -> f.full_key)
                      (Config_store.selected_field cfg0)
                  in
                  match Config_store.begin_edit_selected cfg0 with
                  | Ok config -> (
                      if not (Config_store.is_editing_field config) then
                        match
                          Option.bind sel_key_opt (fun key ->
                              apply_staged_tui_pref_if_needed ~now ~key m config)
                        with
                        | Some res -> res
                        | None -> ({ m with config }, [])
                      else ({ m with config }, []))
                  | Error reason ->
                      ( Model.with_toast ~now ~level:Model.Toast_info
                          (Say.literal reason) { m with config = cfg0 }
                      , [] )))
        | Some Nav.Incidents -> (
            match Incidents.selected_entry m.incidents with
            | Some _ ->
                ({ m with incidents = Incidents.toggle_zoom m.incidents }, [])
            | None -> (m, []))
        | Some (Nav.Queue_context Nav.Drawer_context) -> (
            match active_keeper_for_context m with
            | Some name ->
                Update_nav.jump_to_keeper ~preserve_return:true
                  ~tab:Nav.Keeper_trace
                  ~trace_section:Keeper_context_store.Trace_context m name
            | None -> (m, []))
        | Some
            ( Nav.Queue_context (Nav.Drawer_queue | Nav.Drawer_schedules)
            | Nav.Help
            | Nav.System_gate _ ) ->
            (m, [])
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
          else if
            Config_store.dirty_count m.config > 0
            && not m.config.discard_confirm_armed
          then
            let n = Config_store.dirty_count m.config in
            let config = Config_store.arm_discard_confirm m.config in
            ( Model.with_toast ~now ~level:Model.Toast_warning
                (Say.make
                   ~ko:
                     (Printf.sprintf
                        "저장하지 않은 변경 %d건 — [Ctrl+S] 저장 · [Esc] 다시 눌러 버리고 닫기"
                        n)
                   ~en:
                     (Printf.sprintf
                        "%d unsaved change(s) — [Ctrl+S] save · press [Esc] again to discard"
                        n))
                { m with config }
            , [] )
          else
          let close_overlay_and_resync (base_m : Model.t) =
            let cfg_clean =
              if base_m.config.discard_confirm_armed then
                Config_store.clear_dirty base_m.config
              else Config_store.disarm_discard_confirm base_m.config
            in
            let closed =
              {
                base_m with
                nav =
                  {
                    base_m.nav with
                    overlay = None;
                    return_overlay = None;
                    filter_focused = false;
                  };
                config = Config_store.cancel_edit_field cfg_clean;
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
          if m.incidents.zoomed && m.incidents.show_raw_json then
            ( {
                m with
                incidents =
                  {
                    m.incidents with
                    show_raw_json = false;
                    detail_scroll_offset = 0;
                  };
              }
            , [] )
          else if m.incidents.zoomed then
            ({ m with incidents = Incidents.set_zoomed false m.incidents }, [])
          else if not (String.equal m.incidents.filter_query "") then
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
                incidents = Incidents.reset_view m.incidents;
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
            | Nav.Harness_overrule _
            | Nav.Task_cancel _
            | Nav.Goal_drop _
            | Nav.Schedule_form
            | Nav.Connector_form
            | Nav.Repo_add_form
            | Nav.Board_new_post
            | Nav.Board_goal_proposal
            | Nav.Goal_confirmation_proof
            | Nav.Memory_act_form
            | Nav.Wiki_edit_form
            | Nav.Fusion_launch_form
            | Nav.Runtime_assign_form
            | Nav.Setup_account_key_form
            | Nav.Setup_login_start_form
            | Nav.Board_comment _
            | Nav.Github_token_form _
            | Nav.Code_finder_form
            | Nav.Code_search_form
            | Nav.Keeper_control_confirm _
            | Nav.Keeper_clear_form _
            | Nav.Keeper_operator_note_form _
            | Nav.Discord_reply_form _
            | Nav.Tool_execute_form _
            | Nav.Skill_create_form
            | Nav.Skill_edit_form _
            | Nav.Skill_delete_confirm _
            | Nav.Prompt_override_form _
            | Nav.Preset_create_form
            | Nav.Runtime_param_set_form _
            | Nav.Default_route_edit
            | Nav.Lane_rename_form _
            | Nav.Addon_decl_form _
            | Nav.Addon_act_form _
            | Nav.Browser_interact_form _
            | Nav.Runtime_lane_create
            | Nav.Runtime_lane_edit _
            | Nav.Runtime_lane_delete _
            | Nav.Task_create_form
            | Nav.Task_transition_form _
            | Nav.Task_link_goal _
            | Nav.Goal_upsert_form _
            | Nav.Board_delete_post _
            | Nav.Keeper_lifecycle_form _
            | Nav.Keeper_purge_confirm _
            | Nav.Addon_attach_form
            | Nav.Addon_detach_confirm _
            | Nav.Addon_invoke_action _
            | Nav.Setup_login_input_form _ ->
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
      | Some Nav.Ask_answer -> (
          match m.ask_modal with
          | Some modal when modal.editing_free_text ->
              ( {
                  m with
                  ask_modal =
                    Some (Model.ask_modal_set_editing_free_text false modal);
                }
              , [] )
          | Some _ | None ->
              let closed =
                {
                  m with
                  nav = { m.nav with overlay = None; filter_focused = false };
                  ask_modal =
                    (if Model.has_preserved_ask_return m.nav then m.ask_modal
                     else None);
                }
              in
              (closed, []))
      | Some Nav.Help ->
          let closed =
            {
              m with
              nav =
                {
                  m.nav with
                  overlay = m.nav.return_overlay;
                  return_overlay = None;
                  filter_focused = false;
                };
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
      | Some
          ( Nav.Palette
          | Nav.Queue_context _
          | Nav.System_gate Nav.Media_viewer ) ->
          let closed =
            {
              m with
              nav =
                {
                  m.nav with
                  overlay = None;
                  return_overlay = None;
                  filter_focused = false;
                };
              config = Config_store.cancel_edit_field m.config;
              inline_modal = None;
              ask_modal =
                (if Model.has_preserved_ask_return m.nav then m.ask_modal
                 else None);
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
          if Option.is_some m.knowledge.armed_vote then
            ( {
                m with
                knowledge = Knowledge_store.clear_armed_vote m.knowledge;
              }
            , [] )
          else if m.nav.filter_focused then
            let cleared, cmds = Update_nav.set_active_filter_query "" m in
            ( { cleared with nav = { cleared.nav with filter_focused = false } },
              cmds )
          else if Model.sidebar_has_focus m || Model.sidebar_drawer_open m then
            (Update_nav.exit_sidebar_focus m, [])
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
            else if Option.is_some (board_recovery_keeper m) then
              ( set_board_recovery m
                  (Board_recovery.close m.knowledge.board_recovery)
              , [] )
            else
              let active_chat_interrupt =
                if
                  Option.is_none (Model.active_inspector m)
                  && Model.is_in_keeper_chat m
                then
                  match Model.selected_keeper_name m with
                  | None -> None
                  | Some name -> (
                      let m_unzoomed =
                        { m with nav = { m.nav with zoomed = false } }
                      in
                      let narrow_zoomed =
                        m.nav.zoomed
                        && not
                             (Model.uses_keeper_split
                                ~width:(Model.inner_body_width m_unzoomed)
                                m_unzoomed)
                      in
                      match
                        Chat_transcript.escape_interrupt_target ~model:m
                          ~keeper:name
                      with
                      | Some (`Turn_token _) when narrow_zoomed -> None
                      | Some target -> Some (name, target)
                      | None -> None)
                else None
              in
              match active_chat_interrupt with
              | Some (keeper, target) ->
                  request_keeper_interrupt ~from_escape:true ~now ~keeper ~target m
              | None -> (
                  match m.nav.inspector with
                  | Some _ -> Update_nav.close_inspector m
                  | None ->
                      let m =
                        if m.nav.zoomed && not (Model.can_zoom_current_view m)
                        then
                          {
                            m with
                            nav =
                              {
                                m.nav with
                                zoomed = false;
                                pre_zoom_pane_index = None;
                              };
                          }
                        else m
                      in
                      if Option.is_some m.knowledge.pending_wiki_edit_slug then
                        ( {
                            m with
                            knowledge =
                              Knowledge_store.clear_pending_wiki_edit
                                m.knowledge;
                          }
                        , [] )
                      else if
                        Model.is_artifact_doc_search_active m
                        && not
                             (String.equal m.knowledge.artifact_search_query "")
                      then
                        ( {
                            m with
                            knowledge =
                              Knowledge_store.set_artifact_search "" m.knowledge;
                          }
                        , [] )
                      else if
                        Model.is_board_detail_active m
                        && m.knowledge.thread_view = Knowledge_store.Thread_comments
                      then
                        ( {
                            m with
                            knowledge =
                              m.knowledge
                              |> Knowledge_store.reset_thread_view
                              |> Knowledge_store.clear_armed_vote;
                          }
                        , [] )
                      else if
                        m.infra.show_raw_json
                        && Model.detail_visible m
                        && ((Nav.equal_workspace m.nav.workspace Nav.Work
                             && (Nav.equal_work_tab m.work.active_tab
                                   Nav.Work_pipeline
                                 || Nav.equal_work_tab m.work.active_tab
                                      Nav.Work_tasks))
                            || (Nav.equal_workspace m.nav.workspace Nav.Runtime
                                && Nav.equal_runtime_tab m.runtime.active_tab
                                     Nav.Runtime_failover_lanes)
                            || (Nav.equal_workspace m.nav.workspace Nav.Infra
                                && Nav.equal_infra_tab m.infra.active_tab
                                     Nav.Infra_sandboxes))
                      then
                        let next =
                          {
                            m with
                            infra =
                              {
                                m.infra with
                                show_raw_json = false;
                                detail_scroll_offset = 0;
                              };
                            runtime =
                              { m.runtime with detail_scroll_offset = 0 };
                            nav = { m.nav with json_scroll_offset = 0 };
                          }
                          |> Update_nav.clamp_for_pane
                        in
                        (next, [])
                      else if
                        Knowledge_store.is_memory_diff_pinned m.knowledge
                        && Nav.equal_workspace m.nav.workspace Nav.Keepers
                        && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                             Nav.Keeper_memory
                      then
                        let next =
                          {
                            m with
                            knowledge =
                              Knowledge_store.unpin_memory_diff_revs m.knowledge;
                          }
                        in
                        (next, View_fetches.fetches_for_current_view next)
                      else if m.nav.zoomed && Model.can_zoom_current_view m then
                        let knowledge =
                          if Nav.equal_workspace m.nav.workspace Nav.Knowledge
                          then reset_knowledge_zoom_transient m.knowledge
                          else m.knowledge
                        in
                        let m0 =
                          {
                            m with
                            knowledge;
                            nav =
                              {
                                m.nav with
                                zoomed = false;
                                pre_zoom_pane_index = None;
                              };
                          }
                        in
                        let max_pane =
                          max 0 (Model.focusable_pane_count m0 - 1)
                        in
                        let restored =
                          match m.nav.pre_zoom_pane_index with
                          | Some p -> max 0 (min max_pane p)
                          | None -> max 0 (min max_pane m0.nav.pane_index)
                        in
                        ( { m0 with nav = { m0.nav with pane_index = restored } }
                        , [] )
                      else if
                        Knowledge_store.is_memory_diff_pinned m.knowledge
                        && Nav.equal_workspace m.nav.workspace Nav.Knowledge
                        && Nav.equal_knowledge_tab m.knowledge.active_tab
                             Nav.Knowledge_memory
                      then
                        let next =
                          {
                            m with
                            knowledge =
                              Knowledge_store.unpin_memory_diff_revs m.knowledge;
                          }
                        in
                        (next, View_fetches.fetches_for_current_view next)
                      else if
                        Nav.equal_workspace m.nav.workspace Nav.Keepers
                        && m.nav.pane_index = 1
                        && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                             Nav.Keeper_config
                      then
                        ({ m with nav = { m.nav with pane_index = 0 } }, [])
                      else if
                        Nav.equal_workspace m.nav.workspace Nav.Infra
                        && Nav.equal_infra_tab m.infra.active_tab Nav.Infra_code
                        && not
                             (Infra_store.equal_code_right_mode
                                m.infra.code.right_mode Infra_store.Code_file)
                      then
                        ( {
                            m with
                            infra =
                              Infra_store.set_code_right_mode
                                Infra_store.Code_file m.infra;
                          }
                        , [] )
                      else if
                        Nav.equal_workspace m.nav.workspace Nav.Runtime
                        && Nav.equal_runtime_tab m.runtime.active_tab
                             Nav.Runtime_addons_browser
                        && m.runtime.addon_catalog_mode
                      then
                        let next =
                          {
                            m with
                            nav = { m.nav with pane_index = 0 };
                            runtime =
                              { m.runtime with addon_catalog_mode = false };
                          }
                          |> Update_nav.clamp_for_pane
                        in
                        (next, [])
                      else
                        match Update_nav.pop_workspace_return m with
                        | Some res -> res
                        | None ->
                            if
                              not
                                (String.equal (Update_nav.current_filter_query m) "")
                            then Update_nav.set_active_filter_query "" m
                            else if
                              Nav.equal_workspace m.nav.workspace Nav.Work
                              && Nav.equal_work_tab m.work.active_tab Nav.Work_tasks
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
                            else if
                              Nav.equal_workspace m.nav.workspace Nav.Work
                              && Nav.equal_work_tab m.work.active_tab
                                   Nav.Work_pipeline
                              && not
                                   (Work_store.equal_goal_phase_filter
                                      m.work.goal_phase_filter
                                      Work_store.Goal_filter_all)
                            then
                              ( {
                                  m with
                                  nav = { m.nav with pane_index = 0 };
                                  work =
                                    Work_store.set_goal_phase_filter
                                      Work_store.Goal_filter_all m.work;
                                }
                              , [] )
                            else (m, [])))
  | Keymap.Open_settings -> Update_nav.open_global_settings m
  | Keymap.Teleport_blocked -> Update_nav.teleport_blocked ~now m
  | Keymap.Open_incidents ->
      let incidents =
        m.incidents |> Incidents.reset_view |> Incidents.mark_all_read
      in
      Update_nav.open_overlay { m with incidents } Nav.Incidents
  | Keymap.Voice_ptt_toggle -> Update_nav.toggle_voice ~now m
  | Keymap.Fast_approve_top -> Update_nav.fast_approve_top ~now m
  | Keymap.Fast_deny_top -> Update_nav.fast_deny_top ~now m
  | Keymap.Ask_select_choice choice_1based -> (
      match find_actionable_ask m with
      | Some ask -> (
          match ask.questions with
          | [ q ] when q.mode = Wire_work.Ask_single ->
              Update_nav.submit_ask_choice ~now ask ~choice_1based m
          | _ ->
              Update_nav.open_ask_modal ~preselect_choice_1based:choice_1based
                m ask)
      | None -> (m, []))
  | Keymap.Open_help -> (
      match m.nav.overlay with
      | Some Nav.Help ->
          ( {
              m with
              nav =
                {
                  m.nav with
                  overlay = m.nav.return_overlay;
                  return_overlay = None;
                };
            }
          , [] )
      | Some
          ( Nav.Palette
          | Nav.Settings _
          | Nav.Incidents
          | Nav.Queue_context _
          | Nav.Inline_action _
          | Nav.Ask_answer
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
              && Option.is_none (Model.active_inspector m)
              && Nav.equal_workspace m.nav.workspace Nav.Knowledge
              && Nav.equal_knowledge_tab m.knowledge.active_tab
                   Nav.Knowledge_memory))
      in
      if in_memory_surface then
        Update_nav.open_memory_diagram ~now
          ~kind:Knowledge_store.Diagram_formation_tree m
      else apply_slash_tools ~now None m
  | Keymap.Open_queue_context -> (
      match m.nav.overlay with
      | Some (Nav.Queue_context _) ->
          ({ m with nav = { m.nav with overlay = None } }, [])
      | Some
          ( Nav.Palette
          | Nav.Settings _
          | Nav.Incidents
          | Nav.Inline_action _
          | Nav.Ask_answer
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
      match board_recovery_keeper m, dir with
      | Some keeper, (Keymap.Up | Down | Page_up | Page_down | Home | End) ->
          let board_recovery = Board_recovery.move ~keeper ~direction:dir ~page_rows:m.viewport.rows
              m.knowledge.board_recovery in
          (set_board_recovery m board_recovery, [])
      | Some _, (Keymap.Left | Right) | None, _ ->
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
              | Nav.Ask_answer
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
          (* Space in Settings is strictly local-only and never emits any HTTP
             POST (no Post_config_patch, no Post_tui_preference). In Pane_tree
             it expands/collapses tree groups; in Pane_inspector it toggles
             local Field_bool values (staged for [Ctrl+S]). Enum values such as
             tui.theme/tui.language/tui.board_sort use [←→] or [Enter]. *)
          let two_pane = Config_store.is_two_pane_width ~cols:m.viewport.cols in
          let cfg0 =
            if not two_pane then
              Config_store.set_pane Config_store.Pane_inspector m.config
            else m.config
          in
          match cfg0.settings_pane with
          | Config_store.Pane_tree ->
              let config = Config_store.toggle_tree_node cfg0 in
              let nav =
                { m.nav with overlay = Some (Nav.Settings config.active_tab) }
              in
              ({ m with nav; config }, [])
          | Config_store.Pane_inspector -> (
              match Config_store.selected_field cfg0 with
              | Some { writable = true; kind = Wire_config.Field_bool; _ } -> (
                  match Config_store.step_selected_field ~delta:1 cfg0 with
                  | Ok (config, true) -> ({ m with config }, [])
                  | Ok _ | Error _ -> (m, []))
              | Some
                  {
                    kind =
                      ( Wire_config.Field_bool
                      | Wire_config.Field_int _
                      | Wire_config.Field_float _
                      | Wire_config.Field_string
                      | Wire_config.Field_enum _
                      | Wire_config.Field_string_list
                      | Wire_config.Field_structured
                      | Wire_config.Field_secret );
                    _;
                  }
              | None ->
                  (m, [])))
      | Some Nav.Ask_answer -> (
          match m.ask_modal with
          | None -> (m, [])
          | Some modal when modal.editing_free_text -> (m, [])
          | Some modal -> (
              match Model.ask_modal_current_row modal with
              | Some (Model.Ask_row_choice (idx, _)) ->
                  ( {
                      m with
                      ask_modal =
                        Some (Model.ask_modal_toggle_or_select_choice idx modal);
                    }
                  , [] )
              | Some Model.Ask_row_free_text ->
                  ( {
                      m with
                      ask_modal = Some (Model.ask_modal_enter_free_text modal);
                    }
                  , [] )
              | Some Model.Ask_row_skip ->
                  ( {
                      m with
                      ask_modal = Some (Model.ask_modal_toggle_skip modal);
                    }
                  , [] )
              | None -> (m, [])))
      | Some Nav.Incidents ->
          let incidents =
            if m.incidents.zoomed then Incidents.toggle_raw_json m.incidents
            else Incidents.toggle_show_dismissed m.incidents
          in
          ({ m with incidents }, [])
      | Some
          ( Nav.Palette
          | Nav.Queue_context _
          | Nav.Inline_action _
          | Nav.Help
          | Nav.System_gate _ ) ->
          (m, [])
      | None ->
          if Model.sidebar_has_focus m then (m, [])
          else (
          match Model.active_inspector m with
          | Some (Nav.Verification_inspector _) ->
              let infra = Infra_store.toggle_raw_json m.infra in
              let pane_index =
                if infra.show_raw_json then m.nav.pane_index else 0
              in
              let next =
                {
                  m with
                  infra;
                  nav = { m.nav with pane_index; json_scroll_offset = 0 };
                }
                |> Update_nav.clamp_for_pane
              in
              (next, [])
          | Some
              ( Nav.Tool_inspector _
              | Nav.Skill_inspector _
              | Nav.Exact_run_inspector _ ) ->
              (m, [])
          | None -> (
              match m.nav.workspace with
              | Nav.Keepers ->
                  if
                    (m.nav.pane_index >= 1 || m.nav.zoomed)
                    && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                         Nav.Keeper_chat
                  then apply_toggle_turn_details ~now m
                  else if
                    (m.nav.pane_index >= 1 || m.nav.zoomed)
                    && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                         Nav.Keeper_trace
                  then
                    match Model.selected_keeper_name m with
                    | Some name ->
                        let ks =
                          Keeper_context_store.get_keeper ~keeper:name
                            m.keeper_context
                        in
                        if
                          Keeper_context_store.equal_trace_section
                            ks.trace_section
                            Keeper_context_store.Trace_tool_calls
                        then
                          Update_nav.keeper_enter_action ~name
                            ~tab:Nav.Keeper_trace m
                        else (m, [])
                    | None -> (m, [])
                  else if
                    (m.nav.pane_index >= 1 || m.nav.zoomed)
                    && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                         Nav.Keeper_memory
                  then
                    if
                      Knowledge_store.equal_keeper_memory_subview
                        m.knowledge.keeper_memory_subview
                        Knowledge_store.Kmem_facts_tree
                    then
                      match Model.selected_keeper_name m with
                      | Some name ->
                          Update_nav.keeper_enter_action ~name
                            ~tab:Nav.Keeper_memory m
                      | None -> (m, [])
                    else (m, [])
                  else if
                    (m.nav.pane_index >= 1 || m.nav.zoomed)
                    && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                         Nav.Keeper_identity
                  then
                    (* OAuth switch moved to explicit [a] / [Enter] so Space never POSTs. *)
                    (m, [])
                  else if m.nav.pane_index = 0 then
                    match m.fleet.selected_collapsed_company with
                    | Some company ->
                        ( {
                            m with
                            fleet =
                              Fleet_store.toggle_company_collapsed company
                                m.fleet;
                          }
                        , [] )
                    | None -> (
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
                  else (m, [])
              | Nav.Knowledge -> (
                  match m.knowledge.active_tab with
                  | Nav.Knowledge_board -> (
                      (* Space strictly controls Succession Chain expand/collapse
                         for chains with >1 member! Signal-only toggle is on [s]. *)
                      match
                        Knowledge_store.selected_post_expandable_chain_root
                          m.knowledge
                      with
                      | Some root_id ->
                          ( {
                              m with
                              knowledge =
                                Knowledge_store.toggle_succession_chain ~root_id
                                  m.knowledge;
                            }
                          , [] )
                      | None -> (m, []))
                  | Nav.Knowledge_wiki
                  | Nav.Knowledge_artifacts
                  | Nav.Knowledge_memory ->
                      (m, []))
              | Nav.Runtime -> (
                  match m.runtime.active_tab with
                  | Nav.Runtime_failover_lanes ->
                      if Model.detail_pane_focused ~detail_index:1 m then
                        ( {
                            m with
                            infra = Infra_store.toggle_raw_json m.infra;
                            runtime =
                              { m.runtime with detail_scroll_offset = 0 };
                            nav = { m.nav with json_scroll_offset = 0 };
                          }
                        , [] )
                      else
                        ( {
                            m with
                            runtime =
                              Runtime_store.toggle_outside_lane_probes m.runtime;
                          }
                        , [] )
                  | Nav.Runtime_addons_browser ->
                      if m.nav.pane_index = 1 && not m.runtime.addon_catalog_mode
                      then
                        ( {
                            m with
                            runtime =
                              Runtime_store.toggle_browser_right_focus m.runtime;
                          }
                        , [] )
                      else (m, [])
                  | Nav.Runtime_quotas_credits
                  | Nav.Runtime_efficiency_spend
                  | Nav.Runtime_fusion
                  | Nav.Runtime_tools_usage
                  | Nav.Runtime_connectors ->
                      (m, []))
              | Nav.Work -> (
                  match m.work.active_tab with
                  | Nav.Work_tasks ->
                      if
                        Model.is_work_task_zoomed m
                        || Model.detail_pane_focused ~detail_index:1 m
                      then
                        let infra = Infra_store.toggle_raw_json m.infra in
                        let next =
                          {
                            m with
                            infra;
                            nav = { m.nav with json_scroll_offset = 0 };
                          }
                          |> Update_nav.clamp_for_pane
                        in
                        (next, [])
                      else
                        let next =
                          {
                            m with
                            work = Work_store.cycle_task_status_filter m.work;
                          }
                        in
                        (next, [])
                  | Nav.Work_pipeline ->
                      let detail_idx =
                        if Model.work_pipeline_has_linked_card m then 2 else 1
                      in
                      if
                        Model.is_work_goal_zoomed m
                        || Model.detail_pane_focused ~detail_index:detail_idx m
                      then
                        let infra = Infra_store.toggle_raw_json m.infra in
                        let next =
                          {
                            m with
                            infra;
                            nav = { m.nav with json_scroll_offset = 0 };
                          }
                          |> Update_nav.clamp_for_pane
                        in
                        (next, [])
                      else
                        let work = Work_store.cycle_goal_phase_filter m.work in
                        let lbl =
                          match work.goal_phase_filter with
                          | Work_store.Goal_filter_all ->
                              Say.make ~ko:"목표 필터: 전체" ~en:"Goals filter: All"
                          | Work_store.Goal_filter_active ->
                              Say.make ~ko:"목표 필터: 진행 중" ~en:"Goals filter: Active"
                          | Work_store.Goal_filter_verifying ->
                              Say.make ~ko:"목표 필터: 검증/확인" ~en:"Goals filter: Verifying"
                          | Work_store.Goal_filter_held ->
                              Say.make ~ko:"목표 필터: 보류/차단" ~en:"Goals filter: Held"
                          | Work_store.Goal_filter_closed ->
                              Say.make ~ko:"목표 필터: 완료/중단" ~en:"Goals filter: Closed"
                        in
                        ( Model.with_toast ~now ~level:Model.Toast_info lbl
                            { m with work }
                        , [] )
                  | Nav.Work_schedules
                  | Nav.Work_inbox
                  | Nav.Work_candle_scorecard
                  | Nav.Work_harness ->
                      (m, []))
              | Nav.Infra -> (
                  match m.infra.active_tab with
                  | Nav.Infra_activity_logs
                    when not (m.nav.zoomed && Model.can_zoom_current_view m) ->
                      ( {
                          m with
                          infra = Infra_store.cycle_log_level_filter m.infra;
                        }
                      , [] )
                  | Nav.Infra_activity_logs -> (m, [])
                  | Nav.Infra_code
                    when m.nav.pane_index = 0
                         && not (m.nav.zoomed && Model.can_zoom_current_view m)
                    -> (
                      match Infra_store.selected_code_tree_node m.infra with
                      | Some node when node.has_children ->
                          let was_expanded =
                            Infra_store.String_set.mem node.path
                              m.infra.code.expanded_dirs
                          in
                          let infra =
                            Infra_store.toggle_code_dir node.path m.infra
                          in
                          let cmds =
                            if
                              (not was_expanded)
                              && not
                                   (Infra_store.String_map.mem node.path
                                      infra.code.children_by_dir)
                            then
                              [
                                Cmd.Http_get
                                  {
                                    epoch = m.epoch;
                                    req =
                                      Cmd.Get_workspace_children
                                        {
                                          scope = m.infra.code.scope;
                                          dir = node.path;
                                        };
                                  };
                              ]
                            else []
                          in
                          ({ m with infra }, cmds)
                      | Some _ | None -> (m, []))
                  | Nav.Infra_sandboxes
                    when Model.detail_pane_focused ~detail_index:1 m ->
                      ( {
                          m with
                          infra =
                            {
                              (Infra_store.toggle_raw_json m.infra) with
                              detail_scroll_offset = 0;
                            };
                          nav = { m.nav with json_scroll_offset = 0 };
                        }
                      , [] )
                  | Nav.Infra_code
                  | Nav.Infra_sandboxes
                  | Nav.Infra_repos_changes ->
                      (m, []))
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
                  | Cmd.Http_delete _
                  | Cmd.Http_post_stream _
                  | Cmd.Sync_streams _
                  | Cmd.Update_workspace_guard _
                  | Cmd.Voice_cmd _
                  | Cmd.Copy_clipboard _
                  | Cmd.Render_memory_diagram _
                  | Cmd.Cancel_memory_diagram
                  | Cmd.Fetch_artifact_and_copy _
                  | Cmd.Export_artifact _
                  | Cmd.Open_dos_screen _
                  | Cmd.Open_external_url _
                  | Cmd.Open_editor_escape_hatch _
                  | Cmd.Open_terminal_program _
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
          | Nav.Ask_answer
          | Nav.Help
          | Nav.System_gate _ ) ->
          (m, [])
      | None ->
          if Model.sidebar_has_focus m then (m, [])
          else (
          match Model.active_inspector m with
          | Some (Nav.Skill_inspector _) ->
              execute_slash ~now m (Slash.Skill Slash.Skill_new)
          | Some
              ( Nav.Verification_inspector _
              | Nav.Tool_inspector _
              | Nav.Exact_run_inspector _ ) ->
              (m, [])
          | None -> (
              match m.nav.workspace with
              | Nav.Knowledge -> (
                  match m.knowledge.active_tab with
                  | Nav.Knowledge_board ->
                      Update_nav.open_inline_modal m Nav.Board_new_post
                  | Nav.Knowledge_artifacts
                    when Model.is_artifact_doc_search_active m
                         && not
                              (String.equal
                                 (String.trim m.knowledge.artifact_search_query)
                                 "") ->
                      step_artifact_search ~now ~delta:1 m
                  | Nav.Knowledge_wiki
                  | Nav.Knowledge_artifacts
                  | Nav.Knowledge_memory ->
                      (m, []))
              | Nav.Work -> (
                  match m.work.active_tab with
                  | Nav.Work_pipeline -> open_goal_upsert_modal m ()
                  | Nav.Work_tasks ->
                      Update_nav.open_inline_modal m Nav.Task_create_form
                  | Nav.Work_schedules ->
                      Update_nav.open_schedule_form_populated m
                  | Nav.Work_harness ->
                      open_harness_overrule_for_selected ~verdict:"reject" ~now m
                  | Nav.Work_inbox | Nav.Work_candle_scorecard ->
                      ( Model.with_toast ~now ~level:Model.Toast_info
                          (Say.make
                             ~ko:
                               "목표 생성은 목표(Goals), 작업 생성은 작업(Tasks), 일정 생성은 일정(Schedules) 탭에서 [n]을 누르세요"
                             ~en:
                               "Press [n] on Goals to create a goal, Tasks to add a task, or Schedules to add a schedule")
                          m
                      , [] ))
              | Nav.Runtime -> (
                  match m.runtime.active_tab with
                  | Nav.Runtime_connectors -> open_connector_form_populated m
                  | Nav.Runtime_failover_lanes ->
                      open_runtime_lane_create_modal m
                  | Nav.Runtime_addons_browser ->
                      open_addon_attach_modal m
                  | Nav.Runtime_tools_usage -> (
                      match m.runtime.tools_subview with
                      | Runtime_store.Tools_keeper_skills ->
                          execute_slash ~now m (Slash.Skill Slash.Skill_new)
                      | Runtime_store.Tools_prompts_presets -> (
                          match m.runtime.pp_section with
                          | Runtime_store.Sec_presets ->
                              Update_nav.open_inline_modal m
                                Nav.Preset_create_form
                          | Runtime_store.Sec_prompts
                          | Runtime_store.Sec_params
                          | Runtime_store.Sec_async_requests ->
                              (m, []))
                      | Runtime_store.Tools_usage_calls
                      | Runtime_store.Tools_catalog_tree
                      | Runtime_store.Tools_quality_gate ->
                          (m, []))
                  | Nav.Runtime_quotas_credits
                  | Nav.Runtime_efficiency_spend
                  | Nav.Runtime_fusion ->
                      (m, []))
              | Nav.Infra -> (
                  match m.infra.active_tab with
                  | Nav.Infra_repos_changes ->
                      Update_nav.open_inline_modal m Nav.Repo_add_form
                  | Nav.Infra_sandboxes
                  | Nav.Infra_code
                  | Nav.Infra_activity_logs ->
                      (m, []))
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
      else (match board_recovery_keeper m with
      | Some keeper -> View_fetches.read_board_quarantines ~keeper ~now m
      | None ->
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
              | Nav.Runtime_fusion
              | Nav.Runtime_tools_usage
              | Nav.Runtime_connectors
              | Nav.Runtime_addons_browser ) ) ->
              []
        in
        let next, diagram_cmds =
          if Option.is_some (Memory_diagram.active_diagram next) then
            Update_nav.refresh_open_memory_diagram ~now next
          else (next, [])
        in
        let oauth_refresh_cmd =
          match active_keeper_for_tab Nav.Keeper_identity next with
          | None -> []
          | Some keeper -> (
              let ks =
                Keeper_context_store.get_keeper ~keeper next.keeper_context
              in
              let entries = Update_nav.keeper_identity_entries next ~name:keeper in
              match
                List.nth_opt entries
                  (Update_nav.clamp_index (List.length entries)
                     ks.identity_selected_idx)
              with
              | Some
                  (Update_nav.Identity_oauth { provider; attached = true; _ }) ->
                  [
                    Cmd.Http_post
                      {
                        epoch = next.epoch;
                        req =
                          Cmd.Post_oauth_identity_refresh { keeper; provider };
                      };
                  ]
              | Some
                  ( Update_nav.Identity_oauth { attached = false; _ }
                  | Update_nav.Identity_github )
              | None ->
                  [])
        in
        ( Model.with_toast ~now ~level:Model.Toast_info
            (Say.make ~ko:"현재 화면 새로고침 중" ~en:"Refreshing active view")
            next
        , view_cmds @ probe_cmd @ diagram_cmds @ oauth_refresh_cmd ))
  | Keymap.Copy_selected -> (
      let copy_artifact_body (a : Wire_knowledge.artifact_entry) =
        let fmt_label =
          match Wire_knowledge.artifact_format_of_entry a with
          | `Html -> "HTML"
          | `Markdown -> "Markdown"
        in
        match Knowledge_store.artifact_detail_for_entry a m.knowledge with
        | Some detail ->
            ( Model.with_toast ~now ~level:Model.Toast_info
                (Say.make
                   ~ko:(Printf.sprintf "%s 본문 복사 중 (%dB)" fmt_label
                          (String.length detail.content))
                   ~en:(Printf.sprintf "Copying %s body (%dB)" fmt_label
                          (String.length detail.content)))
                m
            , [ Cmd.Copy_clipboard detail.content ] )
        | None ->
            ( Model.with_toast ~now ~level:Model.Toast_info
                (Say.make
                   ~ko:(Printf.sprintf "%s 본문 불러와 복사 중…" fmt_label)
                   ~en:(Printf.sprintf "Fetching %s body to copy…" fmt_label))
                m
            , [
                Cmd.Fetch_artifact_and_copy
                  { epoch = m.epoch; id = a.id; revision = Some a.revision };
              ] )
      in
      let artifact_target_opt =
        match m.nav.overlay with
        | Some (Nav.System_gate Nav.Media_viewer) -> (
            match Model.focused_artifact m with
            | Some a -> `Artifact a
            | None -> `Other)
        | Some
            ( Nav.Palette
            | Nav.Settings _
            | Nav.Queue_context _
            | Nav.Inline_action _
            | Nav.Ask_answer
            | Nav.Incidents
            | Nav.Help
            | Nav.System_gate
                (Nav.Auth_gate | Nav.Server_offline | Nav.Micro_viewport) ) ->
            `Other
        | None -> (
            match Model.active_inspector m with
            | Some _ -> `Other
            | None ->
                if
                  Nav.equal_workspace m.nav.workspace Nav.Knowledge
                  && Nav.equal_knowledge_tab m.knowledge.active_tab
                       Nav.Knowledge_artifacts
                then
                  match Knowledge_store.selected_artifact m.knowledge with
                  | Some a -> `Artifact a
                  | None -> `Other
                else `Other)
      in
      match artifact_target_opt with
      | `Artifact art -> copy_artifact_body art
      | `Other
        when Option.is_none m.nav.overlay
             && Option.is_none (Model.active_inspector m)
             && Nav.equal_workspace m.nav.workspace Nav.Work
             && Nav.equal_work_tab m.work.active_tab Nav.Work_harness ->
          open_harness_overrule_for_selected ~verdict:"approve" ~now m
      | `Other ->
      let copy_identity_for ~name =
        let ks = Keeper_context_store.get_keeper ~keeper:name m.keeper_context in
        match ks.github_login.device_code with
        | Some code -> Some code
        | None -> (
            match ks.oauth_pending_login with
            | Some (Wire_keeper_context.Oauth_login_exchange ex) ->
                Some ex.authorize_url
            | Some (Wire_keeper_context.Oauth_login_direct _) | None ->
                Some name)
      in
      let text_opt =
        match m.nav.overlay with
        | Some (Nav.Inline_action Nav.Btw_query) -> (
            match m.drafts.btw with
            | Drafts.Btw_answered { reply; _ }
              when not (String.equal (String.trim reply) "") ->
                Some reply
            | Drafts.Btw_streaming { buffer; _ }
              when not (String.equal (String.trim buffer) "") ->
                Some buffer
            | Drafts.Btw_answered _
            | Drafts.Btw_streaming _
            | Drafts.Btw_idle
            | Drafts.Btw_sending _
            | Drafts.Btw_failed _ ->
                None)
        | Some (Nav.System_gate Nav.Media_viewer) -> None
        | Some
            ( Nav.Palette
            | Nav.Settings _
            | Nav.Incidents
            | Nav.Queue_context _
            | Nav.Inline_action
                ( Nav.Gate_reject _
                | Nav.Verification_reject _
                | Nav.Harness_overrule _
                | Nav.Task_cancel _
                | Nav.Goal_drop _
                | Nav.Schedule_form
                | Nav.Connector_form
                | Nav.Repo_add_form
                | Nav.Board_new_post
                | Nav.Board_goal_proposal
                | Nav.Goal_confirmation_proof
                | Nav.Memory_act_form
                | Nav.Wiki_edit_form
                | Nav.Fusion_launch_form
                | Nav.Runtime_assign_form
                | Nav.Setup_account_key_form
                | Nav.Setup_login_start_form
                | Nav.Board_comment _
                | Nav.Github_token_form _
                | Nav.Code_finder_form
                | Nav.Code_search_form
                | Nav.Keeper_control_confirm _
                | Nav.Keeper_clear_form _
                | Nav.Keeper_operator_note_form _
                | Nav.Discord_reply_form _
                | Nav.Tool_execute_form _
                | Nav.Skill_create_form
                | Nav.Skill_edit_form _
                | Nav.Skill_delete_confirm _
                | Nav.Prompt_override_form _
                | Nav.Preset_create_form
                | Nav.Runtime_param_set_form _
                | Nav.Default_route_edit
                | Nav.Lane_rename_form _
                | Nav.Addon_decl_form _
                | Nav.Addon_act_form _
                | Nav.Browser_interact_form _
                | Nav.Runtime_lane_create
                | Nav.Runtime_lane_edit _
                | Nav.Runtime_lane_delete _
                | Nav.Task_create_form
                | Nav.Task_transition_form _
                | Nav.Task_link_goal _
                | Nav.Goal_upsert_form _
                | Nav.Board_delete_post _
                | Nav.Keeper_lifecycle_form _
                | Nav.Keeper_purge_confirm _
                | Nav.Addon_attach_form
                | Nav.Addon_detach_confirm _
                | Nav.Addon_invoke_action _
                | Nav.Setup_login_input_form _ )
            | Nav.Ask_answer
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
            match Model.active_inspector m with
            | Some (Nav.Verification_inspector id) -> (
                match
                  List.find_opt
                    (fun (v : Wire_work.verification_request) ->
                      String.equal v.request_id id)
                    (Work_store.verifications_list m.work)
                with
                | Some v -> Some v.task_title
                | None -> Some id)
            | Some (Nav.Tool_inspector name) -> Some name
            | Some (Nav.Skill_inspector ref_s) -> Some ref_s
            | Some (Nav.Exact_run_inspector run_id) -> Some run_id
            | None -> (
                match m.nav.workspace with
                | Nav.Knowledge -> (
                    match m.knowledge.active_tab with
                    | Nav.Knowledge_board -> (
                        match Knowledge_store.board_detail_post m.knowledge with
                        | None -> None
                        | Some p ->
                            if
                              Model.is_board_detail_active m
                              && m.knowledge.thread_view
                                 = Knowledge_store.Thread_comments
                            then
                              Option.map
                                (fun (tc : Knowledge_store.threaded_comment) ->
                                  tc.comment.body)
                                (Knowledge_store.selected_thread_comment
                                   ~post_id:p.id m.knowledge)
                            else Some p.body)
                    | Nav.Knowledge_wiki -> (
                        match Knowledge_store.selected_wiki_page m.knowledge with
                        | None -> None
                        | Some sel -> (
                            match
                              Observed.to_option
                                (Knowledge_store.wiki_page_for ~slug:sel.slug
                                   m.knowledge)
                            with
                            | Some detail
                              when not
                                     (String.equal
                                        (String.trim detail.body_markdown) "")
                              ->
                                Some detail.body_markdown
                            | Some _ | None -> Some sel.slug))
                    | Nav.Knowledge_artifacts -> None
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
                    | Nav.Infra_code ->
                        if Model.detail_pane_focused ~detail_index:1 m then
                          match Infra_store.open_file_for_current m.infra with
                          | Some f -> Some f.content
                          | None ->
                              Option.map
                                (fun (n : Wire_infra.workspace_tree_node) ->
                                  n.path)
                                (Infra_store.selected_code_tree_node m.infra)
                        else
                          Option.map
                            (fun (n : Wire_infra.workspace_tree_node) -> n.path)
                            (Infra_store.selected_code_tree_node m.infra)
                    | Nav.Infra_activity_logs -> (
                        match Infra_store.selected_timeline_entry m.infra with
                        | Some (Infra_store.Entry_log e) -> Some e.message
                        | Some (Infra_store.Entry_event ev) -> (
                            match ev.detail with
                            | Some d when not (String.equal (String.trim d) "")
                              ->
                                Some (ev.summary ^ "\n" ^ d)
                            | Some _ | None -> Some ev.summary)
                        | None -> None))
                | Nav.Keepers | Nav.Pulse -> (
                    match active_keeper_for_tab Nav.Keeper_identity m with
                    | Some name -> copy_identity_for ~name
                    | None ->
                        let in_chat =
                          Nav.equal_workspace m.nav.workspace Nav.Keepers
                          && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                               Nav.Keeper_chat
                        in
                        match
                          if in_chat then latest_keeper_reply_text m else None
                        with
                        | Some (_, reply) -> Some reply
                        | None -> Model.selected_keeper_name m)
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
                    | Nav.Work_tasks ->
                        Option.map
                          (fun (task : Wire_work.task) -> task.title)
                          (Work_store.selected_task m.work)
                    | Nav.Work_schedules ->
                        Option.map
                          (fun (s : Wire_work.schedule_row) -> s.schedule_id)
                          (Work_store.selected_schedule m.work)
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
                        | None -> None)
                    | Nav.Work_harness ->
                        Option.map
                          (fun (v : Wire_work.harness_verdict_row) ->
                            v.notes_hash)
                          (Work_store.selected_harness_verdict m.work))
                | Nav.Runtime -> (
                    match m.runtime.active_tab with
                    | Nav.Runtime_addons_browser ->
                        if m.runtime.addon_catalog_mode then
                          match
                            Runtime_store.selected_addon_catalog_entry m.runtime
                          with
                          | Some (Wire_runtime.Catalog_package { manifest_path; _ }) ->
                              Some manifest_path
                          | Some (Wire_runtime.Catalog_folder { path; _ })
                          | Some (Wire_runtime.Catalog_issue { path; _ }) ->
                              Some path
                          | None -> None
                        else if m.nav.pane_index = 0 then
                          Option.map
                            (fun (inst : Wire_runtime.addon_instance) ->
                              inst.instance_id)
                            (Runtime_store.selected_addon_instance m.runtime)
                        else (
                          match m.runtime.browser_right_focus with
                          | `Clients ->
                              Option.map
                                (fun (cl : Wire_runtime.browser_client_row) ->
                                  cl.client_id)
                                (Runtime_store.selected_browser_client m.runtime)
                          | `Tabs -> (
                              match Runtime_store.selected_browser_tab m.runtime with
                              | Some tb -> Some tb.url
                              | None ->
                                  Option.map
                                    (fun (cl : Wire_runtime.browser_client_row) ->
                                      cl.client_id)
                                    (Runtime_store.selected_browser_client
                                       m.runtime)))
                    | Nav.Runtime_tools_usage -> (
                        match m.runtime.tools_subview with
                        | Runtime_store.Tools_catalog_tree ->
                            Option.map
                              (fun (e : Wire_runtime.tool_catalog_entry) -> e.name)
                              (Runtime_store.selected_tool_catalog_entry m.runtime)
                        | Runtime_store.Tools_usage_calls ->
                            let tools = Runtime_store.filtered_tools m.runtime in
                            let idx =
                              Update_nav.clamp_index (List.length tools)
                                m.runtime.selected_index
                            in
                            Option.map
                              (fun (t : Wire_runtime.tool_summary) -> t.name)
                              (List.nth_opt tools idx)
                        | Runtime_store.Tools_keeper_skills ->
                            let keeper_names =
                              match Observed.to_option m.fleet.keepers with
                              | Some ks ->
                                  List.map
                                    (fun (k : Wire_fleet.keeper_summary) -> k.name)
                                    ks
                              | None -> []
                            in
                            Runtime_store.selected_tools_surface_keeper
                              ~keeper_names m.runtime
                        | Runtime_store.Tools_quality_gate -> (
                            match Observed.to_option m.runtime.tool_quality with
                            | Some tq ->
                                let idx =
                                  Update_nav.clamp_index
                                    (List.length tq.by_tool)
                                    m.runtime.selected_index
                                in
                                Option.map
                                  (fun (r : Wire_runtime.tool_quality_tool_row) ->
                                    r.name)
                                  (List.nth_opt tq.by_tool idx)
                            | None -> None)
                        | Runtime_store.Tools_prompts_presets -> (
                            match m.runtime.pp_section with
                            | Runtime_store.Sec_prompts ->
                                Option.map
                                  (fun (p : Wire_runtime.prompt_item) -> p.key)
                                  (Runtime_store.selected_prompt_item m.runtime)
                            | Runtime_store.Sec_presets ->
                                Option.map
                                  (fun (p : Wire_runtime.preset_manifest) ->
                                    p.name)
                                  (Runtime_store.selected_preset_manifest
                                     m.runtime)
                            | Runtime_store.Sec_params ->
                                Option.map
                                  (fun (p : Wire_runtime.runtime_param_item) ->
                                    p.key)
                                  (Runtime_store.selected_runtime_param
                                     m.runtime)
                            | Runtime_store.Sec_async_requests ->
                                Option.map
                                  (fun (r : Wire_runtime.async_request_row) ->
                                    r.request_id)
                                  (Runtime_store.selected_async_request
                                     m.runtime)))
                    | Nav.Runtime_connectors ->
                        Option.map
                          (fun (c : Wire_runtime.connector_row) -> c.connector_id)
                          (Runtime_store.selected_connector m.runtime)
                    | Nav.Runtime_fusion ->
                        Option.map
                          (fun (r : Wire_runtime.fusion_run) -> r.run_id)
                          (Runtime_store.selected_fusion_run m.runtime)
                    | Nav.Runtime_quotas_credits ->
                        let accs = Runtime_store.filtered_accounts m.runtime in
                        let idx =
                          Update_nav.clamp_index (List.length accs)
                            m.runtime.selected_index
                        in
                        Option.map
                          (fun (a : Wire_runtime.account_usage) -> a.scope_id)
                          (List.nth_opt accs idx)
                    | Nav.Runtime_efficiency_spend ->
                        Option.map
                          (fun (r : Runtime_store.keeper_spend_row) -> r.keeper)
                          (Runtime_store.selected_keeper_spend_row m.runtime)
                    | Nav.Runtime_failover_lanes ->
                        Option.map
                          (fun (l : Wire_runtime.failover_lane) -> l.id)
                          (Runtime_store.selected_lane m.runtime)))))
      in
      match text_opt with
      | Some txt ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:"클립보드에 복사됨" ~en:"Copied to clipboard")
              m
          , [ Cmd.Copy_clipboard txt ] )
      | None -> (m, []))
  | Keymap.Open_external -> (
      let export_and_open_artifact (a : Wire_knowledge.artifact_entry) =
        let ext =
          Wire_knowledge.artifact_extension
            (Wire_knowledge.artifact_format_of_entry a)
        in
        let filename_stem =
          if String.trim a.title <> "" then a.title else a.id
        in
        let content_opt =
          Option.map
            (fun (d : Wire_knowledge.published_artifact_detail) -> d.content)
            (Knowledge_store.artifact_detail_for_entry a m.knowledge)
        in
        ( Model.with_toast ~now ~level:Model.Toast_info
            (Say.make
               ~ko:(Printf.sprintf "%s 파일 내보내기 후 열기 중…" ext)
               ~en:(Printf.sprintf "Exporting & opening %s…" ext))
            m
        , [
            Cmd.Export_artifact
              {
                epoch = m.epoch;
                id = a.id;
                revision = Some a.revision;
                filename_stem;
                ext;
                content_opt;
                open_after = true;
              };
          ] )
      in
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
      | Some (Nav.System_gate Nav.Media_viewer) -> (
          match Model.focused_artifact m with
          | Some art -> export_and_open_artifact art
          | None -> (m, []))
      | Some
          ( Nav.Palette
          | Nav.Incidents
          | Nav.Queue_context _
          | Nav.Inline_action _
          | Nav.Ask_answer
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
            match
              Observed.to_option
                (Knowledge_store.wiki_page_for ~slug:expected_slug m.knowledge)
            with
            | Some detail -> (
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
            | None -> None
          in
          match Model.active_inspector m with
          | Some _ -> (m, [])
          | None -> (
              match m.nav.workspace with
              | Nav.Infra -> (
                  match m.infra.active_tab with
                  | Nav.Infra_repos_changes -> (
                      match Infra_store.selected_repository m.infra with
                      | Some repo -> (m, [ Cmd.Open_external_url repo.url ])
                      | None -> open_url_or_notice None)
                  | Nav.Infra_sandboxes
                  | Nav.Infra_code
                  | Nav.Infra_activity_logs ->
                      (m, []))
              | Nav.Knowledge -> (
                  match m.knowledge.active_tab with
                  | Nav.Knowledge_artifacts -> (
                      match Knowledge_store.selected_artifact m.knowledge with
                      | Some a -> export_and_open_artifact a
                      | None -> open_url_or_notice None)
                  | Nav.Knowledge_wiki -> (
                      match Knowledge_store.selected_wiki_page m.knowledge with
                      | Some sel ->
                          open_url_or_notice
                            (wiki_external_url ~expected_slug:sel.slug ())
                      | None -> open_url_or_notice None)
                  | Nav.Knowledge_board ->
                      let url_opt =
                        Option.bind
                          (Knowledge_store.board_detail_post m.knowledge)
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
                  | Nav.Work_tasks ->
                      let url_opt =
                        Option.bind (Work_store.selected_task m.work)
                          (fun (t : Wire_work.task) ->
                            Option.bind t.description extract_first_http_url)
                      in
                      open_url_or_notice url_opt
                  | Nav.Work_schedules
                  | Nav.Work_inbox
                  | Nav.Work_candle_scorecard
                  | Nav.Work_harness ->
                      (m, []))
              | Nav.Keepers -> (
                  match
                    (m.fleet.keeper_dive_tab, Model.selected_keeper_name m)
                  with
                  | Nav.Keeper_identity, Some name ->
                      let ks =
                        Keeper_context_store.get_keeper ~keeper:name
                          m.keeper_context
                      in
                      let url_opt =
                        match ks.github_login.device_url with
                        | Some u -> Some u
                        | None -> (
                            match ks.oauth_pending_login with
                            | Some
                                (Wire_keeper_context.Oauth_login_exchange ex) ->
                                Some ex.authorize_url
                            | Some (Wire_keeper_context.Oauth_login_direct _)
                            | None ->
                                None)
                      in
                      open_url_or_notice url_opt
                  | Nav.Keeper_work_sandbox, Some name
                    when (m.nav.pane_index >= 1 || m.nav.zoomed)
                         && not
                              (Board_recovery.shown ~keeper:name
                                 m.knowledge.board_recovery) ->
                      let infra =
                        m.infra
                        |> Infra_store.set_tab Nav.Infra_sandboxes
                        |> Infra_store.select_sandbox_by_keeper name
                      in
                      Update_nav.jump_to_workspace ~pane_index:1 ~return_from:m
                        { m with infra } Nav.Infra
                  | Nav.Keeper_work_sandbox, Some name
                    when (m.nav.pane_index >= 1 || m.nav.zoomed)
                         && Board_recovery.shown ~keeper:name
                              m.knowledge.board_recovery ->
                      (m, [])
                  | (Nav.Keeper_identity | Nav.Keeper_work_sandbox), None
                  | Nav.Keeper_work_sandbox, Some _
                  | ( ( Nav.Keeper_chat
                      | Nav.Keeper_trace
                      | Nav.Keeper_memory
                      | Nav.Keeper_config )
                    , (Some _ | None) ) ->
                      let url_opt =
                        Option.bind (latest_keeper_reply_text m) (fun (_, txt) ->
                            extract_first_http_url txt)
                      in
                      open_url_or_notice url_opt)
              | Nav.Runtime -> (
                  match m.runtime.active_tab with
                  | Nav.Runtime_addons_browser ->
                      if
                        (not m.runtime.addon_catalog_mode)
                        && m.nav.pane_index = 1
                        && m.runtime.browser_right_focus = `Tabs
                      then
                        let url_opt =
                          Option.bind
                            (Runtime_store.selected_browser_tab m.runtime)
                            (fun (tb : Wire_runtime.browser_tab_row) ->
                              extract_first_http_url tb.url)
                        in
                        open_url_or_notice url_opt
                      else
                        ( Model.with_toast ~now ~level:Model.Toast_info
                            (Say.make
                               ~ko:"브라우저 탭 패널(Tab → Space)에서 [o]로 URL을 열 수 있습니다"
                               ~en:"Focus Browser Tabs (Tab → Space) to open a tab URL with [o]")
                            m
                        , [] )
                  | Nav.Runtime_quotas_credits ->
                      open_url_or_notice m.runtime.setup_login_auth_url
                  | Nav.Runtime_efficiency_spend
                  | Nav.Runtime_failover_lanes
                  | Nav.Runtime_fusion
                  | Nav.Runtime_tools_usage
                  | Nav.Runtime_connectors ->
                      (m, []))
              | Nav.Pulse -> (m, []))))
  | Keymap.Toggle_zoom ->
      if Model.sidebar_has_focus m then (m, [])
      else if not (Model.can_zoom_current_view m) then
        if m.nav.zoomed then
          let m0 =
            {
              m with
              nav = { m.nav with zoomed = false; pre_zoom_pane_index = None };
            }
          in
          let max_pane = max 0 (Model.focusable_pane_count m0 - 1) in
          let restored =
            match m.nav.pre_zoom_pane_index with
            | Some p -> max 0 (min max_pane p)
            | None -> max 0 (min max_pane m0.nav.pane_index)
          in
          ({ m0 with nav = { m0.nav with pane_index = restored } }, [])
        else (m, [])
      else
        let zoomed = not m.nav.zoomed in
        let next =
          if zoomed then
            let z_pane =
              if
                Nav.equal_workspace m.nav.workspace Nav.Keepers
                && Model.keeper_preview_has_inner_split m
                && m.nav.pane_index >= 2
              then 1
              else 0
            in
            let drafts =
              if Nav.equal_workspace m.nav.workspace Nav.Keepers then
                match Model.selected_keeper_name m with
                | Some name -> Drafts.set_active_keeper name m.drafts
                | None -> m.drafts
              else m.drafts
            in
            let work =
              if Nav.equal_workspace m.nav.workspace Nav.Work then
                match m.work.active_tab with
                | Nav.Work_pipeline -> Work_store.reset_goal_dive_state m.work
                | Nav.Work_tasks -> Work_store.reset_task_dive_scroll m.work
                | Nav.Work_schedules
                | Nav.Work_inbox
                | Nav.Work_candle_scorecard
                | Nav.Work_harness ->
                    m.work
              else m.work
            in
            {
              m with
              drafts;
              work;
              nav =
                {
                  m.nav with
                  zoomed = true;
                  pre_zoom_pane_index = Some m.nav.pane_index;
                  pane_index = z_pane;
                  json_scroll_offset = 0;
                };
            }
          else
            let knowledge =
              if Nav.equal_workspace m.nav.workspace Nav.Knowledge then
                reset_knowledge_zoom_transient m.knowledge
              else m.knowledge
            in
            let m0 =
              {
                m with
                knowledge;
                nav =
                  {
                    m.nav with
                    zoomed = false;
                    pre_zoom_pane_index = None;
                    json_scroll_offset = 0;
                  };
                infra = { m.infra with show_raw_json = false };
              }
            in
            let max_pane = max 0 (Model.focusable_pane_count m0 - 1) in
            let restored =
              match m.nav.pre_zoom_pane_index with
              | Some p -> max 0 (min max_pane p)
              | None -> max 0 (min max_pane m0.nav.pane_index)
            in
            { m0 with nav = { m0.nav with pane_index = restored } }
        in
        if Option.is_some (Memory_diagram.active_diagram next) then
          Update_nav.refresh_open_memory_diagram ~now next
        else if zoomed then
          (next, View_fetches.fetches_for_current_view next)
        else (next, [])
  | Keymap.Cycle_memory_view ->
      let trace_keeper_opt =
        if
          Option.is_none m.nav.overlay
          && (not (Model.sidebar_has_focus m))
          && Option.is_none (Model.active_inspector m)
          && Nav.equal_workspace m.nav.workspace Nav.Keepers
          && (m.nav.pane_index >= 1 || m.nav.zoomed)
          && Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_trace
        then Model.selected_keeper_name m
        else None
      in
      (match trace_keeper_opt with
      | Some keeper ->
          let keeper_context =
            Keeper_context_store.cycle_trace_section ~keeper ~delta:1
              m.keeper_context
          in
          let next = { m with keeper_context } |> Update_nav.clamp_for_pane in
          (next, View_fetches.fetches_for_current_view next)
      | None ->
          let in_memory =
            Option.is_none m.nav.overlay
            && (not (Model.sidebar_has_focus m))
            &&
            match Model.active_inspector m with
            | Some _ -> false
            | None -> (
                match m.nav.workspace with
                | Nav.Knowledge ->
                    Nav.equal_knowledge_tab m.knowledge.active_tab
                      Nav.Knowledge_memory
                    && Knowledge_store.equal_memory_subview
                         m.knowledge.memory_subview
                         Knowledge_store.Mem_diff_flow
                | Nav.Keepers ->
                    Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                      Nav.Keeper_memory
                | Nav.Pulse | Nav.Work | Nav.Runtime | Nav.Infra -> false)
          in
          if in_memory then
            let knowledge =
              Knowledge_store.cycle_memory_view_mode m.knowledge
            in
            let nav =
              if Nav.equal_workspace m.nav.workspace Nav.Keepers then
                { m.nav with keeper_detail_scroll_offset = 0 }
              else m.nav
            in
            let next = { m with nav; knowledge } in
            (next, View_fetches.fetches_for_current_view next)
          else (m, []))
  | Keymap.Toggle_memory_sort ->
      let in_memory =
        Option.is_none m.nav.overlay
        && (not (Model.sidebar_has_focus m))
        &&
        match Model.active_inspector m with
        | Some _ -> false
        | None -> (
            match m.nav.workspace with
            | Nav.Knowledge ->
                Nav.equal_knowledge_tab m.knowledge.active_tab
                  Nav.Knowledge_memory
                && Knowledge_store.equal_memory_subview
                     m.knowledge.memory_subview Knowledge_store.Mem_diff_flow
            | Nav.Keepers ->
                Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_memory
            | Nav.Pulse | Nav.Work | Nav.Runtime | Nav.Infra -> false)
      in
      if in_memory then
        ( {
            m with
            knowledge = Knowledge_store.toggle_memory_facts_sort m.knowledge;
          }
        , [] )
      else (m, [])
  | Keymap.Cycle_signal_or_source -> (
      if Option.is_some m.nav.overlay || Option.is_some (Model.active_inspector m)
      then (m, [])
      else
        match m.nav.workspace with
        | Nav.Knowledge
          when Nav.equal_knowledge_tab m.knowledge.active_tab
                 Nav.Knowledge_board ->
            let knowledge = Knowledge_store.toggle_signal_only m.knowledge in
            let next = { m with knowledge } in
            (next, View_fetches.fetches_for_current_view next)
        | Nav.Infra
          when Nav.equal_infra_tab m.infra.active_tab Nav.Infra_code ->
            let scope = next_code_scope m in
            let infra = Infra_store.set_code_scope scope m.infra in
            let scope_lbl =
              match scope with
              | Wire_infra.Ws_project -> "project"
              | Wire_infra.Ws_repo id -> "repo:" ^ id
              | Wire_infra.Ws_keeper k -> "keeper:" ^ k
            in
            let next =
              { m with infra }
              |> Model.with_toast ~now ~level:Model.Toast_info
                   (Say.make
                      ~ko:("코드 범위: " ^ scope_lbl)
                      ~en:("Code scope: " ^ scope_lbl))
            in
            (next, View_fetches.fetches_for_current_view next)
        | Nav.Infra
          when Nav.equal_infra_tab m.infra.active_tab Nav.Infra_activity_logs ->
            let infra = Infra_store.cycle_source_filter m.infra in
            let mode_lbl =
              match infra.source_filter with
              | Infra_store.Source_all ->
                  Say.make ~ko:"전체 (로그+이벤트)" ~en:"ALL (Logs+Events)"
              | Infra_store.Source_logs ->
                  Say.make ~ko:"서버 로그만" ~en:"LOGS only"
              | Infra_store.Source_events ->
                  Say.make ~ko:"MASC 이벤트만" ~en:"EVENTS only"
            in
            ( Model.with_toast ~now ~level:Model.Toast_info
                (Say.make
                   ~ko:("피드 소스: " ^ Say.resolve Say.Lang_ko mode_lbl)
                   ~en:("Feed source: " ^ Say.resolve Say.Lang_en mode_lbl))
                { m with infra }
            , [] )
        | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Runtime
        | Nav.Infra ->
            (m, []))
  | Keymap.Cycle_sort_or_speak -> (
      if Option.is_some m.nav.overlay then (m, [])
      else
        match Model.active_inspector m with
        | Some _ -> (m, [])
        | None -> (
            match m.nav.workspace with
            | Nav.Knowledge
              when Nav.equal_knowledge_tab m.knowledge.active_tab
                     Nav.Knowledge_board ->
                let knowledge = Knowledge_store.cycle_board_sort m.knowledge in
                let next =
                  { m with knowledge }
                  |> Model.with_toast ~now ~level:Model.Toast_info
                       (Say.make
                          ~ko:("보드 정렬: " ^ knowledge.board_sort_by)
                          ~en:("Board sort: " ^ knowledge.board_sort_by))
                in
                (next, View_fetches.fetches_for_current_view next)
            | Nav.Work
              when Nav.equal_work_tab m.work.active_tab Nav.Work_pipeline
                   && not (Model.is_work_goal_zoomed m) ->
                let work = Work_store.cycle_goal_sort_mode m.work in
                let lbl =
                  match work.goal_sort_mode with
                  | Work_store.Goal_sort_default ->
                      Say.make ~ko:"목표 정렬: 기본순" ~en:"Goals sort: Default"
                  | Work_store.Goal_sort_phase ->
                      Say.make ~ko:"목표 정렬: 단계순" ~en:"Goals sort: Phase"
                  | Work_store.Goal_sort_progress ->
                      Say.make ~ko:"목표 정렬: 진행률순" ~en:"Goals sort: Progress"
                  | Work_store.Goal_sort_recent ->
                      Say.make ~ko:"목표 정렬: 최신순" ~en:"Goals sort: Recent"
                in
                ( Model.with_toast ~now ~level:Model.Toast_info lbl
                    { m with work }
                , [] )
            | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Runtime
            | Nav.Infra ->
                (m, [])))
  | Keymap.Cycle_hearth_or_overrule -> (
      if Option.is_some m.nav.overlay then (m, [])
      else
        match Model.active_inspector m with
        | Some (Nav.Verification_inspector _) ->
            Update_nav.open_harness_overrule_for_context ~verdict:"approve" ~now
              m
        | Some
            ( Nav.Tool_inspector _
            | Nav.Skill_inspector _
            | Nav.Exact_run_inspector _ ) ->
            (m, [])
        | None -> (
            match m.nav.workspace with
            | Nav.Knowledge
              when Nav.equal_knowledge_tab m.knowledge.active_tab
                     Nav.Knowledge_board ->
                let knowledge = Knowledge_store.cycle_board_hearth m.knowledge in
                let label = Option.value knowledge.board_hearth ~default:"all" in
                let next =
                  { m with knowledge }
                  |> Model.with_toast ~now ~level:Model.Toast_info
                       (Say.make
                          ~ko:("서브보드: #" ^ label)
                          ~en:("Hearth: #" ^ label))
                in
                (next, View_fetches.fetches_for_current_view next)
            | Nav.Work -> (
                match m.work.active_tab with
                | Nav.Work_harness | Nav.Work_pipeline | Nav.Work_tasks ->
                    Update_nav.open_harness_overrule_for_context
                      ~verdict:"approve" ~now m
                | Nav.Work_schedules
                | Nav.Work_inbox
                | Nav.Work_candle_scorecard ->
                    (m, []))
            | Nav.Pulse | Nav.Keepers | Nav.Runtime | Nav.Infra | Nav.Knowledge
              ->
                (m, [])))
  | Keymap.Cycle_time_window -> (
      if Option.is_some m.nav.overlay then (m, [])
      else
        match Model.active_inspector m with
        | Some (Nav.Tool_inspector _) ->
            let runtime = Runtime_store.cycle_tools_window m.runtime in
            let next = { m with runtime } in
            (next, View_fetches.fetches_for_current_view next)
        | Some
            ( Nav.Verification_inspector _
            | Nav.Skill_inspector _
            | Nav.Exact_run_inspector _ ) ->
            (m, [])
        | None -> (
            match m.nav.workspace with
            | Nav.Knowledge
              when Nav.equal_knowledge_tab m.knowledge.active_tab
                     Nav.Knowledge_memory ->
                let knowledge =
                  Knowledge_store.cycle_memory_diff_window m.knowledge
                in
                let next = { m with knowledge } in
                (next, View_fetches.fetches_for_current_view next)
            | Nav.Keepers
              when (m.nav.pane_index >= 1 || m.nav.zoomed)
                   && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                        Nav.Keeper_memory ->
                let knowledge =
                  Knowledge_store.cycle_memory_diff_window m.knowledge
                in
                let next = { m with knowledge } in
                (next, View_fetches.fetches_for_current_view next)
            | Nav.Runtime
              when Nav.equal_runtime_tab m.runtime.active_tab
                     Nav.Runtime_tools_usage ->
                let runtime = Runtime_store.cycle_tools_window m.runtime in
                let next = { m with runtime } in
                (next, View_fetches.fetches_for_current_view next)
            | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Runtime
            | Nav.Infra ->
                (m, [])))
  | Keymap.Cycle_view_mode -> (
      match board_work_keeper m with
      | Some keeper ->
          let current = m.knowledge.board_recovery in
          if Board_recovery.shown ~keeper current then (set_board_recovery m (Board_recovery.close current), [])
          else View_fetches.read_board_quarantines ~keeper ~now
                 (set_board_recovery m (Board_recovery.open_view ~keeper current))
      | None ->
      if Option.is_some (Memory_diagram.active_diagram m) then
        Update_nav.cycle_memory_diagram_mode ~now m
      else
      match active_artifact_target m with
      | Some _ ->
          let knowledge =
            Knowledge_store.toggle_artifact_view_mode m.knowledge
          in
          let msg =
            match knowledge.artifact_view_mode with
            | `Document ->
                Say.make ~ko:"산출물 보기: 문서 렌더링"
                  ~en:"Artifact view: Rendered document"
            | `Raw_source ->
                Say.make ~ko:"산출물 보기: 원문 소스"
                  ~en:"Artifact view: Raw source"
          in
          ( Model.with_toast ~now ~level:Model.Toast_info msg
              { m with knowledge }
          , [] )
      | None -> (
          match active_keeper_for_context m with
          | Some keeper ->
              let keeper_context =
                Keeper_context_store.cycle_subtab ~keeper m.keeper_context
              in
              let next =
                { m with keeper_context } |> Update_nav.clamp_for_pane
              in
              (next, View_fetches.fetches_for_current_view next)
          | None -> (
              if Option.is_some m.nav.overlay then (m, [])
              else
                match Model.active_inspector m with
                | Some (Nav.Verification_inspector _) ->
                    let work = Work_store.cycle_verification_dive_tab m.work in
                    let nav = { m.nav with inspector_scroll_offset = 0 } in
                    let next = { m with nav; work } in
                    (next, View_fetches.fetches_for_current_view next)
                | Some
                    ( Nav.Tool_inspector _
                    | Nav.Skill_inspector _
                    | Nav.Exact_run_inspector _ ) ->
                    (m, [])
                | None -> (
                    match m.nav.workspace with
                    | Nav.Work
                      when Nav.equal_work_tab m.work.active_tab Nav.Work_tasks
                           && not (Model.is_work_task_zoomed m) ->
                        let work = Work_store.cycle_task_status_filter m.work in
                        ({ m with work }, [])
                    | Nav.Work
                      when Nav.equal_work_tab m.work.active_tab
                             Nav.Work_pipeline ->
                        let work = Work_store.toggle_verification_view m.work in
                        let next = { m with work } in
                        (next, View_fetches.fetches_for_current_view next)
                    | Nav.Work
                      when Nav.equal_work_tab m.work.active_tab Nav.Work_inbox ->
                        let work = Work_store.cycle_inbox_subview m.work in
                        let nav =
                          {
                            m.nav with
                            pane_index = 0;
                            zoomed = false;
                            pre_zoom_pane_index = None;
                          }
                        in
                        let next = { m with nav; work } in
                        (next, View_fetches.fetches_for_current_view next)
                    | Nav.Knowledge
                      when Nav.equal_knowledge_tab m.knowledge.active_tab
                             Nav.Knowledge_board
                           && Model.is_board_detail_active m ->
                        ( {
                            m with
                            knowledge =
                              m.knowledge
                              |> Knowledge_store.toggle_thread_view
                              |> Knowledge_store.clear_armed_vote;
                          }
                        , [] )
                    | Nav.Knowledge
                      when Nav.equal_knowledge_tab m.knowledge.active_tab
                             Nav.Knowledge_memory ->
                        let knowledge =
                          Knowledge_store.cycle_memory_subview m.knowledge
                        in
                        let next = { m with knowledge } in
                        (next, View_fetches.fetches_for_current_view next)
                    | Nav.Keepers
                      when (m.nav.pane_index >= 1 || m.nav.zoomed)
                           && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                                Nav.Keeper_memory ->
                        let knowledge =
                          Knowledge_store.cycle_keeper_memory_subview
                            m.knowledge
                        in
                        let nav = { m.nav with keeper_detail_scroll_offset = 0 } in
                        let next = { m with nav; knowledge } in
                        (next, View_fetches.fetches_for_current_view next)
                    | Nav.Keepers
                      when (m.nav.pane_index >= 1 || m.nav.zoomed)
                           && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                                Nav.Keeper_trace -> (
                        match Model.selected_keeper_name m with
                        | Some name ->
                            let ks =
                              Keeper_context_store.get_keeper ~keeper:name
                                m.keeper_context
                            in
                            if
                              Keeper_context_store.equal_trace_section
                                ks.trace_section
                                Keeper_context_store.Trace_metrics_logs
                            then
                              let keeper_context =
                                Keeper_context_store.toggle_logs_subview
                                  ~keeper:name m.keeper_context
                              in
                              let next = { m with keeper_context } in
                              (next, View_fetches.fetches_for_current_view next)
                            else (m, [])
                        | None -> (m, []))
                    | Nav.Runtime
                      when Nav.equal_runtime_tab m.runtime.active_tab
                             Nav.Runtime_tools_usage ->
                        let runtime =
                          Runtime_store.cycle_tools_subview m.runtime
                        in
                        let nav =
                          {
                            m.nav with
                            pane_index = 0;
                            zoomed = false;
                            pre_zoom_pane_index = None;
                          }
                        in
                        let next = { m with nav; runtime } in
                        (next, View_fetches.fetches_for_current_view next)
                    | Nav.Infra
                      when Nav.equal_infra_tab m.infra.active_tab Nav.Infra_code
                      ->
                        let infra = Infra_store.cycle_code_git_mode m.infra in
                        let lbl =
                          Infra_store.code_right_mode_label
                            infra.code.right_mode
                        in
                        let next =
                          { m with infra }
                          |> Model.with_toast ~now ~level:Model.Toast_info
                               (Say.make
                                  ~ko:
                                    ("코드 패널 모드: "
                                    ^ Say.resolve Say.Lang_ko lbl)
                                  ~en:
                                    ("Code panel mode: "
                                    ^ Say.resolve Say.Lang_en lbl))
                        in
                        (next, View_fetches.fetches_for_current_view next)
                    | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers
                    | Nav.Runtime | Nav.Infra ->
                        (m, [])))))
  | Keymap.Context_primary_action -> (
      match board_recovery_keeper m with
      | Some keeper ->
          (match Board_recovery.start ~keeper m.knowledge.board_recovery with
           | None -> (m, [])
           | Some (recovery, item) ->
               (set_board_recovery m recovery, [Cmd.Http_post { epoch = m.epoch; req = Cmd.Post_board_recovery item }]))
      | None ->
      match active_artifact_target m with
      | Some art ->
          let rev, sha =
            match Knowledge_store.artifact_detail_for_entry art m.knowledge with
            | Some d -> (d.artifact.revision, d.artifact.body.sha256)
            | None -> (art.revision, art.body.sha256)
          in
          let cur_check =
            Knowledge_store.artifact_check_for ~id:art.id ~revision:rev
              m.knowledge
          in
          let checked =
            match cur_check with Some c -> not c.checked | None -> true
          in
          let expected_change_id =
            match cur_check with Some c -> Some c.change_id | None -> None
          in
          let expected_workspace =
            Option.map
              (fun (ws : Wire_common.workspace_identity) ->
                (ws.base_path, ws.masc_root))
              m.server_identity.workspace
          in
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:"산출물 확인 체크 전송 중..."
                 ~en:"Updating artifact confirmation check...")
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req =
                    Cmd.Post_artifact_check
                      {
                        expected_workspace;
                        id = art.id;
                        revision = rev;
                        body_sha256 = sha;
                        checked;
                        expected_change_id;
                      };
                };
            ] )
      | None -> (
          if Option.is_some m.nav.overlay then (m, [])
          else
            match Model.active_inspector m with
            | Some _ ->
                (m, [])
            | None -> (
                match m.nav.workspace with
                | Nav.Knowledge
                  when Nav.equal_knowledge_tab m.knowledge.active_tab
                         Nav.Knowledge_board ->
                    open_board_comment_for_selected m
                | Nav.Keepers -> (
                    match Model.selected_keeper_name m with
                    | Some name ->
                        let already_chat =
                          Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                            Nav.Keeper_chat
                        in
                        let detail_vis =
                          Model.detail_visible
                            { m with nav = { m.nav with zoomed = false } }
                        in
                        let zoomed =
                          (m.nav.zoomed || not detail_vis)
                          && Model.can_zoom_current_view m
                        in
                        let pre_zoom_pane_index =
                          if zoomed && not m.nav.zoomed then
                            Some m.nav.pane_index
                          else m.nav.pre_zoom_pane_index
                        in
                        let pane_index = if zoomed then 0 else 1 in
                        let nav =
                          {
                            m.nav with
                            zoomed;
                            pre_zoom_pane_index;
                            pane_index;
                            keeper_detail_scroll_offset = 0;
                            filter_focused = false;
                          }
                        in
                        let fleet =
                          if already_chat then m.fleet
                          else
                            m.fleet
                            |> Fleet_store.set_keeper_dive_tab Nav.Keeper_chat
                            |> Fleet_store.mark_chat_history_loading
                                 ~keeper:name
                        in
                        let config =
                          if already_chat then m.config
                          else Config_store.cancel_edit_field m.config
                        in
                        let knowledge =
                          if already_chat then m.knowledge
                          else
                            m.knowledge
                            |> Knowledge_store.close_memory_reading
                            |> Knowledge_store.close_memory_diagram
                        in
                        let drafts =
                          m.drafts
                          |> Drafts.set_active_keeper name
                          |> Drafts.set_focus true
                        in
                        let next =
                          { m with nav; fleet; config; knowledge; drafts }
                        in
                        let cmds =
                          if
                            already_chat
                            && (m.nav.pane_index >= 1 || m.nav.zoomed)
                          then []
                          else View_fetches.fetches_for_current_view next
                        in
                        (next, cmds)
                    | None ->
                        ( Model.with_toast ~now ~level:Model.Toast_warning
                            (Say.make ~ko:"채팅할 키퍼를 먼저 선택하세요"
                               ~en:"Select a keeper first")
                            m
                        , [] ))
                | Nav.Work
                  when Nav.equal_work_tab m.work.active_tab Nav.Work_inbox
                       && Work_store.equal_inbox_subview m.work.inbox_subview
                            Work_store.Inbox_queue -> (
                    match
                      Attention.current_filtered_item ~query:m.work.filter_query
                        m.attention
                    with
                    | Some { payload = Attention.Payload_ask ask; _ } ->
                        Update_nav.jump_to_keeper ~preserve_return:true
                          ~tab:Nav.Keeper_chat m ask.keeper
                    | Some { payload = Attention.Payload_tool_approval ta; _ } ->
                        Update_nav.jump_to_keeper ~preserve_return:true
                          ~tab:Nav.Keeper_chat m ta.keeper
                    | Some { payload = Attention.Payload_gate g; _ } ->
                        if not (String.equal (String.trim g.keeper) "") then
                          Update_nav.jump_to_keeper ~preserve_return:true
                            ~tab:Nav.Keeper_chat m g.keeper
                        else (m, [])
                    | Some { payload = Attention.Payload_goal_confirmation _; _ }
                    | None ->
                        (m, []))
                | Nav.Work
                  when Nav.equal_work_tab m.work.active_tab Nav.Work_pipeline -> (
                    match Work_store.selected_goal m.work with
                    | Some g -> Update_nav.request_goal_complete_guarded ~now m g
                    | None -> (m, []))
                | Nav.Work
                  when Nav.equal_work_tab m.work.active_tab Nav.Work_tasks -> (
                    match Work_store.selected_task m.work with
                    | Some tk -> open_task_transition_modal ~now m tk
                    | None -> (m, []))
                | Nav.Runtime
                  when Nav.equal_runtime_tab m.runtime.active_tab
                         Nav.Runtime_addons_browser ->
                    if m.runtime.addon_catalog_mode then (m, [])
                    else if m.nav.pane_index = 1 then
                      match
                        ( Runtime_store.selected_browser_client m.runtime
                        , Runtime_store.selected_browser_tab m.runtime )
                      with
                      | Some cl, Some tb ->
                          Update_nav.open_inline_modal m
                            (Nav.Browser_interact_form
                               {
                                 client_id = cl.client_id;
                                 tab_id = tb.id;
                                 expected_url = Some tb.url;
                               })
                      | Some _, None ->
                          ( Model.with_toast ~now ~level:Model.Toast_warning
                              (Say.make
                                 ~ko:"브라우저 탭을 먼저 조회([t]) 및 선택하세요"
                                 ~en:"Fetch ([t]) and select a browser tab first")
                              m
                          , [] )
                      | None, _ ->
                          ( Model.with_toast ~now ~level:Model.Toast_warning
                              (Say.make
                                 ~ko:"브라우저 클라이언트를 먼저 선택하세요"
                                 ~en:"Select a browser client first")
                              m
                          , [] )
                    else if Runtime_store.open_lane_addon_asks m.runtime <> [] then
                      open_addon_ask_modal ~now m
                    else (
                      match Runtime_store.selected_addon_instance m.runtime with
                      | Some inst ->
                          Update_nav.open_inline_modal m
                            (Nav.Addon_act_form
                               {
                                 instance_id = inst.instance_id;
                                 expected_incarnation = inst.instance_id;
                               })
                      | None ->
                          ( Model.with_toast ~now ~level:Model.Toast_warning
                              (Say.make
                                 ~ko:"액션을 실행할 애드온 인스턴스를 선택하세요"
                                 ~en:"Select an addon instance first")
                              m
                          , [] ))
                | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Runtime | Nav.Infra
                  ->
                    (m, []))))
  | Keymap.Toggle_artifact_share -> (
      match active_artifact_target m with
      | None -> (m, [])
      | Some art -> (
          match
            ( m.server_identity.workspace
            , Knowledge_store.artifact_detail_for_entry art m.knowledge )
          with
          | Some ws, Some detail ->
              let operation_id = Random_id.uuid_v7 () in
              let next_shared = not detail.shared in
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:
                       (if next_shared then "외부 공유 활성화 요청 중..."
                       else "외부 공유 해제 요청 중...")
                     ~en:
                       (if next_shared then "Enabling external share..."
                       else "Disabling external share..."))
                  m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_artifact_share
                          {
                            expected_workspace = (ws.base_path, ws.masc_root);
                            id = detail.artifact.id;
                            shared = next_shared;
                            operation_id;
                            expected_version = detail.share_version;
                            expected_artifact_revision = detail.artifact.revision;
                            expected_artifact_sha256 = detail.artifact.body.sha256;
                          };
                    };
                ] )
          | None, _ ->
              ( Model.with_toast ~now ~level:Model.Toast_warning
                  (Say.make ~ko:"서버 워크스페이스 정보가 아직 로드되지 않았습니다"
                     ~en:"Server workspace identity not loaded yet")
                  m
              , [] )
          | Some _, None ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:"산출물 상세 정보를 불러오는 중입니다 — 잠시 후 [P]를 다시 누르세요"
                     ~en:"Loading artifact detail — press [P] again once loaded")
                  m
              , [
                  Cmd.Http_get
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Get_artifact_detail
                          { id = art.id; revision = Some art.revision };
                    };
                ] )))
  | Keymap.Step_revision dir -> (
      let delta = match dir with Keymap.Prev -> -1 | Keymap.Next -> 1 in
      if
        Option.is_none m.nav.overlay
        && (not (Model.sidebar_has_focus m))
        && Option.is_none (Model.active_inspector m)
        && Nav.equal_workspace m.nav.workspace Nav.Keepers
        && (m.nav.pane_index >= 1 || m.nav.zoomed)
        && Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_trace
      then
        match Model.selected_keeper_name m with
        | Some keeper ->
            let keeper_context =
              Keeper_context_store.cycle_trace_section ~keeper ~delta
                m.keeper_context
            in
            let next = { m with keeper_context } |> Update_nav.clamp_for_pane in
            (next, View_fetches.fetches_for_current_view next)
        | None -> (m, [])
      else step_artifact_revision ~now ~delta m)
  | Keymap.Step_context_item dir -> (
      let delta = match dir with Keymap.Prev -> -1 | Keymap.Next -> 1 in
      match active_keeper_for_context m with
      | Some keeper ->
          (* Turn records are newest-first: `<` (Prev) steps older (+1), `>` (Next) steps newer (-1). *)
          let turn_delta = -delta in
          let keeper_context =
            Keeper_context_store.step_turn ~keeper ~delta:turn_delta
              m.keeper_context
          in
          let next = { m with keeper_context } in
          (next, View_fetches.fetches_for_current_view next)
      | None -> (
          if Option.is_some m.nav.overlay then (m, [])
          else
            match Model.active_inspector m with
            | Some _ -> (m, [])
            | None -> (
                match m.nav.workspace with
                | Nav.Knowledge
                  when Nav.equal_knowledge_tab m.knowledge.active_tab
                         Nav.Knowledge_board
                       && Model.is_board_detail_active m -> (
                    match Knowledge_store.board_detail_post_id m.knowledge with
                    | Some post_id ->
                        let knowledge =
                          Knowledge_store.step_thread_comment ~post_id
                            ~delta m.knowledge
                        in
                        ({ m with knowledge }, [])
                    | None -> (m, []))
                | Nav.Knowledge
                  when Nav.equal_knowledge_tab m.knowledge.active_tab
                         Nav.Knowledge_artifacts ->
                    step_artifact_revision ~now ~delta m
                | Nav.Runtime
                  when Nav.equal_runtime_tab m.runtime.active_tab
                         Nav.Runtime_tools_usage
                       && Runtime_store.equal_tools_subview
                            m.runtime.tools_subview
                            Runtime_store.Tools_prompts_presets ->
                    let next_sec =
                      if delta >= 0 then
                        match m.runtime.pp_section with
                        | Runtime_store.Sec_prompts -> Runtime_store.Sec_presets
                        | Runtime_store.Sec_presets -> Runtime_store.Sec_params
                        | Runtime_store.Sec_params ->
                            Runtime_store.Sec_async_requests
                        | Runtime_store.Sec_async_requests ->
                            Runtime_store.Sec_prompts
                      else
                        match m.runtime.pp_section with
                        | Runtime_store.Sec_prompts ->
                            Runtime_store.Sec_async_requests
                        | Runtime_store.Sec_presets -> Runtime_store.Sec_prompts
                        | Runtime_store.Sec_params -> Runtime_store.Sec_presets
                        | Runtime_store.Sec_async_requests ->
                            Runtime_store.Sec_params
                    in
                    let runtime =
                      Runtime_store.set_prompts_presets_section next_sec m.runtime
                    in
                    let next = { m with runtime } in
                    (next, View_fetches.fetches_for_current_view next)
                | Nav.Runtime
                  when Nav.equal_runtime_tab m.runtime.active_tab
                         Nav.Runtime_tools_usage
                       && (Runtime_store.equal_tools_subview
                             m.runtime.tools_subview
                             Runtime_store.Tools_keeper_skills
                           || Runtime_store.equal_tools_subview
                                m.runtime.tools_subview
                                Runtime_store.Tools_quality_gate) ->
                    let keeper_names =
                      match Observed.to_option m.fleet.keepers with
                      | Some ks ->
                          List.map
                            (fun (k : Wire_fleet.keeper_summary) -> k.name)
                            ks
                      | None -> []
                    in
                    let runtime, _ =
                      Runtime_store.step_tools_surface_keeper ~keeper_names
                        ~delta m.runtime
                    in
                    let next = { m with runtime } in
                    (next, View_fetches.fetches_for_current_view next)
                | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers
                | Nav.Runtime | Nav.Infra ->
                    (m, []))))
  | Keymap.Launch_fusion -> (
      if Option.is_some m.nav.overlay then (m, [])
      else
        let in_memory =
          match Model.active_inspector m with
          | Some _ -> false
          | None ->
              (Nav.equal_workspace m.nav.workspace Nav.Knowledge
               && Nav.equal_knowledge_tab m.knowledge.active_tab
                    Nav.Knowledge_memory
               && Knowledge_store.equal_memory_subview
                    m.knowledge.memory_subview Knowledge_store.Mem_diff_flow)
              || (Nav.equal_workspace m.nav.workspace Nav.Keepers
                  && (m.nav.pane_index >= 1 || m.nav.zoomed)
                  && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                       Nav.Keeper_memory)
        in
        if in_memory then
          let knowledge =
            Knowledge_store.set_memory_view_mode Knowledge_store.View_facts
              m.knowledge
          in
          let nav =
            if Nav.equal_workspace m.nav.workspace Nav.Keepers then
              { m.nav with keeper_detail_scroll_offset = 0 }
            else m.nav
          in
          let next = { m with nav; knowledge } in
          (next, View_fetches.fetches_for_current_view next)
        else if Option.is_some (Model.active_inspector m) then (m, [])
        else
          match m.nav.workspace with
          | Nav.Runtime
            when Nav.equal_runtime_tab m.runtime.active_tab
                   Nav.Runtime_failover_lanes
                 || Nav.equal_runtime_tab m.runtime.active_tab Nav.Runtime_fusion
            ->
              open_fusion_launch_modal m
          | Nav.Infra when Nav.equal_infra_tab m.infra.active_tab Nav.Infra_code
            ->
              Update_nav.open_inline_modal m Nav.Code_search_form
          | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Runtime
          | Nav.Infra ->
              (m, []))
  | Keymap.Toggle_unreported -> (
      if Option.is_some m.nav.overlay then (m, [])
      else
        match Model.active_inspector m with
        | Some _ -> (m, [])
        | None -> (
            match m.nav.workspace with
            | Nav.Knowledge
              when Nav.equal_knowledge_tab m.knowledge.active_tab
                     Nav.Knowledge_board ->
                upvote_board_target ~now m
            | Nav.Runtime
              when Nav.equal_runtime_tab m.runtime.active_tab
                     Nav.Runtime_quotas_credits ->
                ( {
                    m with
                    runtime =
                      Runtime_store.toggle_unreported_accounts m.runtime;
                  }
                , [] )
            | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Runtime
            | Nav.Infra ->
                (m, [])))
  | Keymap.Unbind_connector -> (
      match active_keeper_for_tab Nav.Keeper_identity m with
      | Some keeper -> (
          let ks =
            Keeper_context_store.get_keeper ~keeper m.keeper_context
          in
          let entries = Update_nav.keeper_identity_entries m ~name:keeper in
          match
            List.nth_opt entries
              (Update_nav.clamp_index (List.length entries)
                 ks.identity_selected_idx)
          with
          | Some (Update_nav.Identity_oauth { provider; _ }) ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:("OAuth 연결 해제 요청: " ^ provider)
                     ~en:("Disconnecting OAuth provider: " ^ provider))
                  m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req = Cmd.Post_oauth_disconnect { keeper; provider };
                    };
                ] )
          | Some Update_nav.Identity_github | None -> (m, []))
      | None ->
      if Option.is_some m.nav.overlay || Option.is_some (Model.active_inspector m)
      then (m, [])
      else
        match m.nav.workspace with
        | Nav.Runtime
          when Nav.equal_runtime_tab m.runtime.active_tab Nav.Runtime_connectors
          -> (
            match Runtime_store.selected_connector m.runtime with
            | Some conn -> (
                match conn.configured_bindings with
                | b :: _ ->
                    let keeper_name =
                      if String.equal (String.trim b.keeper_name) "" then None
                      else Some b.keeper_name
                    in
                    ( Model.with_toast ~now ~level:Model.Toast_info
                        (Say.make
                           ~ko:
                             (Printf.sprintf "커넥터 바인딩 해제 요청: %s (%s)"
                                conn.connector_id b.channel_id)
                           ~en:
                             (Printf.sprintf "Unbinding connector: %s (%s)"
                                conn.connector_id b.channel_id))
                        m
                    , [
                        Cmd.Http_post
                          {
                            epoch = m.epoch;
                            req =
                              Cmd.Post_connector_unbind
                                {
                                  connector = conn.connector_id;
                                  channel_id = b.channel_id;
                                  keeper_name;
                                };
                          };
                      ] )
                | [] ->
                    ( Model.with_toast ~now ~level:Model.Toast_warning
                        (Say.make
                           ~ko:("해제할 바인딩이 없습니다: " ^ conn.connector_id)
                           ~en:("No bound channels to unbind: " ^ conn.connector_id))
                        m
                    , [] ))
            | None -> (m, []))
        | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Runtime
        | Nav.Infra ->
            (m, []))
  | Keymap.Entity_approve_or_assign -> (
      if Option.is_some m.nav.overlay then (m, [])
      else
        match active_keeper_for_tab Nav.Keeper_identity m with
        | Some keeper -> (
            let ks =
              Keeper_context_store.get_keeper ~keeper m.keeper_context
            in
            let entries = Update_nav.keeper_identity_entries m ~name:keeper in
            match
              List.nth_opt entries
                (Update_nav.clamp_index (List.length entries)
                   ks.identity_selected_idx)
            with
            | Some (Update_nav.Identity_oauth { provider; enabled; _ }) ->
                let next_enabled = not (Option.value ~default:false enabled) in
                ( Model.with_toast ~now ~level:Model.Toast_info
                    (Say.make
                       ~ko:
                         (Printf.sprintf "OAuth 도구 전환: %s -> %s" provider
                            (if next_enabled then "활성" else "비활성"))
                       ~en:
                         (Printf.sprintf "Toggling OAuth tools %s -> %s"
                            provider
                            (if next_enabled then "enabled" else "disabled")))
                    m
                , [
                    Cmd.Http_post
                      {
                        epoch = m.epoch;
                        req =
                          Cmd.Post_oauth_identity_switch
                            { keeper; provider; enabled = next_enabled };
                      };
                  ] )
            | Some Update_nav.Identity_github | None -> (m, []))
        | None ->
        match Model.active_inspector m with
        | Some (Nav.Verification_inspector req_id) -> (
            match
              List.find_opt
                (fun (v : Wire_work.verification_request) ->
                  String.equal v.request_id req_id)
                (Work_store.verifications_list m.work)
            with
            | Some v -> Update_nav.approve_verification_request ~now m v
            | None -> (m, []))
        | Some
            ( Nav.Tool_inspector _
            | Nav.Skill_inspector _
            | Nav.Exact_run_inspector _ ) ->
            (m, [])
        | None -> (
            match m.nav.workspace with
            | Nav.Work
              when Nav.equal_work_tab m.work.active_tab Nav.Work_harness ->
                open_harness_overrule_for_selected ~verdict:"approve" ~now m
            | Nav.Work
              when Nav.equal_work_tab m.work.active_tab Nav.Work_pipeline -> (
                if m.nav.pane_index = 1 && Model.work_pipeline_verifs_visible m
                then
                  match Work_store.selected_verification m.work with
                  | Some v -> Update_nav.approve_verification_request ~now m v
                  | None -> (m, [])
                else if
                  m.nav.pane_index = 1 && Model.work_pipeline_has_linked_card m
                then
                  ( Model.with_toast ~now ~level:Model.Toast_warning
                      (Update_nav.hidden_verif_toast_msg m)
                      m
                  , [] )
                else
                  match Work_store.selected_goal m.work with
                  | Some g -> goal_action_on_approve ~now m g
                  | None -> (m, []))
            | Nav.Infra
              when Nav.equal_infra_tab m.infra.active_tab
                     Nav.Infra_activity_logs ->
                if
                  (not m.infra.acting_rail_open)
                  && Model.inner_body_width m < 104
                then
                  ( Model.with_toast ~now ~level:Model.Toast_warning
                      (Say.make
                         ~ko:"Acting 레일은 가로 104칸 이상에서 표시됩니다"
                         ~en:"Acting rail requires viewport width >= 104 cols")
                      m
                  , [] )
                else
                  let infra = Infra_store.toggle_acting_rail m.infra in
                  let next = Update_nav.clamp_for_pane { m with infra } in
                  (next, View_fetches.fetches_for_current_view next)
            | Nav.Knowledge
              when Nav.equal_knowledge_tab m.knowledge.active_tab
                     Nav.Knowledge_board ->
                open_board_comment_for_selected m
            | Nav.Knowledge
              when Nav.equal_knowledge_tab m.knowledge.active_tab
                     Nav.Knowledge_memory -> (
                match resolve_memory_act_keeper m with
                | Some keeper ->
                    ( Model.with_toast ~now ~level:Model.Toast_info
                        (Say.make
                           ~ko:("사서 라이터 재개 요청: " ^ keeper)
                           ~en:("Requesting librarian writer resume: " ^ keeper))
                        m
                    , [
                        Cmd.Http_post
                          {
                            epoch = m.epoch;
                            req =
                              Cmd.Post_memory_act
                                { keeper; act = Wire_knowledge.Act_resume };
                          };
                      ] )
                | None -> open_memory_act_modal m ~keeper_default:"")
            | Nav.Keepers
              when (m.nav.pane_index >= 1 || m.nav.zoomed)
                   && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                        Nav.Keeper_memory -> (
                match Model.selected_keeper_name m with
                | Some name ->
                    ( Model.with_toast ~now ~level:Model.Toast_info
                        (Say.make
                           ~ko:("사서 라이터 재개 요청: " ^ name)
                           ~en:("Requesting librarian writer resume: " ^ name))
                        m
                    , [
                        Cmd.Http_post
                          {
                            epoch = m.epoch;
                            req =
                              Cmd.Post_memory_act
                                {
                                  keeper = name;
                                  act = Wire_knowledge.Act_resume;
                                };
                          };
                      ] )
                | None -> (m, []))
            | Nav.Keepers
              when (m.nav.pane_index >= 1 || m.nav.zoomed)
                   && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                        Nav.Keeper_config -> (
                match Model.selected_keeper_name m with
                | Some name ->
                    let runtime_default =
                      match Observed.to_option m.runtime.runtime_config_raw with
                      | Some meta ->
                          Option.value (List.assoc_opt name meta.assignments)
                            ~default:""
                      | None -> ""
                    in
                    open_runtime_assign_modal m ~keeper_default:name
                      ~runtime_default ()
                | None -> (m, []))
            | Nav.Runtime -> (
                if
                  Nav.equal_runtime_tab m.runtime.active_tab
                    Nav.Runtime_tools_usage
                  && Runtime_store.equal_tools_subview m.runtime.tools_subview
                       Runtime_store.Tools_prompts_presets
                  && Runtime_store.equal_prompts_presets_section
                       m.runtime.pp_section Runtime_store.Sec_presets
                then
                  match Runtime_store.selected_preset_manifest m.runtime with
                  | Some p ->
                      ( Model.with_toast ~now ~level:Model.Toast_info
                          (Say.make
                             ~ko:("프리셋 복원 중 (자동 백업 _autosave): " ^ p.name)
                             ~en:
                               ("Restoring preset (autosaving _autosave): "
                                ^ p.name))
                          m
                      , [
                          Cmd.Http_post
                            {
                              epoch = m.epoch;
                              req = Cmd.Post_preset_restore { name = p.name };
                            };
                        ] )
                  | None -> (m, [])
                else
                  let keeper_default =
                    Option.value (Update_nav.resolve_target_keeper m) ~default:""
                  in
                  let runtime_default =
                    match Runtime_store.selected_lane m.runtime with
                    | Some lane -> lane.id
                    | None -> (
                        match Observed.to_option m.runtime.runtime_resolved with
                        | Some snap ->
                            Option.value snap.default_route ~default:""
                        | None -> "")
                  in
                  open_runtime_assign_modal m ~keeper_default ~runtime_default ())
            | Nav.Keepers -> (
                match
                  ( selected_keeper_for_lifecycle m
                  , Model.selected_keeper_name m )
                with
                | Some k, _ when k.paused ->
                    dispatch_keeper_resume ~now ~name:k.name m
                | Some k, _ when keeper_is_offline k.health ->
                    dispatch_keeper_boot ~now ~name:k.name m
                | Some k, _ ->
                    open_keeper_lifecycle_modal m ~keeper:k.name
                      ~default_action:"pause"
                | None, Some name ->
                    open_keeper_lifecycle_modal m ~keeper:name
                      ~default_action:"pause"
                | None, None -> (m, []))
            | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Infra ->
                (m, [])))
  | Keymap.Entity_reject_or_cancel -> (
      if Option.is_some m.nav.overlay then (m, [])
      else
        match Model.active_inspector m with
        | Some (Nav.Verification_inspector req_id) -> (
            match
              List.find_opt
                (fun (v : Wire_work.verification_request) ->
                  String.equal v.request_id req_id)
                (Work_store.verifications_list m.work)
            with
            | Some v -> Update_nav.reject_verification_request ~now m v
            | None ->
                ( Model.with_toast ~now ~level:Model.Toast_info
                    (Say.make ~ko:"검증 요청을 찾을 수 없습니다"
                       ~en:"Verification request not found")
                    m
                , [] ))
        | Some (Nav.Skill_inspector ref_s) ->
            execute_slash ~now m (Slash.Skill (Slash.Skill_delete ref_s))
        | Some (Nav.Tool_inspector _ | Nav.Exact_run_inspector _) ->
            (m, [])
        | None -> (
            match m.nav.workspace with
            | Nav.Work -> (
                match m.work.active_tab with
                | Nav.Work_pipeline -> (
                    if
                      m.nav.pane_index = 1
                      && Model.work_pipeline_verifs_visible m
                    then
                      match Work_store.selected_verification m.work with
                      | Some v -> Update_nav.reject_verification_request ~now m v
                      | None -> (m, [])
                    else if
                      m.nav.pane_index = 1
                      && Model.work_pipeline_has_linked_card m
                    then
                      ( Model.with_toast ~now ~level:Model.Toast_warning
                          (Update_nav.hidden_verif_toast_msg m)
                          m
                      , [] )
                    else
                      match Work_store.selected_goal m.work with
                      | Some g -> goal_action_on_stop ~now m g
                      | None -> (m, []))
                | Nav.Work_tasks -> (
                    match Work_store.selected_task m.work with
                    | Some tk ->
                        Update_nav.open_inline_modal m (Nav.Task_cancel tk.id)
                    | None -> (m, []))
                | Nav.Work_harness ->
                    open_harness_overrule_for_selected ~verdict:"reject" ~now m
                | Nav.Work_inbox -> (
                    match m.work.inbox_subview with
                    | Work_store.Inbox_rules -> (
                        match Work_store.selected_gate_rule m.work with
                        | None -> (m, [])
                        | Some rule ->
                            let work =
                              {
                                m.work with
                                gate_snapshot =
                                  Observed.mark_stale m.work.gate_snapshot;
                              }
                            in
                            ( Model.with_toast ~now ~level:Model.Toast_info
                                (Say.make
                                   ~ko:("Always-Approve 규칙 삭제 중: " ^ rule.id)
                                   ~en:("Deleting Always-Approve rule: " ^ rule.id))
                                { m with work }
                            , [
                                Cmd.Http_post
                                  {
                                    epoch = m.epoch;
                                    req = Cmd.Post_gate_rule_delete { id = rule.id };
                                  };
                              ] ))
                    | Work_store.Inbox_queue | Work_store.Inbox_history ->
                        (m, []))
                | Nav.Work_schedules | Nav.Work_candle_scorecard -> (m, []))
            | Nav.Runtime
              when Nav.equal_runtime_tab m.runtime.active_tab
                     Nav.Runtime_failover_lanes -> (
                match Runtime_store.selected_lane m.runtime with
                | Some lane ->
                    open_runtime_lane_delete_modal ~now m lane
                | None -> (m, []))
            | Nav.Runtime
              when Nav.equal_runtime_tab m.runtime.active_tab
                     Nav.Runtime_addons_browser
                   && (not m.runtime.addon_catalog_mode)
                   && m.nav.pane_index = 0
                   && not (m.nav.zoomed && Model.can_zoom_current_view m) -> (
                match Runtime_store.selected_addon_instance m.runtime with
                | Some inst ->
                    execute_slash ~now m
                      (Slash.Addon (Slash.Addon_detach inst.instance_id))
                | None -> (m, []))
            | Nav.Runtime
              when Nav.equal_runtime_tab m.runtime.active_tab
                     Nav.Runtime_tools_usage -> (
                match m.runtime.tools_subview with
                | Runtime_store.Tools_keeper_skills
                  when Model.detail_pane_focused ~detail_index:1 m -> (
                    match Runtime_store.selected_skill_surface m.runtime with
                    | Some sf ->
                        execute_slash ~now m
                          (Slash.Skill (Slash.Skill_delete sf.reference))
                    | None -> (m, []))
                | Runtime_store.Tools_prompts_presets -> (
                    match m.runtime.pp_section with
                    | Runtime_store.Sec_prompts -> (
                        match Runtime_store.selected_prompt_item m.runtime with
                        | Some p ->
                            ( Model.with_toast ~now ~level:Model.Toast_info
                                (Say.make
                                   ~ko:("프롬프트 오버라이드 해제 중: " ^ p.key)
                                   ~en:("Clearing prompt override: " ^ p.key))
                                m
                            , [
                                Cmd.Http_post
                                  {
                                    epoch = m.epoch;
                                    req =
                                      Cmd.Post_prompt_override
                                        { key = p.key; value = None };
                                  };
                              ] )
                        | None -> (m, []))
                    | Runtime_store.Sec_presets -> (
                        match Runtime_store.selected_preset_manifest m.runtime with
                        | Some p ->
                            ( Model.with_toast ~now ~level:Model.Toast_info
                                (Say.make ~ko:("프리셋 삭제 중: " ^ p.name)
                                   ~en:("Deleting preset: " ^ p.name))
                                m
                            , [
                                Cmd.Http_post
                                  {
                                    epoch = m.epoch;
                                    req = Cmd.Post_preset_delete { name = p.name };
                                  };
                              ] )
                        | None -> (m, []))
                    | Runtime_store.Sec_params -> (
                        match Runtime_store.selected_runtime_param m.runtime with
                        | Some p ->
                            ( Model.with_toast ~now ~level:Model.Toast_info
                                (Say.make
                                   ~ko:("파라미터 기본값 복원 중: " ^ p.key)
                                   ~en:("Clearing runtime param: " ^ p.key))
                                m
                            , [
                                Cmd.Http_post
                                  {
                                    epoch = m.epoch;
                                    req =
                                      Cmd.Post_runtime_param_clear
                                        { param_key = p.key };
                                  };
                              ] )
                        | None -> (m, []))
                    | Runtime_store.Sec_async_requests -> (m, []))
                | Runtime_store.Tools_usage_calls
                | Runtime_store.Tools_catalog_tree
                | Runtime_store.Tools_keeper_skills
                | Runtime_store.Tools_quality_gate ->
                    (m, []))
            | Nav.Keepers -> (
                match
                  ( selected_keeper_for_lifecycle m
                  , Model.selected_keeper_name m )
                with
                | Some k, _ ->
                    let default_action =
                      if k.paused then "shutdown" else "pause"
                    in
                    open_keeper_lifecycle_modal m ~keeper:k.name ~default_action
                | None, Some name ->
                    open_keeper_lifecycle_modal m ~keeper:name
                      ~default_action:"pause"
                | None, None -> (m, []))
            | Nav.Pulse | Nav.Knowledge | Nav.Runtime | Nav.Infra ->
                (m, [])))
  | Keymap.Edit_or_export -> (
      match active_artifact_target m with
      | Some art ->
          let ext =
            Wire_knowledge.artifact_extension
              (Wire_knowledge.artifact_format_of_entry art)
          in
          let filename_stem =
            if String.trim art.title <> "" then art.title else art.id
          in
          let content_opt =
            Option.map
              (fun (d : Wire_knowledge.published_artifact_detail) -> d.content)
              (Knowledge_store.artifact_detail_for_entry art m.knowledge)
          in
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make
                 ~ko:(Printf.sprintf "%s 파일 내보내는 중…" ext)
                 ~en:(Printf.sprintf "Exporting %s…" ext))
              m
          , [
              Cmd.Export_artifact
                {
                  epoch = m.epoch;
                  id = art.id;
                  revision = Some art.revision;
                  filename_stem;
                  ext;
                  content_opt;
                  open_after = false;
                };
            ] )
      | None -> (
          if Option.is_some m.nav.overlay then (m, [])
          else
            match Model.active_inspector m with
            | Some (Nav.Tool_inspector tool_name) ->
                let skeleton =
                  match
                    Runtime_store.mcp_tool_schema_for ~name:tool_name m.runtime
                  with
                  | Some s when s.required_params <> [] ->
                      let fields =
                        List.map
                          (fun p -> Printf.sprintf "%S: \"\"" p)
                          s.required_params
                      in
                      "{" ^ String.concat ", " fields ^ "}"
                  | Some _ | None -> "{}"
                in
                Update_nav.open_inline_modal m
                  (Nav.Tool_execute_form
                     { tool_name = Some tool_name; args_json = skeleton })
            | Some (Nav.Skill_inspector ref_s) ->
                execute_slash ~now m (Slash.Skill (Slash.Skill_edit ref_s))
            | Some (Nav.Exact_run_inspector _) -> (m, [])
            | Some (Nav.Verification_inspector _) -> (m, [])
            | None ->
                if
                  Nav.equal_workspace m.nav.workspace Nav.Knowledge
                  && Nav.equal_knowledge_tab m.knowledge.active_tab
                       Nav.Knowledge_wiki
                then
                  match Knowledge_store.selected_wiki_page m.knowledge with
                  | Some p -> open_wiki_edit_modal ~now m ~slug:p.slug
                  | None -> (m, [])
                else if
                  Nav.equal_workspace m.nav.workspace Nav.Keepers
                  && (m.nav.pane_index >= 1 || m.nav.zoomed)
                  && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                       Nav.Keeper_config
                then (
                  match Model.selected_keeper_name m with
                  | Some name ->
                      let config =
                        m.config
                        |> Config_store.set_target
                             (Wire_config.Target_keeper name)
                        |> Config_store.set_tab Nav.Settings_keepers_companies
                      in
                      Update_nav.open_overlay { m with config }
                        (Nav.Settings Nav.Settings_keepers_companies)
                  | None -> (m, []))
                else if
                  (Nav.equal_workspace m.nav.workspace Nav.Knowledge
                   && Nav.equal_knowledge_tab m.knowledge.active_tab
                        Nav.Knowledge_memory
                   && Knowledge_store.equal_memory_subview
                        m.knowledge.memory_subview Knowledge_store.Mem_diff_flow)
                  || (Nav.equal_workspace m.nav.workspace Nav.Keepers
                      && (m.nav.pane_index >= 1 || m.nav.zoomed)
                      && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                           Nav.Keeper_memory)
                then
                  let knowledge =
                    Knowledge_store.set_memory_view_mode
                      Knowledge_store.View_evolution m.knowledge
                  in
                  let nav =
                    if Nav.equal_workspace m.nav.workspace Nav.Keepers then
                      { m.nav with keeper_detail_scroll_offset = 0 }
                    else m.nav
                  in
                  let next = { m with nav; knowledge } in
                  (next, View_fetches.fetches_for_current_view next)
                else if
                  Nav.equal_workspace m.nav.workspace Nav.Runtime
                  && Nav.equal_runtime_tab m.runtime.active_tab Nav.Runtime_addons_browser
                  && m.runtime.addon_catalog_mode
                  && m.nav.pane_index = 0
                  && not (m.nav.zoomed && Model.can_zoom_current_view m)
                then
                  Update_nav.open_inline_modal m
                    (Nav.Addon_decl_form
                       { file_name = "addon.toml"; mode = `Create; expected_source_revision = None })
                else if
                  Nav.equal_workspace m.nav.workspace Nav.Runtime
                  && Nav.equal_runtime_tab m.runtime.active_tab
                       Nav.Runtime_tools_usage
                then (
                  match m.runtime.tools_subview with
                  | Runtime_store.Tools_keeper_skills
                    when Model.detail_pane_focused ~detail_index:1 m -> (
                      match Runtime_store.selected_skill_surface m.runtime with
                      | Some sf ->
                          execute_slash ~now m
                            (Slash.Skill (Slash.Skill_edit sf.reference))
                      | None -> (m, []))
                  | Runtime_store.Tools_prompts_presets -> (
                      match m.runtime.pp_section with
                      | Runtime_store.Sec_prompts -> (
                          match Runtime_store.selected_prompt_item m.runtime with
                          | Some p ->
                              execute_slash ~now m
                                (Slash.Prompt
                                   (Slash.Prompt_set { key = p.key; value = None }))
                          | None -> (m, []))
                      | Runtime_store.Sec_presets -> (m, [])
                      | Runtime_store.Sec_params -> (
                          match Runtime_store.selected_runtime_param m.runtime with
                          | Some p ->
                              execute_slash ~now m
                                (Slash.Prompt
                                   (Slash.Param_set
                                      { key = p.key; value_raw = None }))
                          | None -> (m, []))
                      | Runtime_store.Sec_async_requests -> (m, []))
                  | Runtime_store.Tools_usage_calls
                  | Runtime_store.Tools_catalog_tree
                  | Runtime_store.Tools_keeper_skills
                  | Runtime_store.Tools_quality_gate ->
                      (m, []))
                else if
                  Nav.equal_workspace m.nav.workspace Nav.Runtime
                  && Nav.equal_runtime_tab m.runtime.active_tab
                       Nav.Runtime_fusion
                then (
                  match Runtime_store.selected_fusion_run m.runtime with
                  | Some run -> (
                      let post_id_opt =
                        match
                          Runtime_store.fusion_detail_for ~run_id:run.run_id
                            m.runtime
                        with
                        | Some { evidence = Wire_runtime.Evidence_recorded p; _ }
                          ->
                            Some p.post_id
                        | Some
                            {
                              evidence =
                                Wire_runtime.Evidence_pending
                                | Wire_runtime.Evidence_absent;
                              _;
                            }
                        | None -> (
                            match
                              Runtime_store.historical_evidence_for_run
                                ~run_id:run.run_id m.runtime
                            with
                            | Some ev -> Some ev.post_id
                            | None -> None)
                      in
                      match post_id_opt with
                      | Some post_id ->
                          ( Model.with_toast ~now ~level:Model.Toast_info
                              (Say.make
                                 ~ko:("보드 증거 불러오는 중: " ^ post_id)
                                 ~en:("Loading board evidence: " ^ post_id))
                              m
                          , [
                              Cmd.Http_get
                                {
                                  epoch = m.epoch;
                                  req =
                                    Cmd.Get_fusion_board_evidence { post_id };
                                };
                            ] )
                      | None -> (m, []))
                  | None -> (m, []))
                else if
                  Nav.equal_workspace m.nav.workspace Nav.Work
                  && Nav.equal_work_tab m.work.active_tab Nav.Work_pipeline
                  && not
                       (m.nav.pane_index = 1
                       && Model.work_pipeline_verifs_visible m)
                then (
                  match Work_store.selected_goal m.work with
                  | Some g -> open_goal_upsert_modal m ~goal:g ()
                  | None ->
                      ( Model.with_toast ~now ~level:Model.Toast_info
                          (Say.make ~ko:"편집할 목표를 선택하세요"
                             ~en:"Select a goal to edit")
                          m
                      , [] ))
                else if
                  Nav.equal_workspace m.nav.workspace Nav.Runtime
                  && Nav.equal_runtime_tab m.runtime.active_tab
                       Nav.Runtime_failover_lanes
                then (
                  match Runtime_store.selected_lane m.runtime with
                  | Some lane -> open_runtime_lane_edit_modal ~now m lane
                  | None ->
                      ( Model.with_toast ~now ~level:Model.Toast_info
                          (Say.make ~ko:"편집할 레인을 선택하세요"
                             ~en:"Select a lane to edit")
                          m
                      , [] ))
                else if
                  Nav.equal_workspace m.nav.workspace Nav.Runtime
                  && Nav.equal_runtime_tab m.runtime.active_tab
                       Nav.Runtime_addons_browser
                  && not m.runtime.addon_catalog_mode
                then (
                  match Runtime_store.selected_addon_instance m.runtime with
                  | Some inst ->
                      Update_nav.open_inline_modal m
                        (Nav.Addon_invoke_action
                           {
                             instance_id = inst.instance_id;
                             action_names = inst.action_names;
                           })
                  | None ->
                      ( Model.with_toast ~now ~level:Model.Toast_info
                          (Say.make ~ko:"액션을 호출할 애드온을 선택하세요"
                             ~en:"Select an addon instance to invoke an action")
                          m
                      , [] ))
                else if
                  Nav.equal_workspace m.nav.workspace Nav.Runtime
                  && Nav.equal_runtime_tab m.runtime.active_tab
                       Nav.Runtime_quotas_credits
                then (
                  match Runtime_store.active_setup_login_id m.runtime with
                  | Some login_id ->
                      Update_nav.open_inline_modal m
                        (Nav.Setup_login_input_form { login_id })
                  | None ->
                      ( Model.with_toast ~now ~level:Model.Toast_info
                          (Say.make
                             ~ko:"진행 중인 CLI 로그인이 없습니다 ([l]로 시작)"
                             ~en:"No active CLI login session (press [l] to start)")
                          m
                      , [] ))
                else (m, [])))
  | Keymap.Configure_provider_key -> (
      match active_keeper_for_tab Nav.Keeper_identity m with
      | Some keeper ->
          Update_nav.open_inline_modal m (Nav.Github_token_form keeper)
      | None ->
      if Option.is_some m.nav.overlay || Option.is_some (Model.active_inspector m)
      then (m, [])
      else
        match m.nav.workspace with
        | Nav.Runtime ->
            let integration_default =
              match Observed.to_option m.runtime.setup_inventory with
              | Some { integrations = first :: _; _ } -> first.id
              | Some { integrations = []; _ } | None -> ""
            in
            open_setup_account_key_modal m ~integration_default ()
        | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Infra ->
            (m, []))
  | Keymap.Account_login -> (
      match active_keeper_for_tab Nav.Keeper_identity m with
      | Some keeper -> (
          let ks =
            Keeper_context_store.get_keeper ~keeper m.keeper_context
          in
          let entries = Update_nav.keeper_identity_entries m ~name:keeper in
          match
            List.nth_opt entries
              (Update_nav.clamp_index (List.length entries)
                 ks.identity_selected_idx)
          with
          | Some (Update_nav.Identity_oauth { provider; _ }) ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:("OAuth 로그인 시작: " ^ provider)
                     ~en:("Starting OAuth login: " ^ provider))
                  m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req = Cmd.Post_oauth_login { keeper; provider };
                    };
                ] )
          | Some Update_nav.Identity_github ->
              let keeper_context =
                Keeper_context_store.start_github_login ~keeper m.keeper_context
              in
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:("GitHub 기기 로그인 시작: " ^ keeper)
                     ~en:("Starting GitHub device login: " ^ keeper))
                  { m with keeper_context }
              , [
                  Cmd.Http_post_stream
                    {
                      epoch = m.epoch;
                      req = Cmd.Stream_github_login { keeper };
                    };
                ] )
          | None -> (m, []))
      | None ->
      if Option.is_some m.nav.overlay || Option.is_some (Model.active_inspector m)
      then (m, [])
      else
        match m.nav.workspace with
        | Nav.Runtime -> open_setup_login_modal m ()
        | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Infra ->
            (m, []))
  | Keymap.Poll_account_login -> (
      match active_keeper_for_tab Nav.Keeper_identity m with
      | Some keeper -> (
          let ks =
            Keeper_context_store.get_keeper ~keeper m.keeper_context
          in
          match ks.oauth_pending_login with
          | Some (Wire_keeper_context.Oauth_login_exchange ex) ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:("OAuth 시도 상태 조회: " ^ ex.attempt_id)
                     ~en:("Polling OAuth attempt: " ^ ex.attempt_id))
                  m
              , [
                  Cmd.Http_get
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Get_oauth_attempt_status
                          {
                            keeper;
                            provider = ex.provider;
                            attempt_id = ex.attempt_id;
                          };
                    };
                ] )
          | Some (Wire_keeper_context.Oauth_login_direct _) | None ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make ~ko:"진행 중인 OAuth 로그인이 없습니다 ([l] 시작)"
                     ~en:"No pending OAuth attempt ([l] to start)")
                  m
              , [] ))
      | None ->
      if Option.is_some m.nav.overlay then (m, [])
      else
        match selected_keeper_name_for_lifecycle m with
        | Some keeper ->
            open_keeper_lifecycle_modal m ~keeper ~default_action:"boot"
        | None ->
            if Option.is_some (Model.active_inspector m) then (m, [])
            else
              match m.nav.workspace with
              | Nav.Runtime -> (
                  match m.runtime.setup_login_receipt with
                  | Some r ->
                      ( Model.with_toast ~now ~level:Model.Toast_info
                          (Say.make
                             ~ko:("로그인 영수증 상태 조회: " ^ r.login_id)
                             ~en:("Polling login status: " ^ r.login_id))
                          m
                      , [
                          Cmd.Http_get
                            {
                              epoch = m.epoch;
                              req =
                                Cmd.Get_setup_login_status
                                  { login_id = r.login_id };
                            };
                        ] )
                  | None -> open_setup_login_modal m ())
              | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Infra
                ->
                  (m, []))
  | Keymap.Copy_hash -> (
      match active_artifact_target m with
      | Some art ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:"SHA-256 복사됨" ~en:"Copied SHA-256")
              m
          , [ Cmd.Copy_clipboard art.body.sha256 ] )
      | None ->
          if Option.is_some m.nav.overlay then (m, [])
          else (
            match Model.active_inspector m with
            | Some _ -> (m, [])
            | None ->
                if
                  Nav.equal_workspace m.nav.workspace Nav.Work
                  && Nav.equal_work_tab m.work.active_tab Nav.Work_harness
                then
                  match Work_store.selected_harness_verdict m.work with
                  | Some v when not (String.equal (String.trim v.notes_hash) "") ->
                      ( Model.with_toast ~now ~level:Model.Toast_info
                          (Say.make ~ko:"notes_hash 복사됨"
                             ~en:"Copied notes_hash")
                          m
                      , [ Cmd.Copy_clipboard v.notes_hash ] )
                  | Some _ | None -> (m, [])
                else (m, [])))
  | Keymap.Dismiss_errors -> (
      if Option.is_some m.nav.overlay then (m, [])
      else
        match Model.active_inspector m with
        | Some (Nav.Verification_inspector _) ->
            Update_nav.open_harness_overrule_for_context ~verdict:"reject" ~now
              m
        | Some
            ( Nav.Tool_inspector _
            | Nav.Skill_inspector _
            | Nav.Exact_run_inspector _ ) ->
            (m, [])
        | None -> (
            match m.nav.workspace with
            | Nav.Keepers
              when Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_chat
              -> (
                match Model.selected_keeper_name m with
                | Some name -> dismiss_keeper_chat_errors ~now ~keeper:name m
                | None -> (m, []))
            | Nav.Work -> (
                match m.work.active_tab with
                | Nav.Work_pipeline | Nav.Work_tasks | Nav.Work_harness ->
                    Update_nav.open_harness_overrule_for_context
                      ~verdict:"reject" ~now m
                | Nav.Work_schedules
                | Nav.Work_inbox
                | Nav.Work_candle_scorecard ->
                    (m, []))
            | Nav.Pulse | Nav.Knowledge | Nav.Keepers | Nav.Runtime | Nav.Infra
              ->
                (m, [])))
  | Keymap.Board_vote dir -> (
      let target_opt =
        if Option.is_some m.nav.overlay then None
        else
          match Model.active_inspector m with
          | Some _ -> None
          | None ->
              if
                Nav.equal_workspace m.nav.workspace Nav.Knowledge
                && Nav.equal_knowledge_tab m.knowledge.active_tab
                     Nav.Knowledge_board
              then
                if Model.is_board_detail_active m then
                  Option.bind
                    (Knowledge_store.board_detail_post_id m.knowledge)
                    (fun post_id -> thread_vote_target ~post_id m.knowledge)
                else
                  Option.map
                    (fun (p : Wire_knowledge.board_post) ->
                      Knowledge_store.Vote_post p.id)
                    (Knowledge_store.selected_post m.knowledge)
              else None
      in
      match target_opt with
      | None -> (m, [])
      | Some target -> (
          match Knowledge_store.press_vote ~target ~dir m.knowledge with
          | `Armed knowledge ->
              let sym = match dir with `Up -> "+" | `Down -> "-" in
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:
                       (Printf.sprintf
                          "[%s] 투표 대기 중 — 한 번 더 누르면 확정됩니다" sym)
                     ~en:
                       (Printf.sprintf
                          "Vote [%s] armed — press [%s] again to confirm" sym
                          sym))
                  { m with knowledge }
              , [] )
          | `Confirmed knowledge ->
              let req =
                match target with
                | Knowledge_store.Vote_post post_id ->
                    Cmd.Post_board_vote { post_id; direction = dir }
                | Knowledge_store.Vote_comment { post_id; comment_id } ->
                    Cmd.Post_board_comment_vote
                      { post_id; comment_id; direction = dir }
              in
              ( { m with knowledge }
              , [ Cmd.Http_post { epoch = m.epoch; req } ] )))
  | Keymap.Toggle_memory_scope -> (
      if Option.is_some m.nav.overlay || Option.is_some (Model.active_inspector m)
      then (m, [])
      else
        match m.nav.workspace with
        | Nav.Knowledge
          when Nav.equal_knowledge_tab m.knowledge.active_tab
                 Nav.Knowledge_memory ->
            let next_keeper =
              match m.knowledge.memory_diff_keeper with
              | Some _ -> None
              | None -> (
                  match Update_nav.resolve_target_keeper m with
                  | Some _ as k -> k
                  | None -> (
                      match Observed.to_option m.fleet.keepers with
                      | Some (first :: _) -> Some first.name
                      | Some [] | None -> None))
            in
            let knowledge =
              Knowledge_store.set_memory_diff_keeper next_keeper m.knowledge
            in
            let lbl =
              match next_keeper with
              | Some k -> "Keeper: " ^ k
              | None -> "World"
            in
            let next =
              { m with knowledge }
              |> Model.with_toast ~now ~level:Model.Toast_info
                   (Say.make ~ko:("기억 범위: " ^ lbl) ~en:("Memory scope: " ^ lbl))
            in
            (next, View_fetches.fetches_for_current_view next)
        | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Runtime
        | Nav.Infra ->
            (m, []))
  | Keymap.Copy_public_url -> (
      match active_artifact_target m with
      | Some art ->
          let url =
            let id =
              match Knowledge_store.artifact_detail_for_entry art m.knowledge with
              | Some d -> d.artifact.id
              | None -> art.id
            in
            "/published-artifacts/" ^ id
          in
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:("공개 URL 복사됨: " ^ url)
                 ~en:("Copied public URL: " ^ url))
              m
          , [ Cmd.Copy_clipboard url ] )
      | None -> (m, []))
  | Keymap.Probe_sandbox -> (
      if Option.is_none m.nav.overlay && Option.is_some (selected_board_post_for_crud m)
      then toggle_board_pin ~now m
      else if
        Option.is_none m.nav.overlay
        && Option.is_none (Model.active_inspector m)
        && Nav.equal_workspace m.nav.workspace Nav.Infra
        && Nav.equal_infra_tab m.infra.active_tab Nav.Infra_code
      then
        let m1, _ = Update_nav.open_inline_modal m Nav.Code_finder_form in
        let scope = m1.infra.code.scope in
        let need_files =
          match m1.infra.code.files_catalog with
          | Observed.Value { data = sc, _; stale = false; _ } ->
              not (Wire_infra.equal_workspace_scope sc scope)
          | Observed.Loading _
          | Observed.Value { stale = true; _ }
          | Observed.Absent
          | Observed.Unreported
          | Observed.Failed _ ->
              true
        in
        let cmds =
          if need_files then
            [ Cmd.Http_get { epoch = m1.epoch; req = Cmd.Get_workspace_files { scope } } ]
          else []
        in
        (m1, cmds)
      else if
        Option.is_none m.nav.overlay
        && Option.is_none (Model.active_inspector m)
        && Nav.equal_workspace m.nav.workspace Nav.Runtime
        && Nav.equal_runtime_tab m.runtime.active_tab Nav.Runtime_addons_browser
      then
        let runtime = Runtime_store.toggle_addon_catalog_mode m.runtime in
        let nav =
          {
            m.nav with
            pane_index = 0;
            zoomed = false;
            pre_zoom_pane_index = None;
          }
        in
        let next =
          { m with nav; runtime }
          |> Model.with_toast ~now ~level:Model.Toast_info
               (if runtime.addon_catalog_mode then
                  Say.make ~ko:"애드온 패키지 카탈로그 보기"
                    ~en:"Addons: Package Catalog browser"
                else
                  Say.make ~ko:"애드온 인스턴스 & 브라우저 보기"
                    ~en:"Addons: Instances & Browser view")
        in
        (next, View_fetches.fetches_for_current_view next)
      else
      let target_opt =
        if Option.is_some m.nav.overlay then None
        else
          match Model.active_inspector m with
          | Some _ -> None
          | None -> (
              match m.nav.workspace with
              | Nav.Infra
                when Nav.equal_infra_tab m.infra.active_tab Nav.Infra_sandboxes
                -> (
                  match Infra_store.selected_sandbox_keeper m.infra with
                  | Some k -> Some (`Keeper k, k)
                  | None -> Some (`All, "all"))
              | Nav.Keepers
                when (m.nav.pane_index >= 1 || m.nav.zoomed)
                     && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                          Nav.Keeper_work_sandbox -> (
                  match Model.selected_keeper_name m with
                  | Some name
                    when not
                           (Board_recovery.shown ~keeper:name
                              m.knowledge.board_recovery) ->
                      Some (`Keeper name, name)
                  | Some _ | None -> None)
              | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Runtime
              | Nav.Infra ->
                  None)
      in
      match target_opt with
      | Some (target, label) ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make
                 ~ko:("샌드박스 프로브 실행: " ^ label)
                 ~en:("Probing sandbox: " ^ label))
              m
          , [
              Cmd.Http_post
                { epoch = m.epoch; req = Cmd.Post_sandbox_probe target };
            ] )
      | None -> (m, []))
  | Keymap.Refresh_browser_tabs -> (
      if Option.is_some m.nav.overlay || Option.is_some (Model.active_inspector m)
      then (m, [])
      else
        match m.nav.workspace with
        | Nav.Runtime
          when Nav.equal_runtime_tab m.runtime.active_tab
                 Nav.Runtime_addons_browser -> (
            match Runtime_store.selected_browser_client m.runtime with
            | Some cl ->
                let runtime =
                  Runtime_store.mark_browser_tabs_loading ~since:now
                    ~client_id:cl.client_id m.runtime
                in
                ( Model.with_toast ~now ~level:Model.Toast_info
                    (Say.make
                       ~ko:("브라우저 탭 목록 새로고침: " ^ cl.client_id)
                       ~en:("Refreshing browser tabs: " ^ cl.client_id))
                    { m with runtime }
                , [
                    Cmd.Http_post
                      {
                        epoch = m.epoch;
                        req = Cmd.Post_browser_tabs { client_id = cl.client_id };
                      };
                  ] )
            | None ->
                ( Model.with_toast ~now ~level:Model.Toast_info
                    (Say.make ~ko:"선택된 브라우저 클라이언트가 없습니다"
                       ~en:"No browser client selected")
                    m
                , [] ))
        | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Runtime
        | Nav.Infra ->
            (m, []))
  | Keymap.Open_memory_recovery ->
      let keeper_default =
        Option.value (resolve_memory_act_keeper m) ~default:""
      in
      open_memory_act_modal m ~keeper_default
  | Keymap.Search_prev_match ->
      if
        Model.is_artifact_doc_search_active m
        && not (String.equal (String.trim m.knowledge.artifact_search_query) "")
      then step_artifact_search ~now ~delta:(-1) m
      else (m, [])
  | Keymap.Toggle_memory_chart ->
      let in_memory_chart =
        Option.is_none m.nav.overlay
        && Option.is_none (Memory_diagram.active_diagram m)
        && Option.is_none m.knowledge.memory_reading
        && (not (Model.sidebar_has_focus m))
        &&
        match Model.active_inspector m with
        | Some _ -> false
        | None ->
            (Nav.equal_workspace m.nav.workspace Nav.Knowledge
             && Nav.equal_knowledge_tab m.knowledge.active_tab
                  Nav.Knowledge_memory
             && Knowledge_store.equal_memory_subview
                  m.knowledge.memory_subview Knowledge_store.Mem_diff_flow)
            || (Nav.equal_workspace m.nav.workspace Nav.Keepers
                && Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_memory
                && (m.nav.pane_index >= 1 || m.nav.zoomed))
      in
      if not in_memory_chart then (m, [])
      else
        let knowledge = Knowledge_store.toggle_memory_flow_mode m.knowledge in
        let lbl =
          Masc_tui_ui.Memory_flow.mode_label knowledge.memory_flow_mode
        in
        ( Model.with_toast ~now ~level:Model.Toast_info
            (Say.make
               ~ko:("기억 그래프 모드: " ^ Say.resolve Say.Lang_ko lbl)
               ~en:("Memory chart mode: " ^ Say.resolve Say.Lang_en lbl))
            { m with knowledge }
        , [] )
  | Keymap.Open_external_editor -> (
      let wiki_slug =
        match Model.active_inspector m with
        | Some _ -> None
        | None ->
            if
              Nav.equal_workspace m.nav.workspace Nav.Knowledge
              && Nav.equal_knowledge_tab m.knowledge.active_tab
                   Nav.Knowledge_wiki
            then
              Option.map
                (fun (p : Wire_knowledge.wiki_page_summary) -> p.slug)
                (Knowledge_store.selected_wiki_page m.knowledge)
            else None
      in
      match wiki_slug with
      | Some slug ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make
                 ~ko:("외부 편집기로 위키 열기: " ^ slug)
                 ~en:("Opening wiki page in $EDITOR: " ^ slug))
              m
          , [ Cmd.Open_editor_escape_hatch (Cmd.Edit_wiki_page slug) ] )
      | None -> (m, []))
  | Keymap.Interrupt_turn -> (
      let keeper_opt =
        if
          Option.is_none (Model.active_inspector m)
          && Nav.equal_workspace m.nav.workspace Nav.Keepers
        then
          match Model.selected_keeper_name m with
          | Some _ as k -> k
          | None -> Update_nav.resolve_target_keeper m
        else Update_nav.resolve_target_keeper m
      in
      match keeper_opt with
      | None ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:"중단할 대상 키퍼가 선택되지 않았습니다"
                 ~en:"No target keeper selected to interrupt")
              m
          , [] )
      | Some keeper ->
          let active_turn = Fleet_store.active_turn_for ~keeper m.fleet in
          (match Chat_transcript.explicit_interrupt_target ~model:m ~keeper active_turn with
          | Some target when Chat_transcript.interrupt_target_pending ~model:m ~keeper target ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:("이미 중단 요청을 전송했습니다: " ^ keeper)
                     ~en:("Interrupt already requested for " ^ keeper))
                  m
              , [] )
          | Some target -> request_keeper_interrupt ~now ~keeper ~target m
          | None ->
              let detail =
                match active_turn with
                | Some _ ->
                    Say.make
                      ~ko:("점검 턴은 중단할 수 없습니다: " ^ keeper)
                      ~en:("Maintenance turn cannot be interrupted: " ^ keeper)
                | None ->
                    Say.make
                      ~ko:("진행 중인 턴이 없습니다: " ^ keeper)
                      ~en:("No active turn running for " ^ keeper)
              in
              (Model.with_toast ~now ~level:Model.Toast_info detail m, [])))
  | Keymap.Delete_selected -> (
      if Option.is_some m.nav.overlay || Model.sidebar_has_focus m then (m, [])
      else
        match selected_lane_for_crud m with
        | Some lane -> open_runtime_lane_delete_modal ~now m lane
        | None -> (
            match selected_board_post_for_crud m with
            | Some p ->
                Update_nav.open_inline_modal m
                  (Nav.Board_delete_post { post_id = p.id; title = p.title })
            | None -> (
                if
                  Option.is_none (Model.active_inspector m)
                  && Nav.equal_workspace m.nav.workspace Nav.Runtime
                  && Nav.equal_runtime_tab m.runtime.active_tab
                       Nav.Runtime_addons_browser
                  && not m.runtime.addon_catalog_mode
                then
                  match Runtime_store.selected_addon_instance m.runtime with
                  | Some inst ->
                      Update_nav.open_inline_modal m
                        (Nav.Addon_detach_confirm
                           { instance_id = inst.instance_id; title = inst.title })
                  | None -> (m, [])
                else if Model.is_memory_explorer_surface m then
                  let knowledge =
                    Knowledge_store.set_memory_view_mode Knowledge_store.View_diff
                      m.knowledge
                  in
                  let nav =
                    if
                      Option.is_none (Model.active_inspector m)
                      && Nav.equal_workspace m.nav.workspace Nav.Keepers
                    then { m.nav with keeper_detail_scroll_offset = 0 }
                    else m.nav
                  in
                  let next = { m with nav; knowledge } in
                  (next, View_fetches.fetches_for_current_view next)
                else if Model.is_keeper_config_active m then (m, [])
                else
                  match selected_keeper_name_for_lifecycle m with
                  | Some keeper ->
                      Update_nav.open_inline_modal m
                        (Nav.Keeper_purge_confirm { keeper })
                  | None -> (m, []))))
  | Keymap.Link_task_goal -> (
      if Option.is_some m.nav.overlay || Model.sidebar_has_focus m then (m, [])
      else
        let task_opt =
          match Model.active_inspector m with
          | Some _ ->
              None
          | None ->
              if
                Nav.equal_workspace m.nav.workspace Nav.Work
                && Nav.equal_work_tab m.work.active_tab Nav.Work_tasks
              then Work_store.selected_task m.work
              else None
        in
        match task_opt with
        | Some tk -> open_task_link_goal_modal ~now m tk
        | None -> (m, []))
  | Keymap.Keeper_wake_or_online -> (
      if not (Model.is_keeper_lifecycle_surface m) then (m, [])
      else
        match Model.target_keeper_for_lifecycle m with
        | None ->
            ( Model.with_toast ~now ~level:Model.Toast_warning
                (Say.make ~ko:"선택된 키퍼가 없습니다"
                   ~en:"No Keeper selected")
                m
            , [] )
        | Some name -> dispatch_keeper_smart_wake ~now ~name m)
  | Keymap.Keeper_stop_armed -> (
      if not (Model.is_keeper_lifecycle_surface m) then (m, [])
      else
        match Model.target_keeper_for_lifecycle m with
        | None ->
            ( Model.with_toast ~now ~level:Model.Toast_warning
                (Say.make ~ko:"선택된 키퍼가 없습니다"
                   ~en:"No Keeper selected")
                m
            , [] )
        | Some name -> (
            match Fleet_store.find_keeper ~name m.fleet with
            | Some k when (not k.keepalive_running) && k.paused ->
                ( Model.with_toast ~now ~level:Model.Toast_info
                    (Say.make
                       ~ko:(Printf.sprintf "%s은(는) 이미 오프라인 상태입니다" name)
                       ~en:(Printf.sprintf "%s is already offline" name))
                    (Model.disarm_keeper_stop m)
                , [] )
            | Some _ | None ->
                let is_armed_same =
                  match m.keeper_stop_armed with
                  | Some (armed_name, armed_at) when String.equal armed_name name
                    ->
                      let elapsed =
                        Clock.Mono.seconds_since now ~since:armed_at
                      in
                      elapsed >= 0.0
                      && elapsed < Model.keeper_stop_arm_window_s
                  | Some _ | None -> false
                in
                if is_armed_same then
                  dispatch_keeper_shutdown ~now ~name
                    (Model.disarm_keeper_stop m)
                else
                  let next =
                    { m with keeper_stop_armed = Some (name, now) }
                    |> Model.with_toast ~now
                         ~duration_s:Model.keeper_stop_arm_window_s
                         ~tag:Model.Toast_keeper_stop_arm
                         ~level:Model.Toast_warning
                         (Model.keeper_stop_arm_toast_message ~name)
                  in
                  (next, [])))
  | Keymap.Quit_app -> (
      let is_armed =
        match m.quit_armed_at with
        | Some armed_at ->
            let elapsed = Clock.Mono.seconds_since now ~since:armed_at in
            elapsed >= 0.0 && elapsed <= Model.quit_arm_window_s
        | None -> false
      in
      if is_armed then
        (Model.disarm_quit m, [ Cmd.Quit Exit_reason.Quit_key ])
      else
        let next =
          { m with quit_armed_at = Some now }
          |> Model.with_toast ~now ~duration_s:Model.quit_arm_window_s
               ~tag:Model.Toast_quit_arm ~level:Model.Toast_warning
               Model.quit_arm_toast_message
        in
        (next, []))
