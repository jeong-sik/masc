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

let is_korean_char (s : string) =
  if String.length s = 0 then false
  else
    let d = String.get_utf_8_uchar s 0 in
    if not (Uchar.utf_decode_is_valid d) then false
    else
      let cp = Uchar.to_int (Uchar.utf_decode_uchar d) in
      (cp >= 0xAC00 && cp <= 0xD7A3)
      || (cp >= 0x3131 && cp <= 0x318E)
      || (cp >= 0x1100 && cp <= 0x11FF)

let save_settings_config = Update_actions.save_settings_config

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

let extract_embedded_json_opt s =
  let len = String.length s in
  let rec find_delim i =
    if i >= len then None
    else
      match s.[i] with
      | '{' | '[' -> Some i
      | _ -> find_delim (i + 1)
  in
  match find_delim 0 with
  | None -> None
  | Some idx -> (
      let prefix = String.trim (String.sub s 0 idx) in
      let rest = String.sub s idx (len - idx) in
      match Yojson.Safe.from_string rest with
      | json -> Some (prefix, json)
      | exception Yojson.Json_error _ -> None)

let patch_response_diff_row_count (resp : Wire_config.patch_response) =
  if resp.diff_hunks <> [] then
    List.fold_left
      (fun acc (h : Wire_config.diff_hunk) -> acc + List.length h.lines)
      0 resp.diff_hunks
  else List.length (Masc_tui_ui.Diff.parse_unified resp.unified_diff)

let settings_dry_run_max_scroll (m : Model.t) =
  match m.config.dry_run_preview with
  | Config_store.Dry_run_idle
  | Config_store.Dry_run_loading
  | Config_store.Dry_run_failed _ ->
      0
  | Config_store.Dry_run_ready resp ->
      let n_rows = patch_response_diff_row_count resp in
      if n_rows <= 0 then 0
      else
        let modal_w = max 0 m.viewport.cols in
        let modal_h = max 0 (m.viewport.rows - 2) in
        let inner_w = if modal_w >= 2 && modal_h >= 2 then modal_w - 2 else 0 in
        let inner_h = if modal_w >= 2 && modal_h >= 2 then modal_h - 2 else 0 in
        let body_w = inner_w in
        let body_h = max 0 (inner_h - 2) in
        if body_w <= 0 || body_h <= 0 then 0
        else
          let insp_h0 = if body_w >= 72 then body_h else max 0 (body_h - 1) in
          (* Pane Focus Header Bar (overlays.ml:1547) *)
          let insp_h1 = if insp_h0 >= 4 then insp_h0 - 1 else insp_h0 in
          (* Optional New Keeper Name banner (overlays.ml:1585) *)
          let insp_h =
            match m.config.target with
            | Wire_config.Target_keeper_create when insp_h1 >= 5 -> insp_h1 - 1
            | Wire_config.Target_keeper_create
            | Wire_config.Target_runtime
            | Wire_config.Target_keeper _ ->
                insp_h1
          in
          let has_save_banner =
            match m.config.save_state with
            | Config_store.Save_in_flight
            | Config_store.Save_succeeded _
            | Config_store.Save_failed _ ->
                true
            | Config_store.Save_idle -> Option.is_some m.config.last_snapshot_id
          in
          let work_h =
            if has_save_banner && insp_h >= 6 then insp_h - 1 else insp_h
          in
          if work_h < 10 then 0
          else
            let desired_dry = min (work_h / 2) (max 5 (n_rows + 3)) in
            let top_h = max 5 (work_h - desired_dry) in
            let dry_h = max 0 (work_h - top_h) in
            let warn_n = List.length resp.validation_warnings in
            let diff_h = max 0 (dry_h - 2 - warn_n) in
            if diff_h <= 0 then 0 else max 0 (n_rows - diff_h)

let keeper_config_dry_run_max_scroll (m : Model.t) =
  let name_opt, embedded =
    match Model.active_dive m with
    | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_config }) ->
        (Some name, false)
    | Some
        ( Nav.Dive_keeper
            {
              tab =
                ( Nav.Keeper_chat
                | Nav.Keeper_memory
                | Nav.Keeper_work_candle
                | Nav.Keeper_sandbox );
              _;
            }
        | Nav.Dive_work _
        | Nav.Dive_knowledge _
        | Nav.Dive_infra _ )
    | None ->
        let zoomed = m.nav.zoomed && Model.can_zoom_current_view m in
        ( Option.map
            (fun (k : Wire_fleet.keeper_summary) -> k.name)
            (Fleet_store.selected_keeper_summary m.fleet)
        , not zoomed )
  in
  match name_opt, m.config.dry_run_preview with
  | Some name, Config_store.Dry_run_ready resp
    when Config_store.equal_config_target m.config.target
           (Wire_config.Target_keeper name)
         && (String.equal resp.target ("keeper:" ^ name)
             || String.equal resp.target name)
         && (resp.diff_hunks <> []
             || not (String.equal (String.trim resp.unified_diff) "")) ->
      let _, content_h =
        Chat_transcript.keeper_content_rect_size ~embedded ~model:m
      in
      let rest_h = max 0 (content_h - 1) in
      let diff_h = if rest_h >= 10 then min 7 (rest_h / 3) else 0 in
      if diff_h < 2 then 0
      else
        let body_h = max 1 (diff_h - 1) in
        let n_rows = patch_response_diff_row_count resp in
        max 0 (n_rows - body_h)
  | ( Some _
    , ( Config_store.Dry_run_ready _
      | Config_store.Dry_run_idle
      | Config_store.Dry_run_loading
      | Config_store.Dry_run_failed _ ) )
  | ( None
    , ( Config_store.Dry_run_ready _
      | Config_store.Dry_run_idle
      | Config_store.Dry_run_loading
      | Config_store.Dry_run_failed _ ) ) ->
      0

