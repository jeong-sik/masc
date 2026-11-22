open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

let is_printable_key (ev : Keymap.Input.key_event) =
  (not ev.mods.ctrl) && not ev.mods.alt

let strip_newlines s =
  String.map (function '\n' | '\r' -> ' ' | c -> c) s

let open_custom_inline_modal (m : Model.t)
    (fields : Model.modal_form_field list) =
  let modal : Model.inline_modal_state =
    {
      kind = Nav.Board_new_post;
      fields;
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

let save_settings_config ~now (m : Model.t) =
  match Config_store.build_patch_request ~dry_run:false m.config with
  | Ok req ->
      let config = Config_store.mark_save_in_flight m.config in
      ( { m with config }
      , [ Cmd.Http_post { epoch = m.epoch; req = Cmd.Post_config_patch req } ] )
  | Error reason ->
      ( Model.with_toast ~now ~level:Model.Toast_warning (Say.literal reason) m
      , [] )

let stage_remove_settings_key ~now (m : Model.t) =
  match m.config.settings_pane with
  | Config_store.Pane_tree ->
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make ~ko:"[Tab]으로 검사기(오른쪽)로 이동한 뒤 키를 삭제하세요"
             ~en:"Press [Tab] to focus the inspector before removing a key")
          m
      , [] )
  | Config_store.Pane_inspector -> (
      match Config_store.stage_remove_selected m.config with
      | Ok config ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make
                 ~ko:"키 삭제 스테이징 토글됨 (Space: 미리보기 · Ctrl+S: 저장)"
                 ~en:"Toggled key removal (Space: dry-run · Ctrl+S: save)")
              { m with config }
          , [] )
      | Error reason ->
          ( Model.with_toast ~now ~level:Model.Toast_warning (Say.literal reason)
              m
          , [] ))

let dispatch_settings_overlay_key ~now (m : Model.t)
    (norm : Keymap.Input.key_event) =
  match norm.key with
  | Keymap.Input.Tab ->
      Some ({ m with config = Config_store.toggle_pane m.config }, [])
  | Keymap.Input.Left ->
      let config = Config_store.collapse_or_leave m.config in
      let nav = { m.nav with overlay = Some (Nav.Settings config.active_tab) } in
      Some ({ m with nav; config }, [])
  | Keymap.Input.Right ->
      let config = Config_store.expand_or_enter m.config in
      let nav = { m.nav with overlay = Some (Nav.Settings config.active_tab) } in
      Some ({ m with nav; config }, [])
  | Keymap.Input.Char "h" when is_printable_key norm ->
      let config = Config_store.collapse_or_leave m.config in
      let nav = { m.nav with overlay = Some (Nav.Settings config.active_tab) } in
      Some ({ m with nav; config }, [])
  | Keymap.Input.Char "l" when is_printable_key norm ->
      let config = Config_store.expand_or_enter m.config in
      let nav = { m.nav with overlay = Some (Nav.Settings config.active_tab) } in
      Some ({ m with nav; config }, [])
  | Keymap.Input.Char " " when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m Keymap.Toggle_expand)
  | Keymap.Input.Char "s" when norm.mods.ctrl && not norm.mods.alt ->
      Some (save_settings_config ~now m)
  | Keymap.Input.Char "n" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m Keymap.Create_new)
  | Keymap.Input.Delete -> Some (stage_remove_settings_key ~now m)
  | Keymap.Input.Char "d" when norm.mods.ctrl && not norm.mods.alt ->
      Some (stage_remove_settings_key ~now m)
  | Keymap.Input.Char "e" when norm.mods.ctrl && not norm.mods.alt ->
      Some (Update_actions.execute_action ~now m Keymap.Open_external)
  | Keymap.Input.Char "o" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m Keymap.Open_external)
  | Keymap.Input.Char "/" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m Keymap.Focus_filter)
  | Keymap.Input.Char "[" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m (Keymap.Sub_tab Keymap.Prev))
  | Keymap.Input.Char "]" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m (Keymap.Sub_tab Keymap.Next))
  | Keymap.Input.Char "1" when is_printable_key norm ->
      Some (Update_nav.select_settings_tab m Nav.Settings_general_ui)
  | Keymap.Input.Char "2" when is_printable_key norm ->
      Some (Update_nav.select_settings_tab m Nav.Settings_providers_models)
  | Keymap.Input.Char "3" when is_printable_key norm ->
      Some (Update_nav.select_settings_tab m Nav.Settings_routing_failover)
  | Keymap.Input.Char "4" when is_printable_key norm ->
      Some (Update_nav.select_settings_tab m Nav.Settings_keepers_companies)
  | Keymap.Input.Char "5" when is_printable_key norm ->
      Some (Update_nav.select_settings_tab m Nav.Settings_sandbox_ssh)
  | Keymap.Input.Char "6" when is_printable_key norm ->
      Some (Update_nav.select_settings_tab m Nav.Settings_voice_integrations)
  | Keymap.Input.Char "7" when is_printable_key norm ->
      Some (Update_nav.select_settings_tab m Nav.Settings_board_memory_candle)
  | Keymap.Input.Char _
  | Keymap.Input.Enter
  | Keymap.Input.Backspace
  | Keymap.Input.Escape
  | Keymap.Input.Insert
  | Keymap.Input.Up
  | Keymap.Input.Down
  | Keymap.Input.Home
  | Keymap.Input.End
  | Keymap.Input.Page_up
  | Keymap.Input.Page_down
  | Keymap.Input.Function _ ->
      None

