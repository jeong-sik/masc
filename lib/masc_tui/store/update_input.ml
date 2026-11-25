open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

let is_printable_key (ev : Keymap.Input.key_event) =
  (not ev.mods.ctrl) && not ev.mods.alt

let strip_newlines s =
  String.map (function '\n' | '\r' -> ' ' | c -> c) s

let open_custom_inline_modal ~(kind : Nav.inline_action_kind) (m : Model.t)
    (fields : Model.modal_form_field list) =
  let modal : Model.inline_modal_state =
    {
      kind;
      fields;
      active_field = 0;
      submitting = false;
      submission_id = 0;
      error = None;
    }
  in
  let modal_edit_cursor = String.length (Model.modal_active_field_value modal) in
  let nav =
    {
      m.nav with
      overlay = Some (Nav.Inline_action kind);
      return_overlay = None;
      filter_focused = false;
      modal_edit_cursor;
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
  let cfg0 =
    if not (Config_store.is_two_pane_width ~cols:m.viewport.cols) then
      Config_store.set_pane Config_store.Pane_inspector m.config
    else m.config
  in
  match cfg0.settings_pane with
  | Config_store.Pane_tree ->
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make ~ko:"[Tab]으로 검사기(오른쪽)로 이동한 뒤 키를 삭제하세요"
             ~en:"Press [Tab] to focus the inspector before removing a key")
          m
      , [] )
  | Config_store.Pane_inspector -> (
      match Config_store.stage_remove_selected cfg0 with
      | Ok config ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make
                 ~ko:"키 삭제 스테이징 토글됨 (d: 미리보기 · Ctrl+S: 저장)"
                 ~en:"Toggled key removal (d: dry-run · Ctrl+S: save)")
              { m with config }
          , [] )
      | Error reason ->
          ( Model.with_toast ~now ~level:Model.Toast_warning (Say.literal reason)
              m
          , [] ))

let settings_edit_allows_global_action (act : Keymap.action) =
  Keymap.equal_action act Keymap.Quit_app
  || Keymap.equal_action act Keymap.Confirm_selected
  || Keymap.equal_action act Keymap.Pop_back_or_close

let settings_is_open (m : Model.t) =
  match m.nav.overlay with
  | Some (Nav.Settings _) -> true
  | Some
      ( Nav.Palette
      | Nav.Incidents
      | Nav.Queue_context _
      | Nav.Inline_action _
      | Nav.Ask_answer
      | Nav.Help
      | Nav.System_gate _ )
  | None -> false

let guard_settings_dirty_leave ~now (m : Model.t) act =
  let next, commands = Update_actions.execute_action ~now m act in
  if settings_is_open m && not (settings_is_open next)
     && not (Keymap.equal_action act Keymap.Pop_back_or_close)
     && Config_store.dirty_count m.config > 0
  then
    let n = Config_store.dirty_count m.config in
    ( Model.with_toast ~now ~level:Model.Toast_warning
        (Say.make
           ~ko:
             (Printf.sprintf
                "저장하지 않은 변경 %d건 — [Ctrl+S]로 저장하거나 [Esc] 두 번으로 버리고 닫은 뒤 다시 시도하세요"
                n)
           ~en:
             (Printf.sprintf
                "%d unsaved change(s) — save with [Ctrl+S], or press [Esc] twice to discard and close, then retry"
                n))
        { m with
          nav = { m.nav with filter_focused = false };
          config = Config_store.disarm_discard_confirm m.config }
    , [] )
  else (next, commands)

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
    | Some
        ( Nav.Dive_work _
        | Nav.Dive_knowledge _
        | Nav.Dive_runtime _
        ) ->
        (None, true)
    | None ->
        let zoomed = m.nav.zoomed && Model.can_zoom_current_view m in
        (Model.selected_keeper_name m, not zoomed)
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
  | Keymap.Input.Char "d" when is_printable_key norm ->
      Some (Update_actions.dry_run_settings_config ~now m)
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
  | Keymap.Input.Char "?" when is_printable_key norm ->
      Some (guard_settings_dirty_leave ~now m Keymap.Open_help)
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

let ask_modal_prompt_max_scroll (m : Model.t) (modal : Model.ask_modal) =
  match Model.ask_modal_current_question modal with
  | None -> 0
  | Some q ->
      let rect_w = Int.max 0 m.viewport.cols in
      let rect_h = Int.max 0 (m.viewport.rows - 2) in
      let max_w = Int.max 0 (rect_w - 2) in
      let max_h = Int.max 0 (rect_h - 2) in
      let desired_w = Int.max 66 (rect_w * 3 / 4) in
      let w = Int.min max_w (Int.min 96 desired_w) in
      let desired_h = Int.max 16 (rect_h - 4) in
      let h = Int.min max_h (Int.min 32 desired_h) in
      let inner_w = if w >= 2 && h >= 2 then w - 2 else 0 in
      let inner_h = if w >= 2 && h >= 2 then h - 2 else 0 in
      if inner_w <= 0 || inner_h <= 0 then 0
      else
        let pad_x = if inner_w >= 48 then 2 else 1 in
        let content_w = Int.max 1 (inner_w - (2 * pad_x)) in
        let live_status = Model.ask_live_status m modal.ask.ask_id in
        let banner_h =
          match live_status with
          | Model.Ask_live_closed | Model.Ask_live_in_flight -> 1
          | Model.Ask_live_open ->
              if modal.submitting || Option.is_some modal.error then 1 else 0
        in
        let chips_h = if modal.ask.questions <> [] then 2 else 0 in
        let rem0 = Int.max 0 (inner_h - banner_h - chips_h) in
        let footer_h = if rem0 >= 5 then 1 else 0 in
        let body_h = Int.max 0 (rem0 - footer_h) in
        let sep_h = if body_h >= 6 then 1 else 0 in
        let avail_h = Int.max 0 (body_h - sep_h) in
        let total_rows = List.length (Model.ask_modal_rows q) in
        let min_rows_h =
          Int.min (Int.max 2 total_rows) (Int.max 2 ((avail_h + 1) / 2))
        in
        let md_h =
          if avail_h <= min_rows_h then 0
          else Int.min (avail_h - min_rows_h) (Int.max 2 (avail_h / 3))
        in
        if md_h <= 0 then 0
        else
          let theme = Theme.of_preset m.theme_preset in
          let prompt_md =
            Model.ask_modal_prompt_markdown ~compact:(md_h <= 4) modal.ask q
          in
          let total_lines =
            List.length
              (Masc_tui_ui.Markdown.render_lines ~theme ~width:content_w
                 prompt_md)
          in
          Int.max 0 (total_lines - md_h)

