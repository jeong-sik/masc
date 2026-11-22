open Masc_tui_core
open Masc_tui_keymap

let is_printable_key (ev : Keymap.Input.key_event) =
  (not ev.mods.ctrl) && not ev.mods.alt

let strip_newlines s =
  String.map (function '\n' | '\r' -> ' ' | c -> c) s

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
      Some (Update_actions.execute_action ~now m Keymap.Create_new)
  | Keymap.Input.Char "n" when is_printable_key norm ->
      Some (Update_actions.execute_action ~now m Keymap.Create_new)
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
  | Keymap.Input.Delete
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
  | Keymap.Input.Char "c" when is_printable_key norm ->
      Some ({ m with incidents = Incidents.clear_all m.incidents }, [])
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
          | Some (Nav.Queue_context _ | Nav.Help | Nav.System_gate _) | None -> (
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
                        ({ m with drafts = Drafts.delete_forward m.drafts }, [])
                    | Keymap.Input.Left ->
                        ( { m with drafts = Drafts.move_cursor `Left m.drafts }
                        , [] )
                    | Keymap.Input.Right ->
                        ( { m with drafts = Drafts.move_cursor `Right m.drafts }
                        , [] )
                    | Keymap.Input.Home ->
                        ( { m with drafts = Drafts.move_cursor `Home m.drafts }
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
                  else
                    let is_u_toggle =
                      match norm.key with
                      | Keymap.Input.Char "u" -> is_printable_key norm
                      | Keymap.Input.Char _
                      | Keymap.Input.Enter
                      | Keymap.Input.Tab
                      | Keymap.Input.Backspace
                      | Keymap.Input.Delete
                      | Keymap.Input.Escape
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
                    let on_quotas =
                      Nav.equal_workspace m.nav.workspace Nav.Runtime
                      && Nav.equal_runtime_tab m.runtime.active_tab
                           Nav.Runtime_quotas_credits
                    in
                    if is_u_toggle && on_quotas && Option.is_none m.nav.overlay then
                      ( {
                          m with
                          runtime =
                            Runtime_store.toggle_unreported_accounts m.runtime;
                        }
                      , [] )
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