let dispatch_incidents_overlay_key ~now (m : Model.t)
    (norm : Keymap.Input.key_event) =
  match norm.key with
  | Keymap.Input.Char " " when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m Keymap.Toggle_expand)
  | Keymap.Input.Char "d" when is_printable_key norm ->
      Some ({ m with incidents = Incidents.dismiss_selected m.incidents }, [])
  | Keymap.Input.Char ("c" | "D") when is_printable_key norm ->
      Some ({ m with incidents = Incidents.clear_all m.incidents }, [])
  | Keymap.Input.Char "o" when is_printable_key norm -> (
      match Incidents.selected_entry m.incidents with
      | None -> Some (m, [])
      | Some inc ->
          let target_dive =
            match inc.source with
            | Health.Source_keeper name ->
                Nav.Dive_keeper { name; tab = Nav.Keeper_chat }
            | Health.Source_sandbox name ->
                Nav.Dive_infra (Nav.Sandbox_dive name)
            | Health.Source_runtime lane_id ->
                Nav.Dive_infra (Nav.Lane_dive lane_id)
            | Health.Source_client_http | Health.Source_stream ->
                Nav.Dive_infra (Nav.Incident_dive inc.id)
          in
          Some (Update_nav.push_dive m target_dive))
  | Keymap.Input.Char "/" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m Keymap.Focus_filter)
  | Keymap.Input.Char _
  | Keymap.Input.Enter
  | Keymap.Input.Tab
  | Keymap.Input.Backspace
  | Keymap.Input.Escape
  | Keymap.Input.Delete
  | Keymap.Input.Insert
  | Keymap.Input.Up
  | Keymap.Input.Down
  | Keymap.Input.Left
  | Keymap.Input.Right
  | Keymap.Input.Home
  | Keymap.Input.End
  | Keymap.Input.Page_up
  | Keymap.Input.Page_down
  | Keymap.Input.Function _ ->
      None

let dispatch_system_gate_key ~now (m : Model.t) gate
    (norm : Keymap.Input.key_event) =
  match gate, norm.key with
  | Nav.Server_offline, Keymap.Input.Char "s" when is_printable_key norm -> (
      match m.server_identity.mismatch_state with
      | Model.Mismatch_halted ->
          Some
            ( Model.with_toast ~now ~level:Model.Toast_warning
                (Say.make
                   ~ko:"워크스페이스 불일치 상태에서는 로컬 서버 자동 시작이 차단됩니다"
                   ~en:"Cannot autostart local server during workspace mismatch")
                m
            , [] )
      | Model.Mismatch_none | Model.Mismatch_recovering ->
          let server_identity =
            { m.server_identity with autostart_attempted = true }
          in
          Some
            ( Model.with_toast ~now ~level:Model.Toast_info
                (Say.make ~ko:"로컬 MASC 서버 시작 요청 중..."
                   ~en:"Starting local MASC server...")
                { m with server_identity }
            , [ Cmd.Start_local_server ] ))
  | (Nav.Server_offline | Nav.Auth_gate), Keymap.Input.Char "r"
    when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m Keymap.Refresh)
  | Nav.Media_viewer, Keymap.Input.Char "y" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m Keymap.Copy_selected)
  | ( ( Nav.Server_offline
      | Nav.Auth_gate
      | Nav.Media_viewer
      | Nav.Micro_viewport )
    , ( Keymap.Input.Char _
      | Keymap.Input.Enter
      | Keymap.Input.Tab
      | Keymap.Input.Backspace
      | Keymap.Input.Escape
      | Keymap.Input.Delete
      | Keymap.Input.Insert
      | Keymap.Input.Up
      | Keymap.Input.Down
      | Keymap.Input.Left
      | Keymap.Input.Right
      | Keymap.Input.Home
      | Keymap.Input.End
      | Keymap.Input.Page_up
      | Keymap.Input.Page_down
      | Keymap.Input.Function _ ) ) ->
      None

let interrupt_active_keeper_turn ~now (m : Model.t) =
  let keeper_opt =
    match Model.active_dive m with
    | Some (Nav.Dive_keeper { name; _ }) -> Some name
    | Some (Nav.Dive_work _ | Nav.Dive_knowledge _ | Nav.Dive_infra _) | None ->
        Update_nav.resolve_target_keeper m
  in
  match keeper_opt with
  | None ->
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make ~ko:"중단할 대상 키퍼가 선택되지 않았습니다"
             ~en:"No target keeper selected to interrupt")
          m
      , [] )
  | Some keeper -> (
      let active_stream_opt =
        match Fleet_store.String_map.find_opt keeper m.fleet.chat_streams with
        | Some s when s.active -> Some s
        | Some _ | None -> None
      in
      match
        Fleet_store.active_turn_for ~keeper m.fleet, active_stream_opt
      with
      | Some turn, stream_opt ->
          let fleet =
            match stream_opt with
            | Some s ->
                Fleet_store.finish_chat_stream ~keeper ~request_id:s.request_id
                  ~error:(Some "Interrupted by operator") m.fleet
            | None -> m.fleet
          in
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
                      { keeper; interrupt_token = turn.interrupt_token };
                };
            ] )
      | None, Some s ->
          let interrupt_token =
            Option.value s.operation_id ~default:s.request_id
          in
          let fleet =
            Fleet_store.finish_chat_stream ~keeper ~request_id:s.request_id
              ~error:(Some "Interrupted by operator") m.fleet
          in
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
                    Cmd.Post_keeper_turn_interrupt { keeper; interrupt_token };
                };
            ] )
      | None, None ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make
                 ~ko:("진행 중인 턴이 없습니다: " ^ keeper)
                 ~en:("No active turn running for " ^ keeper))
              m
          , [] ))