let dispatch_ask_answer_overlay_key ~now (m : Model.t)
    (norm : Keymap.Input.key_event) =
  match m.ask_modal with
  | None -> (
      match norm.key with
      | Keymap.Input.Escape ->
          Some (Update_actions.execute_action ~now m Keymap.Pop_back_or_close)
      | Keymap.Input.Char _
      | Keymap.Input.Enter
      | Keymap.Input.Tab
      | Keymap.Input.Backspace
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
          None)
  | Some modal when modal.submitting -> (
      match norm.key with
      | Keymap.Input.Escape ->
          Some (Update_actions.execute_action ~now m Keymap.Pop_back_or_close)
      | Keymap.Input.Char _
      | Keymap.Input.Enter
      | Keymap.Input.Tab
      | Keymap.Input.Backspace
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
          | Some act when Keymap.equal_action act Keymap.Quit_app ->
              Some (Update_actions.execute_action ~now m Keymap.Quit_app)
          | Some _ | None -> Some (m, [])))
  | Some modal when modal.editing_free_text -> (
      match norm.key with
      | Keymap.Input.Escape ->
          Some
            ( {
                m with
                ask_modal =
                  Some (Model.ask_modal_set_editing_free_text false modal);
              }
            , [] )
      | Keymap.Input.Enter when norm.mods.ctrl || norm.mods.alt ->
          let modal', _confirmed = Model.ask_modal_confirm_free_text modal in
          Some
            (Update_nav.submit_ask_modal ~now { m with ask_modal = Some modal' })
      | Keymap.Input.Enter ->
          Some (Update_actions.execute_action ~now m Keymap.Confirm_selected)
      | Keymap.Input.Backspace ->
          Some
            ( {
                m with
                ask_modal = Some (Model.ask_modal_backspace_free_text modal);
              }
            , [] )
      | Keymap.Input.Delete ->
          Some
            ( {
                m with
                ask_modal = Some (Model.ask_modal_delete_free_text modal);
              }
            , [] )
      | Keymap.Input.Left ->
          Some
            ( {
                m with
                ask_modal =
                  Some (Model.ask_modal_move_free_text_cursor `Left modal);
              }
            , [] )
      | Keymap.Input.Right ->
          Some
            ( {
                m with
                ask_modal =
                  Some (Model.ask_modal_move_free_text_cursor `Right modal);
              }
            , [] )
      | Keymap.Input.Home ->
          Some
            ( {
                m with
                ask_modal =
                  Some (Model.ask_modal_move_free_text_cursor `Home modal);
              }
            , [] )
      | Keymap.Input.End ->
          Some
            ( {
                m with
                ask_modal =
                  Some (Model.ask_modal_move_free_text_cursor `End modal);
              }
            , [] )
      | Keymap.Input.Char "a" when norm.mods.ctrl && not norm.mods.alt ->
          Some
            ( {
                m with
                ask_modal =
                  Some (Model.ask_modal_move_free_text_cursor `Home modal);
              }
            , [] )
      | Keymap.Input.Char "e" when norm.mods.ctrl && not norm.mods.alt ->
          Some
            ( {
                m with
                ask_modal =
                  Some (Model.ask_modal_move_free_text_cursor `End modal);
              }
            , [] )
      | Keymap.Input.Char "u" when norm.mods.ctrl && not norm.mods.alt ->
          Some
            ( {
                m with
                ask_modal = Some (Model.ask_modal_kill_free_text_start modal);
              }
            , [] )
      | Keymap.Input.Tab when (not norm.mods.ctrl) && not norm.mods.alt ->
          Some
            (Update_actions.execute_action ~now m
               (Keymap.Cycle_focus_pane
                  (if norm.mods.shift then Keymap.Prev else Keymap.Next)))
      | Keymap.Input.Char s when is_printable_key norm ->
          Some
            ( {
                m with
                ask_modal = Some (Model.ask_modal_insert_free_text s modal);
              }
            , [] )
      | Keymap.Input.Up
      | Keymap.Input.Down
      | Keymap.Input.Page_up
      | Keymap.Input.Page_down
      | Keymap.Input.Insert
      | Keymap.Input.Function _ ->
          Some (m, [])
      | Keymap.Input.Char _ | Keymap.Input.Tab -> (
          match Keymap.dispatch ~scope_chain:[ Keymap.Global ] norm with
          | Some act when Keymap.equal_action act Keymap.Quit_app ->
              Some (Update_actions.execute_action ~now m Keymap.Quit_app)
          | Some _ | None -> Some (m, [])))
  | Some modal -> (
      match norm.key with
      | Keymap.Input.Enter when norm.mods.ctrl || norm.mods.alt ->
          Some (Update_nav.submit_ask_modal ~now m)
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
          let norm = Keymap.replay_ime_event norm in
          match norm.key with
          | Keymap.Input.Char "J" when is_printable_key norm ->
              let max_scroll = ask_modal_prompt_max_scroll m modal in
              Some
                ( {
                    m with
                    ask_modal =
                      Some
                        (Model.ask_modal_scroll_prompt ~max_scroll ~delta:1
                           modal);
                  }
                , [] )
          | Keymap.Input.Char "K" when is_printable_key norm ->
              let max_scroll = ask_modal_prompt_max_scroll m modal in
              Some
                ( {
                    m with
                    ask_modal =
                      Some
                        (Model.ask_modal_scroll_prompt ~max_scroll ~delta:(-1)
                           modal);
                  }
                , [] )
          | Keymap.Input.Down when norm.mods.shift && not norm.mods.ctrl && not norm.mods.alt ->
              let max_scroll = ask_modal_prompt_max_scroll m modal in
              Some
                ( {
                    m with
                    ask_modal =
                      Some
                        (Model.ask_modal_scroll_prompt ~max_scroll ~delta:1
                           modal);
                  }
                , [] )
          | Keymap.Input.Up when norm.mods.shift && not norm.mods.ctrl && not norm.mods.alt ->
              let max_scroll = ask_modal_prompt_max_scroll m modal in
              Some
                ( {
                    m with
                    ask_modal =
                      Some
                        (Model.ask_modal_scroll_prompt ~max_scroll ~delta:(-1)
                           modal);
                  }
                , [] )
          | Keymap.Input.Char "j" when is_printable_key norm ->
              Some
                (Update_actions.execute_action ~now m (Keymap.Move Keymap.Down))
          | Keymap.Input.Char "k" when is_printable_key norm ->
              Some
                (Update_actions.execute_action ~now m (Keymap.Move Keymap.Up))
          | Keymap.Input.Char "g" when is_printable_key norm ->
              Some
                (Update_actions.execute_action ~now m (Keymap.Move Keymap.Home))
          | Keymap.Input.Char "G" when is_printable_key norm ->
              Some
                (Update_actions.execute_action ~now m (Keymap.Move Keymap.End))
          | Keymap.Input.Char " " when is_printable_key norm ->
              Some (Update_actions.execute_action ~now m Keymap.Toggle_expand)
          | Keymap.Input.Char "i" when is_printable_key norm -> (
              match Model.ask_modal_current_question modal with
              | Some q when q.allow_free_text ->
                  Some
                    ( {
                        m with
                        ask_modal = Some (Model.ask_modal_enter_free_text modal);
                      }
                    , [] )
              | Some _ | None -> Some (m, []))
          | Keymap.Input.Char "C" when is_printable_key norm ->
              Some
                (Update_nav.jump_to_keeper ~preserve_return:true
                   ~tab:Nav.Keeper_chat m modal.ask.keeper)
          | Keymap.Input.Char "[" when is_printable_key norm ->
              Some
                (Update_actions.execute_action ~now m
                   (Keymap.Sub_tab Keymap.Prev))
          | Keymap.Input.Char "]" when is_printable_key norm ->
              Some
                (Update_actions.execute_action ~now m
                   (Keymap.Sub_tab Keymap.Next))
          | Keymap.Input.Char "?" when is_printable_key norm ->
              Some (Update_actions.execute_action ~now m Keymap.Open_help)
          | Keymap.Input.Char s
            when is_printable_key norm && Int.equal (String.length s) 1 -> (
              match Model.ask_choice_index_of_char s.[0] with
              | Some idx -> (
                  match Model.ask_modal_current_question modal with
                  | Some q when idx >= 0 && idx < List.length q.choices ->
                      Some
                        ( {
                            m with
                            ask_modal =
                              Some
                                (Model.ask_modal_toggle_or_select_choice idx
                                   modal);
                          }
                        , [] )
                  | Some _ | None -> Some (m, []))
              | None -> Some (m, []))
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
              None))

let dispatch_incidents_overlay_key ~now (m : Model.t)
    (norm : Keymap.Input.key_event) =
  let norm = Keymap.replay_ime_event norm in
  match norm.key with
  | Keymap.Input.Char "J" when is_printable_key norm ->
      let max_scroll = Update_nav.incidents_detail_max_scroll m in
      Some
        ( {
            m with
            incidents =
              Incidents.move_detail_scroll ~max_scroll ~delta:1 m.incidents;
          }
        , [] )
  | Keymap.Input.Char "K" when is_printable_key norm ->
      let max_scroll = Update_nav.incidents_detail_max_scroll m in
      Some
        ( {
            m with
            incidents =
              Incidents.move_detail_scroll ~max_scroll ~delta:(-1) m.incidents;
          }
        , [] )
  | Keymap.Input.Char "z" when is_printable_key norm -> (
      match Incidents.selected_entry m.incidents with
      | Some _ ->
          Some ({ m with incidents = Incidents.toggle_zoom m.incidents }, [])
      | None -> Some (m, []))
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
  | Keymap.Input.Char ("c" | "D")
    when is_printable_key norm && not m.incidents.zoomed ->
      if m.incidents.clear_confirm_armed then
        Some
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:"장애 이력을 모두 비웠습니다"
                 ~en:"Cleared all incident history")
              { m with incidents = Incidents.clear_all m.incidents }
          , [] )
      else if Incidents.count m.incidents = 0 then Some (m, [])
      else
        Some
          ( Model.with_toast ~now ~level:Model.Toast_warning
              (Say.make
                 ~ko:"모든 장애 이력을 삭제하려면 [c] 또는 [D]를 한 번 더 누르세요"
                 ~en:"Press [c] or [D] again to clear all incidents")
              { m with incidents = Incidents.arm_clear_confirm m.incidents }
          , [] )
  | Keymap.Input.Char "?" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m Keymap.Open_help)
  | Keymap.Input.Char "o" when is_printable_key norm -> (
      match Incidents.selected_entry m.incidents with
      | None -> Some (m, [])
      | Some inc -> (
          match inc.source with
          | Health.Source_keeper name ->
              Some
                (Update_nav.jump_to_keeper ~preserve_return:true
                   ~tab:Nav.Keeper_chat m name)
          | Health.Source_sandbox name ->
              let infra =
                m.infra
                |> Infra_store.set_tab Nav.Infra_sandboxes
                |> Infra_store.select_sandbox_by_keeper name
              in
              let m' = { m with infra } in
              let zoomed =
                not
                  (Model.detail_visible
                     {
                       m' with
                       nav =
                         {
                           m'.nav with
                           workspace = Nav.Infra;
                           dive_stack = [];
                           overlay = None;
                           zoomed = false;
                         };
                     })
              in
              Some
                (Update_nav.jump_to_workspace ~pane_index:1 ~zoomed
                   ~return_from:m m' Nav.Infra)
          | Health.Source_runtime lane_id ->
              let runtime =
                m.runtime
                |> Runtime_store.set_tab Nav.Runtime_failover_lanes
                |> Runtime_store.select_lane_by_id lane_id
              in
              Some
                (Update_nav.jump_to_workspace ~pane_index:1 ~zoomed:false
                   ~return_from:m { m with runtime } Nav.Runtime)
          | Health.Source_client_http | Health.Source_stream ->
              if m.incidents.zoomed then Some (m, [])
              else
                Some
                  ({ m with incidents = Incidents.set_zoomed true m.incidents }, [])))
  | Keymap.Input.Char "/" when is_printable_key norm && not m.incidents.zoomed ->
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
  | Keymap.Input.Char "n" when is_printable_key norm ->
      (match Update_nav.queue_run_next_target m with
       | None -> None
       | Some { keeper; request_id; interrupt_token; _ } ->
           let queue = Fleet_store.chat_queue_for ~keeper m.fleet in
           let queue = { queue with read = Observed.loading ~since_ns:now } in
           let fleet = Fleet_store.set_chat_queue ~keeper queue m.fleet in
           let next =
             Model.with_toast ~now ~level:Model.Toast_info
               (Say.make ~ko:"대기 메시지 우선 실행 요청 중"
                  ~en:"Requesting priority for the queued message")
               { m with fleet }
           in
           Some (next,
             [ Cmd.Http_post
                 { epoch = m.epoch;
                   req = Cmd.Post_keeper_run_next { keeper; request_id; interrupt_token } } ]))
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
  | Keymap.Input.Char "<" when is_printable_key norm ->
      Some
        (Update_actions.execute_action ~now m
           (Keymap.Step_context_item Keymap.Prev))
  | Keymap.Input.Char ">" when is_printable_key norm ->
      Some
        (Update_actions.execute_action ~now m
           (Keymap.Step_context_item Keymap.Next))
  | Keymap.Input.Char "v" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m Keymap.Cycle_view_mode)
  | Keymap.Input.Char "?" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m Keymap.Open_help)
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
  | Nav.Media_viewer, Keymap.Input.Up
    when (not norm.mods.ctrl) && not norm.mods.alt ->
      Some (Update_nav.apply_move m Keymap.Up)
  | Nav.Media_viewer, Keymap.Input.Down
    when (not norm.mods.ctrl) && not norm.mods.alt ->
      Some (Update_nav.apply_move m Keymap.Down)
  | Nav.Media_viewer, Keymap.Input.Page_up
    when (not norm.mods.ctrl) && not norm.mods.alt ->
      Some (Update_nav.apply_move m Keymap.Page_up)
  | Nav.Media_viewer, Keymap.Input.Page_down
    when (not norm.mods.ctrl) && not norm.mods.alt ->
      Some (Update_nav.apply_move m Keymap.Page_down)
  | Nav.Media_viewer, Keymap.Input.Home
    when (not norm.mods.ctrl) && not norm.mods.alt ->
      Some (Update_nav.apply_move m Keymap.Home)
  | Nav.Media_viewer, Keymap.Input.End
    when (not norm.mods.ctrl) && not norm.mods.alt ->
      Some (Update_nav.apply_move m Keymap.End)
  | Nav.Media_viewer, Keymap.Input.Char "k" when is_printable_key norm ->
      Some (Update_nav.apply_move m Keymap.Up)
  | Nav.Media_viewer, Keymap.Input.Char "j" when is_printable_key norm ->
      Some (Update_nav.apply_move m Keymap.Down)
  | Nav.Media_viewer, Keymap.Input.Char "g" when is_printable_key norm ->
      Some (Update_nav.apply_move m Keymap.Home)
  | Nav.Media_viewer, Keymap.Input.Char "G" when is_printable_key norm ->
      Some (Update_nav.apply_move m Keymap.End)
  | Nav.Media_viewer, Keymap.Input.Char "?" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m Keymap.Open_help)
  | Nav.Media_viewer, Keymap.Input.Char "r" when is_printable_key norm -> (
      match Model.focused_artifact m with
      | Some art ->
          Some
            ( Model.with_toast ~now ~level:Model.Toast_info
                (Say.make ~ko:"아티팩트 본문을 다시 불러오는 중…"
                   ~en:"Refetching artifact body…")
                m
            , [
                Cmd.Http_get
                  {
                    epoch = m.epoch;
                    req =
                      Cmd.Get_artifact_detail
                        { id = art.id; revision = Some art.revision };
                  };
              ] )
      | None ->
          Some
            ( Model.with_toast ~now ~level:Model.Toast_warning
                (Say.make ~ko:"선택된 아티팩트가 없습니다"
                   ~en:"No artifact selected")
                m
            , [] ))
  | Nav.Media_viewer, Keymap.Input.Char "y" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m Keymap.Copy_selected)
  | Nav.Media_viewer, Keymap.Input.Char "H" when is_printable_key norm -> (
      match Model.focused_artifact m with
      | Some art ->
          Some
            ( Model.with_toast ~now ~level:Model.Toast_info
                (Say.make ~ko:"SHA-256 복사됨" ~en:"Copied SHA-256")
                m
            , [ Cmd.Copy_clipboard art.body.sha256 ] )
      | None ->
          Some
            ( Model.with_toast ~now ~level:Model.Toast_warning
                (Say.make ~ko:"선택된 아티팩트가 없습니다"
                   ~en:"No artifact selected")
                m
            , [] ))
  | Nav.Media_viewer, Keymap.Input.Char "e" when is_printable_key norm -> (
      match Model.focused_artifact m with
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
          Some
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
      | None ->
          Some
            ( Model.with_toast ~now ~level:Model.Toast_warning
                (Say.make ~ko:"선택된 아티팩트가 없습니다"
                   ~en:"No artifact selected")
                m
            , [] ))
  | Nav.Media_viewer, Keymap.Input.Char "o" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m Keymap.Open_external)
  | Nav.Media_viewer, Keymap.Input.Char "v" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m Keymap.Cycle_view_mode)
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