let dispatch_settings_overlay_key ~now (m : Model.t)
    (norm : Keymap.Input.key_event) =
  let norm = Keymap.replay_ime_event norm in
  let has_tree = Config_store.is_two_pane_width ~cols:m.viewport.cols in
  match norm.key with
  | Keymap.Input.Tab ->
      if has_tree then
        Some ({ m with config = Config_store.toggle_pane m.config }, [])
      else Some (m, [])
  | Keymap.Input.Left ->
      Some (Update_actions.step_settings_pane_lr ~now m Keymap.Left)
  | Keymap.Input.Right ->
      Some (Update_actions.step_settings_pane_lr ~now m Keymap.Right)
  | Keymap.Input.Char "h" when is_printable_key norm ->
      Some (Update_actions.step_settings_pane_lr ~now m Keymap.Left)
  | Keymap.Input.Char "l" when is_printable_key norm ->
      Some (Update_actions.step_settings_pane_lr ~now m Keymap.Right)
  | Keymap.Input.Char "J" when is_printable_key norm ->
      let max_scroll = settings_dry_run_max_scroll m in
      Some
        ( {
            m with
            config =
              Config_store.move_dry_run_scroll ~max_scroll ~delta:1 m.config;
          }
        , [] )
  | Keymap.Input.Char "K" when is_printable_key norm ->
      let max_scroll = settings_dry_run_max_scroll m in
      Some
        ( {
            m with
            config =
              Config_store.move_dry_run_scroll ~max_scroll ~delta:(-1) m.config;
          }
        , [] )
  | Keymap.Input.Char "j" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m (Keymap.Move Keymap.Down))
  | Keymap.Input.Char "k" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m (Keymap.Move Keymap.Up))
  | Keymap.Input.Char "g" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m (Keymap.Move Keymap.Home))
  | Keymap.Input.Char "G" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m (Keymap.Move Keymap.End))
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

let incidents_detail_max_scroll (m : Model.t) =
  match Incidents.selected_entry m.incidents with
  | None -> 0
  | Some inc ->
      let overlay_w = max 0 m.viewport.cols in
      let overlay_h = max 0 (m.viewport.rows - 2) in
      let drawer_w =
        if overlay_w >= 110 then min 94 (overlay_w * 2 / 3)
        else max 0 (overlay_w - 2)
      in
      let drawer_h = max 0 (overlay_h - 2) in
      let inner_w = if drawer_w >= 2 && drawer_h >= 2 then drawer_w - 2 else 0 in
      let inner_h = if drawer_w >= 2 && drawer_h >= 2 then drawer_h - 2 else 0 in
      let content_r =
        Rect.make ~x:0 ~y:0 ~w:inner_w ~h:(max 0 (inner_h - 1))
      in
      if content_r.h < 10 then 0
      else
        let detail_r =
          match
            Masc_tui_ui.Layout.split_v ~gap:1 content_r
              [ Masc_tui_ui.Layout.Ratio 0.45; Masc_tui_ui.Layout.Flex 1 ]
          with
          | [ _; d ] -> d
          | _ -> Rect.empty
        in
        let pad_x = if inner_w >= 56 then 2 else 1 in
        let d_pad = Masc_tui_ui.Card.pad_inner ~pad_x detail_r in
        let payload_w = max 0 d_pad.w in
        let payload_h = max 0 (d_pad.h - 1) in
        if payload_w <= 0 || payload_h <= 0 then 0
        else
          match extract_embedded_json_opt inc.detail with
          | Some (prefix, json) ->
              let tree_h =
                if (not (String.equal prefix "")) && payload_h >= 2 then
                  payload_h - 1
                else payload_h
              in
              let lines =
                Masc_tui_ui.Json_tree.flatten ~max_depth:4 ~redact_secrets:true
                  json
              in
              max 0 (List.length lines - tree_h)
          | None ->
              let theme = Theme.of_preset m.theme_preset in
              let lines =
                Masc_tui_ui.Markdown.render_lines ~theme ~width:payload_w
                  inc.detail
              in
              max 0 (List.length lines - payload_h)

let dispatch_incidents_overlay_key ~now (m : Model.t)
    (norm : Keymap.Input.key_event) =
  let norm = Keymap.replay_ime_event norm in
  match norm.key with
  | Keymap.Input.Char "J" when is_printable_key norm ->
      let max_scroll = incidents_detail_max_scroll m in
      Some
        ( {
            m with
            incidents =
              Incidents.move_detail_scroll ~max_scroll ~delta:1 m.incidents;
          }
        , [] )
  | Keymap.Input.Char "K" when is_printable_key norm ->
      let max_scroll = incidents_detail_max_scroll m in
      Some
        ( {
            m with
            incidents =
              Incidents.move_detail_scroll ~max_scroll ~delta:(-1) m.incidents;
          }
        , [] )
  | Keymap.Input.Char "j" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m (Keymap.Move Keymap.Down))
  | Keymap.Input.Char "k" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m (Keymap.Move Keymap.Up))
  | Keymap.Input.Char "g" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m (Keymap.Move Keymap.Home))
  | Keymap.Input.Char "G" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m (Keymap.Move Keymap.End))
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

let dispatch_queue_context_overlay_key ~now (m : Model.t)
    (norm : Keymap.Input.key_event) =
  let norm = Keymap.replay_ime_event norm in
  match norm.key with
  | Keymap.Input.Char "j" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m (Keymap.Move Keymap.Down))
  | Keymap.Input.Char "k" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m (Keymap.Move Keymap.Up))
  | Keymap.Input.Char "g" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m (Keymap.Move Keymap.Home))
  | Keymap.Input.Char "G" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m (Keymap.Move Keymap.End))
  | Keymap.Input.Char "[" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m (Keymap.Sub_tab Keymap.Prev))
  | Keymap.Input.Char "]" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m (Keymap.Sub_tab Keymap.Next))
  | Keymap.Input.Tab when (not norm.mods.ctrl) && not norm.mods.alt ->
      let dir = if norm.mods.shift then Keymap.Prev else Keymap.Next in
      Some (Update_actions.execute_action ~now m (Keymap.Sub_tab dir))
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