let open_goal_confirmation_proof_modal (m : Model.t) ~(goal_id : string)
    ~(criterion_revision : string) =
  (* Never fabricate request_id, verification_run_id, or operator_id: ask the
     operator to supply exact server-issued confirmation proof fields. *)
  open_custom_inline_modal m
    [
      {
        key = "confirm_goal_id";
        label = Say.make ~ko:"목표 ID" ~en:"Goal ID";
        value = goal_id;
        required = true;
      };
      {
        key = "confirm_criterion_revision";
        label = Say.make ~ko:"기준 리비전 (criterion_revision)" ~en:"Criterion revision";
        value = criterion_revision;
        required = true;
      };
      {
        key = "confirm_request_id";
        label =
          Say.make ~ko:"서버 발급 request_id (GET /goals/confirmation)"
            ~en:"Server-issued request_id (GET /goals/confirmation)";
        value = "";
        required = true;
      };
      {
        key = "confirm_verification_run_id";
        label =
          Say.make ~ko:"서버 발급 verification_run_id"
            ~en:"Server-issued verification_run_id";
        value = "";
        required = true;
      };
      {
        key = "confirm_operator_id";
        label =
          Say.make ~ko:"운영자 ID (expected_operator_id)"
            ~en:"Operator ID (expected_operator_id)";
        value = "";
        required = true;
      };
    ]

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
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make
             ~ko:("목표 완료 검증 요청: " ^ g.title)
             ~en:("Requesting goal completion verification: " ^ g.title))
          m
      , [
          Cmd.Http_post
            {
              epoch = m.epoch;
              req =
                Cmd.Post_goal_transition
                  {
                    goal_id = g.id;
                    action = Wire_work.Request_complete;
                    note = None;
                  };
            };
        ] )
  | Wire_work.Verifying ->
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make ~ko:"목표가 현재 검증 진행 중입니다"
             ~en:"Goal is already verifying")
          m
      , [] )
  | Wire_work.Paused _ ->
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make ~ko:("목표 재개 요청: " ^ g.title) ~en:("Resuming goal: " ^ g.title))
          m
      , [
          Cmd.Http_post
            {
              epoch = m.epoch;
              req =
                Cmd.Post_goal_transition
                  { goal_id = g.id; action = Wire_work.Resume; note = None };
            };
        ] )
  | Wire_work.Blocked _ ->
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make ~ko:("목표 차단 해제: " ^ g.title) ~en:("Unblocking goal: " ^ g.title))
          m
      , [
          Cmd.Http_post
            {
              epoch = m.epoch;
              req =
                Cmd.Post_goal_transition
                  { goal_id = g.id; action = Wire_work.Unblock; note = None };
            };
        ] )
  | Wire_work.Completed | Wire_work.Dropped ->
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make ~ko:("목표 재개(Reopen): " ^ g.title) ~en:("Reopening goal: " ^ g.title))
          m
      , [
          Cmd.Http_post
            {
              epoch = m.epoch;
              req =
                Cmd.Post_goal_transition
                  { goal_id = g.id; action = Wire_work.Reopen; note = None };
            };
        ] )

let goal_action_on_stop ~now (m : Model.t) (g : Wire_work.goal) =
  match g.phase with
  | Wire_work.Paused _ ->
      ( Model.with_toast ~now ~level:Model.Toast_warning
          (Say.make ~ko:("목표 폐기(Drop) 요청: " ^ g.title) ~en:("Dropping goal: " ^ g.title))
          m
      , [
          Cmd.Http_post
            {
              epoch = m.epoch;
              req =
                Cmd.Post_goal_transition
                  { goal_id = g.id; action = Wire_work.Drop; note = None };
            };
        ] )
  | Wire_work.Executing
  | Wire_work.Verifying
  | Wire_work.Awaiting_confirmation
  | Wire_work.Blocked _ ->
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make ~ko:("목표 일시정지 요청: " ^ g.title) ~en:("Pausing goal: " ^ g.title))
          m
      , [
          Cmd.Http_post
            {
              epoch = m.epoch;
              req =
                Cmd.Post_goal_transition
                  { goal_id = g.id; action = Wire_work.Pause; note = None };
            };
        ] )
  | Wire_work.Completed | Wire_work.Dropped ->
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make ~ko:"이미 종료된 목표입니다 ([a] 재개)"
             ~en:"Goal is already terminal ([a] to reopen)")
          m
      , [] )

let resolve_memory_act_keeper (m : Model.t) =
  match Model.active_dive m with
  | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_memory }) -> Some name
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
      | Nav.Dive_infra _ )
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
  open_custom_inline_modal m
    [
      {
        key = "memory_keeper";
        label = Say.make ~ko:"대상 키퍼" ~en:"Target keeper";
        value = keeper_default;
        required = true;
      };
      {
        key = "memory_act";
        label =
          Say.make ~ko:"복구 액션 (resume|adopt|restart_reading|skip_item|skip_line)"
            ~en:"Recovery act (resume|adopt|restart_reading|skip_item|skip_line)";
        value = "resume";
        required = true;
      };
      {
        key = "memory_arg";
        label =
          Say.make ~ko:"인자 (observed / turn_log:line / offset)"
            ~en:"Argument (observed / turn_log:line / offset)";
        value = "";
        required = false;
      };
    ]