let open_runtime_assign_modal (m : Model.t) ?(keeper_default = "")
    ?(runtime_default = "") () =
  open_custom_inline_modal ~kind:Nav.Runtime_assign_form m
    [
      {
        key = "assign_keeper";
        label = Say.make ~ko:"대상 키퍼" ~en:"Target keeper";
        value = keeper_default;
        required = false;
        secret = false;
      };
      {
        key = "assign_runtime_id";
        label = Say.make ~ko:"런타임 / 레인 ID" ~en:"Runtime / lane ID";
        value = runtime_default;
        required = false;
        secret = false;
      };
    ]

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

(* Fallback contextual hotkeys for keys not bound in Keymap Unfocused_nav/Global
   or screen_context_intercept. Keys handled by Keymap.dispatch or
   screen_context_intercept never reach this function. *)
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
  if Model.sidebar_has_focus m then (m, [])
  else if is_ctrl_e then
    Update_actions.execute_action ~now m Keymap.Open_external_editor
  else
    match printable_char with
    | Some "."
      when Option.is_some (Memory_diagram.active_memory_content_rect m)
           || (Option.is_none m.nav.overlay
               && Option.is_none (Model.active_dive m)
               && Nav.equal_workspace m.nav.workspace Nav.Knowledge
               && Nav.equal_knowledge_tab m.knowledge.active_tab
                    Nav.Knowledge_memory) ->
        Update_nav.open_memory_diagram ~now
          ~kind:Knowledge_store.Diagram_pele_card m
    | Some _ | None -> (
        match Model.active_dive m with
        | Some (Nav.Dive_runtime (Nav.Skill_dive ref_s)) -> (
            match printable_char with
            | Some "R" ->
                ( Model.with_toast ~now ~level:Model.Toast_info
                    (Say.make ~ko:"스킬 카탈로그 새로고침 중…"
                       ~en:"Refreshing skill catalog…")
                    m
                , [
                    Cmd.Http_post
                      { epoch = m.epoch; req = Cmd.Post_skills_refresh };
                  ] )
            | Some "p" -> (
                match
                  Runtime_store.skill_editor_loaded_for ~reference:ref_s
                    m.runtime
                with
                | Some loaded ->
                    ( Model.with_toast ~now ~level:Model.Toast_info
                        (Say.make ~ko:"스킬 미리보기 검증 중…"
                           ~en:"Validating skill preview…")
                        m
                    , [
                        Cmd.Http_post
                          {
                            epoch = m.epoch;
                            req =
                              Cmd.Post_skill_editor_preview
                                {
                                  reference = ref_s;
                                  reference_json = loaded.reference_json;
                                  source_text = loaded.source_text;
                                };
                          };
                      ] )
                | None -> (m, []))
            | Some _ | None -> (m, []))
        | Some
            ( Nav.Dive_work _
            | Nav.Dive_knowledge _
            | Nav.Dive_runtime (Nav.Tool_dive _ | Nav.Exact_run_dive _) ) ->
            (m, [])
        | None -> (
            match m.nav.workspace with
            | Nav.Runtime -> (
                match printable_char with
                | Some "R"
                  when Nav.equal_runtime_tab m.runtime.active_tab
                         Nav.Runtime_failover_lanes -> (
                    match Runtime_store.selected_lane m.runtime with
                    | Some lane when Wire_runtime.is_named_routing_lane lane.id
                      ->
                        Update_nav.open_inline_modal m
                          (Nav.Lane_rename_form { lane = lane.id })
                    | Some _ ->
                        ( Model.with_toast ~now ~level:Model.Toast_warning
                            (Say.make ~ko:"일반 레인 이름만 변경할 수 있습니다"
                               ~en:"Only named lanes can be renamed")
                            m
                        , [] )
                    | None -> (m, []))
                | Some "D"
                  when Nav.equal_runtime_tab m.runtime.active_tab
                         Nav.Runtime_failover_lanes -> (
                    match Observed.to_option m.runtime.exact_lane_runs with
                    | Some (first :: _) ->
                        Update_nav.push_dive m
                          (Nav.Dive_runtime (Nav.Exact_run_dive first.run_id))
                    | Some [] | None -> (m, []))
                | Some "O"
                  when Nav.equal_runtime_tab m.runtime.active_tab
                         Nav.Runtime_addons_browser -> (
                    if m.nav.pane_index = 1 then
                      match
                        ( Runtime_store.selected_browser_client m.runtime
                        , Runtime_store.selected_browser_tab m.runtime )
                      with
                      | Some cl, Some tb ->
                          ( Model.with_toast ~now ~level:Model.Toast_info
                              (Say.make
                                 ~ko:
                                   (Printf.sprintf "브라우저 장면 로드 중 (#%d)…"
                                      tb.id)
                                 ~en:
                                   (Printf.sprintf "Fetching browser scene (#%d)…"
                                      tb.id))
                              m
                          , [
                              Cmd.Http_post
                                {
                                  epoch = m.epoch;
                                  req =
                                    Cmd.Post_browser_scene
                                      {
                                        client_id = cl.client_id;
                                        tab_id = tb.id;
                                        view = `Content;
                                      };
                                };
                            ] )
                      | Some _, None | None, (Some _ | None) -> (m, [])
                    else if not m.runtime.addon_catalog_mode then
                      match Runtime_store.selected_addon_instance m.runtime with
                      | Some inst ->
                          ( Model.with_toast ~now ~level:Model.Toast_info
                              (Say.make
                                 ~ko:("애드온 관측 트리거 중: " ^ inst.instance_id)
                                 ~en:
                                   ("Triggering addon observe: " ^ inst.instance_id))
                              m
                          , [
                              Cmd.Http_post
                                {
                                  epoch = m.epoch;
                                  req =
                                    Cmd.Post_lane_addon_observe
                                      { instance_id = inst.instance_id };
                                };
                            ] )
                      | None -> (m, [])
                    else (m, []))
                | Some "D"
                  when Nav.equal_runtime_tab m.runtime.active_tab
                         Nav.Runtime_addons_browser
                       && (not m.runtime.addon_catalog_mode)
                       && m.nav.pane_index = 0 ->
                    let lane_id =
                      Option.map
                        (fun (inst : Wire_runtime.addon_instance) ->
                          inst.addon_id)
                        (Runtime_store.selected_addon_instance m.runtime)
                    in
                    ( Model.with_toast ~now ~level:Model.Toast_info
                        (Say.make ~ko:"애드온 슬라이스 조회 중…"
                           ~en:"Fetching addon slice…")
                        m
                    , [
                        Cmd.Http_get
                          {
                            epoch = m.epoch;
                            req =
                              Cmd.Get_lane_addon_slice
                                { run_id = None; lane_id };
                          };
                      ] )
                | Some "W"
                  when Nav.equal_runtime_tab m.runtime.active_tab
                         Nav.Runtime_addons_browser
                       && m.nav.pane_index = 1 -> (
                    match
                      ( Runtime_store.selected_browser_client m.runtime
                      , Runtime_store.selected_browser_tab m.runtime )
                    with
                    | Some cl, Some tb ->
                        ( Model.with_toast ~now ~level:Model.Toast_info
                            (Say.make
                               ~ko:
                                 (Printf.sprintf
                                    "브라우저 스크린샷 캡처 중 (#%d)…" tb.id)
                               ~en:
                                 (Printf.sprintf
                                    "Capturing browser screenshot (#%d)…" tb.id))
                            m
                        , [
                            Cmd.Http_post
                              {
                                epoch = m.epoch;
                                req =
                                  Cmd.Post_browser_screenshot
                                    { client_id = cl.client_id; tab_id = tb.id };
                              };
                          ] )
                    | Some _, None | None, (Some _ | None) -> (m, []))
                | Some "R"
                  when Nav.equal_runtime_tab m.runtime.active_tab
                         Nav.Runtime_tools_usage
                       && Runtime_store.equal_tools_subview
                            m.runtime.tools_subview
                            Runtime_store.Tools_keeper_skills ->
                    ( Model.with_toast ~now ~level:Model.Toast_info
                        (Say.make ~ko:"스킬 카탈로그 새로고침 중…"
                           ~en:"Refreshing skill catalog…")
                        m
                    , [
                        Cmd.Http_post
                          { epoch = m.epoch; req = Cmd.Post_skills_refresh };
                      ] )
                | Some _ | None -> (m, []))
            | Nav.Keepers -> (
                match printable_char with
                | Some "A"
                  when (m.nav.pane_index >= 1
                        || (m.nav.zoomed && Model.can_zoom_current_view m))
                       && Option.is_some (Model.selected_keeper_name m)
                       && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                            Nav.Keeper_memory ->
                    Update_actions.execute_action ~now m
                      Keymap.Open_memory_recovery
                | Some _ | None -> (m, []))
            | Nav.Knowledge -> (
                match printable_char with
                | Some "A"
                  when Nav.equal_knowledge_tab m.knowledge.active_tab
                         Nav.Knowledge_memory ->
                    Update_actions.execute_action ~now m
                      Keymap.Open_memory_recovery
                | Some _ | None -> (m, []))
            | Nav.Work -> (
                match printable_char with
                | Some "C"
                  when Nav.equal_work_tab m.work.active_tab Nav.Work_inbox
                       && Work_store.equal_inbox_subview m.work.inbox_subview
                            Work_store.Inbox_queue -> (
                    match
                      Attention.current_filtered_item ~query:m.work.filter_query
                        m.attention
                    with
                    | Some (entry : Attention.entry) -> (
                        match entry.payload with
                        | Attention.Payload_ask ask ->
                            Update_nav.jump_to_keeper ~preserve_return:true
                              ~tab:Nav.Keeper_chat m ask.keeper
                        | Attention.Payload_tool_approval ta ->
                            Update_nav.jump_to_keeper ~preserve_return:true
                              ~tab:Nav.Keeper_chat m ta.keeper
                        | Attention.Payload_gate g ->
                            if not (String.equal (String.trim g.keeper) "") then
                              Update_nav.jump_to_keeper ~preserve_return:true
                                ~tab:Nav.Keeper_chat m g.keeper
                            else (m, [])
                        | Attention.Payload_goal_confirmation _ -> (m, []))
                    | None -> (m, []))
                | Some _ | None -> (m, []))
            | Nav.Infra | Nav.Pulse -> (m, [])))

let keeper_config_target_name (m : Model.t) =
  match Model.active_dive m with
  | Some
      ( Nav.Dive_work _
      | Nav.Dive_knowledge _
      | Nav.Dive_runtime _
      ) ->
      None
  | None ->
      if Model.is_keeper_config_active m then Model.selected_keeper_name m
      else None

let dispatch_keeper_config_key ~now (m : Model.t)
    (norm : Keymap.Input.key_event) =
  if Config_store.is_editing_field m.config then
    match norm.key with
    | Keymap.Input.Backspace ->
        Some
          ({ m with config = Config_store.backspace_edit_buffer m.config }, [])
    | Keymap.Input.Delete ->
        Some ({ m with config = Config_store.delete_edit_forward m.config }, [])
    | Keymap.Input.Left when (not norm.mods.ctrl) && not norm.mods.alt ->
        Some
          ({ m with config = Config_store.move_edit_cursor `Left m.config }, [])
    | Keymap.Input.Right when (not norm.mods.ctrl) && not norm.mods.alt ->
        Some
          ({ m with config = Config_store.move_edit_cursor `Right m.config }, [])
    | Keymap.Input.Home when (not norm.mods.ctrl) && not norm.mods.alt ->
        Some
          ({ m with config = Config_store.move_edit_cursor `Home m.config }, [])
    | Keymap.Input.End when (not norm.mods.ctrl) && not norm.mods.alt ->
        Some
          ({ m with config = Config_store.move_edit_cursor `End m.config }, [])
    | Keymap.Input.Char "a" when norm.mods.ctrl && not norm.mods.alt ->
        Some
          ({ m with config = Config_store.move_edit_cursor `Home m.config }, [])
    | Keymap.Input.Char "e" when norm.mods.ctrl && not norm.mods.alt ->
        Some
          ({ m with config = Config_store.move_edit_cursor `End m.config }, [])
    | Keymap.Input.Char "u" when norm.mods.ctrl && not norm.mods.alt ->
        Some
          ({ m with config = Config_store.kill_edit_line_start m.config }, [])
    | Keymap.Input.Char "w" when norm.mods.ctrl && not norm.mods.alt ->
        Some ({ m with config = Config_store.kill_edit_word m.config }, [])
    | Keymap.Input.Char s when is_printable_key norm ->
        Some
          ({ m with config = Config_store.append_edit_char s m.config }, [])
    | Keymap.Input.Enter -> (
        match Config_store.commit_edit_field m.config with
        | Ok config ->
            Some
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:"변경값이 스테이징됨 (Ctrl+S: 저장 · d: 미리보기)"
                     ~en:"Staged field change (Ctrl+S: save · d: dry-run)")
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
    | Keymap.Input.Char "d" when is_printable_key norm -> (
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
    | Keymap.Input.Char " " when is_printable_key norm -> (
        match Config_store.keeper_selected_field ~lang:m.lang m.config with
        | Some f when f.writable && f.kind = Wire_config.Field_bool ->
            step_lr 1
        | Some _ | None ->
            Some
              ( Model.with_toast ~now ~level:Model.Toast_info
                  (Say.make
                     ~ko:"[d] Dry-run 미리보기 · [Enter] 편집 · [←→] 값 변경"
                     ~en:"[d] Dry-run diff · [Enter] Edit · [←→] Cycle value")
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
                     ~ko:"키 삭제 스테이징 토글됨 (d: 미리보기 · Ctrl+S: 저장)"
                     ~en:"Toggled key removal (d: dry-run · Ctrl+S: save)")
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
                     ~ko:"키 삭제 스테이징 토글됨 (d: 미리보기 · Ctrl+S: 저장)"
                     ~en:"Toggled key removal (d: dry-run · Ctrl+S: save)")
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

let rec apply_key_event ~now (m : Model.t) (ev : Keymap.Input.key_event) =
  let norm = Keymap.normalize_key_event ev in
  let is_quit_key =
    match Keymap.dispatch ~scope_chain:[ Keymap.Global ] norm with
    | Some act -> Keymap.equal_action act Keymap.Quit_app
    | None -> false
  in
  let quit_arm_active =
    match m.quit_armed_at with
    | Some armed_at ->
        let elapsed = Clock.Mono.seconds_since now ~since:armed_at in
        elapsed >= 0.0 && elapsed <= Model.quit_arm_window_s
    | None -> false
  in
  let is_keeper_stop_key =
    Model.is_keeper_lifecycle_surface m
    && (not (Model.is_memory_diff_pin_surface m))
    &&
    match
      Keymap.dispatch
        ~scope_chain:(Keymap.Screen_context :: Model.focus_scope_chain m)
        norm
    with
    | Some act -> Keymap.equal_action act Keymap.Keeper_stop_armed
    | None -> false
  in
  let keeper_stop_arm_active =
    Model.is_keeper_lifecycle_surface m
    &&
    match m.keeper_stop_armed with
    | Some (_, armed_at) ->
        let elapsed = Clock.Mono.seconds_since now ~since:armed_at in
        elapsed >= 0.0 && elapsed < Model.keeper_stop_arm_window_s
    | None -> false
  in
  let m =
    if Option.is_some m.quit_armed_at && not is_quit_key then
      Model.disarm_quit m
    else m
  in
  let m =
    if Option.is_some m.keeper_stop_armed && not is_keeper_stop_key then
      Model.disarm_keeper_stop m
    else m
  in
  let is_plain_escape =
    (not norm.mods.ctrl)
    && (not norm.mods.alt)
    &&
    match norm.key with
    | Keymap.Input.Escape -> true
    | Keymap.Input.Char _
    | Keymap.Input.Enter
    | Keymap.Input.Tab
    | Keymap.Input.Backspace
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
        false
  in
  (* Plain Esc consumes only an active arm (quit or keeper stop) without popping
     an active dive/modal. Every other non-confirm key disarms above AND
     continues normal dispatch so the user's first keypress is never lost. *)
  if
    (quit_arm_active && (not is_quit_key) && is_plain_escape)
    || (keeper_stop_arm_active && (not is_keeper_stop_key) && is_plain_escape)
  then (m, [])
  else
  (* Top-precedence Micro_viewport gate per tui-chat-design/SKILL.md: never
     mutate hidden drafts or underlying overlays. On <40x12 only Quit_app is
     accepted; on Micro (<80x24) only Quit_app, Force_refresh, and
     Teleport_blocked ('J') advertised by the Micro Cockpit are accepted. *)
  if Model.is_too_small_viewport m.viewport then
    match Keymap.dispatch ~scope_chain:[ Keymap.Global ] norm with
    | Some act when Keymap.equal_action act Keymap.Quit_app ->
        Update_actions.execute_action ~now m Keymap.Quit_app
    | Some _ | None -> (m, [])
  else if
    Model.equal_breakpoint m.breakpoint Model.Micro
    && Option.is_none m.nav.overlay
  then
    (* Micro Cockpit (<80x24) hides Composer, Filter, and workspace body,
       while still rendering Overlays on top. Block hidden-surface edits and
       only allow explicit global/overlay-open actions. *)
    let micro_allowed =
      [
        Keymap.Quit_app;
        Keymap.Refresh;
        Keymap.Teleport_blocked;
        Keymap.Open_settings;
        Keymap.Open_palette;
        Keymap.Open_help;
        Keymap.Open_incidents;
        Keymap.Open_queue_context;
      ]
    in
    match
      Keymap.dispatch ~scope_chain:[ Keymap.Unfocused_nav; Keymap.Global ] norm
    with
    | Some act when List.exists (Keymap.equal_action act) micro_allowed ->
        Update_actions.execute_action ~now m act
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
        | Nav.Ask_answer
        | Nav.Help )
    | None -> (
        (* 1. Active filter box text capture *)
        if m.nav.filter_focused then
          match norm.key with
          | Keymap.Input.Escape ->
              let cleared, cmds = Update_nav.set_active_filter_query "" m in
              ( { cleared with nav = { cleared.nav with filter_focused = false } }
              , cmds )
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
              Update_nav.set_active_filter_query q m
          | Keymap.Input.Char s when is_printable_key norm ->
              let q = Update_nav.current_filter_query m ^ s in
              Update_nav.set_active_filter_query q m
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
              | Some act -> guard_settings_dirty_leave ~now m act
              | None -> (m, []))
        else
          (* 2. Active text-owning and action-owning overlays *)
          match m.nav.overlay with
          | Some Nav.Palette -> (
              match norm.key with
              | Keymap.Input.Backspace ->
                  let query = Update_nav.drop_last_utf8 m.palette.query in
                  ( {
                      m with
                      palette = { m.palette with query; selected = 0 };
                      nav = { m.nav with palette_scroll_offset = 0 };
                    }
                  , [] )
              | Keymap.Input.Char s when is_printable_key norm ->
                  let query = m.palette.query ^ s in
                  ( {
                      m with
                      palette = { m.palette with query; selected = 0 };
                      nav = { m.nav with palette_scroll_offset = 0 };
                    }
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
              | None -> (
                  match norm.key with
                  | Keymap.Input.Escape ->
                      Update_actions.execute_action ~now m
                        Keymap.Pop_back_or_close
                  | Keymap.Input.Char _
                  | Keymap.Input.Enter
                  | Keymap.Input.Tab
                  | Keymap.Input.Backspace
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
                      let cleaned =
                        { m with nav = { m.nav with overlay = None } }
                      in
                      apply_key_event ~now cleaned ev)
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
                  let cycle_modal_picker ~delta =
                    let cycle_in options cur =
                      match options with
                      | [] -> None
                      | _ ->
                          let len = List.length options in
                          let idx =
                            let rec find i = function
                              | [] -> -1
                              | x :: rest ->
                                  if String.equal x cur then i
                                  else find (i + 1) rest
                            in
                            find 0 options
                          in
                          let next_idx =
                            if idx < 0 then 0
                            else
                              let v = (idx + delta) mod len in
                              if v < 0 then v + len else v
                          in
                          List.nth_opt options next_idx
                    in
                    let active_fld = List.nth_opt modal.fields modal.active_field in
                    match modal.kind, active_fld with
                    | Nav.Connector_form, Some { key = "connector"; value; _ } -> (
                        let ids =
                          List.map
                            (fun (c : Wire_runtime.connector_row) ->
                              c.connector_id)
                            (Runtime_store.filtered_connectors m.runtime)
                        in
                        match cycle_in ids (String.trim value) with
                        | Some next_id ->
                            let first_chan =
                              match
                                Runtime_store.connector_channel_names
                                  ~connector_id:next_id m.runtime
                              with
                              | first :: _ -> first.id
                              | [] -> ""
                            in
                            let fields =
                              List.map
                                (fun (f : Model.modal_form_field) ->
                                  if String.equal f.key "connector" then
                                    { f with value = next_id }
                                  else if
                                    (String.equal f.key "channel"
                                    || String.equal f.key "channel_id")
                                    && not (String.equal first_chan "")
                                  then { f with value = first_chan }
                                  else f)
                                modal.fields
                            in
                            let cmds =
                              if
                                not
                                  (Runtime_store.String_map.mem next_id
                                     m.runtime.connector_names)
                              then
                                [
                                  Cmd.Http_get
                                    {
                                      epoch = m.epoch;
                                      req =
                                        Cmd.Get_connector_names
                                          {
                                            connector = next_id;
                                            scope = "channel";
                                          };
                                    };
                                ]
                              else []
                            in
                            Some
                              ( { m with inline_modal = Some { modal with fields; error = None } }
                              , cmds )
                        | None -> None)
                    | ( Nav.Connector_form
                      , Some { key = ("channel" | "channel_id"); value; _ } ) -> (
                        let cid = Model.modal_field_value ~key:"connector" modal in
                        let chans =
                          List.map
                            (fun (cm : Wire_runtime.connector_name_mapping) ->
                              cm.id)
                            (Runtime_store.connector_channel_names
                               ~connector_id:cid m.runtime)
                        in
                        match cycle_in chans (String.trim value) with
                        | Some next_ch ->
                            let next_modal =
                              Model.modal_update_active_field
                                (fun _ -> next_ch)
                                modal
                            in
                            Some ({ m with inline_modal = Some next_modal }, [])
                        | None -> None)
                    | Nav.Fusion_launch_form, Some { key = "fusion_preset"; value; _ } -> (
                        let presets =
                          match Observed.to_option m.runtime.fusion_config with
                          | Some cfg ->
                              List.map
                                (fun (p : Wire_runtime.fusion_preset_option) ->
                                  p.name)
                                cfg.presets
                          | None -> []
                        in
                        match cycle_in presets (String.trim value) with
                        | Some next_p ->
                            let next_modal =
                              Model.modal_update_active_field
                                (fun _ -> next_p)
                                modal
                            in
                            Some ({ m with inline_modal = Some next_modal }, [])
                        | None -> None)
                    | Nav.Runtime_lane_create, Some { key = "lane_kind"; value; _ } -> (
                        match
                          cycle_in [ "failover"; "exact_output" ]
                            (String.lowercase_ascii (String.trim value))
                        with
                        | Some next_kind ->
                            let next_modal =
                              Model.modal_update_active_field
                                (fun _ -> next_kind)
                                modal
                            in
                            Some ({ m with inline_modal = Some next_modal }, [])
                        | None -> None)
                    | Nav.Task_transition_form _, Some { key = "task_action"; value; _ } -> (
                        match
                          cycle_in
                            [ "claim"; "start"; "release"; "submit_for_verification" ]
                            (String.lowercase_ascii (String.trim value))
                        with
                        | Some next_act ->
                            let next_modal =
                              Model.modal_update_active_field
                                (fun _ -> next_act)
                                modal
                            in
                            Some ({ m with inline_modal = Some next_modal }, [])
                        | None -> None)
                    | Nav.Goal_upsert_form id_opt, Some { key = "goal_measure_kind"; value; _ } -> (
                        let choices =
                          match id_opt with
                          | Some _ -> [ ""; "done_when"; "count"; "quantity" ]
                          | None -> [ "done_when"; "count"; "quantity" ]
                        in
                        match
                          cycle_in choices
                            (String.lowercase_ascii (String.trim value))
                        with
                        | Some next_mk ->
                            let next_modal =
                              Model.modal_update_active_field
                                (fun _ -> next_mk)
                                modal
                            in
                            Some ({ m with inline_modal = Some next_modal }, [])
                        | None -> None)
                    | Nav.Keeper_lifecycle_form _, Some { key = "lifecycle_action"; value; _ } -> (
                        match
                          cycle_in
                            [ "boot"; "pause"; "resume"; "shutdown"; "reset" ]
                            (String.lowercase_ascii (String.trim value))
                        with
                        | Some next_op ->
                            let next_modal =
                              Model.modal_update_active_field
                                (fun _ -> next_op)
                                modal
                            in
                            Some ({ m with inline_modal = Some next_modal }, [])
                        | None -> None)
                    | ( Nav.Addon_invoke_action { action_names; _ }
                      , Some { key = "addon_action_name"; value; _ } ) -> (
                        match cycle_in action_names (String.trim value) with
                        | Some next_act ->
                            let next_modal =
                              Model.modal_update_active_field
                                (fun _ -> next_act)
                                modal
                            in
                            Some ({ m with inline_modal = Some next_modal }, [])
                        | None -> None)
                    | ( ( Nav.Connector_form
                        | Nav.Fusion_launch_form
                        | Nav.Runtime_lane_create
                        | Nav.Task_transition_form _
                        | Nav.Goal_upsert_form _
                        | Nav.Keeper_lifecycle_form _
                        | Nav.Addon_invoke_action _ )
                      , (Some _ | None) )
                    | ( ( Nav.Btw_query
                        | Nav.Gate_reject _
                        | Nav.Verification_reject _
                        | Nav.Harness_overrule _
                        | Nav.Task_cancel _
                        | Nav.Goal_drop _
                        | Nav.Schedule_form
                        | Nav.Repo_add_form
                        | Nav.Board_new_post
                        | Nav.Board_goal_proposal
                        | Nav.Goal_confirmation_proof
                        | Nav.Memory_act_form
                        | Nav.Wiki_edit_form
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
                        | Nav.Runtime_lane_edit _
                        | Nav.Runtime_lane_delete _
                        | Nav.Task_create_form
                        | Nav.Task_link_goal _
                        | Nav.Board_delete_post _
                        | Nav.Keeper_purge_confirm _
                        | Nav.Addon_attach_form
                        | Nav.Addon_detach_confirm _
                        | Nav.Setup_login_input_form _ )
                      , (Some _ | None) ) ->
                        None
                  in
                  let sync_picker_cursor (m_out, cmds) =
                    let cursor =
                      match m_out.Model.inline_modal with
                      | Some mdl ->
                          String.length (Model.modal_active_field_value mdl)
                      | None -> 0
                    in
                    ( { m_out with nav = { m_out.nav with modal_edit_cursor = cursor } }
                    , cmds )
                  in
                  let cur_val = Model.modal_active_field_value modal in
                  let cur_pos =
                    Int.max 0 (Int.min (String.length cur_val) m.nav.modal_edit_cursor)
                  in
                  let apply_modal_edit (next_val, next_cur) =
                    ( {
                        m with
                        inline_modal =
                          Some
                            (Model.modal_update_active_field
                               (fun _ -> next_val)
                               modal);
                        nav = { m.nav with modal_edit_cursor = next_cur };
                      }
                    , [] )
                  in
                  let insert_newline () =
                    match List.nth_opt modal.fields modal.active_field with
                    | Some field
                      when editable && Model.modal_field_multiline field ->
                        apply_modal_edit
                          (Update_nav.insert_at_cursor ~text:cur_val
                             ~cursor:cur_pos ~insert:"\n")
                    | Some _ | None -> (m, [])
                  in
                  match norm.key with
                  | Keymap.Input.Enter
                    when norm.mods.shift && is_printable_key norm ->
                      insert_newline ()
                  | Keymap.Input.Char "j" when norm.mods.ctrl && not norm.mods.alt ->
                      insert_newline ()
                  | Keymap.Input.Left when editable && (not norm.mods.ctrl) && not norm.mods.alt -> (
                      match cycle_modal_picker ~delta:(-1) with
                      | Some res -> sync_picker_cursor res
                      | None ->
                          let next_cur =
                            Update_nav.move_cursor_utf8 `Left ~text:cur_val
                              ~cursor:cur_pos
                          in
                          ( { m with nav = { m.nav with modal_edit_cursor = next_cur } }
                          , [] ))
                  | Keymap.Input.Right when editable && (not norm.mods.ctrl) && not norm.mods.alt -> (
                      match cycle_modal_picker ~delta:1 with
                      | Some res -> sync_picker_cursor res
                      | None ->
                          let next_cur =
                            Update_nav.move_cursor_utf8 `Right ~text:cur_val
                              ~cursor:cur_pos
                          in
                          ( { m with nav = { m.nav with modal_edit_cursor = next_cur } }
                          , [] ))
                  | Keymap.Input.Home when editable && (not norm.mods.ctrl) && not norm.mods.alt ->
                      ({ m with nav = { m.nav with modal_edit_cursor = 0 } }, [])
                  | Keymap.Input.End when editable && (not norm.mods.ctrl) && not norm.mods.alt ->
                      ( {
                          m with
                          nav =
                            {
                              m.nav with
                              modal_edit_cursor = String.length cur_val;
                            };
                        }
                      , [] )
                  | Keymap.Input.Char "a" when editable && norm.mods.ctrl && not norm.mods.alt ->
                      ({ m with nav = { m.nav with modal_edit_cursor = 0 } }, [])
                  | Keymap.Input.Char "e" when editable && norm.mods.ctrl && not norm.mods.alt ->
                      ( {
                          m with
                          nav =
                            {
                              m.nav with
                              modal_edit_cursor = String.length cur_val;
                            };
                        }
                      , [] )
                  | Keymap.Input.Char "u" when editable && norm.mods.ctrl && not norm.mods.alt ->
                      apply_modal_edit
                        (Update_nav.kill_to_start ~text:cur_val ~cursor:cur_pos)
                  | Keymap.Input.Char "w" when editable && norm.mods.ctrl && not norm.mods.alt ->
                      apply_modal_edit
                        (Update_nav.kill_word_back ~text:cur_val ~cursor:cur_pos)
                  | Keymap.Input.Delete when editable ->
                      apply_modal_edit
                        (Update_nav.delete_at_cursor ~text:cur_val ~cursor:cur_pos)
                  | Keymap.Input.Tab when editable ->
                      let delta = if norm.mods.shift then -1 else 1 in
                      let next_modal = Model.modal_cycle_field ~delta modal in
                      let modal_edit_cursor =
                        String.length (Model.modal_active_field_value next_modal)
                      in
                      ( {
                          m with
                          inline_modal = Some next_modal;
                          nav = { m.nav with modal_edit_cursor };
                        }
                      , [] )
                  | Keymap.Input.Backspace when editable ->
                      apply_modal_edit
                        (Update_nav.backspace_at_cursor ~text:cur_val
                           ~cursor:cur_pos)
                  | Keymap.Input.Char s when editable && is_printable_key norm ->
                      apply_modal_edit
                        (Update_nav.insert_at_cursor ~text:cur_val ~cursor:cur_pos
                           ~insert:s)
                  | Keymap.Input.Char "y"
                    when (not editable)
                         && Nav.equal_inline_action_kind modal.kind Nav.Btw_query
                         && is_printable_key norm ->
                      Update_actions.execute_action ~now m Keymap.Copy_selected
                  | Keymap.Input.Char "j"
                    when (not editable)
                         && Nav.equal_inline_action_kind modal.kind Nav.Btw_query
                         && is_printable_key norm ->
                      Update_nav.apply_move m Keymap.Down
                  | Keymap.Input.Char "k"
                    when (not editable)
                         && Nav.equal_inline_action_kind modal.kind Nav.Btw_query
                         && is_printable_key norm ->
                      Update_nav.apply_move m Keymap.Up
                  | Keymap.Input.Char "g"
                    when (not editable)
                         && Nav.equal_inline_action_kind modal.kind Nav.Btw_query
                         && is_printable_key norm ->
                      Update_nav.apply_move m Keymap.Home
                  | Keymap.Input.Char "G"
                    when (not editable)
                         && Nav.equal_inline_action_kind modal.kind Nav.Btw_query
                         && is_printable_key norm ->
                      Update_nav.apply_move m Keymap.End
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
              | Keymap.Input.Delete ->
                  ( {
                      m with
                      config = Config_store.delete_edit_forward m.config;
                    }
                  , [] )
              | Keymap.Input.Left when (not norm.mods.ctrl) && not norm.mods.alt ->
                  ( {
                      m with
                      config = Config_store.move_edit_cursor `Left m.config;
                    }
                  , [] )
              | Keymap.Input.Right when (not norm.mods.ctrl) && not norm.mods.alt ->
                  ( {
                      m with
                      config = Config_store.move_edit_cursor `Right m.config;
                    }
                  , [] )
              | Keymap.Input.Home when (not norm.mods.ctrl) && not norm.mods.alt ->
                  ( {
                      m with
                      config = Config_store.move_edit_cursor `Home m.config;
                    }
                  , [] )
              | Keymap.Input.End when (not norm.mods.ctrl) && not norm.mods.alt ->
                  ( {
                      m with
                      config = Config_store.move_edit_cursor `End m.config;
                    }
                  , [] )
              | Keymap.Input.Char "a" when norm.mods.ctrl && not norm.mods.alt ->
                  ( {
                      m with
                      config = Config_store.move_edit_cursor `Home m.config;
                    }
                  , [] )
              | Keymap.Input.Char "e" when norm.mods.ctrl && not norm.mods.alt ->
                  ( {
                      m with
                      config = Config_store.move_edit_cursor `End m.config;
                    }
                  , [] )
              | Keymap.Input.Char "u" when norm.mods.ctrl && not norm.mods.alt ->
                  ( {
                      m with
                      config = Config_store.kill_edit_line_start m.config;
                    }
                  , [] )
              | Keymap.Input.Char "w" when norm.mods.ctrl && not norm.mods.alt ->
                  ( { m with config = Config_store.kill_edit_word m.config }
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
              | Keymap.Input.Insert
              | Keymap.Input.Function _ -> (
                  match
                    Keymap.dispatch ~scope_chain:(Model.focus_scope_chain m)
                      norm
                  with
                  | Some act when settings_edit_allows_global_action act ->
                      Update_actions.execute_action ~now m act
                  | Some _ | None -> (m, [])))
          | Some (Nav.Settings _) -> (
              let m =
                if Keymap.Input.equal_key norm.key Keymap.Input.Escape then m
                else
                  { m with config = Config_store.disarm_discard_confirm m.config }
              in
              match dispatch_settings_overlay_key ~now m norm with
              | Some res -> res
              | None -> (
                  match
                    Keymap.dispatch ~scope_chain:(Model.focus_scope_chain m)
                      norm
                  with
                  | Some act -> guard_settings_dirty_leave ~now m act
                  | None -> (m, [])))
          | Some Nav.Incidents -> (
              let is_clear_key =
                is_printable_key norm
                && (Keymap.Input.equal_key norm.key (Keymap.Input.Char "c")
                   || Keymap.Input.equal_key norm.key (Keymap.Input.Char "D"))
              in
              let m =
                if is_clear_key then m
                else
                  {
                    m with
                    incidents = Incidents.disarm_clear_confirm m.incidents;
                  }
              in
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
          | Some Nav.Ask_answer -> (
              match dispatch_ask_answer_overlay_key ~now m norm with
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
                    if Model.sidebar_has_focus m then None
                    else if
                      Model.is_keeper_config_active m
                      && not (Drafts.is_focused m.drafts)
                    then dispatch_keeper_config_key ~now m norm
                    else if not (Drafts.is_focused m.drafts) then
                      (* Pillar 3: typing Korean while unfocused inside
                         Keepers > Chat (split focus or Focus Mode) auto-focuses
                         the composer and inserts the character instead of
                         letting Korean jamo replay trigger centered modals. *)
                      let keeper_chat_korean =
                        match Model.active_dive m, norm.key with
                        | None, Keymap.Input.Char s
                          when is_printable_key norm && is_korean_char s
                               && Model.is_in_keeper_chat m
                               && not
                                    (Model.equal_breakpoint m.breakpoint
                                       Model.Micro) -> (
                            match Model.selected_keeper_name m with
                            | Some name ->
                                let drafts =
                                  m.drafts
                                  |> Drafts.set_active_keeper name
                                  |> Drafts.set_focus true
                                  |> Drafts.insert_text s
                                in
                                Some ({ m with drafts }, [])
                            | None -> None)
                        | ( ( Some
                                ( Nav.Dive_work _
                                | Nav.Dive_knowledge _
                                | Nav.Dive_runtime _ )
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
                      in
                      match keeper_chat_korean with
                      | Some _ as handled -> handled
                      | None -> (
                          let replayed = Keymap.replay_ime_event norm in
                          match Model.active_dive m, replayed.key with
                          | ( Some (Nav.Dive_work (Nav.Goal_dive goal_id))
                            , Keymap.Input.Char "J" )
                            when is_printable_key replayed
                                 && Option.is_none
                                      (Model.fast_approval_strip_item m) ->
                              Some
                                ( Update_nav.scroll_goal_dive_measure ~delta:1
                                    ~goal_id m
                                , [] )
                          | ( Some (Nav.Dive_work (Nav.Goal_dive goal_id))
                            , Keymap.Input.Char "K" )
                            when is_printable_key replayed ->
                              Some
                                ( Update_nav.scroll_goal_dive_measure ~delta:(-1)
                                    ~goal_id m
                                , [] )
                          | ( Some (Nav.Dive_work (Nav.Goal_dive goal_id))
                            , Keymap.Input.Down )
                            when replayed.mods.shift && (not replayed.mods.ctrl)
                                 && not replayed.mods.alt ->
                              Some
                                ( Update_nav.scroll_goal_dive_measure ~delta:1
                                    ~goal_id m
                                , [] )
                          | ( Some (Nav.Dive_work (Nav.Goal_dive goal_id))
                            , Keymap.Input.Up )
                            when replayed.mods.shift && (not replayed.mods.ctrl)
                                 && not replayed.mods.alt ->
                              Some
                                ( Update_nav.scroll_goal_dive_measure ~delta:(-1)
                                    ~goal_id m
                                , [] )
                          | ( Some (Nav.Dive_knowledge (Nav.Artifact_dive _))
                            , Keymap.Input.Char "M" )
                            when is_printable_key replayed
                                 && Option.is_some (Model.focused_artifact m) ->
                              Some
                                (Update_nav.open_overlay m
                                   (Nav.System_gate Nav.Media_viewer))
                          | None, Keymap.Input.Char "M"
                            when is_printable_key replayed
                                 && Nav.equal_workspace m.nav.workspace
                                      Nav.Knowledge
                                 && Nav.equal_knowledge_tab
                                      m.knowledge.active_tab
                                      Nav.Knowledge_artifacts
                                 && Option.is_some (Model.focused_artifact m) ->
                              Some
                                (Update_nav.open_overlay m
                                   (Nav.System_gate Nav.Media_viewer))
                          | (Some _ | None), Keymap.Input.Char "D"
                            when is_printable_key replayed
                                 && Model.is_memory_diff_pin_surface m ->
                              Some (Update_nav.pin_memory_diff_range m)
                          | ( ( Some
                                  ( Nav.Dive_work
                                      ( Nav.Goal_dive _
                                      | Nav.Task_dive _
                                      | Nav.Verification_dive _ )
                                  | Nav.Dive_knowledge
                                      ( Nav.Thread_dive _
                                      | Nav.Wiki_dive _
                                      | Nav.Artifact_dive _ )
                                  | Nav.Dive_runtime _ )
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
                              None)
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
                      let screen_context_intercept =
                        if
                          Drafts.is_focused m.drafts
                          || m.nav.filter_focused
                          || Model.sidebar_has_focus m
                          || Option.is_some m.nav.overlay
                        then None
                        else
                          let replayed = Keymap.replay_ime_event norm in
                          if not (is_printable_key replayed) then None
                          else
                            match key_char_opt replayed.key with
                            | Some "s"
                              when Option.is_none (Model.active_dive m)
                                   && ((Nav.equal_workspace m.nav.workspace
                                          Nav.Knowledge
                                        && Nav.equal_knowledge_tab
                                             m.knowledge.active_tab
                                             Nav.Knowledge_board)
                                      || (Nav.equal_workspace m.nav.workspace
                                            Nav.Infra
                                          && (Nav.equal_infra_tab
                                                m.infra.active_tab
                                                Nav.Infra_activity_logs
                                             || Nav.equal_infra_tab
                                                  m.infra.active_tab
                                                  Nav.Infra_code))) ->
                                Some Keymap.Cycle_signal_or_source
                            | Some "m"
                              when Option.is_none (Model.active_dive m)
                                   && Nav.equal_workspace m.nav.workspace
                                        Nav.Knowledge
                                   && Nav.equal_knowledge_tab
                                        m.knowledge.active_tab
                                        Nav.Knowledge_memory ->
                                Some Keymap.Toggle_memory_scope
                            | Some "Y"
                              when Option.is_none
                                     (Model.fast_approval_strip_item m)
                                   && (match Model.active_dive m with
                                   | Some
                                       (Nav.Dive_knowledge (Nav.Artifact_dive _))
                                     ->
                                       true
                                   | Some
                                       ( Nav.Dive_knowledge
                                           (Nav.Thread_dive _ | Nav.Wiki_dive _)
                                       | Nav.Dive_work _
                                       | Nav.Dive_runtime _
                                       ) ->
                                       false
                                   | None ->
                                       Nav.equal_workspace m.nav.workspace
                                         Nav.Knowledge
                                       && Nav.equal_knowledge_tab
                                            m.knowledge.active_tab
                                            Nav.Knowledge_artifacts) ->
                                Some Keymap.Copy_public_url
                            | Some "N"
                              when Model.is_artifact_dive_search_active m ->
                                Some Keymap.Search_prev_match
                            | Some "p"
                              when (match Model.active_dive m with
                                   | Some
                                       (Nav.Dive_knowledge (Nav.Thread_dive _)) ->
                                       true
                                   | Some
                                       ( Nav.Dive_knowledge
                                           (Nav.Wiki_dive _ | Nav.Artifact_dive _)
                                       | Nav.Dive_work _
                                       | Nav.Dive_runtime _ ) ->
                                       false
                                   | None ->
                                       (Nav.equal_workspace m.nav.workspace
                                          Nav.Knowledge
                                       && Nav.equal_knowledge_tab
                                            m.knowledge.active_tab
                                            Nav.Knowledge_board)
                                       || (Nav.equal_workspace m.nav.workspace
                                             Nav.Infra
                                          && (Nav.equal_infra_tab
                                                m.infra.active_tab
                                                Nav.Infra_sandboxes
                                             || Nav.equal_infra_tab
                                                  m.infra.active_tab
                                                  Nav.Infra_code))
                                       || (Nav.equal_workspace m.nav.workspace
                                             Nav.Runtime
                                          && Nav.equal_runtime_tab
                                               m.runtime.active_tab
                                               Nav.Runtime_addons_browser)
                                       || (Nav.equal_workspace m.nav.workspace
                                             Nav.Keepers
                                          && (m.nav.pane_index >= 1
                                             || m.nav.zoomed)
                                          && Nav.equal_keeper_tab
                                               m.fleet.keeper_dive_tab
                                               Nav.Keeper_work_sandbox
                                           && not
                                                (Option.fold ~none:false
                                                   ~some:(fun name ->
                                                     Board_recovery.shown
                                                       ~keeper:name
                                                       m.knowledge.board_recovery)
                                                   (Model.selected_keeper_name m)))) ->
                                Some Keymap.Probe_sandbox
                            | Some "g"
                              when (match Model.active_dive m with
                                   | Some (Nav.Dive_work (Nav.Task_dive _)) ->
                                       true
                                   | Some
                                       ( Nav.Dive_work
                                           ( Nav.Goal_dive _
                                           | Nav.Verification_dive _ )
                                       | Nav.Dive_knowledge _
                                       | Nav.Dive_runtime _
                                       ) ->
                                       false
                                   | None ->
                                       Nav.equal_workspace m.nav.workspace
                                         Nav.Work
                                       && Nav.equal_work_tab m.work.active_tab
                                            Nav.Work_tasks) ->
                                Some Keymap.Link_task_goal
                            | Some "R"
                              when (match Model.active_dive m with
                                   | Some
                                       (Nav.Dive_knowledge (Nav.Thread_dive _))
                                     ->
                                       true
                                   | Some
                                       ( Nav.Dive_knowledge
                                           (Nav.Wiki_dive _ | Nav.Artifact_dive _)
                                       | Nav.Dive_work _
                                       | Nav.Dive_runtime _
                                       ) ->
                                       false
                                   | None ->
                                       Nav.equal_workspace m.nav.workspace
                                         Nav.Knowledge
                                       && Nav.equal_knowledge_tab
                                            m.knowledge.active_tab
                                            Nav.Knowledge_board) ->
                                Some Keymap.Context_primary_action
                            | Some "t"
                              when Option.is_none (Model.active_dive m)
                                   && Nav.equal_workspace m.nav.workspace
                                        Nav.Runtime
                                   && Nav.equal_runtime_tab m.runtime.active_tab
                                        Nav.Runtime_addons_browser ->
                                Some Keymap.Refresh_browser_tabs
                            | Some "W" when Model.is_keeper_lifecycle_surface m
                              ->
                                Some Keymap.Keeper_wake_or_online
                            | Some "D" when Model.is_keeper_lifecycle_surface m
                              ->
                                Some Keymap.Keeper_stop_armed
                            | Some _ | None -> None
                      in
                      if is_ctrl_x then
                        Update_actions.execute_action ~now m Keymap.Interrupt_turn
                      else
                        match screen_context_intercept with
                        | Some act -> Update_actions.execute_action ~now m act
                        | None ->
                        (* 3. Single-SSOT Keymap dispatch *)
                    let sidebar_action_gate :
                        Keymap.action -> [ `Allow | `Move_right | `Ignore ] =
                      function
                      | Keymap.Toggle_sidebar
                      | Keymap.Move _
                      | Keymap.Dive_selected
                      | Keymap.Pop_back_or_close
                      | Keymap.Cycle_focus_pane _
                      | Keymap.Switch_workspace _
                      | Keymap.Sub_tab _
                      | Keymap.Open_palette
                      | Keymap.Open_settings
                      | Keymap.Open_incidents
                      | Keymap.Open_queue_context
                      | Keymap.Open_help
                      | Keymap.Open_keeper_switcher
                      | Keymap.Open_model_switcher
                      | Keymap.Teleport_blocked
                      | Keymap.Focus_composer
                      | Keymap.Focus_filter
                      | Keymap.Voice_ptt_toggle
                      | Keymap.Refresh
                      | Keymap.Toggle_tool_details
                      | Keymap.Toggle_thinking
                      | Keymap.Cycle_origin_mode
                      | Keymap.Interrupt_turn
                      | Keymap.Quit_app ->
                          `Allow
                      | Keymap.Account_login -> `Move_right
                      | Keymap.Fast_approve_top
                      | Keymap.Fast_deny_top
                      | Keymap.Confirm_selected
                      | Keymap.Ask_select_choice _
                      | Keymap.Composer_kill_word
                      | Keymap.Composer_newline
                      | Keymap.Submit_steer
                      | Keymap.Submit_followup
                      | Keymap.Toggle_expand
                      | Keymap.Create_new
                      | Keymap.Copy_selected
                      | Keymap.Open_external
                      | Keymap.Toggle_zoom
                      | Keymap.Cycle_memory_view
                      | Keymap.Toggle_memory_sort
                      | Keymap.Cycle_signal_or_source
                      | Keymap.Cycle_sort_or_speak
                      | Keymap.Cycle_hearth_or_overrule
                      | Keymap.Cycle_time_window
                      | Keymap.Cycle_view_mode
                      | Keymap.Context_primary_action
                      | Keymap.Toggle_artifact_share
                      | Keymap.Step_revision _
                      | Keymap.Step_context_item _
                      | Keymap.Launch_fusion
                      | Keymap.Toggle_unreported
                      | Keymap.Unbind_connector
                      | Keymap.Entity_approve_or_assign
                      | Keymap.Entity_reject_or_cancel
                      | Keymap.Edit_or_export
                      | Keymap.Configure_provider_key
                      | Keymap.Poll_account_login
                      | Keymap.Copy_hash
                      | Keymap.Dismiss_errors
                      | Keymap.Board_vote _
                      | Keymap.Toggle_memory_scope
                      | Keymap.Copy_public_url
                      | Keymap.Probe_sandbox
                      | Keymap.Refresh_browser_tabs
                      | Keymap.Open_memory_recovery
                      | Keymap.Search_prev_match
                      | Keymap.Toggle_memory_chart
                      | Keymap.Open_external_editor
                      | Keymap.Delete_selected
                      | Keymap.Link_task_goal
                      | Keymap.Keeper_wake_or_online
                      | Keymap.Keeper_stop_armed ->
                          `Ignore
                    in
                    match
                      Keymap.dispatch ~scope_chain:(Model.focus_scope_chain m)
                        norm
                    with
                    | Some act ->
                        if Model.sidebar_has_focus m then
                          match sidebar_action_gate act with
                          | `Allow -> Update_actions.execute_action ~now m act
                          | `Move_right -> Update_nav.apply_move m Keymap.Right
                          | `Ignore -> (m, [])
                        else Update_actions.execute_action ~now m act
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
                          | Keymap.Input.Up
                            when (not norm.mods.ctrl) && (not norm.mods.alt)
                                 && Drafts.current_draft_is_multiline m.drafts ->
                              ( {
                                  m with
                                  drafts =
                                    Drafts.move_cursor_vertical `Up m.drafts;
                                }
                              , [] )
                          | Keymap.Input.Down
                            when (not norm.mods.ctrl) && (not norm.mods.alt)
                                 && Drafts.current_draft_is_multiline m.drafts ->
                              ( {
                                  m with
                                  drafts =
                                    Drafts.move_cursor_vertical `Down m.drafts;
                                }
                              , [] )
                          | Keymap.Input.Page_up
                            when (not norm.mods.ctrl) && not norm.mods.alt ->
                              Update_nav.apply_move m Keymap.Page_up
                          | Keymap.Input.Page_down
                            when (not norm.mods.ctrl) && not norm.mods.alt ->
                              Update_nav.apply_move m Keymap.Page_down
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
    || (Model.equal_breakpoint m.breakpoint Model.Micro
        && Option.is_none m.nav.overlay)
  then (m, [])
  else
    match m.nav.overlay with
    | Some
        (Nav.System_gate
           (Nav.Micro_viewport | Nav.Auth_gate | Nav.Server_offline)) ->
        (m, [])
    | Some Nav.Palette ->
        let query = m.palette.query ^ strip_newlines text in
        ( {
            m with
            palette = { m.palette with query; selected = 0 };
            nav = { m.nav with palette_scroll_offset = 0 };
          }
        , [] )
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
              let cur_val = Model.modal_active_field_value modal in
              let cur_pos =
                Int.max 0 (Int.min (String.length cur_val) m.nav.modal_edit_cursor)
              in
              let next_val, next_cur =
                Update_nav.insert_at_cursor ~text:cur_val ~cursor:cur_pos
                  ~insert:text
              in
              ( {
                  m with
                  inline_modal =
                    Some
                      (Model.modal_update_active_field
                         (fun _ -> next_val)
                         modal);
                  nav = { m.nav with modal_edit_cursor = next_cur };
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
        Update_nav.set_active_filter_query q m
    | Some Nav.Ask_answer -> (
        match m.ask_modal with
        | Some modal when modal.editing_free_text && not modal.submitting ->
            ( {
                m with
                ask_modal =
                  Some
                    (Model.ask_modal_insert_free_text (strip_newlines text)
                       modal);
              }
            , [] )
        | Some _ | None -> (m, []))
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
          Update_nav.set_active_filter_query q m
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
  if
    Model.is_too_small_viewport m.viewport
    || (Model.equal_breakpoint m.breakpoint Model.Micro
        && Option.is_none m.nav.overlay)
  then (m, [])
  else
    let cancel_edit (m : Model.t) =
      if Config_store.is_editing_field m.config then
        { m with config = Config_store.cancel_edit_field m.config }
      else m
    in
    match ev with
    | Keymap.Input.Wheel { dir; col; row } -> (
        let m = Model.disarm_keeper_stop m in
        let gx = col - 1 in
        let gy = row - 1 in
        let move_dir =
          match dir with
          | Keymap.Input.Wheel_up -> Keymap.Up
          | Keymap.Input.Wheel_down -> Keymap.Down
        in
        let over_sidebar =
          Option.is_none m.nav.overlay
          &&
          match Model.sidebar_rect m with
          | Some sr -> Rect.contains sr ~x:gx ~y:gy
          | None -> false
        in
        if over_sidebar then
          (* Sidebar mouse wheel only scrolls the sidebar viewport — never
             navigates workspaces or destroys the active dive_stack. *)
          let inner_h =
            match Model.sidebar_rect m with
            | Some sr -> Int.max 1 (sr.h - 2)
            | None -> 10
          in
          let total_rows = List.length Model.sidebar_visual_rows in
          let max_scroll = Int.max 0 (total_rows - inner_h) in
          let delta =
            match dir with
            | Keymap.Input.Wheel_up -> -2
            | Keymap.Input.Wheel_down -> 2
          in
          let sidebar_scroll =
            Store_scroll.clamp_scroll ~max_scroll (m.nav.sidebar_scroll + delta)
          in
          ({ m with nav = { m.nav with sidebar_scroll } }, [])
        else
          let m_target =
            if Model.sidebar_has_focus m then Update_nav.exit_sidebar_focus m
            else m
          in
          let m_base = cancel_edit m_target in
          let hit_pane =
            if Option.is_some m_base.nav.overlay then None
            else
              let rects = Model.pane_rects m_base in
              let n = Model.focusable_pane_count m_base in
              let rec find i = function
                | [] -> None
                | r :: rest ->
                    if i < n && Rect.contains r ~x:gx ~y:gy then Some i
                    else find (i + 1) rest
              in
              find 0 rects
          in
          match hit_pane with
          | Some idx when not (Int.equal idx m_base.nav.pane_index) ->
              let orig_pane = m_base.nav.pane_index in
              let m_scrolled, cmds =
                Update_actions.execute_action ~now
                  { m_base with nav = { m_base.nav with pane_index = idx } }
                  (Keymap.Move move_dir)
              in
              let same_view =
                Nav.equal_workspace m_scrolled.nav.workspace m_base.nav.workspace
                && Option.equal Nav.equal_overlay m_scrolled.nav.overlay
                     m_base.nav.overlay
                && Int.equal
                     (List.length m_scrolled.nav.dive_stack)
                     (List.length m_base.nav.dive_stack)
              in
              let m_final =
                if same_view then
                  let max_p =
                    Int.max 0 (Model.focusable_pane_count m_scrolled - 1)
                  in
                  let restored = Int.max 0 (Int.min max_p orig_pane) in
                  {
                    m_scrolled with
                    nav = { m_scrolled.nav with pane_index = restored };
                  }
                else m_scrolled
              in
              (m_final, cmds)
          | Some _ | None ->
              Update_actions.execute_action ~now m_base (Keymap.Move move_dir))
    | Keymap.Input.Left_press { col; row } -> (
        if
          Option.is_some m.nav.overlay
          || Model.equal_breakpoint m.breakpoint Model.Micro
        then (m, [])
        else
          let m = m |> cancel_edit |> Model.disarm_keeper_stop in
          let gx = col - 1 in
          let gy = row - 1 in
          (* 1. Top Rail clickable [b] Menu toggle at cols 1..4, row 0 *)
          if gy = 0 && gx >= 1 && gx <= 4 then
            Update_actions.execute_action ~now m Keymap.Toggle_sidebar
          else
            match Model.sidebar_rect m with
            | Some sr when Rect.contains sr ~x:gx ~y:gy ->
                let inner =
                  Rect.make ~x:(sr.x + 1) ~y:(sr.y + 1)
                    ~w:(Int.max 0 (sr.w - 2))
                    ~h:(Int.max 0 (sr.h - 2))
                in
                if gy >= inner.y && gy < Rect.bottom inner then
                  let effective_cursor =
                    if Model.sidebar_has_focus m then m.nav.sidebar_cursor
                    else Nav.menu_item_index (Model.active_menu_target m)
                  in
                  let start =
                    Model.sidebar_viewport_start ~inner_h:inner.h
                      ~scroll:m.nav.sidebar_scroll ~cursor:effective_cursor
                  in
                  if
                    Model.sidebar_has_below_overflow ~inner_h:inner.h ~start
                    && gy = Rect.bottom inner - 1
                  then
                    let total_rows = List.length Model.sidebar_visual_rows in
                    let max_scroll = Int.max 0 (total_rows - inner.h) in
                    let step = Int.max 4 (inner.h / 2) in
                    let sidebar_scroll =
                      Store_scroll.clamp_scroll ~max_scroll (start + step)
                    in
                    let m_focused = Update_nav.enter_sidebar_focus m in
                    let next_cursor =
                      if sidebar_scroll >= max_scroll then
                        let rec last_item acc = function
                          | [] -> acc
                          | Model.Sidebar_item { index; _ } :: rest ->
                              last_item index rest
                          | Model.Sidebar_section _ :: rest -> last_item acc rest
                        in
                        last_item m_focused.nav.sidebar_cursor
                          Model.sidebar_visual_rows
                      else
                        let min_vis_idx = sidebar_scroll + 1 in
                        let rec first_item_from idx = function
                          | [] -> m_focused.nav.sidebar_cursor
                          | Model.Sidebar_item { index; _ } :: _
                            when idx >= min_vis_idx ->
                              index
                          | (Model.Sidebar_section _ | Model.Sidebar_item _)
                            :: rest ->
                              first_item_from (idx + 1) rest
                        in
                        first_item_from 0 Model.sidebar_visual_rows
                    in
                    ( {
                        m_focused with
                        nav =
                          {
                            m_focused.nav with
                            sidebar_cursor = next_cursor;
                            sidebar_scroll;
                          };
                      }
                    , [] )
                  else
                    let vis_idx = start + (gy - inner.y) in
                    match List.nth_opt Model.sidebar_visual_rows vis_idx with
                    | Some (Model.Sidebar_item { index; item }) ->
                        let m_sel =
                          {
                            m with
                            nav =
                              {
                                m.nav with
                                sidebar_cursor = index;
                                sidebar_scroll = start;
                              };
                          }
                        in
                        Update_nav.navigate_menu_target ~keep_sidebar_focus:false
                          m_sel item.target
                    | Some (Model.Sidebar_section _) | None ->
                        (Update_nav.enter_sidebar_focus m, [])
                else (Update_nav.enter_sidebar_focus m, [])
            | Some _ | None ->
                if Model.sidebar_drawer_open m then
                  (Update_nav.exit_sidebar_focus m, [])
                else
                  let body_r = Model.body_rect m in
                  if Rect.contains body_r ~x:gx ~y:gy then
                    let m0 =
                      let exited = Update_nav.exit_sidebar_focus m in
                      {
                        exited with
                        nav = { exited.nav with filter_focused = false };
                        drafts = Drafts.set_focus false m.drafts;
                      }
                    in
                    let panes = Model.focusable_pane_count m0 in
                    let rects = Model.pane_rects m0 in
                    let hit_pane =
                      let rec find i = function
                        | [] -> None
                        | r :: rest ->
                            if Rect.contains r ~x:gx ~y:gy then Some i
                            else find (i + 1) rest
                      in
                      find 0 rects
                    in
                    let next_pane =
                      match hit_pane with
                      | Some idx -> Int.min (Int.max 0 (panes - 1)) idx
                      | None ->
                          if panes <= 1 || body_r.w <= 0 then 0
                          else if gx < body_r.x + (body_r.w / 2) then 0
                          else Int.min (panes - 1) 1
                    in
                    ( Update_nav.clamp_for_pane
                        { m0 with nav = { m0.nav with pane_index = next_pane } }
                    , [] )
                  else
                    match Model.composer_rect m with
                    | Some cr when Rect.contains cr ~x:gx ~y:gy ->
                        let m0 = Update_nav.exit_sidebar_focus m in
                        ( {
                            m0 with
                            nav = { m0.nav with filter_focused = false };
                            drafts = Drafts.set_focus true m0.drafts;
                          }
                        , [] )
                    | Some _ | None -> (m, []))
    | Keymap.Input.Left_drag _ | Keymap.Input.Left_release _ -> (m, [])