let dispatch_help_overlay_key ~now (m : Model.t)
    (norm : Keymap.Input.key_event) =
  let norm = Keymap.replay_ime_event norm in
  match norm.key with
  | Keymap.Input.Char "?" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m Keymap.Open_help)
  | Keymap.Input.Char "j" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m (Keymap.Move Keymap.Down))
  | Keymap.Input.Char "k" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m (Keymap.Move Keymap.Up))
  | Keymap.Input.Char "g" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m (Keymap.Move Keymap.Home))
  | Keymap.Input.Char "G" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m (Keymap.Move Keymap.End))
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
  let norm = Keymap.replay_ime_event norm in
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
      match Chat_transcript.live_chat_phase ~model:m ~keeper with
      | Chat_transcript.Phase_interrupting ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make
                 ~ko:("이미 중단 요청을 전송했습니다: " ^ keeper)
                 ~en:("Interrupt already requested for " ^ keeper))
              m
          , [] )
      | Chat_transcript.Phase_idle
      | Chat_transcript.Phase_queued _
      | Chat_transcript.Phase_confirming
      | Chat_transcript.Phase_failed _ ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make
                 ~ko:("진행 중인 턴이 없습니다: " ^ keeper)
                 ~en:("No active turn running for " ^ keeper))
              m
          , [] )
      | Chat_transcript.Phase_sending
      | Chat_transcript.Phase_awaiting_turn
      | Chat_transcript.Phase_thinking
      | Chat_transcript.Phase_tool_running _
      | Chat_transcript.Phase_streaming ->
          let active_stream_opt =
            match Fleet_store.String_map.find_opt keeper m.fleet.chat_streams with
            | Some s when s.active && not s.interrupting -> Some s
            | Some _ | None -> None
          in
          let interruptible_tx_opt =
            match Drafts.active_tx_for_keeper ~keeper m.drafts with
            | Some
                ({ state = Drafts.Sending | Drafts.Pending_processing; _ } as tx) ->
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
                  Fleet_store.mark_chat_stream_interrupting ~keeper
                    ~request_id:s.request_id ~interrupting:true m.fleet
              | None -> m.fleet
            in
            let drafts =
              match tx_opt with
              | Some (tx : Drafts.pending_message) ->
                  Drafts.mark_interrupting ~now ~request_id:tx.request_id
                    m.drafts
              | None -> m.drafts
            in
            (fleet, drafts)
          in
          match
            Fleet_store.active_turn_for ~keeper m.fleet
          , active_stream_opt
          , interruptible_tx_opt
          with
          | Some turn, stream_opt, tx_opt ->
              let fleet, drafts = mark_ui_interrupting stream_opt tx_opt in
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
                        Cmd.Post_keeper_turn_interrupt
                          { keeper; target = `Turn_token turn.interrupt_token };
                    };
                ] )
          | None, Some s, tx_opt ->
              let op_id = Option.value s.operation_id ~default:s.request_id in
              let fleet, drafts = mark_ui_interrupting (Some s) tx_opt in
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
                        Cmd.Post_keeper_turn_interrupt
                          { keeper; target = `Operation_id op_id };
                    };
                ] )
          | None, None, Some tx ->
              let op_id = Option.value tx.operation_id ~default:tx.request_id in
              let fleet, drafts = mark_ui_interrupting None (Some tx) in
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
                        Cmd.Post_keeper_turn_interrupt
                          { keeper; target = `Operation_id op_id };
                    };
                ] )
          | None, None, None ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:("진행 중인 턴이 없습니다: " ^ keeper)
                     ~en:("No active turn running for " ^ keeper))
                  m
              , [] ))

let dismiss_keeper_chat_errors ~now ~keeper (m : Model.t) =
  let drafts, removed = Drafts.dismiss_failed_for_keeper ~keeper m.drafts in
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
           ~ko:(Printf.sprintf "실패 알림 %d건 닫힘" count)
           ~en:(Printf.sprintf "Dismissed %d failed notice(s)" count))
        { m with drafts; fleet }
    , [] )
  else (m, [])

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

let open_wiki_edit_modal ~now (m : Model.t) ~(slug : string) =
  match Observed.to_option m.knowledge.wiki_page with
  | Some d when String.equal d.slug slug ->
      open_custom_inline_modal m
        [
          {
            key = "wiki_slug";
            label = Say.make ~ko:"위키 슬러그" ~en:"Wiki slug";
            value = slug;
            required = true;
            secret = false;
          };
          {
            key = "wiki_title";
            label = Say.make ~ko:"제목" ~en:"Title";
            value = d.frontmatter.title;
            required = true;
            secret = false;
          };
          {
            key = "wiki_summary";
            label = Say.make ~ko:"요약" ~en:"Summary";
            value = d.frontmatter.summary;
            required = false;
            secret = false;
          };
          {
            key = "wiki_body";
            label = Say.make ~ko:"본문 (Markdown)" ~en:"Body (Markdown)";
            value = d.body_markdown;
            required = true;
            secret = false;
          };
          {
            key = "wiki_note";
            label = Say.make ~ko:"변경 메모" ~en:"Edit note";
            value = "";
            required = false;
            secret = false;
          };
        ]
  | Some _ | None ->
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make
             ~ko:("위키 본문을 불러오는 중입니다 (" ^ slug ^ ") — 잠시 후 [e]를 다시 누르세요")
             ~en:("Loading wiki page body (" ^ slug ^ ") — press [e] again once loaded"))
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
  let preset_default = Option.value draft.preset ~default:"" in
  open_custom_inline_modal m
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
        label = Say.make ~ko:"프리셋 (선택)" ~en:"Preset (optional)";
        value = preset_default;
        required = false;
        secret = false;
      };
    ]

let open_runtime_assign_modal (m : Model.t) ?(keeper_default = "")
    ?(runtime_default = "") () =
  open_custom_inline_modal m
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
  open_custom_inline_modal m
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
  open_custom_inline_modal m
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
                      | Wire_fleet.Role_peer _
                      | Wire_fleet.Role_system
                      | Wire_fleet.Role_tool
                      | Wire_fleet.Role_request_failure ->
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
  let norm = Keymap.replay_ime_event norm in
  let is_ctrl_e =
    norm.mods.ctrl && (not norm.mods.alt)
    && Option.equal String.equal (key_char_opt norm.key) (Some "e")
  in
  let printable_char =
    if is_printable_key norm then key_char_opt norm.key else None
  in
  (* 0. Active Memory Diagram & Memory Explorer diagram triggers (., v) *)
  match printable_char with
  | Some "v" when Option.is_some (Memory_diagram.active_diagram m) ->
      Update_nav.cycle_memory_diagram_mode ~now m
  | Some "."
    when Option.is_some (Memory_diagram.active_memory_content_rect m)
         || (Option.is_none m.nav.overlay
            && Option.is_none (Model.active_dive m)
            && Nav.equal_workspace m.nav.workspace Nav.Knowledge
            && Nav.equal_knowledge_tab m.knowledge.active_tab
                 Nav.Knowledge_memory) ->
      Update_nav.open_memory_diagram ~now
        ~kind:Knowledge_store.Diagram_pele_card m
  | _ -> (
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
        | Some "e" -> open_wiki_edit_modal ~now m ~slug
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
      | Nav.Keeper_memory, Some "e" ->
          let knowledge =
            Knowledge_store.set_memory_view_mode Knowledge_store.View_evolution
              m.knowledge
          in
          let next = { m with nav = { m.nav with dive_scroll_offset = 0 }; knowledge } in
          (next, View_fetches.fetches_for_current_view next)
      | Nav.Keeper_memory, Some "f" ->
          let knowledge =
            Knowledge_store.set_memory_view_mode Knowledge_store.View_facts
              m.knowledge
          in
          let next = { m with nav = { m.nav with dive_scroll_offset = 0 }; knowledge } in
          (next, View_fetches.fetches_for_current_view next)
      | Nav.Keeper_memory, Some "d" ->
          let knowledge =
            Knowledge_store.set_memory_view_mode Knowledge_store.View_diff
              m.knowledge
          in
          let next = { m with nav = { m.nav with dive_scroll_offset = 0 }; knowledge } in
          (next, View_fetches.fetches_for_current_view next)
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
      | Nav.Keeper_config, Some "a" ->
          let runtime_default =
            match Observed.to_option m.runtime.runtime_config_raw with
            | Some meta -> Option.value (List.assoc_opt name meta.assignments) ~default:""
            | None -> ""
          in
          open_runtime_assign_modal m ~keeper_default:name ~runtime_default ()
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
          let rest =
            match m.nav.dive_stack with _ :: tl -> tl | [] -> []
          in
          let nav =
            {
              m.nav with
              dive_stack =
                Nav.Dive_keeper { name; tab = Nav.Keeper_chat } :: rest;
              pane_index = 0;
              dive_scroll_offset = 0;
            }
          in
          let fleet =
            m.fleet
            |> Fleet_store.set_keeper_dive_tab Nav.Keeper_chat
            |> Fleet_store.mark_chat_history_loading ~keeper:name
          in
          let config = Config_store.cancel_edit_field m.config in
          let knowledge =
            m.knowledge
            |> Knowledge_store.close_memory_reading
            |> Knowledge_store.close_memory_diagram
          in
          let drafts =
            m.drafts |> Drafts.set_active_keeper name |> Drafts.set_focus true
          in
          let next = { m with nav; fleet; config; knowledge; drafts } in
          (next, View_fetches.fetches_for_current_view next)
      | Nav.Keeper_config, Some "e" ->
          let config =
            m.config
            |> Config_store.set_target (Wire_config.Target_keeper name)
            |> Config_store.set_tab Nav.Settings_keepers_companies
          in
          Update_nav.open_overlay { m with config }
            (Nav.Settings Nav.Settings_keepers_companies)
      | Nav.Keeper_chat, Some "X" ->
          dismiss_keeper_chat_errors ~now ~keeper:name m
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
          | Some "a" ->
              let keeper_default =
                Option.value (Update_nav.resolve_target_keeper m) ~default:""
              in
              let runtime_default =
                match Runtime_store.selected_lane m.runtime with
                | Some lane -> lane.id
                | None -> (
                    match Observed.to_option m.runtime.runtime_resolved with
                    | Some snap -> Option.value snap.default_route ~default:""
                    | None -> "")
              in
              open_runtime_assign_modal m ~keeper_default ~runtime_default ()
          | Some "K" ->
              let integration_default =
                match Observed.to_option m.runtime.setup_inventory with
                | Some { integrations = first :: _; _ } -> first.id
                | Some { integrations = []; _ } | None -> ""
              in
              open_setup_account_key_modal m ~integration_default ()
          | Some "l" -> open_setup_login_modal m ()
          | Some "L" -> (
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
                            Cmd.Get_setup_login_status { login_id = r.login_id };
                        };
                    ] )
              | None -> open_setup_login_modal m ())
          | Some "f"
            when Nav.equal_runtime_tab m.runtime.active_tab
                   Nav.Runtime_failover_lanes ->
              open_fusion_launch_modal m
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
          let split_keeper_opt =
            if
              m.nav.pane_index = 1
              || (m.nav.zoomed && Model.can_zoom_current_view m)
            then
              Option.map
                (fun (k : Wire_fleet.keeper_summary) -> k.name)
                (Fleet_store.selected_keeper_summary m.fleet)
            else None
          in
          match split_keeper_opt, m.fleet.keeper_dive_tab, printable_char with
          | Some name, Nav.Keeper_sandbox, Some "p" ->
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:("샌드박스 프로브 실행: " ^ name)
                     ~en:("Probing sandbox: " ^ name))
                  m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req = Cmd.Post_sandbox_probe (`Keeper name);
                    };
                ] )
          | Some _, Nav.Keeper_memory, Some "e" ->
              let knowledge =
                Knowledge_store.set_memory_view_mode
                  Knowledge_store.View_evolution m.knowledge
              in
              let next =
                { m with nav = { m.nav with dive_scroll_offset = 0 }; knowledge }
              in
              (next, View_fetches.fetches_for_current_view next)
          | Some _, Nav.Keeper_memory, Some "f" ->
              let knowledge =
                Knowledge_store.set_memory_view_mode Knowledge_store.View_facts
                  m.knowledge
              in
              let next =
                { m with nav = { m.nav with dive_scroll_offset = 0 }; knowledge }
              in
              (next, View_fetches.fetches_for_current_view next)
          | Some _, Nav.Keeper_memory, Some "d" ->
              let knowledge =
                Knowledge_store.set_memory_view_mode Knowledge_store.View_diff
                  m.knowledge
              in
              let next =
                { m with nav = { m.nav with dive_scroll_offset = 0 }; knowledge }
              in
              (next, View_fetches.fetches_for_current_view next)
          | Some name, Nav.Keeper_memory, Some "a" ->
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
          | Some name, Nav.Keeper_memory, Some "A" ->
              open_memory_act_modal m ~keeper_default:name
          | _, _, Some "c" -> (
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
          | _, Nav.Keeper_chat, Some "X" -> (
              match Fleet_store.selected_keeper_summary m.fleet with
              | Some k -> dismiss_keeper_chat_errors ~now ~keeper:k.name m
              | None -> (m, []))
          | _, _, Some "S" -> (
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
          | ( (Some _ | None)
            , ( Nav.Keeper_chat
              | Nav.Keeper_memory
              | Nav.Keeper_work_candle
              | Nav.Keeper_sandbox
              | Nav.Keeper_config )
            , (Some _ | None) ) ->
              (m, []))
      | Nav.Knowledge -> (
          match m.knowledge.active_tab with
          | Nav.Knowledge_memory -> (
              match printable_char with
              | Some "e" ->
                  let knowledge =
                    Knowledge_store.set_memory_view_mode
                      Knowledge_store.View_evolution m.knowledge
                  in
                  let next = { m with knowledge } in
                  (next, View_fetches.fetches_for_current_view next)
              | Some "f" ->
                  let knowledge =
                    Knowledge_store.set_memory_view_mode
                      Knowledge_store.View_facts m.knowledge
                  in
                  let next = { m with knowledge } in
                  (next, View_fetches.fetches_for_current_view next)
              | Some "d" ->
                  let knowledge =
                    Knowledge_store.set_memory_view_mode
                      Knowledge_store.View_diff m.knowledge
                  in
                  let next = { m with knowledge } in
                  (next, View_fetches.fetches_for_current_view next)
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
                        | Some "e" -> open_wiki_edit_modal ~now m ~slug:p.slug
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
              let active_target =
                match m.nav.pane_index with
                | 1 when Model.work_pipeline_has_linked_card m -> (
                    match Work_store.selected_verification m.work with
                    | Some v -> `Verification v
                    | None -> `None)
                | _ -> (
                    match Work_store.selected_goal m.work with
                    | Some g -> `Goal g
                    | None -> `None)
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
      | Nav.Pulse -> (m, [])))

let keeper_config_target_name (m : Model.t) =
  match Model.active_dive m with
  | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_config }) -> Some name
  | Some
      ( Nav.Dive_keeper
          {
            tab =
              ( Nav.Keeper_chat
              | Nav.Keeper_memory
              | Nav.Keeper_work_candle
              | Nav.Keeper_sandbox );
            _;
          }
      | Nav.Dive_work _
      | Nav.Dive_knowledge _
      | Nav.Dive_infra _ ) ->
      None
  | None ->
      if Model.is_keeper_config_active m then
        Option.map
          (fun (k : Wire_fleet.keeper_summary) -> k.name)
          (Fleet_store.selected_keeper_summary m.fleet)
      else None