let open_wiki_edit_modal (m : Model.t) ~(slug : string) =
  let title, summary, body =
    match Observed.to_option m.knowledge.wiki_page with
    | Some d when String.equal d.slug slug ->
        (d.frontmatter.title, d.frontmatter.summary, d.body_markdown)
    | Some _ | None -> (
        match Knowledge_store.selected_wiki_page m.knowledge with
        | Some p when String.equal p.slug slug -> (p.title, p.summary, "")
        | Some _ | None -> (slug, "", ""))
  in
  open_custom_inline_modal m
    [
      {
        key = "wiki_slug";
        label = Say.make ~ko:"위키 슬러그" ~en:"Wiki slug";
        value = slug;
        required = true;
      };
      {
        key = "wiki_title";
        label = Say.make ~ko:"제목" ~en:"Title";
        value = title;
        required = true;
      };
      {
        key = "wiki_summary";
        label = Say.make ~ko:"요약" ~en:"Summary";
        value = summary;
        required = false;
      };
      {
        key = "wiki_body";
        label = Say.make ~ko:"본문 (Markdown)" ~en:"Body (Markdown)";
        value = body;
        required = true;
      };
      {
        key = "wiki_note";
        label = Say.make ~ko:"변경 메모" ~en:"Edit note";
        value = "";
        required = false;
      };
    ]

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
  let preset_default = Option.value draft.preset ~default:"" in
  open_custom_inline_modal m
    [
      {
        key = "fusion_keeper";
        label = Say.make ~ko:"실행 키퍼" ~en:"Keeper";
        value = keeper_default;
        required = true;
      };
      {
        key = "fusion_prompt";
        label = Say.make ~ko:"Fusion 프롬프트" ~en:"Fusion prompt";
        value = draft.prompt;
        required = true;
      };
      {
        key = "fusion_topology";
        label =
          Say.make ~ko:"토폴로지 (선택: simple|refine|conditional|judge_of_judges)"
            ~en:"Topology (optional: simple|refine|conditional|judge_of_judges)";
        value = topo_default;
        required = false;
      };
      {
        key = "fusion_preset";
        label = Say.make ~ko:"프리셋 (선택)" ~en:"Preset (optional)";
        value = preset_default;
        required = false;
      };
    ]

let latest_reply_for_tts (m : Model.t) =
  let keeper_opt =
    match Model.active_dive m with
    | Some (Nav.Dive_keeper { name; _ }) -> Some name
    | Some (Nav.Dive_work _ | Nav.Dive_knowledge _ | Nav.Dive_infra _) | None ->
        Update_nav.resolve_target_keeper m
  in
  match keeper_opt with
  | None -> None
  | Some keeper -> (
      match Fleet_store.String_map.find_opt keeper m.fleet.chat_streams with
      | Some s when s.active && not (String.equal (String.trim s.text) "") ->
          Some (keeper, s.text)
      | Some _ | None -> (
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

let key_char_opt = function
  | Keymap.Input.Char s -> Some s
  | Keymap.Input.Enter
  | Keymap.Input.Tab
  | Keymap.Input.Backspace
  | Keymap.Input.Escape
  | Keymap.Input.Delete
  | Keymap.Input.Insert
  | Keymap.Input.Up
  | Keymap.Input.Down
  | Keymap.Input.Left
  | Keymap.Input.Right
  | Keymap.Input.Home
  | Keymap.Input.End
  | Keymap.Input.Page_up
  | Keymap.Input.Page_down
  | Keymap.Input.Function _ ->
      None

let dispatch_contextual_hotkey ~now (m : Model.t)
    (norm : Keymap.Input.key_event) =
  let is_ctrl_e =
    norm.mods.ctrl && (not norm.mods.alt)
    && Option.equal String.equal (key_char_opt norm.key) (Some "e")
  in
  let printable_char =
    if is_printable_key norm then key_char_opt norm.key else None
  in
  (* 1. Active Dive contextual hotkeys *)
  match Model.active_dive m with
  | Some (Nav.Dive_work (Nav.Verification_dive req_id)) -> (
      let ver_opt =
        List.find_opt
          (fun (v : Wire_work.verification_request) ->
            String.equal v.request_id req_id)
          (Work_store.verifications_list m.work)
      in
      match printable_char, ver_opt with
      | Some "a", Some v ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make
                 ~ko:("검증 승인 전송: " ^ v.task_title)
                 ~en:("Approving verification: " ^ v.task_title))
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req =
                    Cmd.Post_verification_verdict
                      {
                        task_id = v.task_id;
                        verification_id = v.request_id;
                        verdict = Wire_work.Verdict_approve;
                        notes = None;
                      };
                };
            ] )
      | Some "x", _ ->
          Update_nav.open_inline_modal m (Nav.Verification_reject req_id)
      | Some ("h" | "X"), Some v ->
          Update_nav.open_inline_modal m (Nav.Harness_overrule v.task_id)
      | Some ("h" | "X"), None ->
          Update_nav.open_inline_modal m (Nav.Harness_overrule req_id)
      | _ -> (m, []))
  | Some (Nav.Dive_work (Nav.Goal_dive goal_id)) -> (
      let goal_opt =
        List.find_opt
          (fun (g : Wire_work.goal) -> String.equal g.id goal_id)
          (Work_store.goals m.work)
      in
      match printable_char, goal_opt with
      | Some "a", Some g -> goal_action_on_approve ~now m g
      | Some "c", Some g ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make
                 ~ko:("목표 완료 검증 요청: " ^ g.title)
                 ~en:("Requesting goal completion: " ^ g.title))
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req =
                    Cmd.Post_goal_transition
                      {
                        goal_id = g.id;
                        action = Wire_work.Request_complete;
                        note = None;
                      };
                };
            ] )
      | Some "x", Some g -> goal_action_on_stop ~now m g
      | _ -> (m, []))
  | Some (Nav.Dive_work (Nav.Task_dive task_id)) -> (
      match printable_char with
      | Some "x" -> Update_nav.open_inline_modal m (Nav.Task_cancel task_id)
      | Some ("h" | "X") ->
          Update_nav.open_inline_modal m (Nav.Harness_overrule task_id)
      | _ -> (m, []))
  | Some (Nav.Dive_knowledge (Nav.Wiki_dive slug)) ->
      if is_ctrl_e then
        ( Model.with_toast ~now ~level:Model.Toast_info
            (Say.make
               ~ko:("외부 편집기로 위키 열기: " ^ slug)
               ~en:("Opening wiki page in $EDITOR: " ^ slug))
            m
        , [ Cmd.Open_editor_escape_hatch (Cmd.Edit_wiki_page slug) ] )
      else (
        match printable_char with
        | Some "e" -> open_wiki_edit_modal m ~slug
        | _ -> (m, []))
  | Some (Nav.Dive_infra (Nav.Sandbox_dive keeper)) -> (
      match printable_char with
      | Some "p" ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make
                 ~ko:("샌드박스 프로브 실행: " ^ keeper)
                 ~en:("Probing sandbox: " ^ keeper))
              m
          , [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req = Cmd.Post_sandbox_probe (`Keeper keeper);
                };
            ] )
      | _ -> (m, []))
  | Some (Nav.Dive_keeper { name; tab }) -> (
      match tab, printable_char with
      | Nav.Keeper_sandbox, Some "p" ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make
                 ~ko:("샌드박스 프로브 실행: " ^ name)
                 ~en:("Probing sandbox: " ^ name))
              m
          , [
              Cmd.Http_post
                { epoch = m.epoch; req = Cmd.Post_sandbox_probe (`Keeper name) };
            ] )
      | Nav.Keeper_memory, Some "a" ->
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
                      { keeper = name; act = Wire_knowledge.Act_resume };
                };
            ] )
      | Nav.Keeper_memory, Some "A" ->
          open_memory_act_modal m ~keeper_default:name
      | Nav.Keeper_chat, Some "c" ->
          let drafts =
            m.drafts |> Drafts.set_active_keeper name |> Drafts.set_focus true
          in
          ({ m with drafts }, [])
      | ( ( Nav.Keeper_memory
          | Nav.Keeper_work_candle
          | Nav.Keeper_sandbox
          | Nav.Keeper_config )
        , Some "c" ) ->
          let m1, cmds =
            Update_nav.push_dive m
              (Nav.Dive_keeper { name; tab = Nav.Keeper_chat })
          in
          let drafts =
            m1.drafts |> Drafts.set_active_keeper name |> Drafts.set_focus true
          in
          ({ m1 with drafts }, cmds)
      | Nav.Keeper_chat, Some "S" -> (
          match latest_reply_for_tts m with
          | Some (keeper, text) ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:("음성 읽기 시작: " ^ keeper)
                     ~en:("Speaking latest reply from " ^ keeper))
                  m
              , [ Cmd.Voice_cmd (Cmd.Speak { text; voice_id = None }) ] )
          | None ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make ~ko:"읽을 최근 키퍼 응답이 없습니다"
                     ~en:"No recent keeper reply to speak")
                  m
              , [] ))
      | ( ( Nav.Keeper_chat
          | Nav.Keeper_memory
          | Nav.Keeper_work_candle
          | Nav.Keeper_sandbox
          | Nav.Keeper_config )
        , (Some _ | None) ) ->
          (m, []))
  | Some
      ( Nav.Dive_knowledge (Nav.Thread_dive _ | Nav.Artifact_dive _ | Nav.Memory_diff_dive _)
      | Nav.Dive_infra (Nav.Lane_dive _ | Nav.Incident_dive _) ) ->
      (m, [])
  | None -> (
      (* 2. Workspace-level contextual hotkeys *)
      match m.nav.workspace with
      | Nav.Runtime -> (
          match printable_char with
          | Some "u"
            when Nav.equal_runtime_tab m.runtime.active_tab
                   Nav.Runtime_quotas_credits ->
              ( {
                  m with
                  runtime = Runtime_store.toggle_unreported_accounts m.runtime;
                }
              , [] )
          | Some "f" -> open_fusion_launch_modal m
          | _ -> (m, []))
      | Nav.Infra -> (
          match m.infra.active_tab, printable_char with
          | Nav.Infra_sandboxes, Some "p" ->
              let target, label =
                match Infra_store.selected_sandbox_keeper m.infra with
                | Some k -> (`Keeper k, k)
                | None -> (`All, "all")
              in
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:("샌드박스 프로브 실행: " ^ label)
                     ~en:("Probing sandbox: " ^ label))
                  m
              , [
                  Cmd.Http_post
                    { epoch = m.epoch; req = Cmd.Post_sandbox_probe target };
                ] )
          | ( ( Nav.Infra_sandboxes
              | Nav.Infra_repos_changes
              | Nav.Infra_activity_logs )
            , (Some _ | None) ) ->
              (m, []))
      | Nav.Keepers -> (
          match printable_char with
          | Some "c" -> (
              match Fleet_store.selected_keeper_summary m.fleet with
              | Some k ->
                  let m1, cmds =
                    Update_nav.push_dive m
                      (Nav.Dive_keeper
                         { name = k.name; tab = Nav.Keeper_chat })
                  in
                  let drafts =
                    m1.drafts
                    |> Drafts.set_active_keeper k.name
                    |> Drafts.set_focus true
                  in
                  ({ m1 with drafts }, cmds)
              | None ->
                  ( Model.with_toast ~now ~level:Model.Toast_warning
                      (Say.make ~ko:"채팅할 키퍼를 먼저 선택하세요"
                         ~en:"Select a keeper first")
                      m
                  , [] ))
          | Some "S" -> (
              match latest_reply_for_tts m with
              | Some (keeper, text) ->
                  ( Model.with_toast ~now ~level:Model.Toast_info
                      (Say.make
                         ~ko:("음성 읽기 시작: " ^ keeper)
                         ~en:("Speaking latest reply from " ^ keeper))
                      m
                  , [ Cmd.Voice_cmd (Cmd.Speak { text; voice_id = None }) ] )
              | None ->
                  ( Model.with_toast ~now ~level:Model.Toast_info
                      (Say.make ~ko:"읽을 최근 키퍼 응답이 없습니다"
                         ~en:"No recent keeper reply to speak")
                      m
                  , [] ))
          | _ -> (m, []))
      | Nav.Knowledge -> (
          match m.knowledge.active_tab with
          | Nav.Knowledge_memory -> (
              match printable_char with
              | Some "a" -> (
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
                                  {
                                    keeper;
                                    act = Wire_knowledge.Act_resume;
                                  };
                            };
                        ] )
                  | None -> open_memory_act_modal m ~keeper_default:"")
              | Some "A" ->
                  let keeper_default =
                    Option.value (resolve_memory_act_keeper m) ~default:""
                  in
                  open_memory_act_modal m ~keeper_default
              | _ -> (m, []))
          | Nav.Knowledge_wiki_artifacts -> (
              match m.knowledge.wiki_artifacts_submode with
              | `Wiki -> (
                  match Knowledge_store.selected_wiki_page m.knowledge with
                  | None -> (m, [])
                  | Some p ->
                      if is_ctrl_e then
                        ( Model.with_toast ~now ~level:Model.Toast_info
                            (Say.make
                               ~ko:("외부 편집기로 위키 열기: " ^ p.slug)
                               ~en:("Opening wiki page in $EDITOR: " ^ p.slug))
                            m
                        , [
                            Cmd.Open_editor_escape_hatch
                              (Cmd.Edit_wiki_page p.slug);
                          ] )
                      else (
                        match printable_char with
                        | Some "e" -> open_wiki_edit_modal m ~slug:p.slug
                        | _ -> (m, [])))
              | `Artifacts -> (m, []))
          | Nav.Knowledge_board -> (
              match printable_char with
              | Some "R" -> (
                  match Knowledge_store.quarantines_list m.knowledge with
                  | q :: _ ->
                      ( Model.with_toast ~now ~level:Model.Toast_info
                          (Say.make
                             ~ko:("격리 항목 재큐잉 요청: " ^ q.quarantine_id)
                             ~en:("Requeuing quarantine: " ^ q.quarantine_id))
                          m
                      , [
                          Cmd.Http_post
                            {
                              epoch = m.epoch;
                              req =
                                Cmd.Post_quarantine_requeue
                                  {
                                    keeper = q.keeper;
                                    partition_id = q.partition_id;
                                    quarantine_id = q.quarantine_id;
                                    reason = None;
                                  };
                            };
                        ] )
                  | [] ->
                      ( Model.with_toast ~now ~level:Model.Toast_info
                          (Say.make ~ko:"재큐잉할 격리 항목이 없습니다"
                             ~en:"No quarantined posts to requeue")
                          m
                      , [] ))
              | _ -> (m, [])))
      | Nav.Work -> (
          match m.work.active_tab with
          | Nav.Work_pipeline -> (
              let verif_focused = Int.equal (m.nav.pane_index mod 2) 1 in
              let active_target =
                match
                  verif_focused
                , Work_store.selected_goal m.work
                , Work_store.selected_verification m.work
                with
                | true, _, Some v -> `Verification v
                | false, Some g, _ -> `Goal g
                | true, Some g, None -> `Goal g
                | false, None, Some v -> `Verification v
                | (true | false), None, None -> `None
              in
              match active_target with
              | `Goal g -> (
                  match printable_char with
                  | Some "a" -> goal_action_on_approve ~now m g
                  | Some "c" ->
                      ( Model.with_toast ~now ~level:Model.Toast_info
                          (Say.make
                             ~ko:("목표 완료 검증 요청: " ^ g.title)
                             ~en:("Requesting goal completion: " ^ g.title))
                          m
                      , [
                          Cmd.Http_post
                            {
                              epoch = m.epoch;
                              req =
                                Cmd.Post_goal_transition
                                  {
                                    goal_id = g.id;
                                    action = Wire_work.Request_complete;
                                    note = None;
                                  };
                            };
                        ] )
                  | Some "x" -> goal_action_on_stop ~now m g
                  | _ -> (m, []))
              | `Verification v -> (
                  match printable_char with
                  | Some "a" ->
                      ( Model.with_toast ~now ~level:Model.Toast_info
                          (Say.make
                             ~ko:("검증 승인 전송: " ^ v.task_title)
                             ~en:("Approving verification: " ^ v.task_title))
                          m
                      , [
                          Cmd.Http_post
                            {
                              epoch = m.epoch;
                              req =
                                Cmd.Post_verification_verdict
                                  {
                                    task_id = v.task_id;
                                    verification_id = v.request_id;
                                    verdict = Wire_work.Verdict_approve;
                                    notes = None;
                                  };
                            };
                        ] )
                  | Some "x" ->
                      Update_nav.open_inline_modal m
                        (Nav.Verification_reject v.request_id)
                  | Some ("h" | "X") ->
                      Update_nav.open_inline_modal m
                        (Nav.Harness_overrule v.task_id)
                  | _ -> (m, []))
              | `None -> (m, []))
          | Nav.Work_tasks_schedules -> (
              match Work_store.selected_task m.work, printable_char with
              | Some task, Some "x" ->
                  Update_nav.open_inline_modal m (Nav.Task_cancel task.id)
              | Some task, Some ("h" | "X") ->
                  Update_nav.open_inline_modal m (Nav.Harness_overrule task.id)
              | _ -> (m, []))
          | Nav.Work_inbox | Nav.Work_candle_scorecard -> (m, []))
      | Nav.Pulse -> (m, []))