let dispatch_keeper_config_key ~now (m : Model.t)
    (norm : Keymap.Input.key_event) =
  if Config_store.is_editing_field m.config then
    match norm.key with
    | Keymap.Input.Backspace ->
        Some
          ({ m with config = Config_store.backspace_edit_buffer m.config }, [])
    | Keymap.Input.Char s when is_printable_key norm ->
        Some
          ({ m with config = Config_store.append_edit_char s m.config }, [])
    | Keymap.Input.Enter -> (
        match Config_store.commit_edit_field m.config with
        | Ok config ->
            Some
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:"변경값이 스테이징됨 (Ctrl+S: 저장 · Space: 미리보기)"
                     ~en:"Staged field change (Ctrl+S: save · Space: dry-run)")
                  { m with config }
              , [] )
        | Error reason ->
            Some
              ( Model.with_toast ~now ~level:Model.Toast_warning
                  (Say.literal reason) m
              , [] ))
    | Keymap.Input.Escape ->
        Some ({ m with config = Config_store.cancel_edit_field m.config }, [])
    | Keymap.Input.Tab
    | Keymap.Input.Left
    | Keymap.Input.Right
    | Keymap.Input.Up
    | Keymap.Input.Down
    | Keymap.Input.Home
    | Keymap.Input.End
    | Keymap.Input.Page_up
    | Keymap.Input.Page_down ->
        Some (m, [])
    | Keymap.Input.Char _
    | Keymap.Input.Delete
    | Keymap.Input.Insert
    | Keymap.Input.Function _ -> (
        match Keymap.dispatch ~scope_chain:[ Keymap.Global ] norm with
        | Some act when Keymap.equal_action act Keymap.Quit_app ->
            Some (Update_actions.execute_action ~now m Keymap.Quit_app)
        | Some _ | None -> Some (m, []))
  else
    let norm = Keymap.replay_ime_event norm in
    let step_lr delta =
      match Config_store.step_keeper_field ~lang:m.lang ~delta m.config with
      | Ok (config, true) -> Some ({ m with config }, [])
      | Ok (_, false) ->
          Some
            ( Model.with_toast ~now ~level:Model.Toast_info
                (Say.make ~ko:"[Enter] 키로 텍스트 값을 편집하세요"
                   ~en:"Press [Enter] to edit text value")
                m
            , [] )
      | Error reason ->
          Some
            ( Model.with_toast ~now ~level:Model.Toast_info (Say.literal reason)
                m
            , [] )
    in
    match norm.key with
    | Keymap.Input.Up -> Some (Update_nav.apply_move m Keymap.Up)
    | Keymap.Input.Down -> Some (Update_nav.apply_move m Keymap.Down)
    | Keymap.Input.Page_up -> Some (Update_nav.apply_move m Keymap.Page_up)
    | Keymap.Input.Page_down -> Some (Update_nav.apply_move m Keymap.Page_down)
    | Keymap.Input.Home -> Some (Update_nav.apply_move m Keymap.Home)
    | Keymap.Input.End -> Some (Update_nav.apply_move m Keymap.End)
    | Keymap.Input.Char "k" when is_printable_key norm ->
        Some (Update_nav.apply_move m Keymap.Up)
    | Keymap.Input.Char "j" when is_printable_key norm ->
        Some (Update_nav.apply_move m Keymap.Down)
    | Keymap.Input.Char "J" when is_printable_key norm ->
        let max_scroll = keeper_config_dry_run_max_scroll m in
        Some
          ( {
              m with
              config =
                Config_store.move_dry_run_scroll ~max_scroll ~delta:1 m.config;
            }
          , [] )
    | Keymap.Input.Char "K" when is_printable_key norm ->
        let max_scroll = keeper_config_dry_run_max_scroll m in
        Some
          ( {
              m with
              config =
                Config_store.move_dry_run_scroll ~max_scroll ~delta:(-1)
                  m.config;
            }
          , [] )
    | Keymap.Input.Char "g" when is_printable_key norm ->
        Some (Update_nav.apply_move m Keymap.Home)
    | Keymap.Input.Char "G" when is_printable_key norm ->
        Some (Update_nav.apply_move m Keymap.End)
    | Keymap.Input.Left -> step_lr (-1)
    | Keymap.Input.Right -> step_lr 1
    | Keymap.Input.Char "h" when is_printable_key norm -> step_lr (-1)
    | Keymap.Input.Char "l" when is_printable_key norm -> step_lr 1
    | Keymap.Input.Enter -> (
        match Config_store.begin_edit_keeper_selected ~lang:m.lang m.config with
        | Ok config -> Some ({ m with config }, [])
        | Error reason ->
            Some
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.literal reason) m
              , [] ))
    | Keymap.Input.Char " " when is_printable_key norm -> (
        match Config_store.keeper_selected_field ~lang:m.lang m.config with
        | Some f when f.writable && f.kind = Wire_config.Field_bool ->
            step_lr 1
        | _ ->
            if Config_store.dirty_count m.config > 0 then
              match Config_store.build_patch_request ~dry_run:true m.config with
              | Ok req ->
                  let config = Config_store.mark_dry_run_loading m.config in
                  Some
                    ( { m with config }
                    , [
                        Cmd.Http_post
                          { epoch = m.epoch; req = Cmd.Post_config_patch req };
                      ] )
              | Error reason ->
                  Some
                    ( Model.with_toast ~now ~level:Model.Toast_info
                        (Say.literal reason) m
                    , [] )
            else
              Some
                ( Model.with_toast ~now ~level:Model.Toast_info
                    (Say.make
                       ~ko:"변경된 필드가 없습니다 ([←→] 값 변경 · [Enter] 편집)"
                       ~en:"No staged changes ([←→] cycle · [Enter] edit)")
                    m
                , [] ))
    | Keymap.Input.Char "s" when norm.mods.ctrl && not norm.mods.alt ->
        Some (save_settings_config ~now m)
    | Keymap.Input.Delete -> (
        match
          Config_store.stage_remove_keeper_selected ~lang:m.lang m.config
        with
        | Ok config ->
            Some
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:"키 삭제 스테이징 토글됨 (Space: 미리보기 · Ctrl+S: 저장)"
                     ~en:"Toggled key removal (Space: dry-run · Ctrl+S: save)")
                  { m with config }
              , [] )
        | Error reason ->
            Some
              ( Model.with_toast ~now ~level:Model.Toast_warning
                  (Say.literal reason) m
              , [] ))
    | Keymap.Input.Char "d" when norm.mods.ctrl && not norm.mods.alt -> (
        match
          Config_store.stage_remove_keeper_selected ~lang:m.lang m.config
        with
        | Ok config ->
            Some
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:"키 삭제 스테이징 토글됨 (Space: 미리보기 · Ctrl+S: 저장)"
                     ~en:"Toggled key removal (Space: dry-run · Ctrl+S: save)")
                  { m with config }
              , [] )
        | Error reason ->
            Some
              ( Model.with_toast ~now ~level:Model.Toast_warning
                  (Say.literal reason) m
              , [] ))
    | Keymap.Input.Char "e" when is_printable_key norm -> (
        match keeper_config_target_name m with
        | Some name ->
            let config =
              m.config
              |> Config_store.set_target (Wire_config.Target_keeper name)
              |> Config_store.set_tab Nav.Settings_keepers_companies
            in
            Some
              (Update_nav.open_overlay { m with config }
                 (Nav.Settings Nav.Settings_keepers_companies))
        | None -> None)
    | Keymap.Input.Char "a" when is_printable_key norm -> (
        match keeper_config_target_name m with
        | Some name ->
            let runtime_default =
              match Observed.to_option m.runtime.runtime_config_raw with
              | Some meta ->
                  Option.value (List.assoc_opt name meta.assignments)
                    ~default:""
              | None -> ""
            in
            Some (open_runtime_assign_modal m ~keeper_default:name ~runtime_default ())
        | None -> None)
    | Keymap.Input.Char _
    | Keymap.Input.Tab
    | Keymap.Input.Backspace
    | Keymap.Input.Escape
    | Keymap.Input.Insert
    | Keymap.Input.Function _ ->
        None

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
        (Nav.System_gate (Nav.Auth_gate | Nav.Server_offline as gate)) -> (
        (* Auth_gate & Server_offline strictly block all Global chords except
           Quit_app and gate-local retry/autostart actions. *)
        match Keymap.dispatch ~scope_chain:[ Keymap.Global ] norm with
        | Some act when Keymap.equal_action act Keymap.Quit_app ->
            Update_actions.execute_action ~now m Keymap.Quit_app
        | Some _ | None -> (
            match dispatch_system_gate_key ~now m gate norm with
            | Some res -> res
            | None -> (m, [])))
    | Some
        ( Nav.System_gate Nav.Media_viewer
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
          | Keymap.Input.Escape ->
              let cleared = Update_nav.set_active_filter_query "" m in
              ( { cleared with nav = { cleared.nav with filter_focused = false } }
              , [] )
          | Keymap.Input.Enter | Keymap.Input.Tab ->
              ({ m with nav = { m.nav with filter_focused = false } }, [])
          | Keymap.Input.Up when (not norm.mods.ctrl) && not norm.mods.alt ->
              Update_nav.apply_move m Keymap.Up
          | Keymap.Input.Down when (not norm.mods.ctrl) && not norm.mods.alt ->
              Update_nav.apply_move m Keymap.Down
          | Keymap.Input.Page_up when (not norm.mods.ctrl) && not norm.mods.alt ->
              Update_nav.apply_move m Keymap.Page_up
          | Keymap.Input.Page_down when (not norm.mods.ctrl) && not norm.mods.alt ->
              Update_nav.apply_move m Keymap.Page_down
          | Keymap.Input.Backspace ->
              let q =
                Update_nav.drop_last_utf8 (Update_nav.current_filter_query m)
              in
              (Update_nav.set_active_filter_query q m, [])
          | Keymap.Input.Char s when is_printable_key norm ->
              let q = Update_nav.current_filter_query m ^ s in
              (Update_nav.set_active_filter_query q m, [])
          | Keymap.Input.Char _
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
                        | Nav.Schedule_form
                        | Nav.Connector_form
                        | Nav.Repo_add_form
                        | Nav.Board_new_post )
                      , _ ) ->
                        true
                  in
                  match norm.key with
                  | Keymap.Input.Tab when editable ->
                      let delta = if norm.mods.shift then -1 else 1 in
                      ( {
                          m with
                          inline_modal =
                            Some (Model.modal_cycle_field ~delta modal);
                        }
                      , [] )
                  | Keymap.Input.Backspace when editable ->
                      ( {
                          m with
                          inline_modal =
                            Some
                              (Model.modal_update_active_field
                                 Update_nav.drop_last_utf8 modal);
                        }
                      , [] )
                  | Keymap.Input.Char s when editable && is_printable_key norm ->
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
              | Keymap.Input.Tab when (not norm.mods.ctrl) && not norm.mods.alt ->
                  Update_actions.execute_action ~now m
                    (Keymap.Cycle_focus_pane
                       (if norm.mods.shift then Keymap.Prev else Keymap.Next))
              | Keymap.Input.Left
              | Keymap.Input.Right
              | Keymap.Input.Up
              | Keymap.Input.Down
              | Keymap.Input.Home
              | Keymap.Input.End
              | Keymap.Input.Page_up
              | Keymap.Input.Page_down ->
                  (m, [])
              | Keymap.Input.Char _
              | Keymap.Input.Enter
              | Keymap.Input.Tab
              | Keymap.Input.Escape
              | Keymap.Input.Delete
              | Keymap.Input.Insert
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
          | Some (Nav.Queue_context _) -> (
              match dispatch_queue_context_overlay_key ~now m norm with
              | Some res -> res
              | None -> (
                  match
                    Keymap.dispatch ~scope_chain:(Model.focus_scope_chain m)
                      norm
                  with
                  | Some act -> Update_actions.execute_action ~now m act
                  | None -> (m, [])))
          | Some Nav.Help -> (
              match dispatch_help_overlay_key ~now m norm with
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
          | None -> (
              (* Interactive Composer `/` & `@` popup navigation/completion *)
              let popup_handled =
                if not (Drafts.is_focused m.drafts) then None
                else
                  match Update_nav.resolve_composer_popup m with
                  | Update_nav.Composer_popup_none -> None
                  | Update_nav.Composer_popup_slash { items; selected; _ }
                  | Update_nav.Composer_popup_mention { items; selected; _ } -> (
                      let len = List.length items in
                      if len <= 0 || norm.mods.ctrl || norm.mods.alt then None
                      else
                        match norm.key with
                        | Keymap.Input.Up ->
                            Some
                              ( {
                                  m with
                                  drafts =
                                    Drafts.move_popup ~delta:(-1) ~count:len
                                      ~wrap:true m.drafts;
                                }
                              , [] )
                        | Keymap.Input.Down ->
                            Some
                              ( {
                                  m with
                                  drafts =
                                    Drafts.move_popup ~delta:1 ~count:len
                                      ~wrap:true m.drafts;
                                }
                              , [] )
                        | Keymap.Input.Page_up ->
                            Some
                              ( {
                                  m with
                                  drafts =
                                    Drafts.move_popup ~delta:(-8) ~count:len
                                      ~wrap:false m.drafts;
                                }
                              , [] )
                        | Keymap.Input.Page_down ->
                            Some
                              ( {
                                  m with
                                  drafts =
                                    Drafts.move_popup ~delta:8 ~count:len
                                      ~wrap:false m.drafts;
                                }
                              , [] )
                        | Keymap.Input.Home ->
                            Some
                              ( {
                                  m with
                                  drafts = Drafts.set_popup_selected 0 m.drafts;
                                }
                              , [] )
                        | Keymap.Input.End ->
                            Some
                              ( {
                                  m with
                                  drafts =
                                    Drafts.set_popup_selected (len - 1) m.drafts;
                                }
                              , [] )
                        | Keymap.Input.Tab when norm.mods.shift ->
                            Some
                              ( {
                                  m with
                                  drafts =
                                    Drafts.move_popup ~delta:(-1) ~count:len
                                      ~wrap:true m.drafts;
                                }
                              , [] )
                        | Keymap.Input.Tab -> (
                            match List.nth_opt items selected with
                            | Some cand ->
                                Some (Update_nav.apply_popup_completion cand m, [])
                            | None -> Some (m, []))
                        | Keymap.Input.Char _
                        | Keymap.Input.Enter
                        | Keymap.Input.Backspace
                        | Keymap.Input.Escape
                        | Keymap.Input.Delete
                        | Keymap.Input.Insert
                        | Keymap.Input.Left
                        | Keymap.Input.Right
                        | Keymap.Input.Function _ ->
                            None)
              in
              match popup_handled with
              | Some res -> res
              | None ->
                  let pre_dispatch =
                    if
                      Model.is_keeper_config_active m
                      && not (Drafts.is_focused m.drafts)
                    then dispatch_keeper_config_key ~now m norm
                    else if not (Drafts.is_focused m.drafts) then
                      (* Pillar 3: typing Korean while unfocused inside
                         Dive_keeper { tab = Keeper_chat } auto-focuses the
                         composer and inserts the character instead of letting
                         Korean jamo replay trigger centered modals. *)
                      match Model.active_dive m, norm.key with
                      | ( Some
                            (Nav.Dive_keeper
                               { name; tab = Nav.Keeper_chat })
                        , Keymap.Input.Char s )
                        when is_printable_key norm && is_korean_char s
                             && not (Model.equal_breakpoint m.breakpoint Model.Micro)
                        ->
                          let drafts =
                            m.drafts
                            |> Drafts.set_active_keeper name
                            |> Drafts.set_focus true
                            |> Drafts.insert_text s
                          in
                          Some ({ m with drafts }, [])
                      | ( ( Some
                              ( Nav.Dive_keeper
                                  {
                                    tab =
                                      ( Nav.Keeper_chat
                                      | Nav.Keeper_memory
                                      | Nav.Keeper_work_candle
                                      | Nav.Keeper_sandbox
                                      | Nav.Keeper_config );
                                    _;
                                  }
                              | Nav.Dive_work _
                              | Nav.Dive_knowledge _
                              | Nav.Dive_infra _ )
                          | None )
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
                    else None
                  in
                  match pre_dispatch with
                  | Some res -> res
                  | None ->
                      let is_ctrl_x =
                        norm.mods.ctrl && (not norm.mods.alt)
                        && (not norm.mods.shift)
                        && Option.equal String.equal (key_char_opt norm.key)
                             (Some "x")
                      in
                      if is_ctrl_x then interrupt_active_keeper_turn ~now m
                      else
                        (* 3. Single-SSOT Keymap dispatch *)
                    match
                      Keymap.dispatch ~scope_chain:(Model.focus_scope_chain m)
                        norm
                    with
                    | Some act -> Update_actions.execute_action ~now m act
                    | None ->
                        (* 4. Contextual workspace hotkeys & Composer raw editing keys *)
                        if Drafts.is_focused m.drafts then
                          match norm.key with
                          | Keymap.Input.Char "a"
                            when norm.mods.ctrl && not norm.mods.alt ->
                              ( {
                                  m with
                                  drafts =
                                    Drafts.move_cursor_line `Start m.drafts;
                                }
                              , [] )
                          | Keymap.Input.Char "e"
                            when norm.mods.ctrl && not norm.mods.alt ->
                              ( {
                                  m with
                                  drafts = Drafts.move_cursor_line `End m.drafts;
                                }
                              , [] )
                          | Keymap.Input.Char "u"
                            when norm.mods.ctrl && not norm.mods.alt ->
                              ( {
                                  m with
                                  drafts = Drafts.kill_line_start m.drafts;
                                }
                              , [] )
                          | Keymap.Input.Backspace when norm.mods.alt ->
                              ({ m with drafts = Drafts.kill_word m.drafts }, [])
                          | Keymap.Input.Backspace ->
                              ({ m with drafts = Drafts.backspace m.drafts }, [])
                          | Keymap.Input.Delete ->
                              ( {
                                  m with
                                  drafts = Drafts.delete_forward m.drafts;
                                }
                              , [] )
                          | Keymap.Input.Left
                            when norm.mods.ctrl || norm.mods.alt ->
                              ( {
                                  m with
                                  drafts =
                                    Drafts.move_cursor_word `Left m.drafts;
                                }
                              , [] )
                          | Keymap.Input.Right
                            when norm.mods.ctrl || norm.mods.alt ->
                              ( {
                                  m with
                                  drafts =
                                    Drafts.move_cursor_word `Right m.drafts;
                                }
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
                              ( {
                                  m with
                                  drafts = Drafts.move_cursor `End m.drafts;
                                }
                              , [] )
                          | Keymap.Input.Char s when is_printable_key norm ->
                              ( {
                                  m with
                                  drafts = Drafts.insert_text s m.drafts;
                                }
                              , [] )
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
                        else dispatch_contextual_hotkey ~now m norm))

let apply_paste ~now:_ (m : Model.t) text =
  if
    String.equal text ""
    || Model.is_too_small_viewport m.viewport
    || Model.equal_breakpoint m.breakpoint Model.Micro
  then (m, [])
  else
    match m.nav.overlay with
    | Some
        (Nav.System_gate
           (Nav.Micro_viewport | Nav.Auth_gate | Nav.Server_offline)) ->
        (m, [])
    | Some Nav.Palette ->
        let query = m.palette.query ^ strip_newlines text in
        ({ m with palette = { m.palette with query; selected = 0 } }, [])
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
                  | Nav.Schedule_form
                  | Nav.Connector_form
                  | Nav.Repo_add_form
                  | Nav.Board_new_post )
                , _ ) ->
                  true
            in
            if not editable then (m, [])
            else
              ( {
                  m with
                  inline_modal =
                    Some
                      (Model.modal_update_active_field
                         (fun v -> v ^ text)
                         modal);
                }
              , [] ))
    | Some (Nav.Settings _) when Config_store.is_editing_field m.config ->
        ( {
            m with
            config =
              Config_store.append_edit_char (strip_newlines text) m.config;
          }
        , [] )
    | Some (Nav.Settings _ | Nav.Incidents) when m.nav.filter_focused ->
        let q = Update_nav.current_filter_query m ^ strip_newlines text in
        (Update_nav.set_active_filter_query q m, [])
    | Some
        ( Nav.Settings _
        | Nav.Incidents
        | Nav.Queue_context _
        | Nav.Help
        | Nav.System_gate Nav.Media_viewer ) ->
        (m, [])
    | None ->
        if m.nav.filter_focused then
          let q = Update_nav.current_filter_query m ^ strip_newlines text in
          (Update_nav.set_active_filter_query q m, [])
        else if
          Model.is_keeper_config_active m && Config_store.is_editing_field m.config
        then
          ( {
              m with
              config =
                Config_store.append_edit_char (strip_newlines text) m.config;
            }
          , [] )
        else
          let drafts =
            m.drafts |> Drafts.set_focus true |> Drafts.insert_text text
          in
          ({ m with drafts }, [])

let apply_mouse ~now (m : Model.t) (ev : Keymap.Input.mouse_event) =
  if Model.is_too_small_viewport m.viewport then (m, [])
  else
    let m =
      if Config_store.is_editing_field m.config then
        { m with config = Config_store.cancel_edit_field m.config }
      else m
    in
    match ev with
    | Keymap.Input.Wheel { dir = Keymap.Input.Wheel_up; _ } ->
        Update_actions.execute_action ~now m (Keymap.Move Keymap.Up)
    | Keymap.Input.Wheel { dir = Keymap.Input.Wheel_down; _ } ->
        Update_actions.execute_action ~now m (Keymap.Move Keymap.Down)
    | Keymap.Input.Left_press _
    | Keymap.Input.Left_drag _
    | Keymap.Input.Left_release _ ->
        (m, [])