let apply_key_event ~now (m : Model.t) (ev : Keymap.Input.key_event) =
  let norm = Keymap.normalize_key_event ev in
  (* Top-precedence Micro_viewport gate per tui-chat-design/SKILL.md: never
     mutate hidden drafts or underlying overlays; only Quit_app is accepted. *)
  if Model.is_too_small_viewport m.viewport then
    match Keymap.dispatch ~scope_chain:[ Keymap.Global ] norm with
    | Some act when Keymap.equal_action act Keymap.Quit_app ->
        Update_actions.execute_action ~now m Keymap.Quit_app
    | Some _ | None -> (m, [])
  else
    match m.nav.overlay with
    | Some (Nav.System_gate Nav.Micro_viewport) -> (
        match Keymap.dispatch ~scope_chain:[ Keymap.Global ] norm with
        | Some act when Keymap.equal_action act Keymap.Quit_app ->
            Update_actions.execute_action ~now m Keymap.Quit_app
        | Some _ | None -> (m, []))
    | Some
        ( Nav.System_gate (Nav.Auth_gate | Nav.Server_offline | Nav.Media_viewer)
        | Nav.Palette
        | Nav.Settings _
        | Nav.Incidents
        | Nav.Queue_context _
        | Nav.Inline_action _
        | Nav.Help )
    | None -> (
        (* 1. Active filter box text capture *)
        if m.nav.filter_focused then
          match norm.key with
          | Keymap.Input.Escape | Keymap.Input.Enter ->
              ({ m with nav = { m.nav with filter_focused = false } }, [])
          | Keymap.Input.Backspace ->
              let q =
                Update_nav.drop_last_utf8 (Update_nav.current_filter_query m)
              in
              (Update_nav.set_active_filter_query q m, [])
          | Keymap.Input.Char s when is_printable_key norm ->
              let q = Update_nav.current_filter_query m ^ s in
              (Update_nav.set_active_filter_query q m, [])
          | Keymap.Input.Char _
          | Keymap.Input.Tab
          | Keymap.Input.Delete
          | Keymap.Input.Insert
          | Keymap.Input.Up
          | Keymap.Input.Down
          | Keymap.Input.Left
          | Keymap.Input.Right
          | Keymap.Input.Home
          | Keymap.Input.End
          | Keymap.Input.Page_up
          | Keymap.Input.Page_down
          | Keymap.Input.Function _ -> (
              match Keymap.dispatch ~scope_chain:[ Keymap.Global ] norm with
              | Some act -> Update_actions.execute_action ~now m act
              | None -> (m, []))
        else
          (* 2. Active text-owning and action-owning overlays *)
          match m.nav.overlay with
          | Some Nav.Palette -> (
              match norm.key with
              | Keymap.Input.Backspace ->
                  let query = Update_nav.drop_last_utf8 m.palette.query in
                  ( { m with palette = { m.palette with query; selected = 0 } }
                  , [] )
              | Keymap.Input.Char s when is_printable_key norm ->
                  let query = m.palette.query ^ s in
                  ( { m with palette = { m.palette with query; selected = 0 } }
                  , [] )
              | Keymap.Input.Char _
              | Keymap.Input.Enter
              | Keymap.Input.Tab
              | Keymap.Input.Escape
              | Keymap.Input.Delete
              | Keymap.Input.Insert
              | Keymap.Input.Up
              | Keymap.Input.Down
              | Keymap.Input.Left
              | Keymap.Input.Right
              | Keymap.Input.Home
              | Keymap.Input.End
              | Keymap.Input.Page_up
              | Keymap.Input.Page_down
              | Keymap.Input.Function _ -> (
                  match
                    Keymap.dispatch ~scope_chain:(Model.focus_scope_chain m)
                      norm
                  with
                  | Some act -> Update_actions.execute_action ~now m act
                  | None -> (m, [])))
          | Some (Nav.Inline_action _) -> (
              match m.inline_modal with
              | None -> (m, [])
              | Some modal -> (
                  match norm.key with
                  | Keymap.Input.Tab ->
                      let delta = if norm.mods.shift then -1 else 1 in
                      ( {
                          m with
                          inline_modal =
                            Some (Model.modal_cycle_field ~delta modal);
                        }
                      , [] )
                  | Keymap.Input.Backspace ->
                      ( {
                          m with
                          inline_modal =
                            Some
                              (Model.modal_update_active_field
                                 Update_nav.drop_last_utf8 modal);
                        }
                      , [] )
                  | Keymap.Input.Char s when is_printable_key norm ->
                      ( {
                          m with
                          inline_modal =
                            Some
                              (Model.modal_update_active_field
                                 (fun v -> v ^ s)
                                 modal);
                        }
                      , [] )
                  | Keymap.Input.Char _
                  | Keymap.Input.Enter
                  | Keymap.Input.Escape
                  | Keymap.Input.Delete
                  | Keymap.Input.Insert
                  | Keymap.Input.Up
                  | Keymap.Input.Down
                  | Keymap.Input.Left
                  | Keymap.Input.Right
                  | Keymap.Input.Home
                  | Keymap.Input.End
                  | Keymap.Input.Page_up
                  | Keymap.Input.Page_down
                  | Keymap.Input.Function _ -> (
                      match
                        Keymap.dispatch ~scope_chain:(Model.focus_scope_chain m)
                          norm
                      with
                      | Some act -> Update_actions.execute_action ~now m act
                      | None -> (m, []))))
          | Some (Nav.Settings _) when Config_store.is_editing_field m.config -> (
              match norm.key with
              | Keymap.Input.Backspace ->
                  ( {
                      m with
                      config = Config_store.backspace_edit_buffer m.config;
                    }
                  , [] )
              | Keymap.Input.Char s when is_printable_key norm ->
                  ( { m with config = Config_store.append_edit_char s m.config }
                  , [] )
              | Keymap.Input.Char _
              | Keymap.Input.Enter
              | Keymap.Input.Tab
              | Keymap.Input.Escape
              | Keymap.Input.Delete
              | Keymap.Input.Insert
              | Keymap.Input.Up
              | Keymap.Input.Down
              | Keymap.Input.Left
              | Keymap.Input.Right
              | Keymap.Input.Home
              | Keymap.Input.End
              | Keymap.Input.Page_up
              | Keymap.Input.Page_down
              | Keymap.Input.Function _ -> (
                  match
                    Keymap.dispatch ~scope_chain:(Model.focus_scope_chain m)
                      norm
                  with
                  | Some act -> Update_actions.execute_action ~now m act
                  | None -> (m, [])))
          | Some (Nav.Settings _) -> (
              match dispatch_settings_overlay_key ~now m norm with
              | Some res -> res
              | None -> (
                  match
                    Keymap.dispatch ~scope_chain:(Model.focus_scope_chain m)
                      norm
                  with
                  | Some act -> Update_actions.execute_action ~now m act
                  | None -> (m, [])))
          | Some Nav.Incidents -> (
              match dispatch_incidents_overlay_key ~now m norm with
              | Some res -> res
              | None -> (
                  match
                    Keymap.dispatch ~scope_chain:(Model.focus_scope_chain m)
                      norm
                  with
                  | Some act -> Update_actions.execute_action ~now m act
                  | None -> (m, [])))
          | Some (Nav.System_gate gate) -> (
              match dispatch_system_gate_key ~now m gate norm with
              | Some res -> res
              | None -> (
                  match
                    Keymap.dispatch ~scope_chain:(Model.focus_scope_chain m)
                      norm
                  with
                  | Some act -> Update_actions.execute_action ~now m act
                  | None -> (m, [])))
          | Some (Nav.Queue_context _ | Nav.Help) | None -> (
              let is_ctrl_x =
                Option.is_none m.nav.overlay
                && norm.mods.ctrl && (not norm.mods.alt)
                && Option.equal String.equal (key_char_opt norm.key) (Some "x")
              in
              if is_ctrl_x then interrupt_active_keeper_turn ~now m
              else
                (* 3. Single-SSOT Keymap dispatch *)
                match
                  Keymap.dispatch ~scope_chain:(Model.focus_scope_chain m) norm
                with
                | Some act -> Update_actions.execute_action ~now m act
                | None ->
                    (* 4. Contextual workspace hotkeys & Composer raw editing keys *)
                    if Drafts.is_focused m.drafts then
                      match norm.key with
                      | Keymap.Input.Backspace ->
                          ({ m with drafts = Drafts.backspace m.drafts }, [])
                      | Keymap.Input.Delete ->
                          ( { m with drafts = Drafts.delete_forward m.drafts }
                          , [] )
                      | Keymap.Input.Left ->
                          ( {
                              m with
                              drafts = Drafts.move_cursor `Left m.drafts;
                            }
                          , [] )
                      | Keymap.Input.Right ->
                          ( {
                              m with
                              drafts = Drafts.move_cursor `Right m.drafts;
                            }
                          , [] )
                      | Keymap.Input.Home ->
                          ( {
                              m with
                              drafts = Drafts.move_cursor `Home m.drafts;
                            }
                          , [] )
                      | Keymap.Input.End ->
                          ({ m with drafts = Drafts.move_cursor `End m.drafts }, [])
                      | Keymap.Input.Char s when is_printable_key norm ->
                          ({ m with drafts = Drafts.insert_text s m.drafts }, [])
                      | Keymap.Input.Char _
                      | Keymap.Input.Enter
                      | Keymap.Input.Tab
                      | Keymap.Input.Escape
                      | Keymap.Input.Insert
                      | Keymap.Input.Up
                      | Keymap.Input.Down
                      | Keymap.Input.Page_up
                      | Keymap.Input.Page_down
                      | Keymap.Input.Function _ ->
                          (m, [])
                    else if Option.is_none m.nav.overlay then
                      dispatch_contextual_hotkey ~now m norm
                    else (m, [])))

let apply_paste ~now:_ (m : Model.t) text =
  if String.equal text "" || Model.is_too_small_viewport m.viewport then (m, [])
  else
    match m.nav.overlay with
    | Some (Nav.System_gate Nav.Micro_viewport) -> (m, [])
    | Some Nav.Palette ->
        let query = m.palette.query ^ strip_newlines text in
        ({ m with palette = { m.palette with query; selected = 0 } }, [])
    | Some (Nav.Inline_action _) -> (
        match m.inline_modal with
        | None -> (m, [])
        | Some modal ->
            ( {
                m with
                inline_modal =
                  Some
                    (Model.modal_update_active_field (fun v -> v ^ text) modal);
              }
            , [] ))
    | Some (Nav.Settings _) when Config_store.is_editing_field m.config ->
        ( {
            m with
            config =
              Config_store.append_edit_char (strip_newlines text) m.config;
          }
        , [] )
    | Some
        ( Nav.Settings _
        | Nav.Incidents
        | Nav.Queue_context _
        | Nav.Help
        | Nav.System_gate (Nav.Auth_gate | Nav.Server_offline | Nav.Media_viewer)
          ) ->
        (m, [])
    | None ->
        if m.nav.filter_focused then
          let q = Update_nav.current_filter_query m ^ strip_newlines text in
          (Update_nav.set_active_filter_query q m, [])
        else
          let drafts =
            m.drafts |> Drafts.set_focus true |> Drafts.insert_text text
          in
          ({ m with drafts }, [])

let apply_mouse ~now (m : Model.t) (ev : Keymap.Input.mouse_event) =
  if Model.is_too_small_viewport m.viewport then (m, [])
  else
    match ev with
    | Keymap.Input.Wheel { dir = Keymap.Input.Wheel_up; _ } ->
        Update_actions.execute_action ~now m (Keymap.Move Keymap.Up)
    | Keymap.Input.Wheel { dir = Keymap.Input.Wheel_down; _ } ->
        Update_actions.execute_action ~now m (Keymap.Move Keymap.Down)
    | Keymap.Input.Left_press _
    | Keymap.Input.Left_drag _
    | Keymap.Input.Left_release _ ->
        (m, [])
