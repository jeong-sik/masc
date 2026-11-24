open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

let is_utf8_cont b = b land 0xC0 = 0x80

let drop_last_utf8 s =
  let len = String.length s in
  if len <= 0 then ""
  else
    let rec prev i =
      if i <= 0 then 0
      else if is_utf8_cont (Char.code s.[i]) then prev (i - 1)
      else i
    in
    String.sub s 0 (prev (len - 1))

let clamp_utf8_cursor s idx =
  let len = String.length s in
  let c = max 0 (min len idx) in
  let rec align i =
    if i <= 0 || i >= len then i
    else if is_utf8_cont (Char.code s.[i]) then align (i - 1)
    else i
  in
  align c

let prev_utf8_boundary s idx =
  let i = clamp_utf8_cursor s idx in
  if i <= 0 then 0
  else
    let rec walk p =
      if p <= 0 then 0
      else if is_utf8_cont (Char.code s.[p]) then walk (p - 1)
      else p
    in
    walk (i - 1)

let next_utf8_boundary s idx =
  let len = String.length s in
  let i = clamp_utf8_cursor s idx in
  if i >= len then len
  else
    let rec walk p =
      if p >= len then len
      else if is_utf8_cont (Char.code s.[p]) then walk (p + 1)
      else p
    in
    walk (i + 1)

let insert_at_cursor ~text ~cursor ~insert =
  let len = String.length text in
  let c = clamp_utf8_cursor text cursor in
  let before = String.sub text 0 c in
  let after = String.sub text c (len - c) in
  (before ^ insert ^ after, c + String.length insert)

let backspace_at_cursor ~text ~cursor =
  let len = String.length text in
  let c = clamp_utf8_cursor text cursor in
  if c <= 0 then (text, 0)
  else
    let prev = prev_utf8_boundary text c in
    (String.sub text 0 prev ^ String.sub text c (len - c), prev)

let delete_at_cursor ~text ~cursor =
  let len = String.length text in
  let c = clamp_utf8_cursor text cursor in
  if c >= len then (text, c)
  else
    let next = next_utf8_boundary text c in
    (String.sub text 0 c ^ String.sub text next (len - next), c)

let move_cursor_utf8 dir ~text ~cursor =
  let len = String.length text in
  let c = clamp_utf8_cursor text cursor in
  match dir with
  | `Left -> prev_utf8_boundary text c
  | `Right -> next_utf8_boundary text c
  | `Home -> 0
  | `End -> len

let kill_to_start ~text ~cursor =
  let len = String.length text in
  let c = clamp_utf8_cursor text cursor in
  if c <= 0 then (text, 0) else (String.sub text c (len - c), 0)

let kill_word_back ~text ~cursor =
  let len = String.length text in
  let c = clamp_utf8_cursor text cursor in
  if c <= 0 then (text, 0)
  else
    let is_sep ch = Char.equal ch ' ' || Char.equal ch '\t' || Char.equal ch '/' in
    let rec skip_sep i =
      if i > 0 && is_sep text.[i - 1] then skip_sep (i - 1) else i
    in
    let rec skip_word i =
      if i > 0 && not (is_sep text.[i - 1]) then
        skip_word (prev_utf8_boundary text i)
      else i
    in
    let start = skip_word (skip_sep c) in
    (String.sub text 0 start ^ String.sub text c (len - c), start)

let contains_ci = Store_scroll.contains_ci
let clamp_index = Store_scroll.clamp_index

let utf8_folded_uchars s =
  let len = String.length s in
  let rec loop i acc =
    if i >= len then Array.of_list (List.rev acc)
    else
      let d = String.get_utf_8_uchar s i in
      let n = Uchar.utf_decode_length d in
      let u = Uchar.utf_decode_uchar d in
      let code = Uchar.to_int u in
      let folded =
        if code >= Char.code 'A' && code <= Char.code 'Z' then
          Uchar.of_int (code + 32)
        else u
      in
      loop (i + max 1 n) (folded :: acc)
  in
  loop 0 []

let fuzzy_score ~query target =
  let q = String.lowercase_ascii (String.trim query) in
  let q_len = String.length q in
  if q_len = 0 then Some 100
  else
    let t = String.lowercase_ascii target in
    let t_len = String.length t in
    if String.equal q t then Some 1000
    else if String.starts_with ~prefix:q t then Some (800 - (t_len - q_len))
    else if contains_ci ~needle:q t then Some (500 - (t_len - q_len))
    else
      let qa = utf8_folded_uchars q in
      let ta = utf8_folded_uchars t in
      let qn = Array.length qa in
      let tn = Array.length ta in
      if qn > tn then None
      else
        let rec match_seq qi ti score consecutive =
          if qi >= qn then Some (Int.max 1 score)
          else if ti >= tn then None
          else if Uchar.equal qa.(qi) ta.(ti) then
            let bonus = if consecutive then 12 else 4 in
            let start_bonus = if ti = 0 then 10 else 0 in
            match_seq (qi + 1) (ti + 1) (score + bonus + start_bonus) true
          else match_seq qi (ti + 1) (score - 1) false
        in
        match_seq 0 0 100 false

let trim_left s =
  let len = String.length s in
  let rec skip i =
    if i < len && (Char.equal s.[i] ' ' || Char.equal s.[i] '\t') then
      skip (i + 1)
    else i
  in
  let start = skip 0 in
  if start = 0 then s else String.sub s start (len - start)

type popup_candidate_kind =
  | Popup_slash_cmd of Slash.spec
  | Popup_slash_arg of {
      spec : Slash.spec;
      arg : string;
      full_text : string;
    }
  | Popup_mention of Wire_fleet.keeper_summary

type popup_candidate = {
  kind : popup_candidate_kind;
  trigger : string;
  label : string;
  detail : string option;
}

type composer_popup =
  | Composer_popup_none
  | Composer_popup_slash of {
      query : string;
      items : popup_candidate list;
      selected : int;
    }
  | Composer_popup_mention of {
      query : string;
      items : popup_candidate list;
      selected : int;
    }

let slash_spec_takes_arg (spec : Slash.spec) = Option.is_some spec.arg_hint

let slash_spec_requires_arg (spec : Slash.spec) =
  match spec.id with
  | Slash.Cmd_btw -> true
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
  | Slash.Cmd_queue
  | Slash.Cmd_context
  | Slash.Cmd_tools
  | Slash.Cmd_clear
  | Slash.Cmd_theme
  | Slash.Cmd_lang
  | Slash.Cmd_help
  | Slash.Cmd_restart
  | Slash.Cmd_quit ->
      false

let resolve_slash_arg_candidates (m : Model.t) (spec : Slash.spec) ~arg_raw =
  match spec.id with
  | Slash.Cmd_theme | Slash.Cmd_lang | Slash.Cmd_tools ->
      let prefix_matches = Slash.complete ~prefix:(spec.name ^ " " ^ arg_raw) in
      let all_for_cmd =
        if prefix_matches <> [] then prefix_matches
        else
          Slash.complete ~prefix:(spec.name ^ " ")
          |> List.filter (fun full -> contains_ci ~needle:arg_raw full)
      in
      List.filter_map
        (fun full ->
          match String.index_opt full ' ' with
          | None -> None
          | Some sp ->
              let arg =
                String.trim (String.sub full (sp + 1) (String.length full - sp - 1))
              in
              Some
                {
                  kind = Popup_slash_arg { spec; arg; full_text = full };
                  trigger = full;
                  label = Say.resolve m.lang spec.description;
                  detail = Some arg;
                })
        all_for_cmd
  | Slash.Cmd_keeper ->
      let rank_keeper (k : Wire_fleet.keeper_summary) =
        let q = String.lowercase_ascii (String.trim arg_raw) in
        let n = String.lowercase_ascii k.name in
        if String.equal q "" then 0
        else if String.equal n q then 0
        else if String.starts_with ~prefix:q n then 1
        else if contains_ci ~needle:q k.name then 2
        else 3
      in
      Fleet_store.filtered_keepers { m.fleet with filter_query = "" }
      |> List.filter (fun (k : Wire_fleet.keeper_summary) ->
             contains_ci ~needle:arg_raw k.name
             || contains_ci ~needle:arg_raw k.company)
      |> List.stable_sort (fun a b ->
             Int.compare (rank_keeper a) (rank_keeper b))
      |> List.map (fun (k : Wire_fleet.keeper_summary) ->
             let full_text = spec.name ^ " " ^ k.name in
             {
               kind = Popup_slash_arg { spec; arg = k.name; full_text };
               trigger = full_text;
               label = k.company;
               detail = Some k.runtime_id;
             })
  | Slash.Cmd_model ->
      let rank_model (r : Wire_runtime.runtime_option) =
        let q = String.lowercase_ascii (String.trim arg_raw) in
        let id = String.lowercase_ascii r.id in
        if String.equal q "" then 0
        else if String.equal id q then 0
        else if String.starts_with ~prefix:q id then 1
        else if contains_ci ~needle:q r.id then 2
        else 3
      in
      Runtime_store.runtime_options m.runtime
      |> List.filter (fun (r : Wire_runtime.runtime_option) ->
             contains_ci ~needle:arg_raw r.id
             || contains_ci ~needle:arg_raw r.provider
             ||
             match r.model with
             | Some mdl -> contains_ci ~needle:arg_raw mdl
             | None -> false)
      |> List.stable_sort (fun a b -> Int.compare (rank_model a) (rank_model b))
      |> List.map (fun (r : Wire_runtime.runtime_option) ->
             let full_text = spec.name ^ " " ^ r.id in
             {
               kind = Popup_slash_arg { spec; arg = r.id; full_text };
               trigger = full_text;
               label = r.provider;
               detail = r.model;
             })
  | Slash.Cmd_pulse
  | Slash.Cmd_work
  | Slash.Cmd_knowledge
  | Slash.Cmd_keepers
  | Slash.Cmd_runtime
  | Slash.Cmd_infra
  | Slash.Cmd_config
  | Slash.Cmd_incidents
  | Slash.Cmd_jump
  | Slash.Cmd_voice
  | Slash.Cmd_btw
  | Slash.Cmd_queue
  | Slash.Cmd_context
  | Slash.Cmd_clear
  | Slash.Cmd_help
  | Slash.Cmd_restart
  | Slash.Cmd_quit ->
      []

let resolve_composer_popup (m : Model.t) : composer_popup =
  if
    Option.is_some m.nav.overlay
    || (not (Drafts.is_focused m.drafts))
    || m.drafts.popup_dismissed
  then Composer_popup_none
  else
    let draft = Drafts.current_draft m.drafts in
    let text = draft.text in
    let len = String.length text in
    let cursor = max 0 (min len draft.cursor) in
    let prefix = String.sub text 0 cursor in
    let left_trimmed = trim_left text in
    let lt_len = String.length left_trimmed in
    let leading_spaces = len - lt_len in
    if
      lt_len > 0
      && Char.equal left_trimmed.[0] '/'
      && (not (String.contains text '\n'))
      && cursor > leading_spaces
    then
      let prefix_trimmed = trim_left prefix in
      let pt_len = String.length prefix_trimmed in
      match String.index_opt prefix_trimmed ' ' with
      | None ->
          let query = String.sub prefix_trimmed 1 (max 0 (pt_len - 1)) in
          let specs = Slash.filter ~query ~lang:m.lang in
          let items =
            List.map
              (fun (s : Slash.spec) ->
                {
                  kind = Popup_slash_cmd s;
                  trigger = s.name;
                  label = Say.resolve m.lang s.description;
                  detail = Option.map (Say.resolve m.lang) s.arg_hint;
                })
              specs
          in
          if items = [] then Composer_popup_none
          else
            let selected =
              clamp_index (List.length items) m.drafts.popup_selected
            in
            Composer_popup_slash { query; items; selected }
      | Some sp -> (
          let cmd_tok =
            String.lowercase_ascii (String.sub prefix_trimmed 0 sp)
          in
          let arg_raw =
            String.trim
              (String.sub prefix_trimmed (sp + 1) (pt_len - sp - 1))
          in
          match
            List.find_opt
              (fun (s : Slash.spec) ->
                String.equal (String.lowercase_ascii s.name) cmd_tok)
              Slash.all
          with
          | None -> Composer_popup_none
          | Some spec ->
              let items = resolve_slash_arg_candidates m spec ~arg_raw in
              if items = [] then Composer_popup_none
              else
                let selected =
                  clamp_index (List.length items) m.drafts.popup_selected
                in
                Composer_popup_slash { query = arg_raw; items; selected })
    else
      match String.rindex_opt prefix '@' with
      | Some idx
        when idx = 0
             || Char.equal prefix.[idx - 1] ' '
             || Char.equal prefix.[idx - 1] '\n' ->
          let after = String.sub prefix (idx + 1) (cursor - idx - 1) in
          if String.contains after ' ' || String.contains after '\n' then
            Composer_popup_none
          else
            let rank_keeper (k : Wire_fleet.keeper_summary) =
              let q = String.lowercase_ascii (String.trim after) in
              let n = String.lowercase_ascii k.name in
              if String.equal q "" then 0
              else if String.equal n q then 0
              else if String.starts_with ~prefix:q n then 1
              else if contains_ci ~needle:q k.name then 2
              else 3
            in
            let keepers =
              Fleet_store.filtered_keepers { m.fleet with filter_query = "" }
              |> List.filter (fun (k : Wire_fleet.keeper_summary) ->
                     contains_ci ~needle:after k.name
                     || contains_ci ~needle:after k.company)
              |> List.stable_sort (fun a b ->
                     Int.compare (rank_keeper a) (rank_keeper b))
            in
            let items =
              List.map
                (fun (k : Wire_fleet.keeper_summary) ->
                  {
                    kind = Popup_mention k;
                    trigger = "@" ^ k.name;
                    label = k.company;
                    detail = Some k.runtime_id;
                  })
                keepers
            in
            if items = [] then Composer_popup_none
            else
              let selected =
                clamp_index (List.length items) m.drafts.popup_selected
              in
              Composer_popup_mention { query = after; items; selected }
      | Some _ | None -> Composer_popup_none

let apply_popup_completion (cand : popup_candidate) (m : Model.t) : Model.t =
  match cand.kind with
  | Popup_slash_cmd spec ->
      let completed =
        if slash_spec_takes_arg spec then spec.name ^ " " else spec.name
      in
      { m with drafts = Drafts.set_current_text completed m.drafts }
  | Popup_slash_arg { full_text; _ } ->
      { m with drafts = Drafts.set_current_text full_text m.drafts }
  | Popup_mention k ->
      let draft = Drafts.current_draft m.drafts in
      let len = String.length draft.text in
      let cursor = max 0 (min len draft.cursor) in
      let prefix = String.sub draft.text 0 cursor in
      let suffix = String.sub draft.text cursor (len - cursor) in
      let before =
        match String.rindex_opt prefix '@' with
        | Some idx -> String.sub prefix 0 idx
        | None -> prefix
      in
      let trailing =
        if String.starts_with ~prefix:" " suffix then "" else " "
      in
      let inserted = "@" ^ k.name ^ trailing in
      let next_text = before ^ inserted ^ suffix in
      let next_cursor = String.length before + String.length inserted in
      let drafts =
        if String.equal (String.trim before) "" then
          (* Leading @mention switches the target keeper directly so pressing
             Enter routes to the mentioned keeper instead of the previous one. *)
          let d0 =
            if String.equal (String.trim suffix) "" then
              Drafts.clear_current_draft m.drafts
            else m.drafts
          in
          d0
          |> Drafts.set_active_keeper k.name
          |> Drafts.set_current_text_and_cursor ~text:next_text
               ~cursor:next_cursor
        else
          Drafts.set_current_text_and_cursor ~text:next_text ~cursor:next_cursor
            m.drafts
      in
      { m with drafts }

type palette_section =
  | Pal_sec_commands
  | Pal_sec_workspaces
  | Pal_sec_keepers
  | Pal_sec_companies
  | Pal_sec_goals_tasks
  | Pal_sec_board_wiki
  | Pal_sec_sandboxes
  | Pal_sec_settings
  | Pal_sec_slash

type palette_action =
  | Pal_keymap_action of Keymap.action
  | Pal_menu_target of Nav.menu_target
  | Pal_dive_keeper of string
  | Pal_select_company of string
  | Pal_dive_goal of string
  | Pal_dive_task of string
  | Pal_dive_thread of string
  | Pal_dive_wiki of string
  | Pal_dive_sandbox of string
  | Pal_open_infra_sandboxes of string
  | Pal_open_setting of {
      full_key : string;
      tab : Nav.settings_tab;
    }
  | Pal_slash_spec of Slash.spec

type palette_entry = {
  section : palette_section;
  badge : string;
  title : string;
  meta : string;
  tone : Theme.status_token option;
  action : palette_action;
}

let keeper_health_glyph_and_tone = function
  | Wire_fleet.Keeper_healthy -> (Glyph.Live_healthy, Theme.Status_ok)
  | Wire_fleet.Keeper_working -> (Glyph.Live_working, Theme.Status_active)
  | Wire_fleet.Keeper_idle -> (Glyph.Live_idle, Theme.Status_historical)
  | Wire_fleet.Keeper_degraded ->
      (Glyph.Warning_triangle, Theme.Status_attention)
  | Wire_fleet.Keeper_recovering | Wire_fleet.Keeper_booting ->
      (Glyph.Transport_reconnecting, Theme.Status_active)
  | Wire_fleet.Keeper_failing | Wire_fleet.Keeper_offline ->
      (Glyph.Live_failing, Theme.Status_critical)
  | Wire_fleet.Keeper_paused -> (Glyph.Live_paused, Theme.Status_historical)

let take_n n xs =
  let rec go k acc = function
    | _ when k <= 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: rest -> go (k - 1) (x :: acc) rest
  in
  go n [] xs

let expected_workspace_of (m : Model.t) : Wire_work.expected_workspace option =
  match m.server_identity.workspace with
  | Some ws -> Some { base_path = ws.base_path; masc_root = ws.masc_root }
  | None -> None

let sync_config_for_keeper_tab ~name ~tab (config : Config_store.t) =
  match tab with
  | Nav.Keeper_config ->
      let config = Config_store.set_target (Wire_config.Target_keeper name) config in
      if Nav.equal_settings_tab config.active_tab Nav.Settings_general_ui then
        Config_store.set_tab Nav.Settings_keepers_companies config
      else config
  | Nav.Keeper_chat
  | Nav.Keeper_context
  | Nav.Keeper_tool_calls
  | Nav.Keeper_memory
  | Nav.Keeper_work_candle
  | Nav.Keeper_sandbox
  | Nav.Keeper_logs
  | Nav.Keeper_identity ->
      Config_store.cancel_edit_field config

let sync_fleet_for_keeper_tab ~name ~tab fleet =
  match tab with
  | Nav.Keeper_chat -> Fleet_store.mark_chat_history_loading ~keeper:name fleet
  | Nav.Keeper_context
  | Nav.Keeper_tool_calls
  | Nav.Keeper_memory
  | Nav.Keeper_work_candle
  | Nav.Keeper_sandbox
  | Nav.Keeper_config
  | Nav.Keeper_logs
  | Nav.Keeper_identity ->
      fleet

let sync_config_for_keeper_view (m : Model.t) =
  match m.nav.overlay with
  | Some (Nav.Settings _) -> m
  | Some
      ( Nav.Palette
      | Nav.Incidents
      | Nav.Queue_context _
      | Nav.Inline_action _
      | Nav.Ask_answer
      | Nav.Help
      | Nav.System_gate _ )
  | None -> (
      match Model.active_dive m with
      | Some (Nav.Dive_keeper { name; tab }) ->
          {
            m with
            config = sync_config_for_keeper_tab ~name ~tab m.config;
            fleet = sync_fleet_for_keeper_tab ~name ~tab m.fleet;
          }
      | Some
          ( Nav.Dive_work _
          | Nav.Dive_knowledge _
          | Nav.Dive_runtime _
          | Nav.Dive_infra _ ) ->
          m
      | None -> (
          match m.nav.workspace, Fleet_store.selected_keeper_summary m.fleet with
          | Nav.Keepers, Some k ->
              let knowledge =
                if Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_memory
                then
                  if
                    Option.equal String.equal m.knowledge.memory_diff_keeper
                      (Some k.name)
                  then m.knowledge
                  else
                    Knowledge_store.set_memory_diff_keeper (Some k.name)
                      m.knowledge
                else
                  m.knowledge
                  |> Knowledge_store.close_memory_reading
                  |> Knowledge_store.close_memory_diagram
              in
              {
                m with
                config =
                  sync_config_for_keeper_tab ~name:k.name
                    ~tab:m.fleet.keeper_dive_tab m.config;
                fleet =
                  sync_fleet_for_keeper_tab ~name:k.name
                    ~tab:m.fleet.keeper_dive_tab m.fleet;
                knowledge;
              }
          | Nav.Keepers, None ->
              {
                m with
                knowledge =
                  m.knowledge
                  |> Knowledge_store.close_memory_reading
                  |> Knowledge_store.close_memory_diagram;
              }
          | (Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Runtime | Nav.Infra), _ ->
              m))

let close_drawer_if_floating (m : Model.t) =
  if Model.sidebar_drawer_open m then None else m.nav.sidebar_open

let exit_sidebar_focus (m : Model.t) =
  {
    m with
    nav =
      {
        m.nav with
        sidebar_focused = false;
        sidebar_open = close_drawer_if_floating m;
      };
  }

let sidebar_inner_height (m : Model.t) =
  match Model.sidebar_rect m with
  | Some sr -> Int.max 1 (sr.h - 2)
  | None -> Int.max 1 (Model.inner_body_height m - 2)

let enter_sidebar_focus (m : Model.t) =
  let cursor = Nav.menu_item_index (Model.active_menu_target m) in
  let inner_h = sidebar_inner_height m in
  let scroll =
    Model.sidebar_viewport_start ~inner_h ~scroll:m.nav.sidebar_scroll ~cursor
  in
  {
    m with
    nav =
      {
        m.nav with
        overlay = None;
        filter_focused = false;
        sidebar_focused = true;
        sidebar_cursor = cursor;
        sidebar_scroll = scroll;
      };
    drafts = Drafts.set_focus false m.drafts;
    config = Config_store.cancel_edit_field m.config;
    inline_modal = None;
    ask_modal = None;
  }
let switch_workspace (m : Model.t) ws =
  let nav =
    {
      m.nav with
      workspace = ws;
      dive_stack = [];
      overlay = None;
      pane_index = 0;
      zoomed = false;
      filter_focused = false;
      sidebar_focused = false;
      sidebar_open = close_drawer_if_floating m;
      dive_scroll_offset = 0;
      json_scroll_offset = 0;
    }
  in
  let drafts = Drafts.set_focus false m.drafts in
  let config = Config_store.cancel_edit_field m.config in
  let knowledge =
    m.knowledge
    |> Knowledge_store.close_memory_reading
    |> Knowledge_store.close_memory_diagram
    |> Knowledge_store.clear_pending_wiki_edit
    |> Knowledge_store.clear_armed_vote
    |> Knowledge_store.clear_pending_artifact_revision
  in
  let next =
    {
      m with
      nav;
      drafts;
      config;
      knowledge;
      inline_modal = None;
      ask_modal = None;
    }
    |> sync_config_for_keeper_view
    |> Model.sync_sidebar_cursor
  in
  (next, View_fetches.fetches_for_current_view next)

let refresh_queue_on_entry (m : Model.t) =
  if Option.equal Nav.equal_overlay m.nav.overlay
       (Some (Nav.Queue_context Nav.Drawer_queue)) then
    match Model.target_keeper m with
    | Some keeper ->
        let queue = Fleet_store.chat_queue_for ~keeper m.fleet in
        let fleet =
          Fleet_store.set_chat_queue ~keeper
            { queue with read = Observed.mark_stale queue.read } m.fleet
        in
        { m with fleet }
    | None -> m
  else m

let open_overlay (m : Model.t) overlay =
  let help_scroll_offset =
    match overlay with
    | Nav.Help -> 0
    | Nav.Palette
    | Nav.Settings _
    | Nav.Incidents
    | Nav.Queue_context _
    | Nav.Inline_action _
    | Nav.Ask_answer
    | Nav.System_gate _ ->
        m.nav.help_scroll_offset
  in
  let queue_scroll_offset =
    match overlay with
    | Nav.Queue_context _ -> 0
    | Nav.Palette
    | Nav.Settings _
    | Nav.Incidents
    | Nav.Inline_action _
    | Nav.Ask_answer
    | Nav.Help
    | Nav.System_gate _ ->
        m.nav.queue_scroll_offset
  in
  let return_overlay =
    match overlay, m.nav.overlay with
    | ( Nav.Help
      , Some
          ( ( Nav.Settings _
            | Nav.Incidents
            | Nav.Queue_context _
            | Nav.Ask_answer
            | Nav.System_gate Nav.Media_viewer ) as prev ) ) ->
        Some prev
    | Nav.Help, Some Nav.Help -> m.nav.return_overlay
    | ( Nav.Help
      , ( Some
            ( Nav.Palette
            | Nav.Inline_action _
            | Nav.System_gate
                (Nav.Auth_gate | Nav.Server_offline | Nav.Micro_viewport) )
        | None ) )
    | ( ( Nav.Palette
        | Nav.Settings _
        | Nav.Incidents
        | Nav.Queue_context _
        | Nav.Inline_action _
        | Nav.Ask_answer
        | Nav.System_gate _ )
      , (Some _ | None) ) ->
        None
  in
  let nav =
    {
      m.nav with
      overlay = Some overlay;
      return_overlay;
      filter_focused = false;
      sidebar_focused = false;
      sidebar_open = close_drawer_if_floating m;
      help_scroll_offset;
      queue_scroll_offset;
      btw_scroll_offset = 0;
      palette_scroll_offset = 0;
      modal_edit_cursor = 0;
    }
  in
  let drafts = Drafts.set_focus false m.drafts in
  let config =
    (match overlay, m.config.target with
    | Nav.Settings _, Wire_config.Target_keeper_create -> m.config
    | ( ( Nav.Settings _
        | Nav.Palette
        | Nav.Incidents
        | Nav.Queue_context _
        | Nav.Inline_action _
        | Nav.Ask_answer
        | Nav.Help
        | Nav.System_gate _ )
      , ( Wire_config.Target_runtime
        | Wire_config.Target_keeper _
        | Wire_config.Target_keeper_create ) ) ->
        Config_store.cancel_edit_field m.config)
    |> Config_store.disarm_discard_confirm
  in
  let incidents = Incidents.disarm_clear_confirm m.incidents in
  let knowledge =
    (match overlay with
    | Nav.System_gate Nav.Media_viewer ->
        { m.knowledge with detail_scroll_offset = 0 }
    | Nav.Palette
    | Nav.Settings _
    | Nav.Incidents
    | Nav.Queue_context _
    | Nav.Inline_action _
    | Nav.Ask_answer
    | Nav.Help
    | Nav.System_gate
        (Nav.Auth_gate | Nav.Server_offline | Nav.Micro_viewport) ->
        m.knowledge)
    |> Knowledge_store.clear_pending_wiki_edit
  in
  let ask_modal =
    match overlay with
    | Nav.Ask_answer -> m.ask_modal
    | Nav.Palette
    | Nav.Settings _
    | Nav.Incidents
    | Nav.Queue_context _
    | Nav.Inline_action _
    | Nav.Help
    | Nav.System_gate _ ->
        None
  in
  let inline_modal =
    match overlay with
    | Nav.Inline_action kind -> Some (Model.inline_modal_for kind)
    | Nav.Palette
    | Nav.Settings _
    | Nav.Incidents
    | Nav.Queue_context _
    | Nav.Ask_answer
    | Nav.Help
    | Nav.System_gate _ ->
        None
  in
  let next =
    { m with nav; drafts; config; incidents; knowledge; inline_modal; ask_modal }
    |> Model.sync_sidebar_cursor |> refresh_queue_on_entry
  in
  (next, View_fetches.fetches_for_current_view next)

let open_global_settings ?search_query (m : Model.t) =
  let config =
    m.config
    |> Config_store.set_target Wire_config.Target_runtime
    |> Config_store.set_tab Nav.Settings_general_ui
  in
  let config =
    match search_query with
    | Some q -> Config_store.set_search_query q config
    | None -> config
  in
  open_overlay { m with config } (Nav.Settings config.active_tab)

let select_settings_tab (m : Model.t) tab =
  let config = Config_store.set_tab tab m.config in
  let nav = { m.nav with overlay = Some (Nav.Settings tab) } in
  let next = { m with nav; config } in
  (next, View_fetches.fetches_for_current_view next)

let push_dive (m : Model.t) dive =
  let nav =
    {
      m.nav with
      dive_stack = dive :: m.nav.dive_stack;
      overlay = None;
      pane_index = 0;
      zoomed = false;
      filter_focused = false;
      sidebar_focused = false;
      sidebar_open = close_drawer_if_floating m;
      dive_scroll_offset = 0;
      json_scroll_offset = 0;
    }
  in
  let drafts =
    match dive with
    | Nav.Dive_keeper { name; _ } ->
        m.drafts |> Drafts.set_active_keeper name |> Drafts.set_focus false
    | Nav.Dive_work _
    | Nav.Dive_knowledge _
    | Nav.Dive_runtime _
    | Nav.Dive_infra _ ->
        Drafts.set_focus false m.drafts
  in
  let fleet =
    match dive with
    | Nav.Dive_keeper { name; tab } ->
        m.fleet
        |> Fleet_store.select_keeper name
        |> Fleet_store.set_keeper_dive_tab tab
        |> sync_fleet_for_keeper_tab ~name ~tab
    | Nav.Dive_work _
    | Nav.Dive_knowledge _
    | Nav.Dive_runtime _
    | Nav.Dive_infra _ ->
        m.fleet
  in
  let config =
    match dive with
    | Nav.Dive_keeper { name; tab } ->
        sync_config_for_keeper_tab ~name ~tab m.config
    | Nav.Dive_work _
    | Nav.Dive_knowledge _
    | Nav.Dive_runtime _
    | Nav.Dive_infra _ ->
        Config_store.cancel_edit_field m.config
  in
  let infra = { m.infra with show_raw_json = false } in
  let knowledge =
    let base =
      m.knowledge |> Knowledge_store.clear_armed_vote
      |> Knowledge_store.clear_pending_artifact_revision
    in
    match dive with
    | Nav.Dive_keeper { name; tab = Nav.Keeper_memory } ->
        base
        |> Knowledge_store.close_memory_diagram
        |> Knowledge_store.set_memory_diff_keeper (Some name)
    | Nav.Dive_knowledge (Nav.Memory_diff_dive { keeper; _ }) ->
        if Option.equal String.equal base.memory_diff_keeper keeper then
          base
          |> Knowledge_store.close_memory_reading
          |> Knowledge_store.close_memory_diagram
        else
          base
          |> Knowledge_store.close_memory_diagram
          |> Knowledge_store.set_memory_diff_keeper keeper
    | Nav.Dive_keeper
        {
          tab =
            ( Nav.Keeper_chat
            | Nav.Keeper_context
            | Nav.Keeper_tool_calls
            | Nav.Keeper_work_candle
            | Nav.Keeper_sandbox
            | Nav.Keeper_config
            | Nav.Keeper_logs
            | Nav.Keeper_identity );
          _;
        }
    | Nav.Dive_work _
    | Nav.Dive_knowledge
        (Nav.Thread_dive _ | Nav.Wiki_dive _ | Nav.Artifact_dive _)
    | Nav.Dive_runtime _
    | Nav.Dive_infra _ ->
        base
        |> Knowledge_store.close_memory_reading
        |> Knowledge_store.close_memory_diagram
        |> Knowledge_store.clear_pending_wiki_edit
  in
  let next =
    {
      m with
      nav;
      drafts;
      fleet;
      config;
      knowledge;
      infra;
      inline_modal = None;
      ask_modal = None;
    }
  in
  (next, View_fetches.fetches_for_current_view next)

let navigate_menu_target ?(keep_sidebar_focus = false) (m : Model.t)
    (target : Nav.menu_target) =
  let preserve_sidebar (next, cmds) =
    if not keep_sidebar_focus then (next, cmds)
    else
      let cursor = Nav.menu_item_index target in
      let inner_h = sidebar_inner_height next in
      let scroll =
        Model.sidebar_viewport_start ~inner_h ~scroll:m.nav.sidebar_scroll
          ~cursor
      in
      ( {
          next with
          nav =
            {
              next.nav with
              sidebar_open = m.nav.sidebar_open;
              sidebar_focused = true;
              sidebar_cursor = cursor;
              sidebar_scroll = scroll;
            };
        }
      , cmds )
  in
  match target with
  | Nav.Menu_pulse -> switch_workspace m Nav.Pulse |> preserve_sidebar
  | Nav.Menu_work tab ->
      let work =
        if Nav.equal_work_tab m.work.active_tab tab then m.work
        else Work_store.set_tab tab m.work
      in
      switch_workspace { m with work } Nav.Work |> preserve_sidebar
  | Nav.Menu_knowledge tab ->
      let knowledge =
        if Nav.equal_knowledge_tab m.knowledge.active_tab tab then m.knowledge
        else Knowledge_store.set_tab tab m.knowledge
      in
      switch_workspace { m with knowledge } Nav.Knowledge |> preserve_sidebar
  | Nav.Menu_keepers -> switch_workspace m Nav.Keepers |> preserve_sidebar
  | Nav.Menu_keeper_tab tab ->
      let fleet = Fleet_store.set_keeper_dive_tab tab m.fleet in
      let m1, cmds1 = switch_workspace { m with fleet } Nav.Keepers in
      let next, cmds =
        match Fleet_store.selected_keeper_summary m1.fleet with
        | Some _ when Model.focusable_pane_count m1 >= 2 ->
            let m2 =
              { m1 with nav = { m1.nav with pane_index = 1 } }
              |> sync_config_for_keeper_view
              |> Model.sync_sidebar_cursor
            in
            (m2, cmds1 @ View_fetches.fetches_for_current_view m2)
        | Some k when not keep_sidebar_focus ->
            let m2, cmds2 =
              push_dive m1 (Nav.Dive_keeper { name = k.name; tab })
            in
            (m2, cmds1 @ cmds2)
        | Some _ | None -> (m1, cmds1)
      in
      preserve_sidebar (next, cmds)
  | Nav.Menu_runtime tab ->
      let runtime =
        if Nav.equal_runtime_tab m.runtime.active_tab tab then m.runtime
        else Runtime_store.set_tab tab m.runtime
      in
      switch_workspace { m with runtime } Nav.Runtime |> preserve_sidebar
  | Nav.Menu_infra tab ->
      let infra =
        if Nav.equal_infra_tab m.infra.active_tab tab then m.infra
        else Infra_store.set_tab tab m.infra
      in
      switch_workspace { m with infra } Nav.Infra |> preserve_sidebar
  | Nav.Menu_settings ->
      if keep_sidebar_focus then (m, []) else open_global_settings m
  | Nav.Menu_incidents ->
      if keep_sidebar_focus then (m, [])
      else
        let incidents = Incidents.mark_all_read m.incidents in
        open_overlay { m with incidents } Nav.Incidents
  | Nav.Menu_queue_context ->
      if keep_sidebar_focus then (m, [])
      else open_overlay m (Nav.Queue_context Nav.Drawer_queue)
  | Nav.Menu_help ->
      if keep_sidebar_focus then (m, []) else open_overlay m Nav.Help

let move_sidebar (m : Model.t) (dir : Keymap.move_dir) =
  let n = List.length Nav.all_menu_items in
  if n <= 0 then (m, [])
  else
    let next_cursor =
      match dir with
      | Keymap.Up -> clamp_index n (m.nav.sidebar_cursor - 1)
      | Keymap.Down -> clamp_index n (m.nav.sidebar_cursor + 1)
      | Keymap.Page_up -> clamp_index n (m.nav.sidebar_cursor - 6)
      | Keymap.Page_down -> clamp_index n (m.nav.sidebar_cursor + 6)
      | Keymap.Home -> 0
      | Keymap.End -> n - 1
      | Keymap.Left | Keymap.Right -> clamp_index n m.nav.sidebar_cursor
    in
    let inner_h = sidebar_inner_height m in
    let scroll =
      Model.sidebar_viewport_start ~inner_h ~scroll:m.nav.sidebar_scroll
        ~cursor:next_cursor
    in
    let m_moved =
      {
        m with
        nav =
          {
            m.nav with
            sidebar_focused = true;
            filter_focused = false;
            sidebar_cursor = next_cursor;
            sidebar_scroll = scroll;
          };
        drafts = Drafts.set_focus false m.drafts;
      }
    in
    match Nav.menu_item_of_index next_cursor with
    | None -> (m_moved, [])
    | Some it ->
        if Nav.is_overlay_menu_target it.target then (m_moved, [])
        else navigate_menu_target ~keep_sidebar_focus:true m_moved it.target

let activate_sidebar_cursor (m : Model.t) =
  match Nav.menu_item_of_index m.nav.sidebar_cursor with
  | None -> (exit_sidebar_focus m, [])
  | Some it -> navigate_menu_target ~keep_sidebar_focus:false m it.target

let open_inline_modal (m : Model.t) kind =
  let modal = Model.inline_modal_for kind in
  let modal_edit_cursor = String.length (Model.modal_active_field_value modal) in
  let nav =
    {
      m.nav with
      overlay = Some (Nav.Inline_action kind);
      return_overlay = None;
      filter_focused = false;
      sidebar_focused = false;
      sidebar_open = close_drawer_if_floating m;
      btw_scroll_offset = 0;
      modal_edit_cursor;
    }
  in
  let drafts =
    let d0 = Drafts.set_focus false m.drafts in
    match kind, d0.btw with
    | Nav.Btw_query, (Drafts.Btw_answered _ | Drafts.Btw_failed _) ->
        Drafts.clear_btw d0
    | ( Nav.Btw_query
      | Nav.Gate_reject _
      | Nav.Verification_reject _
      | Nav.Harness_overrule _
      | Nav.Task_cancel _
      | Nav.Schedule_form
      | Nav.Connector_form
      | Nav.Repo_add_form
      | Nav.Board_new_post
      | Nav.Board_comment _
      | Nav.Github_token_form _
      | Nav.Code_finder_form
      | Nav.Code_search_form )
      , ( Drafts.Btw_idle
        | Drafts.Btw_sending _
        | Drafts.Btw_streaming _
        | Drafts.Btw_answered _
        | Drafts.Btw_failed _ ) ->
        d0
  in
  let config = Config_store.cancel_edit_field m.config in
  ({ m with nav; drafts; config; inline_modal = Some modal; ask_modal = None }, [])

let open_ask_modal ?preselect_choice_1based (m : Model.t)
    (ask : Wire_work.ask_row) =
  let modal = Model.ask_modal_for ?preselect_choice_1based ask in
  let nav =
    {
      m.nav with
      overlay = Some Nav.Ask_answer;
      filter_focused = false;
      sidebar_focused = false;
      sidebar_open = close_drawer_if_floating m;
    }
  in
  let drafts = Drafts.set_focus false m.drafts in
  let config = Config_store.cancel_edit_field m.config in
  ({ m with nav; drafts; config; inline_modal = None; ask_modal = Some modal }, [])

let open_palette (m : Model.t) mode =
  let palette = { Model.mode; query = ""; selected = 0 } in
  let nav =
    {
      m.nav with
      overlay = Some Nav.Palette;
      return_overlay = None;
      filter_focused = false;
      sidebar_focused = false;
      sidebar_open = close_drawer_if_floating m;
      palette_scroll_offset = 0;
    }
  in
  let drafts = Drafts.set_focus false m.drafts in
  let config = Config_store.cancel_edit_field m.config in
  let next =
    { m with nav; drafts; config; palette; inline_modal = None; ask_modal = None }
  in
  let extra_cmds =
    match mode with
    | Model.Palette_models ->
        let resolved_cmd =
          match m.runtime.runtime_resolved with
          | Observed.Value { stale = false; _ } -> []
          | Observed.Loading _
          | Observed.Value { stale = true; _ }
          | Observed.Absent
          | Observed.Unreported
          | Observed.Failed _ ->
              [ Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_runtime_resolved } ]
        in
        let raw_cmd =
          match m.runtime.runtime_config_raw with
          | Observed.Value { stale = false; _ } -> []
          | Observed.Loading _
          | Observed.Value { stale = true; _ }
          | Observed.Absent
          | Observed.Unreported
          | Observed.Failed _ ->
              [ Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_runtime_config_raw } ]
        in
        resolved_cmd @ raw_cmd
    | Model.Palette_commands | Model.Palette_keepers -> []
  in
  (next, extra_cmds)

let cycle_sub_tab (m : Model.t) dir =
  match m.nav.overlay with
  | Some (Nav.Settings _) ->
      let config = Config_store.cycle_tab dir m.config in
      let nav = { m.nav with overlay = Some (Nav.Settings config.active_tab) } in
      let next = { m with nav; config } in
      (next, View_fetches.fetches_for_current_view next)
  | Some (Nav.Queue_context tab) ->
      let next_tab =
        match dir with
        | Keymap.Next -> Nav.next_queue_context_tab tab
        | Keymap.Prev -> Nav.prev_queue_context_tab tab
      in
      let next =
        {
          m with
          nav =
            {
              m.nav with
              overlay = Some (Nav.Queue_context next_tab);
              queue_scroll_offset = 0;
            };
        } |> refresh_queue_on_entry
      in
      (next, View_fetches.fetches_for_current_view next)
  | Some Nav.Ask_answer -> (
      match m.ask_modal with
      | Some modal when not modal.editing_free_text ->
          let delta = match dir with Keymap.Next -> 1 | Keymap.Prev -> -1 in
          ({ m with ask_modal = Some (Model.ask_modal_step_question ~delta modal) }, [])
      | Some _ | None -> (m, []))
  | Some
      ( Nav.Palette
      | Nav.Incidents
      | Nav.Inline_action _
      | Nav.Help
      | Nav.System_gate _ ) ->
      (m, [])
  | None -> (
      match m.nav.dive_stack with
      | Nav.Dive_keeper { name; tab } :: rest ->
          let next_tab =
            match dir with
            | Keymap.Next -> Nav.next_keeper_tab tab
            | Keymap.Prev -> Nav.prev_keeper_tab tab
          in
          let nav =
            {
              m.nav with
              dive_stack = Nav.Dive_keeper { name; tab = next_tab } :: rest;
              pane_index = 0;
              dive_scroll_offset = 0;
            }
          in
          let drafts =
            if Nav.equal_keeper_tab next_tab Nav.Keeper_chat then m.drafts
            else Drafts.set_focus false m.drafts
          in
          let fleet =
            m.fleet
            |> Fleet_store.set_keeper_dive_tab next_tab
            |> sync_fleet_for_keeper_tab ~name ~tab:next_tab
          in
          let config =
            sync_config_for_keeper_tab ~name ~tab:next_tab m.config
          in
          let knowledge =
            match next_tab with
            | Nav.Keeper_memory ->
                m.knowledge
                |> Knowledge_store.close_memory_diagram
                |> Knowledge_store.set_memory_diff_keeper (Some name)
            | Nav.Keeper_chat
            | Nav.Keeper_context
            | Nav.Keeper_tool_calls
            | Nav.Keeper_work_candle
            | Nav.Keeper_sandbox
            | Nav.Keeper_config
            | Nav.Keeper_logs
            | Nav.Keeper_identity ->
                m.knowledge
                |> Knowledge_store.close_memory_reading
                |> Knowledge_store.close_memory_diagram
          in
          let next = { m with nav; drafts; fleet; config; knowledge } in
          (next, View_fetches.fetches_for_current_view next)
      | ( Nav.Dive_work _
        | Nav.Dive_knowledge _
        | Nav.Dive_runtime _
        | Nav.Dive_infra _ )
        :: _ ->
          (m, [])
      | [] -> (
          match m.nav.workspace with
          | Nav.Pulse -> (m, [])
          | Nav.Work ->
              let work = Work_store.cycle_tab dir m.work in
              let nav = { m.nav with pane_index = 0; zoomed = false } in
              let next = { m with nav; work } |> Model.sync_sidebar_cursor in
              (next, View_fetches.fetches_for_current_view next)
          | Nav.Knowledge ->
              let knowledge = Knowledge_store.cycle_tab dir m.knowledge in
              let nav = { m.nav with pane_index = 0; zoomed = false } in
              let next =
                { m with nav; knowledge } |> Model.sync_sidebar_cursor
              in
              (next, View_fetches.fetches_for_current_view next)
          | Nav.Keepers ->
              let zoomed_keeper =
                m.nav.zoomed
                && Option.is_some (Fleet_store.selected_keeper_summary m.fleet)
              in
              if m.nav.pane_index = 1 || zoomed_keeper then
                let fleet = Fleet_store.cycle_keeper_dive_tab dir m.fleet in
                let drafts =
                  if Nav.equal_keeper_tab fleet.keeper_dive_tab Nav.Keeper_chat
                  then m.drafts
                  else Drafts.set_focus false m.drafts
                in
                let nav = { m.nav with dive_scroll_offset = 0 } in
                let next =
                  { m with nav; drafts; fleet } |> sync_config_for_keeper_view
                in
                (next, View_fetches.fetches_for_current_view next)
              else
                let fleet = Fleet_store.cycle_fleet_mode dir m.fleet in
                let nav = { m.nav with pane_index = 0; zoomed = false } in
                ({ m with nav; fleet }, [])
          | Nav.Runtime ->
              let runtime = Runtime_store.cycle_tab dir m.runtime in
              let nav = { m.nav with pane_index = 0; zoomed = false } in
              let next =
                { m with nav; runtime } |> Model.sync_sidebar_cursor
              in
              (next, View_fetches.fetches_for_current_view next)
          | Nav.Infra ->
              let infra = Infra_store.cycle_tab dir m.infra in
              let nav = { m.nav with pane_index = 0; zoomed = false } in
              let next = { m with nav; infra } |> Model.sync_sidebar_cursor in
              (next, View_fetches.fetches_for_current_view next)))

let current_filter_query (m : Model.t) =
  match m.nav.overlay with
  | Some Nav.Incidents -> m.incidents.filter_query
  | Some (Nav.Settings _) -> m.config.search_query
  | Some
      ( Nav.Palette
      | Nav.Queue_context _
      | Nav.Inline_action _
      | Nav.Ask_answer
      | Nav.Help
      | Nav.System_gate _ )
  | None -> (
      match Model.active_dive m with
      | Some (Nav.Dive_knowledge (Nav.Artifact_dive _)) ->
          m.knowledge.artifact_search_query
      | Some
          ( Nav.Dive_keeper _
          | Nav.Dive_work _
          | Nav.Dive_knowledge
              (Nav.Thread_dive _ | Nav.Wiki_dive _ | Nav.Memory_diff_dive _)
          | Nav.Dive_runtime _
          | Nav.Dive_infra _ )
      | None ->
          if Model.is_keeper_config_active m then m.config.search_query
          else
            match m.nav.workspace with
            | Nav.Pulse | Nav.Keepers -> m.fleet.filter_query
            | Nav.Work -> m.work.filter_query
            | Nav.Knowledge -> m.knowledge.filter_query
            | Nav.Runtime -> m.runtime.filter_query
            | Nav.Infra -> m.infra.filter_query)

(* The changes panel answers for one repository. When a step leaves the
   Repos cursor on a repository the slot does not answer for (a cursor move,
   a filter edit), point the slot at it and ask for its activity. *)
let follow_selected_repository (m : Model.t) =
  let shown =
    Nav.equal_workspace m.nav.workspace Nav.Infra
    && Option.is_none (Model.active_dive m)
    && Nav.equal_infra_tab m.infra.active_tab Nav.Infra_repos_changes
  in
  let slot_answers_for repo_id =
    match m.infra.repo_activity with
    | Some slot -> String.equal slot.repo_id repo_id
    | None -> false
  in
  match Infra_store.selected_repository m.infra with
  | Some repo when shown && not (slot_answers_for repo.id) ->
      ( {
          m with
          infra = Infra_store.request_repo_activity ~repo_id:repo.id m.infra;
        },
        [
          Cmd.Http_get
            {
              epoch = m.epoch;
              req = Cmd.Get_repository_activity { repo_id = repo.id };
            };
        ] )
  | Some _ | None -> (m, [])

let set_active_filter_query q (m : Model.t) =
  let updated =
    match m.nav.overlay with
    | Some Nav.Incidents ->
        { m with incidents = Incidents.set_filter q m.incidents }
    | Some (Nav.Settings _) ->
        { m with config = Config_store.set_search_query q m.config }
    | Some
        ( Nav.Palette
        | Nav.Queue_context _
        | Nav.Inline_action _
        | Nav.Ask_answer
        | Nav.Help
        | Nav.System_gate _ )
    | None -> (
        match Model.active_dive m with
        | Some (Nav.Dive_knowledge (Nav.Artifact_dive _)) ->
            { m with knowledge = Knowledge_store.set_artifact_search q m.knowledge }
        | Some
            ( Nav.Dive_keeper _
            | Nav.Dive_work _
            | Nav.Dive_knowledge
                (Nav.Thread_dive _ | Nav.Wiki_dive _ | Nav.Memory_diff_dive _)
            | Nav.Dive_runtime _
            | Nav.Dive_infra _ )
        | None ->
            if Model.is_keeper_config_active m then
              {
                m with
                nav = { m.nav with dive_scroll_offset = 0 };
                config = Config_store.set_search_query q m.config;
              }
            else
              match m.nav.workspace with
              | Nav.Pulse | Nav.Keepers ->
                  { m with fleet = Fleet_store.set_filter q m.fleet }
              | Nav.Work -> { m with work = Work_store.set_filter q m.work }
              | Nav.Knowledge ->
                  { m with knowledge = Knowledge_store.set_filter q m.knowledge }
              | Nav.Runtime ->
                  { m with runtime = Runtime_store.set_filter q m.runtime }
              | Nav.Infra -> { m with infra = Infra_store.set_filter q m.infra })
  in
  let max_pane = max 0 (Model.focusable_pane_count updated - 1) in
  follow_selected_repository
    (if updated.nav.pane_index > max_pane then
       { updated with nav = { updated.nav with pane_index = max_pane } }
     else updated)

let palette_filtered_commands (m : Model.t) =
  let q = String.trim m.palette.query in
  let all = Keymap.palette_commands ~lang:m.lang in
  if String.equal q "" then all
  else
    List.filter
      (fun (c : Keymap.palette_command) ->
        contains_ci ~needle:q c.title
        || contains_ci ~needle:q c.shortcut
        ||
        match c.slash_twin with
        | Some s -> contains_ci ~needle:q s
        | None -> false)
      all

let palette_filtered_keepers (m : Model.t) =
  let q = String.trim m.palette.query in
  let all = Fleet_store.filtered_keepers { m.fleet with filter_query = "" } in
  if String.equal q "" then all
  else
    List.filter
      (fun (k : Wire_fleet.keeper_summary) ->
        contains_ci ~needle:q k.name || contains_ci ~needle:q k.company)
      all

let palette_filtered_models (m : Model.t) =
  let q = String.trim m.palette.query in
  let all = Runtime_store.runtime_options m.runtime in
  if String.equal q "" then all
  else
    List.filter
      (fun (r : Wire_runtime.runtime_option) ->
        contains_ci ~needle:q r.id
        || contains_ci ~needle:q r.provider
        ||
        match r.model with Some mdl -> contains_ci ~needle:q mdl | None -> false)
      all

let palette_entries_with_overflow (m : Model.t) :
    palette_entry list * (palette_section * int) list =
  let lang = m.lang in
  let q = String.trim m.palette.query in
  let fuzzy_opt s = fuzzy_score ~query:q s in
  let overflow = ref [] in
  let cap_section sec limit items =
    let total = List.length items in
    let shown = take_n limit items in
    let hidden = total - List.length shown in
    if hidden > 0 then overflow := (sec, hidden) :: !overflow;
    shown
  in
  let cmd_entries =
    palette_filtered_commands m
    |> List.map (fun (c : Keymap.palette_command) ->
           let slash_s =
             match c.slash_twin with Some s -> s | None -> ""
           in
           {
             section = Pal_sec_commands;
             badge = c.shortcut;
             title = c.title;
             meta = slash_s;
             tone = Some Theme.Status_active;
             action = Pal_keymap_action c.action;
           })
  in
  let ws_entries =
    Nav.all_menu_items
    |> List.filter_map (fun (it : Nav.menu_item) ->
           let lbl = Say.resolve lang it.label in
           let sec_lbl = Say.resolve lang (Nav.menu_section_label it.section) in
           let sec_en = Say.resolve Say.Lang_en (Nav.menu_section_label it.section) in
           let sec_ko = Say.resolve Say.Lang_ko (Nav.menu_section_label it.section) in
           let lbl_en = Say.resolve Say.Lang_en it.label in
           let lbl_ko = Say.resolve Say.Lang_ko it.label in
           let sc_s =
             match it.shortcut with
             | Some s -> s
             | None ->
                 Option.value (Nav.menu_section_shortcut it.section) ~default:""
           in
           let search_s =
             Printf.sprintf "%s %s %s %s %s" sc_s sec_ko sec_en lbl_ko lbl_en
           in
           match fuzzy_opt search_s with
           | None -> None
           | Some _ ->
               let badge =
                 match it.shortcut with
                 | Some s -> Printf.sprintf "[%s]" s
                 | None -> "→"
               in
               Some
                 {
                   section = Pal_sec_workspaces;
                   badge;
                   title = lbl;
                   meta = sec_lbl;
                   tone = Some Theme.Status_ok;
                   action = Pal_menu_target it.target;
                 })
    |> cap_section Pal_sec_workspaces (if String.equal q "" then 6 else 12)
  in
  let keeper_entries =
    Fleet_store.filtered_keepers { m.fleet with filter_query = "" }
    |> List.filter_map (fun (k : Wire_fleet.keeper_summary) ->
           match fuzzy_opt (k.name ^ " " ^ k.company) with
           | None -> None
           | Some _ ->
               let g, tone = keeper_health_glyph_and_tone k.health in
               Some
                 {
                   section = Pal_sec_keepers;
                   badge = Glyph.to_utf8 g;
                   title = k.name;
                   meta = Printf.sprintf "%s · %s" k.company k.runtime_id;
                   tone = Some tone;
                   action = Pal_dive_keeper k.name;
                 })
    |> cap_section Pal_sec_keepers (if String.equal q "" then 3 else 6)
  in
  let company_entries =
    Fleet_store.company_groups m.fleet
    |> List.filter_map (fun (g : Wire_fleet.company_group) ->
           match fuzzy_opt g.company with
           | None -> None
           | Some _ ->
               Some
                 {
                   section = Pal_sec_companies;
                   badge = "CO";
                   title = g.company;
                   meta = Printf.sprintf "%d keepers" (List.length g.keepers);
                   tone = None;
                   action = Pal_select_company g.company;
                 })
    |> cap_section Pal_sec_companies (if String.equal q "" then 2 else 5)
  in
  let goal_entries =
    Work_store.goals m.work
    |> List.filter_map (fun (g : Wire_work.goal) ->
           match fuzzy_opt (g.id ^ " " ^ g.title) with
           | None -> None
           | Some _ ->
               Some
                 {
                   section = Pal_sec_goals_tasks;
                   badge = "G";
                   title = g.title;
                   meta = Wire_work.goal_phase_to_string g.phase;
                   tone = Some Theme.Status_ok;
                   action = Pal_dive_goal g.id;
                 })
  in
  let task_entries =
    Work_store.tasks m.work
    |> List.filter_map (fun (t : Wire_work.task) ->
           match fuzzy_opt (t.id ^ " " ^ t.title) with
           | None -> None
           | Some _ ->
               Some
                 {
                   section = Pal_sec_goals_tasks;
                   badge = "T";
                   title = t.title;
                   meta = t.id;
                   tone = None;
                   action = Pal_dive_task t.id;
                 })
  in
  let goals_tasks_entries =
    cap_section Pal_sec_goals_tasks
      (if String.equal q "" then 2 else 5)
      (goal_entries @ task_entries)
  in
  let board_entries =
    Knowledge_store.filtered_posts { m.knowledge with filter_query = "" }
    |> List.filter_map (fun (p : Wire_knowledge.board_post) ->
           match fuzzy_opt (p.title ^ " " ^ p.author) with
           | None -> None
           | Some _ ->
               Some
                 {
                   section = Pal_sec_board_wiki;
                   badge = "#";
                   title = p.title;
                   meta = p.author;
                   tone = None;
                   action = Pal_dive_thread p.id;
                 })
  in
  let wiki_entries =
    match Observed.to_option m.knowledge.wiki_index with
    | None -> []
    | Some wi ->
        wi.pages
        |> List.filter_map (fun (p : Wire_knowledge.wiki_page_summary) ->
               match fuzzy_opt (p.slug ^ " " ^ p.title) with
               | None -> None
               | Some _ ->
                   Some
                     {
                       section = Pal_sec_board_wiki;
                       badge = "W";
                       title = p.title;
                       meta = p.slug;
                       tone = Some Theme.Status_active;
                       action = Pal_dive_wiki p.slug;
                     })
  in
  let board_wiki_entries =
    cap_section Pal_sec_board_wiki
      (if String.equal q "" then 2 else 5)
      (board_entries @ wiki_entries)
  in
  let sandbox_entries =
    let items =
      match Observed.to_option m.infra.sandboxes with
      | None -> []
      | Some sb ->
          let vms =
            List.filter_map
              (fun (g : Wire_infra.microvm_guest) ->
                match fuzzy_opt (g.keeper ^ " " ^ g.guest_name) with
                | None -> None
                | Some _ ->
                    Some
                      {
                        section = Pal_sec_sandboxes;
                        badge = "VM";
                        title = g.keeper;
                        meta = g.backend;
                        tone = Some Theme.Status_active;
                        action = Pal_dive_sandbox g.keeper;
                      })
              sb.microvm_guests
          in
          let sshs =
            List.filter_map
              (fun (p : Wire_infra.ssh_pool) ->
                match fuzzy_opt (p.pool_name ^ " " ^ p.host) with
                | None -> None
                | Some _ ->
                    Some
                      {
                        section = Pal_sec_sandboxes;
                        badge = "SSH";
                        title = p.pool_name;
                        meta = Printf.sprintf "%s:%d" p.host p.port;
                        tone = Some Theme.Status_active;
                        action = Pal_open_infra_sandboxes p.pool_name;
                      })
              sb.ssh_pools
          in
          vms @ sshs
    in
    cap_section Pal_sec_sandboxes (if String.equal q "" then 2 else 4) items
  in
  let settings_entries =
    let items =
      match Observed.to_option m.config.schema with
      | None -> []
      | Some sc ->
          sc.sections
          |> List.concat_map (fun (s : Wire_config.schema_section) ->
                 let tab = Wire_config.settings_tab_of_category s.category in
                 List.filter_map
                   (fun (f : Wire_config.schema_field) ->
                     let leaf = Config_store.field_label ~lang f in
                     match fuzzy_opt (f.full_key ^ " " ^ leaf) with
                     | None -> None
                     | Some _ ->
                         Some
                           {
                             section = Pal_sec_settings;
                             badge = "CFG";
                             title = leaf;
                             meta = f.full_key;
                             tone = None;
                             action =
                               Pal_open_setting { full_key = f.full_key; tab };
                           })
                   s.fields)
    in
    cap_section Pal_sec_settings (if String.equal q "" then 2 else 5) items
  in
  let slash_entries =
    Slash.filter ~query:q ~lang
    |> List.map (fun (s : Slash.spec) ->
           {
             section = Pal_sec_slash;
             badge = s.name;
             title = Say.resolve lang s.description;
             meta =
               (match s.arg_hint with
               | Some h -> Say.resolve lang h
               | None -> "");
             tone = Some Theme.Status_active;
             action = Pal_slash_spec s;
           })
  in
  ( cmd_entries @ ws_entries @ keeper_entries @ company_entries
    @ goals_tasks_entries @ board_wiki_entries @ sandbox_entries
    @ settings_entries @ slash_entries
  , List.rev !overflow )

let palette_entries (m : Model.t) : palette_entry list =
  fst (palette_entries_with_overflow m)

let palette_len (m : Model.t) =
  match m.palette.mode with
  | Model.Palette_commands -> List.length (palette_entries m)
  | Model.Palette_keepers -> List.length (palette_filtered_keepers m)
  | Model.Palette_models -> List.length (palette_filtered_models m)

let resolve_target_keeper (m : Model.t) =
  match m.drafts.active_keeper with
  | Some k when not (String.equal (String.trim k) "") -> Some (String.trim k)
  | Some _ | None -> (
      match Fleet_store.selected_keeper_summary m.fleet with
      | Some k -> Some k.name
      | None -> None)

type steer_refusal =
  | Steer_turn_not_own
  | Steer_no_control_token

type steer_resolution =
  | Steer_own of { control_token : string; operation_id : string }
  | Steer_refused of steer_refusal

let resolve_steer ~keeper (m : Model.t) =
  (* [Stream_keeper_chat] is the only producer of [chat_streams], so an
     active buffer is a request this TUI submitted, and the server keys that
     request's operation by its [request_id]. The turn row's interrupt token
     names whichever turn holds the Keeper (another Keeper's delegated
     request, an autonomous cycle), so it is never a steer target. *)
  match Fleet_store.String_map.find_opt keeper m.fleet.chat_streams with
  | Some s when s.active -> (
      match Fleet_store.chat_control_token_for ~keeper m.fleet with
      | Some control_token ->
          Steer_own { control_token; operation_id = s.request_id }
      | None -> Steer_refused Steer_no_control_token)
  | Some _ | None -> Steer_refused Steer_turn_not_own

let build_chat_submit_cmd (m : Model.t) (tx : Drafts.pending_message) ~mode
    ~is_btw =
  let req : Wire_fleet.chat_submit_request =
    {
      request_id = tx.request_id;
      keeper_name = tx.keeper;
      message = tx.body;
      origin = Wire_fleet.Origin_bare;
      mode;
      turn_instructions = None;
      since_seq = None;
      attachments = [];
    }
  in
  Cmd.Http_post_stream
    { epoch = m.epoch; req = Cmd.Stream_keeper_chat { request = req; is_btw } }

let start_btw_query ~now ~prompt (m : Model.t) =
  let trimmed = String.trim prompt in
  if String.equal trimmed "" then open_inline_modal m Nav.Btw_query
  else
    match resolve_target_keeper m with
    | None ->
        ( Model.with_toast ~now ~level:Model.Toast_warning
            (Say.make ~ko:"대상 키퍼를 먼저 선택하세요"
               ~en:"Select a target keeper first")
            m
        , [] )
    | Some keeper ->
        let drafts, request_id =
          Drafts.start_btw ~now ~keeper ~prompt:trimmed m.drafts
        in
        let req : Wire_fleet.chat_submit_request =
          {
            request_id;
            keeper_name = keeper;
            message = trimmed;
            origin = Wire_fleet.Origin_bare;
            mode = Wire_fleet.Follow_up;
            turn_instructions =
              Some "Answer concisely as an ephemeral /btw side-query.";
            since_seq = None;
            attachments = [];
          }
        in
        let nav =
          {
            m.nav with
            overlay = Some (Nav.Inline_action Nav.Btw_query);
            return_overlay = None;
            filter_focused = false;
            btw_scroll_offset = 0;
            modal_edit_cursor = 0;
          }
        in
        let next =
          {
            m with
            nav;
            config = Config_store.cancel_edit_field m.config;
            drafts = Drafts.set_focus false drafts;
            inline_modal = Some (Model.inline_modal_for Nav.Btw_query);
          }
        in
        ( next
        , [
            Cmd.Http_post_stream
              {
                epoch = m.epoch;
                req = Cmd.Stream_keeper_chat { request = req; is_btw = true };
              };
          ] )

let submit_ask_choice ~now (ask : Wire_work.ask_row) ~choice_1based (m : Model.t)
    =
  match ask.questions with
  | [] ->
      ( Model.with_toast ~now ~level:Model.Toast_warning
          (Say.make ~ko:"선택 가능한 질문 항목이 없습니다" ~en:"Ask has no questions")
          m
      , [] )
  | q :: _ -> (
      match List.nth_opt q.choices (choice_1based - 1) with
      | None ->
          ( Model.with_toast ~now ~level:Model.Toast_warning
              (Say.make
                 ~ko:(Printf.sprintf "선택지 %d번이 없습니다" choice_1based)
                 ~en:(Printf.sprintf "Choice %d does not exist" choice_1based))
              m
          , [] )
      | Some choice ->
          (* Honest in-flight tracking: mark in-flight and advance triage cursor
             without optimistically deleting the item before server ack. *)
          let attn_id = "ask:" ^ ask.ask_id in
          let triage_query =
            if
              Option.is_none m.nav.overlay
              && m.nav.dive_stack = []
              && Nav.equal_workspace m.nav.workspace Nav.Work
              && Nav.equal_work_tab m.work.active_tab Nav.Work_inbox
            then m.work.filter_query
            else ""
          in
          let attention =
            m.attention
            |> Attention.mark_in_flight ~id:attn_id
            |> Attention.move_triage ~query:triage_query ~delta:1
          in
          let cmd =
            Cmd.Http_post
              {
                epoch = m.epoch;
                req =
                  Cmd.Post_ask_answer
                    {
                      keeper = ask.keeper;
                      ask_id = ask.ask_id;
                      answers =
                        [ (q.question_id, Wire_work.Ask_chose [ choice.choice_id ]) ];
                    };
              }
          in
          let next =
            { m with attention }
            |> Model.with_toast ~now ~level:Model.Toast_info
                 (Say.make
                    ~ko:("질문 응답 전송: " ^ choice.label)
                    ~en:("Sent Ask choice: " ^ choice.label))
          in
          (next, [ cmd ]))

let skip_all_ask_questions ~now (ask : Wire_work.ask_row) (m : Model.t) =
  match ask.questions with
  | [] -> (m, [])
  | questions ->
      let attn_id = "ask:" ^ ask.ask_id in
      let answers =
        List.map
          (fun (q : Wire_work.ask_question) ->
            (q.question_id, Wire_work.Ask_skipped))
          questions
      in
      let attention = Attention.mark_in_flight ~id:attn_id m.attention in
      let cmd =
        Cmd.Http_post
          {
            epoch = m.epoch;
            req =
              Cmd.Post_ask_answer
                { keeper = ask.keeper; ask_id = ask.ask_id; answers };
          }
      in
      let next =
        { m with attention }
        |> Model.with_toast ~now ~level:Model.Toast_info
             (Say.make
                ~ko:(Printf.sprintf "@%s 질문 건너뛰기 전송 (%d개 문항)"
                       ask.keeper (List.length answers))
                ~en:(Printf.sprintf "Skipping Ask for @%s (%d question(s))"
                       ask.keeper (List.length answers)))
      in
      (next, [ cmd ])

let submit_ask_modal ~now (m : Model.t) =
  match m.ask_modal with
  | None -> (m, [])
  | Some modal -> (
      match Model.ask_live_status m modal.ask.ask_id with
      | Model.Ask_live_closed ->
          ( Model.with_toast ~now ~level:Model.Toast_warning
              (Say.make ~ko:"이미 응답되었거나 철회된 질문입니다"
                 ~en:"This Ask was already answered or withdrawn")
              m
          , [] )
      | Model.Ask_live_in_flight ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:"이미 응답 전송 중입니다"
                 ~en:"Ask response is already in flight")
              m
          , [] )
      | Model.Ask_live_open when modal.submitting -> (m, [])
      | Model.Ask_live_open -> (
          match Model.ask_modal_build_answers modal with
          | Error first_idx ->
              let jumped = Model.ask_modal_select_question first_idx modal in
              let total = List.length modal.ask.questions in
              ( Model.with_toast ~now ~level:Model.Toast_warning
                  (Say.make
                     ~ko:(Printf.sprintf "미응답 질문이 남아 있습니다 (Q %d/%d)"
                            (first_idx + 1) total)
                     ~en:(Printf.sprintf "Unanswered question remaining (Q %d/%d)"
                            (first_idx + 1) total))
                  { m with ask_modal = Some jumped }
              , [] )
          | Ok answers ->
              let attn_id = "ask:" ^ modal.ask.ask_id in
              let attention = Attention.mark_in_flight ~id:attn_id m.attention in
              let cmd =
                Cmd.Http_post
                  {
                    epoch = m.epoch;
                    req =
                      Cmd.Post_ask_answer
                        {
                          keeper = modal.ask.keeper;
                          ask_id = modal.ask.ask_id;
                          answers;
                        };
                  }
              in
              let submitting_modal =
                {
                  modal with
                  editing_free_text = false;
                  submitting = true;
                  error = None;
                }
              in
              let next =
                {
                  m with
                  ask_modal = Some submitting_modal;
                  attention;
                }
                |> Model.with_toast ~now ~level:Model.Toast_info
                     (Say.make
                        ~ko:(Printf.sprintf "@%s 질문 응답 전송 중 (%d개 문항)"
                               modal.ask.keeper (List.length answers))
                        ~en:(Printf.sprintf "Sending Ask answer to @%s (%d question(s))"
                               modal.ask.keeper (List.length answers)))
              in
              (next, [ cmd ])))

let actionable_approval_item (m : Model.t) =
  let on_work_inbox =
    Option.is_none m.nav.overlay
    && m.nav.dive_stack = []
    && Nav.equal_workspace m.nav.workspace Nav.Work
    && Nav.equal_work_tab m.work.active_tab Nav.Work_inbox
  in
  let on_pulse_attention =
    Option.is_none m.nav.overlay
    && m.nav.dive_stack = []
    && Nav.equal_workspace m.nav.workspace Nav.Pulse
    && Model.equal_pulse_pane (Model.active_pulse_pane m) Model.Pulse_attention
  in
  if on_work_inbox then
    match
      Attention.current_filtered_item ~query:m.work.filter_query m.attention
    with
    | Some e when not (Attention.is_in_flight ~id:e.id m.attention) -> Some e
    | Some _ | None -> None
  else if on_pulse_attention then
    match Attention.current_filtered_item ~query:"" m.attention with
    | Some e when not (Attention.is_in_flight ~id:e.id m.attention) -> Some e
    | Some _ | None -> Attention.top_fast_path m.attention
  else Model.fast_approval_strip_item m

let fast_approve_top ~now (m : Model.t) =
  match actionable_approval_item m with
  | None -> (m, [])
  | Some entry -> (
      match entry.payload with
      | Attention.Payload_tool_approval ta ->
          let attention = Attention.mark_in_flight ~id:entry.id m.attention in
          let cmd =
            Cmd.Http_post
              {
                epoch = m.epoch;
                req =
                  Cmd.Post_tool_approval
                    {
                      keeper = ta.keeper;
                      tool_call_id = ta.tool_call_id;
                      approval_id = ta.approval_id;
                      decision = Wire_work.Tool_approve;
                      expected_workspace = expected_workspace_of m;
                    };
              }
          in
          ({ m with attention }, [ cmd ])
      | Attention.Payload_gate g ->
          let attention = Attention.mark_in_flight ~id:entry.id m.attention in
          let cmd =
            Cmd.Http_post
              {
                epoch = m.epoch;
                req =
                  Cmd.Post_gate_resolution
                    { id = g.id; approved = true; reason = None };
              }
          in
          ({ m with attention }, [ cmd ])
      | Attention.Payload_ask ask ->
          (* NEVER blindly submit choice #1 on Y / Alt+Y — open the dedicated
             Ask Answer Modal while preserving any composer draft. *)
          open_ask_modal m ask
      | Attention.Payload_goal_confirmation g ->
          (* Goal completion confirmation requires exact server-issued proof run
             and operator credentials; never fabricate tokens from the strip. *)
          let next, cmds = push_dive m (Nav.Dive_work (Nav.Goal_dive g.id)) in
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:"목표 상세에서 검증 증명을 확인한 뒤 완료 확정하세요"
                 ~en:"Review verified proof in Goal Dive before confirming completion")
              next
          , cmds ))

let fast_deny_top ~now (m : Model.t) =
  match actionable_approval_item m with
  | None -> (m, [])
  | Some entry -> (
      match entry.payload with
      | Attention.Payload_tool_approval ta ->
          let attention = Attention.mark_in_flight ~id:entry.id m.attention in
          let cmd =
            Cmd.Http_post
              {
                epoch = m.epoch;
                req =
                  Cmd.Post_tool_approval
                    {
                      keeper = ta.keeper;
                      tool_call_id = ta.tool_call_id;
                      approval_id = ta.approval_id;
                      decision = Wire_work.Tool_deny;
                      expected_workspace = expected_workspace_of m;
                    };
              }
          in
          ({ m with attention }, [ cmd ])
      | Attention.Payload_gate g -> open_inline_modal m (Nav.Gate_reject g.id)
      | Attention.Payload_ask ask -> skip_all_ask_questions ~now ask m
      | Attention.Payload_goal_confirmation g ->
          let next, cmds = push_dive m (Nav.Dive_work (Nav.Goal_dive g.id)) in
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:"목표 상세에서 보류·중단·거절을 진행하세요"
                 ~en:"Open Goal Dive to pause, block, or reject completion")
              next
          , cmds ))

let focus_attention_entry_in_inbox (m : Model.t) (entry : Attention.entry) =
  let work0 = Work_store.set_tab Nav.Work_inbox m.work in
  let visible_under_filter =
    List.exists
      (fun (e : Attention.entry) -> String.equal e.id entry.id)
      (Attention.filtered_items ~query:work0.filter_query m.attention)
  in
  let work1 =
    if visible_under_filter then work0 else Work_store.set_filter "" work0
  in
  let filtered = Attention.filtered_items ~query:work1.filter_query m.attention in
  let rec find_idx i = function
    | [] -> None
    | (e : Attention.entry) :: rest ->
        if String.equal e.id entry.id then Some i else find_idx (i + 1) rest
  in
  let attention =
    match find_idx 0 filtered with
    | Some idx -> Attention.select_triage_index idx m.attention
    | None -> m.attention
  in
  let work =
    match entry.payload with
    | Attention.Payload_ask ask ->
        let asks = Work_store.open_asks work1 in
        let rec find_ask i = function
          | [] -> None
          | (a : Wire_work.ask_row) :: rest ->
              if String.equal a.ask_id ask.ask_id then Some i
              else find_ask (i + 1) rest
        in
        (match find_ask 0 asks with
        | Some idx -> { work1 with selected_index = idx }
        | None -> work1)
    | Attention.Payload_tool_approval _
    | Attention.Payload_gate _
    | Attention.Payload_goal_confirmation _ ->
        work1
  in
  { m with work; attention }

let teleport_blocked ~now (m : Model.t) =
  let in_micro = Model.equal_breakpoint m.breakpoint Model.Micro in
  let target_opt =
    if
      (not in_micro)
      && Option.is_none m.nav.overlay
      && m.nav.dive_stack = []
      && Nav.equal_workspace m.nav.workspace Nav.Pulse
      && Model.equal_pulse_pane (Model.active_pulse_pane m)
           Model.Pulse_attention
    then Attention.current_filtered_item ~query:"" m.attention
    else Attention.top_fast_path m.attention
  in
  match target_opt with
  | None ->
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make ~ko:"즉시 조치가 필요한 항목이 없습니다"
             ~en:"No items currently awaiting operator action")
          m
      , [] )
  | Some entry ->
      if in_micro then
        match entry.payload with
        | Attention.Payload_ask ask -> open_ask_modal m ask
        | Attention.Payload_tool_approval _
        | Attention.Payload_gate _
        | Attention.Payload_goal_confirmation _ ->
            open_overlay m (Nav.Queue_context Nav.Drawer_queue)
      else (
        match entry.payload with
        | Attention.Payload_ask ask ->
            let m0 = focus_attention_entry_in_inbox m entry in
            let m1, cmds1 = switch_workspace m0 Nav.Work in
            let m2, cmds2 = open_ask_modal m1 ask in
            (m2, cmds1 @ cmds2)
        | Attention.Payload_tool_approval _ | Attention.Payload_gate _ ->
            let m0 = focus_attention_entry_in_inbox m entry in
            switch_workspace m0 Nav.Work
        | Attention.Payload_goal_confirmation g ->
            let work = Work_store.set_tab Nav.Work_pipeline m.work in
            let m1, cmds1 = switch_workspace { m with work } Nav.Work in
            let m2, cmds2 = push_dive m1 (Nav.Dive_work (Nav.Goal_dive g.id)) in
            (m2, cmds1 @ cmds2))

let toggle_voice ~now (m : Model.t) =
  match m.drafts.voice with
  | Drafts.Voice_off | Drafts.Voice_error _ ->
      let device =
        match Observed.to_option m.config.preferences with
        | Some p -> p.audio_input_device
        | None -> None
      in
      let drafts = Drafts.voice_start_recording ~now m.drafts in
      ({ m with drafts }, [ Cmd.Voice_cmd (Cmd.Start_ptt { device }) ])
  | Drafts.Voice_recording _ ->
      let drafts = Drafts.voice_set_transcribing m.drafts in
      ({ m with drafts }, [ Cmd.Voice_cmd Cmd.Stop_ptt ])
  | Drafts.Voice_transcribing ->
      let drafts = Drafts.voice_set_off m.drafts in
      ({ m with drafts }, [ Cmd.Voice_cmd Cmd.Cancel_ptt ])

let dive_attention_entry (m : Model.t) (entry : Attention.entry) =
  match entry.payload with
  | Attention.Payload_goal_confirmation g ->
      push_dive m (Nav.Dive_work (Nav.Goal_dive g.id))
  | Attention.Payload_ask ask -> open_ask_modal m ask
  | Attention.Payload_tool_approval ta ->
      push_dive m (Nav.Dive_keeper { name = ta.keeper; tab = Nav.Keeper_chat })
  | Attention.Payload_gate g ->
      push_dive m (Nav.Dive_keeper { name = g.keeper; tab = Nav.Keeper_chat })

let launch_memory_diagram ~now ~keeper ~(content_rect : Rect.t) ~kind ~mode
    ~(activity : Wire_knowledge.keeper_memory_activity)
    ~(selected : Wire_knowledge.memory_activity_event) (m : Model.t) =
  let facts =
    Observed.to_option
      (Knowledge_store.keeper_memory_facts_for ~keeper m.knowledge)
  in
  match Memory_diagram.chart_of_activity ~keeper ~activity ~facts ~selected with
  | None ->
      ( Model.with_toast ~now ~level:Model.Toast_warning
          (Say.make
             ~ko:"선택한 변천 이벤트의 기억 계보를 구성할 수 없습니다"
             ~en:"Could not build lineage chart for selected evolution event")
          m
      , [] )
  | Some chart ->
      let ko = Say.equal_lang m.lang Say.Lang_ko in
      let max_width = Int.max 24 content_rect.w in
      let now_unix = m.freshness.last_wall_unix in
      let copy_source =
        Memory_diagram.copy_source_of_chart ~tz_offset_sec:m.tz_offset_sec ~ko
          ~now:now_unix ~keeper_name:keeper ~max_width ~kind ~mode chart
      in
      let request_id =
        Knowledge_store.next_memory_diagram_request_id m.knowledge
      in
      let state : Knowledge_store.memory_diagram_state =
        {
          request_id;
          keeper;
          event_identity = selected.identity;
          revision = selected.revision;
          kind;
          mode;
          payload = Observed.loading ~since_ns:now;
          scroll = 0;
          copy_source;
        }
      in
      let knowledge = Knowledge_store.open_memory_diagram state m.knowledge in
      let nav =
        match Model.active_dive m, m.nav.workspace with
        | None, (Nav.Knowledge | Nav.Keepers) when not m.nav.zoomed ->
            { m.nav with pane_index = 1 }
        | ( None
          , ( Nav.Pulse
            | Nav.Work
            | Nav.Knowledge
            | Nav.Keepers
            | Nav.Runtime
            | Nav.Infra ) )
        | ( Some _
          , ( Nav.Pulse
            | Nav.Work
            | Nav.Knowledge
            | Nav.Keepers
            | Nav.Runtime
            | Nav.Infra ) ) ->
            m.nav
      in
      let cmd =
        Cmd.Render_memory_diagram
          {
            epoch = m.epoch;
            request_id;
            keeper;
            event_identity = selected.identity;
            kind;
            mode;
            ko;
            tz_offset_sec = m.tz_offset_sec;
            now_unix;
            max_width;
            chart;
          }
      in
      ({ m with nav; knowledge }, [ cmd ])

let open_memory_diagram ~now ~kind (m : Model.t) =
  match Memory_diagram.active_memory_content_rect m with
  | None ->
      let on_world_memory =
        Option.is_none m.nav.overlay
        && Option.is_none (Model.active_dive m)
        && Nav.equal_workspace m.nav.workspace Nav.Knowledge
        && Nav.equal_knowledge_tab m.knowledge.active_tab Nav.Knowledge_memory
        && Option.is_none m.knowledge.memory_diff_keeper
      in
      if on_world_memory then
        ( Model.with_toast ~now ~level:Model.Toast_info
            (Say.make
               ~ko:"다이어그램을 보려면 왼쪽 목록에서 키퍼를 선택하세요"
               ~en:"Select a keeper on the left to inspect memory diagrams")
            m
        , [] )
      else (m, [])
  | Some (keeper, content_rect) -> (
      match
        Observed.to_option
          (Knowledge_store.keeper_memory_activity_for ~keeper m.knowledge)
      with
      | Some act -> (
          let selected_opt, empty_toast =
            match Memory_diagram.active_diagram m with
            | Some d ->
                ( List.find_opt
                    (fun (ev : Wire_knowledge.memory_activity_event) ->
                      String.equal ev.identity d.event_identity)
                    act.events
                , Say.make ~ko:"선택한 변천 이벤트를 찾을 수 없습니다"
                    ~en:"Selected memory evolution event no longer in log" )
            | None -> (
                match m.knowledge.memory_view_mode with
                | Knowledge_store.View_evolution ->
                    ( Knowledge_store.selected_activity_event_for ~keeper
                        m.knowledge
                    , Say.make ~ko:"다이어그램을 열 변천 이벤트가 없습니다"
                        ~en:"No memory evolution event selected" )
                | Knowledge_store.View_facts -> (
                    match
                      Knowledge_store.selected_memory_fact_row ~keeper
                        m.knowledge
                    with
                    | Some (Knowledge_store.Fact_ordinary { fact; _ }) ->
                        ( Memory_diagram.find_latest_event_for_fact
                            ~memory_id:fact.memory_id act
                        , Say.make
                            ~ko:"선택한 기억 사실과 연결된 변천 이벤트가 최근 이력에 없습니다"
                            ~en:"No recent evolution event references the selected fact"
                        )
                    | Some
                        ( Knowledge_store.Fact_source _
                        | Knowledge_store.Fact_source_invalidation _ )
                    | None ->
                        ( None
                        , Say.make
                            ~ko:"다이어그램을 열 일반 기억 사실을 선택하세요"
                            ~en:"Select an ordinary memory fact to open its diagram"
                        ))
                | Knowledge_store.View_diff ->
                    let diff_match =
                      match
                        Knowledge_store.selected_memory_diff_item_for
                          ~keeper_opt:(Some keeper) m.knowledge
                      with
                      | Some (Knowledge_store.Keeper_added f) ->
                          Memory_diagram.find_latest_event_for_fact
                            ~memory_id:f.memory_id act
                      | Some (Knowledge_store.Keeper_updated u) -> (
                          match
                            Memory_diagram.find_latest_event_for_fact
                              ~memory_id:u.after.memory_id act
                          with
                          | Some _ as ev -> ev
                          | None ->
                              Memory_diagram.find_latest_event_for_fact
                                ~memory_id:u.before.memory_id act)
                      | Some (Knowledge_store.Keeper_retracted r) ->
                          Memory_diagram.find_latest_event_for_fact
                            ~memory_id:r.memory_id act
                      | Some (Knowledge_store.Keeper_invalidated inv) ->
                          Memory_diagram.find_latest_event_for_fact
                            ~memory_id:inv.memory_id act
                      | Some
                          ( Knowledge_store.World_added _
                          | Knowledge_store.World_updated _
                          | Knowledge_store.World_retracted _ )
                      | None ->
                          None
                    in
                    let resolved =
                      match diff_match with
                      | Some _ as ev -> ev
                      | None ->
                          Knowledge_store.selected_activity_event_for ~keeper
                            m.knowledge
                    in
                    ( resolved
                    , Say.make ~ko:"다이어그램을 열 변천 이벤트가 없습니다"
                        ~en:"No memory evolution event available for diagram" ))
          in
          match selected_opt with
          | None ->
              (Model.with_toast ~now ~level:Model.Toast_info empty_toast m, [])
          | Some selected ->
              let mode =
                match Memory_diagram.active_diagram m with
                | Some d -> d.mode
                | None -> Knowledge_store.Diagram_mode_auto
              in
              launch_memory_diagram ~now ~keeper ~content_rect ~kind ~mode
                ~activity:act ~selected m)
      | None ->
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make
                 ~ko:"기억 변천 이력을 불러오는 중입니다..."
                 ~en:"Loading memory evolution activity...")
              m
          , [
              Cmd.Http_get
                {
                  epoch = m.epoch;
                  req = Cmd.Get_keeper_memory_activity { keeper; limit = 50 };
                };
            ] ))

let cycle_memory_diagram_mode ~now (m : Model.t) =
  match
    Memory_diagram.active_diagram m, Memory_diagram.active_memory_content_rect m
  with
  | Some d, Some (keeper, content_rect) when String.equal d.keeper keeper -> (
      match
        Observed.to_option
          (Knowledge_store.keeper_memory_activity_for ~keeper m.knowledge)
      with
      | Some act -> (
          match
            List.find_opt
              (fun (ev : Wire_knowledge.memory_activity_event) ->
                String.equal ev.identity d.event_identity)
              act.events
          with
          | Some selected ->
              let mode = Knowledge_store.next_memory_diagram_mode d.mode in
              launch_memory_diagram ~now ~keeper ~content_rect ~kind:d.kind
                ~mode ~activity:act ~selected m
          | None -> (m, []))
      | None -> (m, []))
  | (Some _ | None), (Some _ | None) -> (m, [])

let refresh_open_memory_diagram ~now (m : Model.t) =
  match
    Memory_diagram.active_diagram m, Memory_diagram.active_memory_content_rect m
  with
  | Some d, Some (keeper, content_rect) when String.equal d.keeper keeper -> (
      match
        Observed.to_option
          (Knowledge_store.keeper_memory_activity_for ~keeper m.knowledge)
      with
      | Some act -> (
          match
            List.find_opt
              (fun (ev : Wire_knowledge.memory_activity_event) ->
                String.equal ev.identity d.event_identity)
              act.events
          with
          | Some selected ->
              launch_memory_diagram ~now ~keeper ~content_rect ~kind:d.kind
                ~mode:d.mode ~activity:act ~selected m
          | None -> (m, []))
      | None -> (m, []))
  | (Some _ | None), (Some _ | None) -> (m, [])

(* The reading Enter opens on the selected memory row of [keeper_opt]'s
   scope: an activity event, a fact or a diff item. *)
let selected_memory_reading ?(force_diff = false) ~keeper_opt
    (k : Knowledge_store.t) =
  if force_diff then
    match Knowledge_store.selected_memory_diff_item_for ~keeper_opt k with
    | Some item ->
        Some (Knowledge_store.Reading_diff_item { keeper = keeper_opt; item })
    | None -> None
  else
    match keeper_opt, k.memory_view_mode with
    | Some kp, Knowledge_store.View_evolution -> (
        match Knowledge_store.selected_activity_event_for ~keeper:kp k with
        | None -> None
        | Some event ->
            let notes =
              match
                Observed.to_option
                  (Knowledge_store.keeper_memory_activity_for ~keeper:kp k)
              with
              | Some act -> act.notes
              | None -> []
            in
            Some (Knowledge_store.Reading_activity { keeper = kp; event; notes }))
    | Some kp, Knowledge_store.View_facts -> (
        match Knowledge_store.selected_memory_fact_row ~keeper:kp k with
        | None -> None
        | Some (Knowledge_store.Fact_ordinary { revision; fact }) ->
            Some
              (Knowledge_store.Reading_ordinary_fact
                 { keeper = kp; revision; fact })
        | Some (Knowledge_store.Fact_source fact) ->
            Some (Knowledge_store.Reading_source_fact { keeper = kp; fact })
        | Some (Knowledge_store.Fact_source_invalidation invalidation) ->
            Some
              (Knowledge_store.Reading_source_invalidation
                 { keeper = kp; invalidation }))
    | _, Knowledge_store.View_diff
    | None, (Knowledge_store.View_evolution | Knowledge_store.View_facts) -> (
        match Knowledge_store.selected_memory_diff_item_for ~keeper_opt k with
        | Some item ->
            Some
              (Knowledge_store.Reading_diff_item { keeper = keeper_opt; item })
        | None -> None)

let acting_keepers (m : Model.t) : string list =
  let seen = Hashtbl.create 16 in
  let acc = ref [] in
  let add k =
    let k = String.trim k in
    if (not (String.equal k "")) && not (Hashtbl.mem seen k) then (
      Hashtbl.add seen k ();
      acc := k :: !acc)
  in
  (match Observed.to_option m.fleet.turns with
  | Some turns ->
      List.iter (fun (t : Wire_fleet.keeper_turn_row) -> add t.keeper_name) turns
  | None -> ());
  (match Observed.to_option m.fleet.keepers with
  | Some keepers ->
      List.iter
        (fun (k : Wire_fleet.keeper_summary) ->
          match k.health with
          | Wire_fleet.Keeper_working | Wire_fleet.Keeper_recovering
          | Wire_fleet.Keeper_booting ->
              add k.name
          | Wire_fleet.Keeper_healthy
          | Wire_fleet.Keeper_idle
          | Wire_fleet.Keeper_degraded
          | Wire_fleet.Keeper_failing
          | Wire_fleet.Keeper_offline
          | Wire_fleet.Keeper_paused ->
              ())
        keepers
  | None -> ());
  List.rev !acc

let keeper_facts_categories (facts : Wire_knowledge.keeper_memory_facts) :
    (string * Wire_knowledge.keeper_ordinary_fact list) list =
  let ordinary_facts =
    match facts.ordinary with
    | Wire_knowledge.Memory_store_present om -> om.facts
    | Wire_knowledge.Memory_store_absent
    | Wire_knowledge.Memory_store_read_error _ ->
        []
  in
  let tbl : (string, Wire_knowledge.keeper_ordinary_fact list) Hashtbl.t =
    Hashtbl.create 8
  in
  List.iter
    (fun (f : Wire_knowledge.keeper_ordinary_fact) ->
      let raw_cat = Wire_knowledge.memory_fact_category_to_string f.category in
      let cat =
        if String.equal (String.trim raw_cat) "" then "general" else raw_cat
      in
      let prev = Option.value ~default:[] (Hashtbl.find_opt tbl cat) in
      Hashtbl.replace tbl cat (f :: prev))
    ordinary_facts;
  Hashtbl.fold (fun cat xs acc -> (cat, List.rev xs) :: acc) tbl []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

let code_fuzzy_matches ~query (m : Model.t) : string list =
  let files =
    match Observed.to_option m.infra.code.files_catalog with
    | Some (sc, cat) when Wire_infra.equal_workspace_scope sc m.infra.code.scope
      ->
        cat.files
    | Some _ | None -> []
  in
  let q = String.trim query in
  if String.equal q "" then take_n 20 files
  else
    files
    |> List.filter_map (fun path ->
           match fuzzy_score ~query:q path with
           | Some score -> Some (score, path)
           | None -> None)
    |> List.sort (fun (s1, p1) (s2, p2) ->
           let c = Int.compare s2 s1 in
           if c <> 0 then c else String.compare p1 p2)
    |> List.map snd

type keeper_identity_entry =
  | Identity_oauth of {
      provider : string;
      label : string;
      attached : bool;
      enabled : bool option;
    }
  | Identity_github

let keeper_identity_entries (m : Model.t) ~name : keeper_identity_entry list =
  let ks = Keeper_context_store.get_keeper ~keeper:name m.keeper_context in
  let attached_map :
      (string, Wire_keeper_context.oauth_attached_provider) Hashtbl.t =
    Hashtbl.create 8
  in
  (match Observed.to_option ks.oauth_attached with
  | Some snap ->
      List.iter
        (fun (p : Wire_keeper_context.oauth_attached_provider) ->
          Hashtbl.replace attached_map p.provider p)
        snap.providers
  | None -> ());
  let seen = Hashtbl.create 8 in
  let acc = ref [] in
  (match Observed.to_option m.keeper_context.oauth_providers with
  | Some snap ->
      List.iter
        (fun (p : Wire_keeper_context.oauth_provider_row) ->
          if not (Hashtbl.mem seen p.id) then (
            Hashtbl.add seen p.id ();
            let att = Hashtbl.find_opt attached_map p.id in
            let attached =
              match att with Some a -> a.attached | None -> false
            in
            let enabled = Option.bind att (fun a -> a.enabled) in
            acc :=
              Identity_oauth
                { provider = p.id; label = p.label; attached; enabled }
              :: !acc))
        snap.providers
  | None -> ());
  (match Observed.to_option ks.oauth_attached with
  | Some snap ->
      List.iter
        (fun (a : Wire_keeper_context.oauth_attached_provider) ->
          if not (Hashtbl.mem seen a.provider) then (
            Hashtbl.add seen a.provider ();
            acc :=
              Identity_oauth
                {
                  provider = a.provider;
                  label = a.provider_label;
                  attached = a.attached;
                  enabled = a.enabled;
                }
              :: !acc))
        snap.providers
  | None -> ());
  List.rev (Identity_github :: !acc)

(* What Enter does on the current unfocused view. [dive_selected] runs the
   plan and the footer reads [enter_hint], so the footer only offers Enter
   where the key does something. *)
type enter_plan =
  | Enter_noop
  | Enter_expand_company of string
  | Enter_keeper_action of Cmd.t list
  | Enter_dispatch of Cmd.t list
  | Enter_open_dos_screen
  | Enter_push of Nav.dive
  | Enter_attention of Attention.entry
  | Enter_toggle_unreported_accounts
  | Enter_fetch_memory_diff
  | Enter_open_memory_reading of Knowledge_store.memory_reading_entry
  | Enter_scope_memory of string option
  | Enter_toggle_fact_category of string
  | Enter_code_toggle_dir of {
      scope : Wire_infra.workspace_scope;
      path : string;
    }
  | Enter_code_open_file of {
      scope : Wire_infra.workspace_scope;
      path : string;
    }
  | Enter_code_jump_match of {
      scope : Wire_infra.workspace_scope;
      path : string;
      line : int;
    }

(* Enter on a memory row opens its reading, unless a reading or a memory
   diagram is already open; with nothing selected it does [otherwise]. *)
let memory_reading_plan ?force_diff ~keeper_opt ~otherwise (m : Model.t) =
  if
    Option.is_some m.knowledge.memory_reading
    || Option.is_some (Memory_diagram.active_diagram m)
  then Enter_noop
  else
    match selected_memory_reading ?force_diff ~keeper_opt m.knowledge with
    | Some entry -> Enter_open_memory_reading entry
    | None -> otherwise ()

let keeper_enter_plan ~name ~tab (m : Model.t) : enter_plan =
  let ks = Keeper_context_store.get_keeper ~keeper:name m.keeper_context in
  match tab with
  | Nav.Keeper_context
    when Keeper_context_store.equal_context_subtab ks.subtab
           Keeper_context_store.Ctx_exact_input -> (
      match
        Keeper_context_store.selected_turn_ref ks
      , Keeper_context_store.selected_provider_part ks
      with
      | Some turn_ref, Some part ->
          Enter_keeper_action
            [
              Cmd.Http_get
                {
                  epoch = m.epoch;
                  req =
                    Cmd.Get_keeper_provider_input_part
                      { keeper = name; turn_ref; index = part.part_index };
                };
            ]
      | _ -> Enter_noop)
  | Nav.Keeper_tool_calls -> (
      match Keeper_context_store.selected_tool_call ks with
      | Some { execution_id = Some execution_id; _ } ->
          Enter_keeper_action
            [
              Cmd.Http_get
                {
                  epoch = m.epoch;
                  req =
                    Cmd.Get_keeper_tool_result
                      {
                        keeper = name;
                        execution_id;
                        offset = Some 0;
                        max_bytes = Some 16384;
                        source_id = None;
                      };
                };
            ]
      | Some { execution_id = None; _ } | None -> Enter_noop)
  | Nav.Keeper_memory
    when Knowledge_store.equal_keeper_memory_subview
           m.knowledge.keeper_memory_subview Knowledge_store.Kmem_facts_tree -> (
      match Knowledge_store.memory_facts_for_keeper ~keeper:name m.knowledge with
      | Some facts -> (
          let cats = keeper_facts_categories facts in
          match
            List.nth_opt cats
              (clamp_index (List.length cats) m.knowledge.facts_selected_index)
          with
          | Some (cat, _) -> Enter_toggle_fact_category cat
          | None -> Enter_noop)
      | None -> Enter_noop)
  | Nav.Keeper_identity -> (
      let entries = keeper_identity_entries m ~name in
      match
        List.nth_opt entries
          (clamp_index (List.length entries) ks.identity_selected_idx)
      with
      | Some (Identity_oauth { provider; enabled; _ }) ->
          let next_enabled = not (Option.value ~default:false enabled) in
          Enter_keeper_action
            [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req =
                    Cmd.Post_oauth_identity_switch
                      { keeper = name; provider; enabled = next_enabled };
                };
            ]
      | Some Identity_github | None -> Enter_noop)
  | Nav.Keeper_chat
  | Nav.Keeper_context
  | Nav.Keeper_memory
  | Nav.Keeper_work_candle
  | Nav.Keeper_sandbox
  | Nav.Keeper_config
  | Nav.Keeper_logs ->
      Enter_noop

let keeper_enter_action ~name ~tab (m : Model.t) =
  match keeper_enter_plan ~name ~tab m with
  | Enter_keeper_action cmds -> (m, cmds)
  | Enter_toggle_fact_category cat ->
      ( {
          m with
          knowledge = Knowledge_store.toggle_fact_category cat m.knowledge;
        }
      , [] )
  | Enter_noop
  | Enter_expand_company _
  | Enter_dispatch _
  | Enter_open_dos_screen
  | Enter_push _
  | Enter_attention _
  | Enter_toggle_unreported_accounts
  | Enter_fetch_memory_diff
  | Enter_open_memory_reading _
  | Enter_scope_memory _
  | Enter_code_toggle_dir _
  | Enter_code_open_file _
  | Enter_code_jump_match _ ->
      (m, [])

let enter_plan (m : Model.t) : enter_plan =
  (* Never push duplicate or cross-workspace dives when already inside a dive!
     Inside Keeper_context (Exact_input), Keeper_tool_calls, or Keeper_memory
     (Facts Tree), Enter fetches the selected part/result or toggles category. *)
  match Model.active_dive m with
  | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_memory })
    when Knowledge_store.equal_keeper_memory_subview
           m.knowledge.keeper_memory_subview Knowledge_store.Kmem_diff_flow ->
      memory_reading_plan ~keeper_opt:(Some name)
        ~otherwise:(fun () -> Enter_noop)
        m
  | Some
      (Nav.Dive_knowledge (Nav.Memory_diff_dive { keeper; from_rev; to_rev })) ->
      memory_reading_plan ~force_diff:true ~keeper_opt:keeper
        ~otherwise:(fun () -> Enter_noop)
        {
          m with
          knowledge =
            Knowledge_store.scope_memory_diff_dive ~keeper ~from_rev ~to_rev
              m.knowledge;
        }
  | Some
      (Nav.Dive_keeper
         {
           name;
           tab =
             ( Nav.Keeper_context
             | Nav.Keeper_tool_calls
             | Nav.Keeper_memory
             | Nav.Keeper_identity ) as tab;
         }) ->
      keeper_enter_plan ~name ~tab m
  | Some (Nav.Dive_runtime (Nav.Fusion_dive run_id)) -> (
      let post_id_opt =
        match Runtime_store.fusion_detail_for ~run_id m.runtime with
        | Some { evidence = Wire_runtime.Evidence_recorded p; _ } ->
            Some p.post_id
        | Some
            {
              evidence = Wire_runtime.Evidence_pending | Wire_runtime.Evidence_absent;
              _;
            }
        | None -> (
            match Runtime_store.historical_evidence_for_run ~run_id m.runtime with
            | Some ev -> Some ev.post_id
            | None -> None)
      in
      match post_id_opt with
      | Some post_id ->
          Enter_dispatch
            [
              Cmd.Http_get
                {
                  epoch = m.epoch;
                  req = Cmd.Get_fusion_board_evidence { post_id };
                };
            ]
      | None -> Enter_noop)
  | Some
      (Nav.Dive_keeper
         {
           tab =
             ( Nav.Keeper_chat
             | Nav.Keeper_work_candle
             | Nav.Keeper_sandbox
             | Nav.Keeper_config
             | Nav.Keeper_logs );
           _;
         })
  | Some
      ( Nav.Dive_work _
      | Nav.Dive_knowledge
          (Nav.Thread_dive _ | Nav.Wiki_dive _ | Nav.Artifact_dive _)
      | Nav.Dive_runtime (Nav.Tool_dive _)
      | Nav.Dive_infra _ ) ->
      Enter_noop
  | None -> (
      match m.nav.workspace with
      | Nav.Pulse -> (
          match Model.active_pulse_pane m with
          | Model.Pulse_attention -> (
              match Attention.current_triage_item m.attention with
              | Some entry -> Enter_attention entry
              | None -> Enter_noop)
          | Model.Pulse_companies -> (
              match Fleet_store.selected_company_keeper m.fleet with
              | Some k ->
                  Enter_push
                    (Nav.Dive_keeper
                       { name = k.name; tab = m.fleet.keeper_dive_tab })
              | None -> Enter_noop)
          | Model.Pulse_goals -> (
              match Work_store.selected_pulse_goal m.work with
              | Some g -> Enter_push (Nav.Dive_work (Nav.Goal_dive g.id))
              | None -> Enter_noop)
          | Model.Pulse_world -> (
              match Knowledge_store.selected_pulse_thread m.knowledge with
              | Some p -> Enter_push (Nav.Dive_knowledge (Nav.Thread_dive p.id))
              | None -> Enter_noop))
      | Nav.Keepers -> (
          match m.fleet.selected_collapsed_company with
          | Some company when m.nav.pane_index = 0 && not m.nav.zoomed ->
              Enter_expand_company company
          | Some _ | None ->
          match Fleet_store.selected_keeper_summary m.fleet with
          | Some k
            when (m.nav.pane_index = 1 || m.nav.zoomed)
                 && (Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                       Nav.Keeper_context
                    || Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                         Nav.Keeper_tool_calls
                    || Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                         Nav.Keeper_identity
                    || (Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                          Nav.Keeper_memory
                       && Knowledge_store.equal_keeper_memory_subview
                            m.knowledge.keeper_memory_subview
                            Knowledge_store.Kmem_facts_tree)) ->
              keeper_enter_plan ~name:k.name ~tab:m.fleet.keeper_dive_tab m
          | Some k ->
              if
                (m.nav.pane_index = 1 || m.nav.zoomed)
                && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                     Nav.Keeper_memory
              then
                if
                  Knowledge_store.equal_keeper_memory_subview
                    m.knowledge.keeper_memory_subview
                    Knowledge_store.Kmem_diff_flow
                then
                  memory_reading_plan ~keeper_opt:(Some k.name)
                    ~otherwise:(fun () -> Enter_noop)
                    m
                else Enter_noop
              else
                Enter_push
                  (Nav.Dive_keeper
                     { name = k.name; tab = m.fleet.keeper_dive_tab })
          | None -> Enter_noop)
      | Nav.Work -> (
          match m.work.active_tab with
          | Nav.Work_pipeline -> (
              match m.nav.pane_index with
              | 1 when Model.work_pipeline_has_linked_card m -> (
                  match Work_store.selected_verification m.work with
                  | Some v ->
                      Enter_push
                        (Nav.Dive_work (Nav.Verification_dive v.request_id))
                  | None -> Enter_noop)
              | _ -> (
                  match Work_store.selected_goal m.work with
                  | Some g -> Enter_push (Nav.Dive_work (Nav.Goal_dive g.id))
                  | None -> Enter_noop))
          | Nav.Work_tasks -> (
              match Work_store.selected_task m.work with
              | Some task -> Enter_push (Nav.Dive_work (Nav.Task_dive task.id))
              | None -> Enter_noop)
          | Nav.Work_schedules -> Enter_noop
          | Nav.Work_inbox -> (
              match
                Attention.current_filtered_item ~query:m.work.filter_query
                  m.attention
              with
              | Some entry -> Enter_attention entry
              | None -> Enter_noop)
          | Nav.Work_candle_scorecard | Nav.Work_harness -> Enter_noop)
      | Nav.Knowledge -> (
          match m.knowledge.active_tab with
          | Nav.Knowledge_board -> (
              match Knowledge_store.selected_post m.knowledge with
              | Some p -> Enter_push (Nav.Dive_knowledge (Nav.Thread_dive p.id))
              | None -> Enter_noop)
          | Nav.Knowledge_wiki -> (
              match Knowledge_store.selected_wiki_page m.knowledge with
              | Some p ->
                  Enter_push (Nav.Dive_knowledge (Nav.Wiki_dive p.slug))
              | None -> Enter_noop)
          | Nav.Knowledge_artifacts -> (
              match Knowledge_store.selected_artifact m.knowledge with
              | Some a ->
                  Enter_push (Nav.Dive_knowledge (Nav.Artifact_dive a.id))
              | None -> Enter_noop)
          | Nav.Knowledge_memory -> (
              let diff_plan () =
                let rev_bounds =
                  match
                    Observed.to_option
                      (Knowledge_store.current_memory_diff m.knowledge)
                  with
                  | None -> None
                  | Some diff -> (
                      match diff.range.from_rev, diff.range.to_rev with
                      | Some a, Some b when b >= a && b > 0 -> Some (a, b)
                      | Some _, Some _
                      | Some _, None
                      | None, Some _
                      | None, None -> (
                          match diff.body with
                          | Wire_knowledge.Keeper_diff { revisions = first :: rest; _ } ->
                              let last =
                                List.fold_left (fun _ r -> r) first rest
                              in
                              Some (min first.rev last.rev, max first.rev last.rev)
                          | Wire_knowledge.World_diff { revisions = first :: rest; _ } ->
                              let last =
                                List.fold_left (fun _ r -> r) first rest
                              in
                              Some (min first.rev last.rev, max first.rev last.rev)
                          | Wire_knowledge.Keeper_diff { revisions = []; _ }
                          | Wire_knowledge.World_diff { revisions = []; _ } ->
                              None))
                in
                match rev_bounds with
                | Some (from_rev, to_rev) ->
                    Enter_push
                      (Nav.Dive_knowledge
                         (Nav.Memory_diff_dive
                            {
                              keeper = m.knowledge.memory_diff_keeper;
                              from_rev;
                              to_rev;
                            }))
                | None -> Enter_fetch_memory_diff
              in
              if
                not
                  (Knowledge_store.equal_memory_subview
                     m.knowledge.memory_subview Knowledge_store.Mem_diff_flow)
              then Enter_noop
              else if m.nav.pane_index = 1 || m.nav.zoomed then
                memory_reading_plan ~keeper_opt:m.knowledge.memory_diff_keeper
                  ~otherwise:diff_plan m
              else
                match Knowledge_store.selected_memory_left_row m.knowledge with
                | Some (Knowledge_store.Left_writer w) ->
                    Enter_scope_memory (Some w.keeper)
                | Some Knowledge_store.Left_world_scope -> Enter_scope_memory None
                | Some (Knowledge_store.Left_conflict _) | None -> diff_plan ()))
      | Nav.Runtime -> (
          match m.runtime.active_tab with
          | Nav.Runtime_quotas_credits ->
              if
                m.nav.pane_index = 1
                && Runtime_store.is_unreported_toggle_row_selected m.runtime
              then Enter_toggle_unreported_accounts
              else Enter_noop
          | Nav.Runtime_failover_lanes -> (
              match Runtime_store.selected_lane m.runtime with
              | Some lane -> Enter_push (Nav.Dive_infra (Nav.Lane_dive lane.id))
              | None -> Enter_noop)
          | Nav.Runtime_efficiency_spend -> (
              match Runtime_store.selected_keeper_spend_row m.runtime with
              | Some row ->
                  Enter_push
                    (Nav.Dive_keeper
                       { name = row.keeper; tab = Nav.Keeper_work_candle })
              | None -> Enter_noop)
          | Nav.Runtime_tools_usage -> (
              match m.runtime.tools_subview with
              | Runtime_store.Tools_catalog_tree -> (
                  match Runtime_store.selected_tool_catalog_entry m.runtime with
                  | Some entry ->
                      Enter_push (Nav.Dive_runtime (Nav.Tool_dive entry.name))
                  | None -> Enter_noop)
              | Runtime_store.Tools_usage_calls
              | Runtime_store.Tools_keeper_skills ->
                  Enter_noop)
          | Nav.Runtime_fusion -> (
              match Runtime_store.selected_fusion_run m.runtime with
              | Some run ->
                  Enter_push (Nav.Dive_runtime (Nav.Fusion_dive run.run_id))
              | None -> Enter_noop)
          | Nav.Runtime_addons_browser when m.runtime.addon_catalog_mode -> (
              match Runtime_store.selected_addon_catalog_entry m.runtime with
              | Some (Wire_runtime.Catalog_folder { path }) ->
                  Enter_dispatch
                    [
                      Cmd.Http_get
                        {
                          epoch = m.epoch;
                          req =
                            Cmd.Get_addon_package_catalog
                              { directory = Some path };
                        };
                    ]
              | Some (Wire_runtime.Catalog_package { manifest_path; _ }) ->
                  Enter_dispatch
                    [
                      Cmd.Http_get
                        {
                          epoch = m.epoch;
                          req = Cmd.Get_addon_package_preview { manifest_path };
                        };
                    ]
              | Some (Wire_runtime.Catalog_issue _) | None -> Enter_noop)
          | Nav.Runtime_addons_browser
            when m.nav.pane_index = 0 && Runtime_store.selected_live_dos_screen m.runtime ->
              Enter_open_dos_screen
          | Nav.Runtime_connectors | Nav.Runtime_addons_browser -> Enter_noop)
      | Nav.Infra -> (
          match m.infra.active_tab with
          | Nav.Infra_sandboxes -> (
              match Infra_store.selected_sandbox_keeper m.infra with
              | Some keeper ->
                  Enter_push (Nav.Dive_infra (Nav.Sandbox_dive keeper))
              | None -> Enter_noop)
          | Nav.Infra_code ->
              let scope = m.infra.code.scope in
              if m.nav.pane_index = 0 then
                match Infra_store.selected_code_tree_node m.infra with
                | None -> Enter_noop
                | Some node when node.has_children ->
                    Enter_code_toggle_dir { scope; path = node.path }
                | Some node -> Enter_code_open_file { scope; path = node.path }
              else (
                match m.infra.code.right_mode with
                | Infra_store.Code_search_results -> (
                    match Observed.to_option m.infra.code.search_result with
                    | Some (sc, res)
                      when Wire_infra.equal_workspace_scope sc scope -> (
                        match
                          List.nth_opt res.matches
                            m.infra.code.search_selected_index
                        with
                        | Some mt ->
                            Enter_code_jump_match
                              { scope; path = mt.path; line = max 1 mt.line }
                        | None -> Enter_noop)
                    | Some _ | None -> Enter_noop)
                | Infra_store.Code_file
                | Infra_store.Code_git_status
                | Infra_store.Code_git_branches
                | Infra_store.Code_git_worktrees
                | Infra_store.Code_git_blame
                | Infra_store.Code_git_log
                | Infra_store.Code_git_diff ->
                    Enter_noop)
          | Nav.Infra_activity_logs ->
              if m.infra.acting_rail_open && m.nav.pane_index = 2 then
                let acting = acting_keepers m in
                match
                  List.nth_opt acting
                    (clamp_index (List.length acting)
                       m.infra.acting_selected_index)
                with
                | Some k ->
                    Enter_push (Nav.Dive_infra (Nav.Runtime_trace_dive k))
                | None -> Enter_noop
              else (
                match Infra_store.selected_timeline_entry m.infra with
                | Some (Infra_store.Entry_log e) ->
                    Enter_push (Nav.Dive_infra (Nav.Log_detail_dive e.seq))
                | Some (Infra_store.Entry_event { keeper = Some k; _ }) ->
                    Enter_push (Nav.Dive_infra (Nav.Runtime_trace_dive k))
                | Some (Infra_store.Entry_event { keeper = None; _ }) | None ->
                    Enter_noop)
          | Nav.Infra_repos_changes -> Enter_noop))

let dive_selected (m : Model.t) =
  match enter_plan m with
  | Enter_noop -> (m, [])
  | Enter_expand_company company ->
      ( {
          m with
          fleet = Fleet_store.toggle_company_collapsed company m.fleet;
        }
      , [] )
  | Enter_keeper_action cmds | Enter_dispatch cmds -> (m, cmds)
  | Enter_open_dos_screen -> (m, [ Cmd.Open_dos_screen { epoch = m.epoch } ])
  | Enter_push dive -> push_dive m dive
  | Enter_attention entry -> dive_attention_entry m entry
  | Enter_toggle_unreported_accounts ->
      ( { m with runtime = Runtime_store.toggle_unreported_accounts m.runtime }
      , [] )
  | Enter_fetch_memory_diff ->
      ( m
      , [
          Cmd.Http_get
            {
              epoch = m.epoch;
              req =
                Cmd.Get_memory_diff
                  {
                    keeper = m.knowledge.memory_diff_keeper;
                    window = m.knowledge.memory_diff_window;
                  };
            };
        ] )
  | Enter_open_memory_reading entry ->
      ( {
          m with
          knowledge = Knowledge_store.open_memory_reading entry m.knowledge;
        }
      , [] )
  | Enter_scope_memory keeper ->
      let knowledge =
        Knowledge_store.set_memory_diff_keeper keeper m.knowledge
      in
      let next = { m with nav = { m.nav with pane_index = 1 }; knowledge } in
      (next, View_fetches.fetches_for_current_view next)
  | Enter_toggle_fact_category cat ->
      ( {
          m with
          knowledge = Knowledge_store.toggle_fact_category cat m.knowledge;
        }
      , [] )
  | Enter_code_toggle_dir { scope; path } ->
      let was_expanded =
        Infra_store.String_set.mem path m.infra.code.expanded_dirs
      in
      let infra = Infra_store.toggle_code_dir path m.infra in
      let needs_children =
        (not was_expanded)
        && not (Infra_store.String_map.mem path infra.code.children_by_dir)
      in
      let cmds =
        if needs_children then
          [
            Cmd.Http_get
              {
                epoch = m.epoch;
                req = Cmd.Get_workspace_children { scope; dir = path };
              };
          ]
        else []
      in
      ({ m with infra }, cmds)
  | Enter_code_open_file { scope; path } ->
      let infra =
        m.infra
        |> Infra_store.set_code_active_file (Some path)
        |> Infra_store.set_code_right_mode Infra_store.Code_file
      in
      let nav = { m.nav with pane_index = 1 } in
      ( { m with nav; infra }
      , [
          Cmd.Http_get
            { epoch = m.epoch; req = Cmd.Get_workspace_file { scope; path } };
        ] )
  | Enter_code_jump_match { scope; path; line } ->
      let code =
        {
          m.infra.code with
          active_file_path = Some path;
          right_mode = Infra_store.Code_file;
          file_scroll_offset = max 0 (line - 1);
          pending_jump_line = Some (path, line);
        }
      in
      ( { m with infra = { m.infra with code } }
      , [
          Cmd.Http_get
            { epoch = m.epoch; req = Cmd.Get_workspace_file { scope; path } };
        ] )

type enter_hint =
  | Enter_hint_hidden
  | Enter_hint_dos_screen
  | Enter_hint_dive
  | Enter_hint_edit_field
  | Enter_hint_confirm_field

(* Keeper config takes Enter before the keymap does
   (Update_input.dispatch_keeper_config_key, behind the same condition): Enter
   starts editing the selected field, or confirms the edit in progress. *)
let enter_hint (m : Model.t) =
  if Model.sidebar_has_focus m then
    Enter_hint_dive
  else if Model.is_keeper_config_active m && not (Drafts.is_focused m.drafts) then
    if Config_store.is_editing_field m.config then Enter_hint_confirm_field
    else Enter_hint_edit_field
  else
    match enter_plan m with
    | Enter_noop -> Enter_hint_hidden
    | Enter_open_dos_screen -> Enter_hint_dos_screen
    | Enter_expand_company _
    | Enter_keeper_action _ | Enter_dispatch _
    | Enter_push _ | Enter_attention _ | Enter_toggle_unreported_accounts
    | Enter_fetch_memory_diff | Enter_open_memory_reading _
    | Enter_scope_memory _ | Enter_toggle_fact_category _
    | Enter_code_toggle_dir _ | Enter_code_open_file _
    | Enter_code_jump_match _ ->
        Enter_hint_dive

type inline_form_kind =
  | Form_standard of Nav.inline_action_kind
  | Form_board_goal_proposal
  | Form_goal_confirmation_proof
  | Form_memory_act
  | Form_wiki_edit
  | Form_fusion_launch
  | Form_runtime_assign
  | Form_setup_account_key
  | Form_setup_login_start

let classify_inline_form (modal : Model.inline_modal_state) : inline_form_kind =
  match modal.kind with
  | Nav.Board_new_post -> (
      match modal.fields with
      | { key = "proposal_title"; _ } :: _ -> Form_board_goal_proposal
      | { key = "confirm_goal_id"; _ } :: _ -> Form_goal_confirmation_proof
      | { key = "memory_keeper"; _ } :: _ -> Form_memory_act
      | { key = "wiki_slug"; _ } :: _ -> Form_wiki_edit
      | { key = "fusion_keeper"; _ } :: _ -> Form_fusion_launch
      | { key = "assign_keeper"; _ } :: _ -> Form_runtime_assign
      | { key = "setup_key_integration"; _ } :: _ -> Form_setup_account_key
      | { key = "setup_login_integration"; _ } :: _ -> Form_setup_login_start
      | _ -> Form_standard Nav.Board_new_post)
  | ( Nav.Btw_query
    | Nav.Gate_reject _
    | Nav.Verification_reject _
    | Nav.Harness_overrule _
    | Nav.Task_cancel _
    | Nav.Schedule_form
    | Nav.Connector_form
    | Nav.Repo_add_form
    | Nav.Board_comment _
    | Nav.Github_token_form _
    | Nav.Code_finder_form
    | Nav.Code_search_form ) as std ->
      Form_standard std

(* The Schedule form's operator text. A delay is a whole count and one unit,
   [90s], [10m], [2h] or [1d]; anything else is refused rather than read as
   a guess. *)
let seconds_per_delay_unit = function
  | 's' -> Some 1
  | 'm' -> Some 60
  | 'h' -> Some 3600
  | 'd' -> Some 86400
  | _ -> None

let parse_schedule_delay raw =
  let text = String.lowercase_ascii (String.trim raw) in
  let len = String.length text in
  let refused =
    Error
      (Printf.sprintf "\"%s\" is not a delay such as 90s, 10m, 2h or 1d" raw)
  in
  if len < 2 then refused
  else
    let digits = String.sub text 0 (len - 1) in
    let count =
      if String.for_all (fun c -> c >= '0' && c <= '9') digits then
        int_of_string_opt digits
      else None
    in
    match (count, seconds_per_delay_unit text.[len - 1]) with
    | Some n, Some unit_sec when n >= 1 && n <= max_int / unit_sec ->
        Ok (n * unit_sec)
    | Some _, Some _ | Some _, None | None, Some _ | None, None -> refused

let parse_schedule_repeat raw =
  let words =
    String.split_on_char ' ' (String.lowercase_ascii (String.trim raw))
    |> List.filter (fun w -> not (String.equal w ""))
  in
  match words with
  | [ "once" ] -> Ok Wire_work.Repeat_once
  | [ "every"; delay ] ->
      Result.map
        (fun interval_sec -> Wire_work.Repeat_every { interval_sec })
        (parse_schedule_delay delay)
  | _ ->
      Error
        (Printf.sprintf "\"%s\" is not a repeat such as once or every 1h"
           raw)

let submit_inline_modal ~now (m : Model.t) =
  match m.inline_modal with
  | None -> (m, [])
  | Some modal when modal.submitting -> (m, [])
  | Some modal -> (
      let missing_required =
        List.find_opt
          (fun (f : Model.modal_form_field) ->
            f.required && String.equal (String.trim f.value) "")
          modal.fields
      in
      match missing_required with
      | Some fld ->
          let err =
            Printf.sprintf "%s is required" (Say.resolve m.lang fld.label)
          in
          ({ m with inline_modal = Some { modal with error = Some err } }, [])
      | None -> (
          let mark_submitting (m_in : Model.t) =
            {
              m_in with
              inline_modal = Some { modal with submitting = true; error = None };
            }
          in
          (* Mutations whose replies route through Reply_work_mutation,
             Reply_wiki_put, Reply_memory_act, or Reply_fusion_launch emit
             toasts in Update_http without clearing inline_modal, so close the
             modal immediately with an honest in-flight toast to prevent hang. *)
          let close_with_inflight_toast ~msg (m_in : Model.t) =
            let nav = { m_in.nav with overlay = None; filter_focused = false } in
            { m_in with nav; inline_modal = None }
            |> Model.with_toast ~now ~level:Model.Toast_info msg
          in
          let set_modal_error err =
            ({ m with inline_modal = Some { modal with error = Some err } }, [])
          in
          match classify_inline_form modal with
          | Form_standard Nav.Btw_query ->
              let prompt = Model.modal_field_value ~key:"prompt" modal in
              start_btw_query ~now ~prompt m
          | Form_standard (Nav.Gate_reject id) ->
              let reason = Model.modal_field_value ~key:"reason" modal in
              let attention =
                Attention.mark_in_flight ~id:("gate:" ^ id) m.attention
              in
              ( close_with_inflight_toast
                  ~msg:
                    (Say.make
                       ~ko:("게이트 거절 전송 중: " ^ id)
                       ~en:("Submitting gate rejection: " ^ id))
                  { m with attention }
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_gate_resolution
                          { id; approved = false; reason = Some reason };
                    };
                ] )
          | Form_standard (Nav.Verification_reject verification_id) -> (
              let reason = Model.modal_field_value ~key:"reason" modal in
              let notes_raw = Model.modal_field_value ~key:"notes" modal in
              let notes =
                if String.equal notes_raw "" then None else Some notes_raw
              in
              match
                List.find_opt
                  (fun (v : Wire_work.verification_request) ->
                    String.equal v.request_id verification_id)
                  (Work_store.verifications_list m.work)
              with
              | None ->
                  set_modal_error
                    (Printf.sprintf "Verification request %s not found"
                       verification_id)
              | Some v ->
                  ( close_with_inflight_toast
                      ~msg:
                        (Say.make
                           ~ko:("검증 거절 전송 중: " ^ v.task_title)
                           ~en:("Submitting verification rejection: " ^ v.task_title))
                      m
                  , [
                      Cmd.Http_post
                        {
                          epoch = m.epoch;
                          req =
                            Cmd.Post_verification_verdict
                              {
                                task_id = v.task_id;
                                verification_id;
                                verdict = Wire_work.Verdict_reject { reason };
                                notes;
                              };
                        };
                    ] ))
          | Form_standard (Nav.Harness_overrule default_hash) -> (
              let notes_hash_raw =
                String.trim (Model.modal_field_value ~key:"notes_hash" modal)
              in
              let notes_hash =
                if String.equal notes_hash_raw "" then String.trim default_hash
                else notes_hash_raw
              in
              let verdict_raw =
                String.lowercase_ascii
                  (Model.modal_field_value ~key:"verdict" modal)
              in
              let reason = Model.modal_field_value ~key:"reason" modal in
              if not (Wire_work.is_valid_notes_hash notes_hash) then
                set_modal_error
                  "notes_hash must be 64 lowercase hex characters"
              else
                match verdict_raw with
                | "approve" | "reject" ->
                    let verdict =
                      if String.equal verdict_raw "reject" then `Reject
                      else `Approve
                    in
                    ( mark_submitting m
                    , [
                        Cmd.Http_post
                          {
                            epoch = m.epoch;
                            req =
                              Cmd.Post_harness_overrule
                                { notes_hash; verdict; reason };
                          };
                      ] )
                | _ ->
                    set_modal_error "Verdict must be 'approve' or 'reject'")
          | Form_standard (Nav.Task_cancel task_id) -> (
              let reason_raw = Model.modal_field_value ~key:"reason" modal in
              let reason =
                if String.equal reason_raw "" then None else Some reason_raw
              in
              match expected_workspace_of m with
              | None ->
                  set_modal_error
                    "Server workspace identity must be loaded before \
                     cancelling a task"
              | Some expected_workspace ->
                  ( mark_submitting m
                  , [
                      Cmd.Http_post
                        {
                          epoch = m.epoch;
                          req =
                            Cmd.Post_task_cancel
                              { task_id; reason; expected_workspace };
                        };
                    ] ))
          | Form_standard Nav.Schedule_form -> (
              let keeper_name = Model.modal_field_value ~key:"keeper" modal in
              let message = Model.modal_field_value ~key:"prompt" modal in
              match
                ( parse_schedule_repeat
                    (Model.modal_field_value ~key:"recurrence" modal),
                  parse_schedule_delay
                    (Model.modal_field_value ~key:"first_run_in" modal) )
              with
              | Error err, (Ok _ | Error _) | Ok _, Error err ->
                  set_modal_error err
              | Ok repeat, Ok first_due_in_sec ->
                  ( mark_submitting m
                  , [
                      Cmd.Http_post
                        {
                          epoch = m.epoch;
                          req =
                            Cmd.Post_schedule_create
                              { keeper_name; message; first_due_in_sec; repeat };
                        };
                    ] ))
          | Form_standard Nav.Connector_form ->
              let connector = Model.modal_field_value ~key:"connector" modal in
              let channel_id =
                let cid = Model.modal_field_value ~key:"channel_id" modal in
                if String.equal cid "" then
                  Model.modal_field_value ~key:"channel" modal
                else cid
              in
              let keeper_name =
                let kn = Model.modal_field_value ~key:"keeper_name" modal in
                if String.equal kn "" then
                  Model.modal_field_value ~key:"keeper" modal
                else kn
              in
              ( mark_submitting m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_connector_bind
                          { connector; channel_id; keeper_name };
                    };
                ] )
          | Form_standard (Nav.Board_comment { post_id; parent_id }) ->
              let content = Model.modal_field_value ~key:"content" modal in
              ( mark_submitting m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_board_comment { post_id; content; parent_id };
                    };
                ] )
          | Form_standard Nav.Repo_add_form ->
              let url = Model.modal_field_value ~key:"url" modal in
              let branch_raw = Model.modal_field_value ~key:"branch" modal in
              let branch =
                if String.equal branch_raw "" then None else Some branch_raw
              in
              ( mark_submitting m
              , [
                  Cmd.Http_post
                    { epoch = m.epoch; req = Cmd.Post_repo_add { url; branch } };
                ] )
          | Form_standard Nav.Board_new_post ->
              let title = Model.modal_field_value ~key:"title" modal in
              let body = Model.modal_field_value ~key:"body" modal in
              let hearth_raw = Model.modal_field_value ~key:"hearth" modal in
              let hearth =
                if String.equal hearth_raw "" then None else Some hearth_raw
              in
              ( mark_submitting m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req = Cmd.Post_board_create { title; body; hearth };
                    };
                ] )
          | Form_board_goal_proposal -> (
              let title = Model.modal_field_value ~key:"proposal_title" modal in
              let measure =
                Model.modal_field_value ~key:"proposal_measure" modal
              in
              let proc =
                Model.modal_field_value ~key:"proposal_procedure" modal
              in
              let prio_raw =
                Model.modal_field_value ~key:"proposal_priority" modal
              in
              let prio_res =
                if String.equal prio_raw "" then Ok 2
                else
                  match int_of_string_opt prio_raw with
                  | Some p when p >= 1 && p <= 5 -> Ok p
                  | Some _ | None ->
                      Error "Priority must be an integer between 1 and 5"
              in
              match prio_res with
              | Error err -> set_modal_error err
              | Ok prio ->
                  let body =
                    if String.equal proc "" then
                      Printf.sprintf "Priority: P%d\nMeasure: %s" prio measure
                    else
                      Printf.sprintf
                        "Priority: P%d\nMeasure: %s\nProcedure: %s" prio measure
                        proc
                  in
                  ( mark_submitting m
                  , [
                      Cmd.Http_post
                        {
                          epoch = m.epoch;
                          req =
                            Cmd.Post_board_create
                              {
                                title = "[Goal Proposal] " ^ title;
                                body;
                                hearth = Some "goals";
                              };
                        };
                    ] ))
          | Form_goal_confirmation_proof -> (
              let goal_id =
                Model.modal_field_value ~key:"confirm_goal_id" modal
              in
              let criterion_revision =
                Model.modal_field_value ~key:"confirm_criterion_revision" modal
              in
              let request_id =
                Model.modal_field_value ~key:"confirm_request_id" modal
              in
              let verification_run_id =
                Model.modal_field_value ~key:"confirm_verification_run_id" modal
              in
              let expected_operator_id =
                Model.modal_field_value ~key:"confirm_operator_id" modal
              in
              match
                expected_workspace_of m, m.server_identity.observer_instance_id
              with
              | Some expected_workspace, Some inst_id
                when not (String.equal (String.trim inst_id) "") ->
                  let req : Wire_work.goal_confirmation_request =
                    {
                      goal_id;
                      criterion_revision;
                      request_id;
                      verification_run_id;
                      expected_workspace;
                      expected_operator_id;
                      expected_runtime_instance_id = String.trim inst_id;
                    }
                  in
                  ( close_with_inflight_toast
                      ~msg:
                        (Say.make
                           ~ko:("목표 완료 확정 전송 중: " ^ goal_id)
                           ~en:("Submitting goal confirmation: " ^ goal_id))
                      m
                  , [
                      Cmd.Http_post
                        { epoch = m.epoch; req = Cmd.Post_goal_confirmation req };
                    ] )
              | _ ->
                  set_modal_error
                    "Server workspace and runtime instance identity must be \
                     loaded before confirming a goal")
          | Form_memory_act -> (
              let keeper =
                Model.modal_field_value ~key:"memory_keeper" modal
              in
              let act_raw =
                String.lowercase_ascii
                  (Model.modal_field_value ~key:"memory_act" modal)
              in
              let arg = Model.modal_field_value ~key:"memory_arg" modal in
              let parsed_act =
                match act_raw with
                | "resume" -> Ok Wire_knowledge.Act_resume
                | "adopt" ->
                    if String.equal arg "" then
                      Error "Observed value is required for adopt"
                    else Ok (Wire_knowledge.Act_adopt { observed = arg })
                | "restart_reading" ->
                    if String.equal arg "" then
                      Error "Observed value is required for restart_reading"
                    else
                      Ok
                        (Wire_knowledge.Act_restart_reading { observed = arg })
                | "skip_item" -> (
                    match String.rindex_opt arg ':' with
                    | None ->
                        Error "skip_item requires <turn_log>:<line> argument"
                    | Some idx -> (
                        let turn_log = String.trim (String.sub arg 0 idx) in
                        let line_s =
                          String.trim
                            (String.sub arg (idx + 1)
                               (String.length arg - idx - 1))
                        in
                        match int_of_string_opt line_s with
                        | Some line
                          when line >= 1 && not (String.equal turn_log "") ->
                            Ok (Wire_knowledge.Act_skip_item { turn_log; line })
                        | Some _ | None ->
                            Error
                              "skip_item requires <turn_log>:<positive_line>"))
                | "skip_line" -> (
                    match int_of_string_opt arg with
                    | Some offset when offset >= 0 ->
                        Ok (Wire_knowledge.Act_skip_line { offset })
                    | Some _ | None ->
                        Error "skip_line requires a non-negative byte offset")
                | _ ->
                    Error
                      "Unsupported act (use: resume | adopt | restart_reading \
                       | skip_item | skip_line)"
              in
              match parsed_act with
              | Error err -> set_modal_error err
              | Ok act ->
                  ( close_with_inflight_toast
                      ~msg:
                        (Say.make
                           ~ko:("사서 기억 복구 전송 중: " ^ keeper)
                           ~en:("Submitting memory recovery act: " ^ keeper))
                      m
                  , [
                      Cmd.Http_post
                        {
                          epoch = m.epoch;
                          req = Cmd.Post_memory_act { keeper; act };
                        };
                    ] ))
          | Form_wiki_edit ->
              let slug = Model.modal_field_value ~key:"wiki_slug" modal in
              let title = Model.modal_field_value ~key:"wiki_title" modal in
              let summary = Model.modal_field_value ~key:"wiki_summary" modal in
              let body = Model.modal_field_value ~key:"wiki_body" modal in
              let note_raw = Model.modal_field_value ~key:"wiki_note" modal in
              let note =
                if String.equal note_raw "" then "TUI inline edit" else note_raw
              in
              (* The save names the revision the form opened on, not the
                 one the slot holds now: a page read again while the form is
                 open must not let the old text pass the server's check. A
                 slug typed over the base's creates a page, which the server
                 refuses if one exists. *)
              let expected_revision, expected_sha256, source, tags =
                match m.knowledge.wiki_edit_base with
                | Some base when String.equal base.slug slug ->
                    ( Some base.revision
                    , Some base.sha256
                    , base.source
                    , base.tags )
                | Some _ | None ->
                    (None, None, Wire_knowledge.Source_observation, [])
              in
              let request : Wire_knowledge.wiki_put_request =
                {
                  expected_revision;
                  expected_sha256;
                  title;
                  summary;
                  source;
                  tags;
                  body;
                  note;
                }
              in
              ( close_with_inflight_toast
                  ~msg:
                    (Say.make
                       ~ko:("위키 문서 저장 중: " ^ slug)
                       ~en:("Saving wiki page: " ^ slug))
                  {
                    m with
                    knowledge = Knowledge_store.end_wiki_edit m.knowledge;
                  }
              , [
                  Cmd.Http_put
                    {
                      epoch = m.epoch;
                      req = Cmd.Put_wiki_page { page = slug; request };
                    };
                ] )
          | Form_fusion_launch -> (
              let keeper =
                Model.modal_field_value ~key:"fusion_keeper" modal
              in
              let prompt =
                Model.modal_field_value ~key:"fusion_prompt" modal
              in
              let topo_raw =
                String.lowercase_ascii
                  (Model.modal_field_value ~key:"fusion_topology" modal)
              in
              let preset_raw =
                Model.modal_field_value ~key:"fusion_preset" modal
              in
              let topology_res =
                if String.equal topo_raw "" then Ok None
                else
                  match Wire_runtime.fusion_topology_of_string topo_raw with
                  | Some topo -> Ok (Some topo)
                  | None ->
                      Error
                        "Unknown topology (use: simple | refine | conditional \
                         | judge_of_judges | staged_judge_of_judges)"
              in
              match topology_res with
              | Error err -> set_modal_error err
              | Ok topology ->
                  let preset =
                    if String.equal preset_raw "" then None
                    else Some preset_raw
                  in
                  let request : Wire_runtime.fusion_launch_request =
                    { prompt; preset; topology; web_tools = false }
                  in
                  let runtime =
                    Runtime_store.set_fusion_submitting true m.runtime
                  in
                  ( close_with_inflight_toast
                      ~msg:
                        (Say.make
                           ~ko:("퓨전 패널 실행 요청 중: " ^ keeper)
                           ~en:("Launching fusion run for " ^ keeper))
                      { m with runtime }
                  , [
                      Cmd.Http_post
                        {
                          epoch = m.epoch;
                          req = Cmd.Post_fusion_launch { keeper; request };
                        };
                    ] ))
          | Form_runtime_assign -> (
              let keeper_raw =
                String.trim (Model.modal_field_value ~key:"assign_keeper" modal)
              in
              let runtime_raw =
                String.trim (Model.modal_field_value ~key:"assign_runtime_id" modal)
              in
              if String.equal keeper_raw "" || String.equal (String.lowercase_ascii keeper_raw) "default" then
                if String.equal runtime_raw "" then
                  set_modal_error "runtime_id is required when setting the default route"
                else
                  ( close_with_inflight_toast
                      ~msg:
                        (Say.make
                           ~ko:("기본 런타임 변경 전송 중: " ^ runtime_raw)
                           ~en:("Updating default route: " ^ runtime_raw))
                      m
                  , [
                      Cmd.Http_post
                        {
                          epoch = m.epoch;
                          req =
                            Cmd.Post_runtime_default_route
                              { runtime_id = runtime_raw };
                        };
                    ] )
              else
                let runtime_id =
                  if String.equal runtime_raw "" then None else Some runtime_raw
                in
                let source_revision, previous_runtime_id =
                  match Observed.to_option m.runtime.runtime_config_raw with
                  | Some meta ->
                      ( Some meta.source_revision
                      , List.assoc_opt keeper_raw meta.assignments )
                  | None -> (None, None)
                in
                ( close_with_inflight_toast
                    ~msg:
                      (Say.make
                         ~ko:
                           (Printf.sprintf "키퍼 런타임 배정 전송 중: %s -> %s"
                              keeper_raw
                              (Option.value runtime_id ~default:"(default)"))
                         ~en:
                           (Printf.sprintf "Assigning runtime for %s -> %s"
                              keeper_raw
                              (Option.value runtime_id ~default:"(default)")))
                    m
                , [
                    Cmd.Http_post
                      {
                        epoch = m.epoch;
                        req =
                          Cmd.Post_runtime_assignment
                            {
                              keeper_name = keeper_raw;
                              runtime_id;
                              source_revision;
                              previous_runtime_id;
                            };
                      };
                  ] ))
          | Form_setup_account_key -> (
              let integration_id =
                String.trim
                  (Model.modal_field_value ~key:"setup_key_integration" modal)
              in
              let key =
                String.trim (Model.modal_field_value ~key:"setup_key_secret" modal)
              in
              match Observed.to_option m.runtime.runtime_config_raw with
              | None ->
                  set_modal_error
                    "Runtime config revision not loaded yet — press [r] to refresh"
              | Some meta ->
                  ( close_with_inflight_toast
                      ~msg:
                        (Say.make
                           ~ko:("API 키 등록 요청 중: " ^ integration_id)
                           ~en:("Registering API key for " ^ integration_id))
                      m
                  , [
                      Cmd.Http_post
                        {
                          epoch = m.epoch;
                          req =
                            Cmd.Post_setup_account_key
                              {
                                integration_id;
                                key;
                                source_revision = meta.source_revision;
                              };
                        };
                    ] ))
          | Form_standard (Nav.Github_token_form keeper) ->
              let token = Model.modal_field_value ~key:"token" modal in
              let hostname_raw = Model.modal_field_value ~key:"hostname" modal in
              let hostname =
                if String.equal hostname_raw "" then None else Some hostname_raw
              in
              (* Security: close modal immediately and never echo/log PAT. *)
              ( close_with_inflight_toast
                  ~msg:
                    (Say.make
                       ~ko:("GitHub PAT 저장 요청 전송 중: " ^ keeper)
                       ~en:("Submitting masked GitHub PAT for " ^ keeper))
                  m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req = Cmd.Post_github_token { keeper; token; hostname };
                    };
                ] )
          | Form_standard Nav.Code_finder_form ->
              let query = Model.modal_field_value ~key:"query" modal in
              let scope = m.infra.code.scope in
              let path =
                match code_fuzzy_matches ~query m with
                | first :: _ -> first
                | [] -> query
              in
              let infra =
                m.infra
                |> Infra_store.set_code_active_file (Some path)
                |> Infra_store.set_code_right_mode Infra_store.Code_file
              in
              let nav =
                {
                  m.nav with
                  overlay = None;
                  filter_focused = false;
                  pane_index = 1;
                }
              in
              ( { m with nav; infra; inline_modal = None }
              , [
                  Cmd.Http_get
                    {
                      epoch = m.epoch;
                      req = Cmd.Get_workspace_file { scope; path };
                    };
                ] )
          | Form_standard Nav.Code_search_form ->
              let query = Model.modal_field_value ~key:"query" modal in
              let qlen = String.length query in
              if qlen < 2 || qlen > 200 then
                set_modal_error "Query must be between 2 and 200 bytes"
              else
                let scope = m.infra.code.scope in
                let infra =
                  Infra_store.set_code_right_mode
                    Infra_store.Code_search_results m.infra
                in
                let nav =
                  {
                    m.nav with
                    overlay = None;
                    filter_focused = false;
                    pane_index = 1;
                  }
                in
                ( { m with nav; infra; inline_modal = None }
                , [
                    Cmd.Http_get
                      {
                        epoch = m.epoch;
                        req = Cmd.Get_workspace_search { scope; query };
                      };
                  ] )
          | Form_setup_login_start ->
              let integration_id =
                String.trim
                  (Model.modal_field_value ~key:"setup_login_integration" modal)
              in
              let account_ref_raw =
                String.trim
                  (Model.modal_field_value ~key:"setup_login_account_ref" modal)
              in
              let account_ref =
                if String.equal account_ref_raw "" then None
                else Some account_ref_raw
              in
              ( close_with_inflight_toast
                  ~msg:
                    (Say.make
                       ~ko:("계정 로그인 시작 요청 중: " ^ integration_id)
                       ~en:("Starting official CLI login for " ^ integration_id))
                  m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_setup_login_start
                          { integration_id; account_ref };
                    };
                ] )))

let move_delta = function
  | Keymap.Up -> -1
  | Keymap.Down -> 1
  | Keymap.Page_up -> -10
  | Keymap.Page_down -> 10
  | Keymap.Home -> -100000
  | Keymap.End -> 100000
  | Keymap.Left | Keymap.Right -> 0

let estimated_viewport_rows (m : Model.t) =
  let rows = m.viewport.rows in
  match m.nav.overlay with
  | Some (Nav.Settings _) -> max 4 (rows - 10)
  | Some Nav.Incidents -> max 4 ((rows - 8) * 45 / 100)
  | Some
      ( Nav.Palette
      | Nav.Queue_context _
      | Nav.Inline_action _
      | Nav.Ask_answer
      | Nav.Help
      | Nav.System_gate _ ) ->
      max 4 (rows - 10)
  | None -> (
      match m.nav.workspace with
      | Nav.Pulse -> max 4 (rows / 3)
      | Nav.Keepers -> max 4 (rows - 11)
      | Nav.Work -> (
          match m.work.active_tab with
          | Nav.Work_pipeline -> min 10 (max 4 (rows - 14))
          | Nav.Work_tasks | Nav.Work_schedules -> max 4 (rows - 14)
          | Nav.Work_inbox | Nav.Work_candle_scorecard | Nav.Work_harness ->
              max 4 (rows - 12))
      | Nav.Knowledge -> max 4 (rows - 14)
      | Nav.Runtime -> (
          match m.runtime.active_tab with
          | Nav.Runtime_efficiency_spend -> max 4 ((rows - 10) * 40 / 100)
          | Nav.Runtime_tools_usage -> max 4 (rows - 16)
          | Nav.Runtime_fusion
          | Nav.Runtime_connectors
          | Nav.Runtime_addons_browser ->
              max 4 (rows - 14)
          | Nav.Runtime_quotas_credits | Nav.Runtime_failover_lanes ->
              max 4 (rows - 11))
      | Nav.Infra -> max 4 (rows - 12))

let sync_runtime_companies_if_needed (m : Model.t) =
  match Observed.to_option m.fleet.keepers with
  | Some ks when ks <> [] -> Runtime_store.sync_keeper_companies ks m.runtime
  | Some _ | None -> m.runtime

let scroll_delta = function
  | Keymap.Up -> -1
  | Keymap.Down -> 1
  | Keymap.Page_up -> -10
  | Keymap.Page_down -> 10
  | Keymap.Home -> -100000
  | Keymap.End -> 100000
  | Keymap.Left | Keymap.Right -> 0

let ui_bp (m : Model.t) =
  Masc_tui_ui.Layout.classify_viewport ~cols:(max 0 m.viewport.cols)
    ~rows:(max 0 m.viewport.rows)

let ui_body_rect (m : Model.t) =
  Rect.make ~x:0 ~y:0 ~w:(Model.inner_body_width m)
    ~h:(Model.inner_body_height m)

let ui_card_inner (r : Rect.t) =
  if r.w >= 2 && r.h >= 2 then
    Rect.make ~x:(r.x + 1) ~y:(r.y + 1) ~w:(r.w - 2) ~h:(r.h - 2)
  else Rect.empty

let ui_pad_content ~bp ?(pad_y = 0) (r : Rect.t) =
  Masc_tui_ui.Card.pad_inner ~pad_x:(Masc_tui_ui.Layout.card_pad_x bp) ~pad_y r

let markdown_max_scroll ~theme ~width ~height text =
  if width <= 0 || height <= 0 then 0
  else
    let lines = Masc_tui_ui.Markdown.render_lines ~width ~theme text in
    max 0 (List.length lines - height)

let parse_json_or_wrap_store ~key raw =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then `Assoc []
  else
    try Yojson.Safe.from_string trimmed
    with Yojson.Json_error _ -> `Assoc [ (key, `String raw) ]

let extract_embedded_json_store s =
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

let ops_pad_content (r : Rect.t) =
  let pad_x = if r.w >= 60 then 2 else 1 in
  Masc_tui_ui.Card.pad_inner ~pad_x ~pad_y:0 r

let rejection_diff_row_count ~lang (v : Wire_work.verification_request) =
  let say ~ko ~en = Say.resolve lang (Say.make ~ko ~en) in
  let expected_lines =
    let c =
      List.map (fun s -> say ~ko:("계약: " ^ s) ~en:("Contract: " ^ s))
        v.completion_contract
    in
    let a =
      List.map (fun s -> say ~ko:("필수 산출물: " ^ s) ~en:("Required: " ^ s))
        v.required_artifacts
    in
    c @ a
  in
  let observed_lines =
    let ev =
      if v.submitted_evidence = [] then
        [ say ~ko:"제출된 증거: 없음" ~en:"Submitted evidence: none" ]
      else
        List.map (fun s -> say ~ko:("증거: " ^ s) ~en:("Evidence: " ^ s))
          v.submitted_evidence
    in
    let err =
      match v.evidence_projection_error with
      | Some e -> [ say ~ko:("증거 투영 오류: " ^ e) ~en:("Evidence gap: " ^ e) ]
      | None -> []
    in
    let critique =
      match v.review_observation with
      | Some obs when not (String.equal (String.trim obs.detail) "") ->
          [
            Printf.sprintf "%s (%s): %s"
              (say ~ko:"검증자 판정" ~en:"Verifier")
              obs.actor obs.detail;
          ]
      | Some _ | None -> []
    in
    ev @ err @ critique
  in
  let before = String.concat "\n" expected_lines in
  let after = String.concat "\n" observed_lines in
  List.length (Masc_tui_ui.Diff.rows ~before ~after)

let evidence_checklist_row_count (v : Wire_work.verification_request) =
  List.length v.required_artifacts
  + List.length v.submitted_evidence
  + if Option.is_some v.evidence_projection_error then 1 else 0

let json_of_goal_store (g : Wire_work.goal) : Yojson.Safe.t =
  let opt_s = function Some s -> `String s | None -> `Null in
  let crit =
    match g.criterion_verdict with
    | Wire_work.Criterion_pending -> `String "pending"
    | Wire_work.Criterion_valid -> `String "valid"
    | Wire_work.Criterion_invalid r -> `Assoc [ ("invalid", `String r) ]
    | Wire_work.Criterion_unavailable r -> `Assoc [ ("unavailable", `String r) ]
  in
  `Assoc
    [
      ("id", `String g.id);
      ("title", `String g.title);
      ("phase", `String (Wire_work.goal_phase_to_string g.phase));
      ("priority", `Int g.priority);
      ("due_date", opt_s g.due_date);
      ("measure", `String g.measure);
      ("procedure", `String g.procedure);
      ("criterion_revision", opt_s g.criterion_revision);
      ("criterion_verdict", crit);
      ("last_review_note", opt_s g.last_review_note);
    ]

let json_of_task_store (tk : Wire_work.task) : Yojson.Safe.t =
  let opt_s = function Some s -> `String s | None -> `Null in
  let st_json =
    match tk.status with
    | Wire_work.Todo -> `Assoc [ ("state", `String "Todo") ]
    | Wire_work.Claimed { assignee; claimed_at } ->
        `Assoc
          [
            ("state", `String "Claimed");
            ("assignee", `String assignee);
            ("claimed_at", `String claimed_at);
          ]
    | Wire_work.InProgress { assignee; started_at } ->
        `Assoc
          [
            ("state", `String "InProgress");
            ("assignee", `String assignee);
            ("started_at", `String started_at);
          ]
    | Wire_work.AwaitingVerification
        { assignee; started_at; submitted_at; verification_id } ->
        `Assoc
          [
            ("state", `String "AwaitingVerification");
            ("assignee", `String assignee);
            ("started_at", `String started_at);
            ("submitted_at", `String submitted_at);
            ("verification_id", `String verification_id);
          ]
    | Wire_work.Done { assignee; completed_at; notes } ->
        `Assoc
          [
            ("state", `String "Done");
            ("assignee", `String assignee);
            ("completed_at", `String completed_at);
            ("notes", opt_s notes);
          ]
    | Wire_work.Cancelled { cancelled_by; cancelled_at; reason } ->
        `Assoc
          [
            ("state", `String "Cancelled");
            ("cancelled_by", `String cancelled_by);
            ("cancelled_at", `String cancelled_at);
            ("reason", opt_s reason);
          ]
  in
  let gl_json =
    match tk.goal_link with
    | Wire_work.Unlinked -> `Null
    | Wire_work.Linked gid -> `String gid
  in
  `Assoc
    [
      ("id", `String tk.id);
      ("title", `String tk.title);
      ("priority", `Int tk.priority);
      ("goal_id", gl_json);
      ("status", st_json);
      ("description", opt_s tk.description);
    ]

let json_of_verification_store (v : Wire_work.verification_request) :
    Yojson.Safe.t =
  let opt_s = function Some s -> `String s | None -> `Null in
  let obs_json =
    match v.review_observation with
    | None -> `Null
    | Some obs ->
        `Assoc
          [
            ("state", `String "observed");
            ("actor", `String obs.actor);
            ("detail", `String obs.detail);
          ]
  in
  `Assoc
    [
      ("request_id", `String v.request_id);
      ("task_id", `String v.task_id);
      ("task_title", `String v.task_title);
      ("submitted_by", `String v.submitted_by);
      ( "completion_contract"
      , `List (List.map (fun s -> `String s) v.completion_contract) );
      ( "required_artifacts"
      , `List (List.map (fun s -> `String s) v.required_artifacts) );
      ( "submitted_evidence"
      , `List (List.map (fun s -> `String s) v.submitted_evidence) );
      ("evidence_projection_error", opt_s v.evidence_projection_error);
      ("review_observation", obs_json);
    ]

let split_dive_with_json_store ~bp ~(show_raw_json : bool) (rect : Rect.t) =
  if show_raw_json && rect.w >= 88 then
    match
      Masc_tui_ui.Layout.split_h_bp bp rect
        [ Masc_tui_ui.Layout.Ratio 0.58; Masc_tui_ui.Layout.Flex 1 ]
    with
    | [ l; r ] -> (l, r)
    | _ -> (rect, Rect.empty)
  else if show_raw_json then (Rect.empty, rect)
  else (rect, Rect.empty)

let json_card_max_scroll ~max_depth (json_card_rect : Rect.t)
    (json : Yojson.Safe.t) =
  let inner = ui_card_inner json_card_rect in
  if Rect.is_empty inner then 0
  else
    let content = ops_pad_content inner in
    if Rect.is_empty content then 0
    else
      let lines =
        Masc_tui_ui.Json_tree.flatten ~max_depth ~redact_secrets:true json
      in
      max 0 (List.length lines - content.h)

let json_of_metrics_store (m : Wire_infra.tool_metrics_24h) : Yojson.Safe.t =
  let opt_float obs =
    match Observed.to_option obs with Some f -> `Float f | None -> `Null
  in
  let fc = m.failure_classes in
  `Assoc
    [
      ("calls", `Int m.calls);
      ("failures", `Int m.failures);
      ("failure_unclassified", `Int m.failure_unclassified);
      ("p50_ms", opt_float m.p50_ms);
      ("p95_ms", opt_float m.p95_ms);
      ("max_ms", opt_float m.max_ms);
      ( "failure_classes"
      , `Assoc
          [
            ("dependency_unavailable", `Int fc.dependency_unavailable);
            ("runtime_failure", `Int fc.runtime_failure);
            ("policy_rejection", `Int fc.policy_rejection);
            ("workflow_rejection", `Int fc.workflow_rejection);
            ("operator_cancelled", `Int fc.operator_cancelled);
          ] );
    ]

type sandbox_entry_info = {
  backend_rows : int;
  json : Yojson.Safe.t;
}

let sandbox_entry_info_of_detail ~sandboxes
    (detail : Wire_infra.keeper_sandbox_detail) : sandbox_entry_info =
  match detail with
  | Wire_infra.Sandbox_microvm g ->
      {
        backend_rows = 5;
        json =
          `Assoc
            [
              ("keeper", `String g.keeper);
              ("backend", `String g.backend);
              ("guest_name", `String g.guest_name);
              ("presence", `String g.presence);
              ("socket", `String "socket");
              ("shim_parity", `String "shim");
              ("network_mode", `String "net");
              ("volume", `String "vol");
              ("metrics_24h", json_of_metrics_store g.metrics_24h);
            ];
      }
  | Wire_infra.Sandbox_ssh_keeper { session = ks; pool = embedded_pool } ->
      let pool_opt =
        match embedded_pool with
        | Some _ as p -> p
        | None -> (
            match sandboxes with
            | Some (s : Wire_infra.sandboxes_snapshot) ->
                List.find_opt
                  (fun (p : Wire_infra.ssh_pool) ->
                    List.exists
                      (fun (s_ks : Wire_infra.ssh_keeper_session) ->
                        String.equal s_ks.keeper ks.keeper)
                      p.keeper_sessions)
                  s.ssh_pools
            | None -> None)
      in
      let pool_name, host, port, unix_user, remote_root =
        match pool_opt with
        | Some p -> (p.pool_name, p.host, p.port, p.unix_user, p.remote_root)
        | None -> ("remote_ssh", "remote", 22, ks.keeper, "/")
      in
      let has_dispatch =
        match ks.last_dispatch with `Assoc (_ :: _) -> true | _ -> false
      in
      {
        backend_rows = 5 + if has_dispatch then 1 else 0;
        json =
          `Assoc
            [
              ("keeper", `String ks.keeper);
              ("pool", `String pool_name);
              ("host", `String host);
              ("port", `Int port);
              ("unix_user", `String unix_user);
              ("remote_root", `String remote_root);
              ("last_dispatch", ks.last_dispatch);
              ("metrics_24h", json_of_metrics_store ks.metrics_24h);
            ];
      }
  | Wire_infra.Sandbox_ssh_unbound u ->
      {
        backend_rows = 3 + if Option.is_some u.remote_endpoint then 1 else 0;
        json =
          `Assoc
            [
              ("keeper", `String u.keeper);
              ("backend", `String u.backend);
              ("binding_state", `String u.binding_state);
              ( "remote_endpoint"
              , match u.remote_endpoint with Some ep -> `String ep | None -> `Null );
              ("metrics_24h", json_of_metrics_store u.metrics_24h);
            ];
      }
  | Wire_infra.Sandbox_docker d ->
      {
        backend_rows = 2;
        json =
          `Assoc
            [
              ("keeper", `String d.keeper);
              ("backend", `String d.backend);
              ("network_mode", `String "net");
              ("metrics_24h", json_of_metrics_store d.metrics_24h);
            ];
      }

let sandbox_entry_info_for_keeper ~use_keeper_detail ~keeper
    (inf : Infra_store.t) : sandbox_entry_info option =
  let sandboxes = Observed.to_option inf.sandboxes in
  let from_detail =
    if not use_keeper_detail then None
    else
      Option.map
        (fun (resp : Wire_infra.keeper_sandbox_response) ->
          sandbox_entry_info_of_detail ~sandboxes resp.sandbox)
        (Observed.to_option (Infra_store.keeper_sandbox_for ~keeper inf))
  in
  match from_detail with
  | Some _ as found -> found
  | None -> (
      match sandboxes with
      | None -> None
      | Some s -> (
          match
            List.find_opt
              (fun (g : Wire_infra.microvm_guest) -> String.equal g.keeper keeper)
              s.microvm_guests
          with
          | Some g ->
              Some
                (sandbox_entry_info_of_detail ~sandboxes
                   (Wire_infra.Sandbox_microvm g))
          | None -> (
              let ssh_bound =
                List.find_map
                  (fun (p : Wire_infra.ssh_pool) ->
                    List.find_map
                      (fun (ks : Wire_infra.ssh_keeper_session) ->
                        if String.equal ks.keeper keeper then Some (p, ks)
                        else None)
                      p.keeper_sessions)
                  s.ssh_pools
              in
              match ssh_bound with
              | Some (p, ks) ->
                  Some
                    (sandbox_entry_info_of_detail ~sandboxes
                       (Wire_infra.Sandbox_ssh_keeper
                          { session = ks; pool = Some p }))
              | None -> (
                      match
                        List.find_opt
                          (fun (u : Wire_infra.ssh_unbound_keeper) ->
                            String.equal u.keeper keeper)
                          s.ssh_unbound_keepers
                      with
                      | Some u ->
                          Some
                            (sandbox_entry_info_of_detail ~sandboxes
                               (Wire_infra.Sandbox_ssh_unbound u))
                      | None -> (
                          match
                            List.find_opt
                              (fun (d : Wire_infra.docker_keeper) ->
                                String.equal d.keeper keeper)
                              s.docker_keepers
                          with
                          | Some d ->
                              Some
                                (sandbox_entry_info_of_detail ~sandboxes
                                   (Wire_infra.Sandbox_docker d))
                          | None -> None)))))

let sandbox_inspector_rem_rows ~inner_h (info : sandbox_entry_info) =
  let band_h = if inner_h >= 8 then 2 else 1 in
  let content_h = max 0 (inner_h - band_h) in
  max 0 (content_h - (6 + info.backend_rows))

let help_max_scroll (m : Model.t) =
  let modal_w = min (max 0 (m.viewport.cols - 4)) 128 in
  let modal_h = min (max 0 (m.viewport.rows - 4)) 28 in
  let inner_w = if modal_w >= 2 && modal_h >= 2 then modal_w - 2 else 0 in
  let inner_h = if modal_w >= 2 && modal_h >= 2 then modal_h - 2 else 0 in
  if inner_w <= 0 || inner_h <= 0 then 0
  else
    let pad_x = if inner_w >= 72 then 2 else 1 in
    let content_w = max 0 (inner_w - (2 * pad_x)) in
    let tui_lbl = Model.tui_build_label m in
    let server_lbl = Model.server_build_label m in
    let has_build_bar =
      ((not (String.equal tui_lbl "")) || Option.is_some server_lbl)
      && inner_h >= 4
    in
    let header_h =
      if not has_build_bar then 0 else if inner_h >= 6 then 2 else 1
    in
    let content_h = max 1 (inner_h - header_h) in
    let compact_count (grp : Keymap.help_group) =
      let seen_ws = ref false in
      let seen_move = ref false in
      let seen_ask = ref false in
      let n_entries =
        List.fold_left
          (fun acc (e : Keymap.help_entry) ->
            match e.action with
            | Keymap.Switch_workspace _ ->
                if !seen_ws then acc
                else (
                  seen_ws := true;
                  acc + 1)
            | Keymap.Move _ ->
                if !seen_move then acc
                else (
                  seen_move := true;
                  acc + 1)
            | Keymap.Ask_select_choice _ ->
                if !seen_ask then acc
                else (
                  seen_ask := true;
                  acc + 1)
            | Keymap.Toggle_sidebar
            | Keymap.Sub_tab _
            | Keymap.Cycle_focus_pane _
            | Keymap.Focus_composer
            | Keymap.Focus_filter
            | Keymap.Dive_selected
            | Keymap.Confirm_selected
            | Keymap.Pop_back_or_close
            | Keymap.Open_settings
            | Keymap.Teleport_blocked
            | Keymap.Open_incidents
            | Keymap.Voice_ptt_toggle
            | Keymap.Fast_approve_top
            | Keymap.Fast_deny_top
            | Keymap.Open_help
            | Keymap.Open_palette
            | Keymap.Open_keeper_switcher
            | Keymap.Open_model_switcher
            | Keymap.Toggle_tool_details
            | Keymap.Open_queue_context
            | Keymap.Toggle_thinking
            | Keymap.Cycle_origin_mode
            | Keymap.Composer_kill_word
            | Keymap.Composer_newline
            | Keymap.Submit_steer
            | Keymap.Submit_followup
            | Keymap.Toggle_expand
            | Keymap.Create_new
            | Keymap.Refresh
            | Keymap.Open_external
            | Keymap.Copy_selected
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
            | Keymap.Account_login
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
            | Keymap.Interrupt_turn
            | Keymap.Quit_app ->
                acc + 1)
          0 grp.entries
      in
      1 + n_entries + 1
    in
    let groups = Keymap.help_entries ~scope_chain:Keymap.all_scopes ~lang:m.lang in
    let is_left_cat = function
      | Keymap.Cat_navigation | Keymap.Cat_actions -> true
      | Keymap.Cat_overlays | Keymap.Cat_composer | Keymap.Cat_approval -> false
    in
    let left_lines =
      List.fold_left
        (fun acc (g : Keymap.help_group) ->
          if is_left_cat g.category then acc + compact_count g else acc)
        0 groups
    in
    let right_lines =
      List.fold_left
        (fun acc (g : Keymap.help_group) ->
          if not (is_left_cat g.category) then acc + compact_count g else acc)
        0 groups
    in
    let total =
      if content_w >= 72 then max left_lines right_lines
      else left_lines + right_lines
    in
    max 0 (total - content_h)

let btw_max_scroll (m : Model.t) =
  let body_opt =
    match m.drafts.btw with
    | Drafts.Btw_streaming { buffer; _ } -> Some buffer
    | Drafts.Btw_answered { reply; _ } -> Some reply
    | Drafts.Btw_idle | Drafts.Btw_sending _ | Drafts.Btw_failed _ -> None
  in
  match body_opt with
  | None -> 0
  | Some body ->
      let overlay_h = max 0 (m.viewport.rows - 2) in
      let w = min (max 0 (m.viewport.cols - 4)) 84 in
      let desired_h =
        min (max 13 (overlay_h * 65 / 100)) (max 7 (overlay_h - 4))
      in
      let h = min (max 0 (overlay_h - 2)) desired_h in
      let inner_w = if w >= 2 && h >= 2 then w - 2 else 0 in
      let inner_h = if w >= 2 && h >= 2 then h - 2 else 0 in
      if inner_w <= 0 || inner_h < 3 then 0
      else
        let pad_x = if inner_w >= 48 then 2 else 1 in
        let padded_w = max 1 (inner_w - (2 * pad_x)) in
        let md_h = max 1 (inner_h - 2) in
        let theme = Theme.of_preset m.theme_preset in
        markdown_max_scroll ~theme ~width:padded_w ~height:md_h body

let queue_context_max_scroll (m : Model.t) tab =
  let modal_h = min (max 0 (m.viewport.rows - 4)) 24 in
  let inner_h = if modal_h >= 2 then modal_h - 2 else 0 in
  let body_h = max 1 (inner_h - 2) in
  let keeper =
    match resolve_target_keeper m with
    | Some k -> k
    | None -> Drafts.target_keeper_key m.drafts
  in
  let total_rows =
    match tab with
    | Nav.Drawer_queue ->
        let attn_count = Attention.count m.attention in
        let attn_rows = if attn_count > 0 then attn_count + 3 else 0 in
        let queue, txs = Model.drawer_queue ~keeper m in
        let server_rows = List.length queue.operations in
        let others = Drafts.other_keepers_draft_count m.drafts in
        attn_rows + 1 + server_rows + (if txs = [] then 0 else 1 + List.length txs)
        + 3 + (if others > 0 then 1 else 0)
    | Nav.Drawer_schedules -> List.length (Work_store.schedules_list m.work)
    | Nav.Drawer_context ->
        let keeper_opt = Fleet_store.find_keeper ~name:keeper m.fleet in
        let ctx_st =
          Keeper_context_store.get_keeper ~keeper m.keeper_context
        in
        let eff_row =
          match Observed.to_option m.runtime.efficiency with
          | None -> None
          | Some eff ->
              List.find_opt
                (fun (r : Wire_runtime.keeper_efficiency_row) ->
                  String.equal r.keeper keeper)
                eff.keepers
        in
        let turn_entry = Keeper_context_store.selected_turn_entry ctx_st in
        let r = ref 0 in
        (match Observed.to_option ctx_st.turn_records, turn_entry with
        | Some _, Some _ -> r := !r + 1
        | _ -> ());
        (* Ratio gauge + spacer *)
        r := !r + 3;
        (* Cache bar / fallback turn composition *)
        (match eff_row with
        | Some _ -> r := !r + 4
        | None -> r := !r + (if Option.is_some turn_entry then 3 else 1));
        if Option.is_some keeper_opt then r := !r + 1;
        if Option.is_some eff_row && Option.is_some turn_entry then r := !r + 3;
        if Option.is_some (Keeper_context_store.cache_outcome_for_selected_turn ctx_st)
        then r := !r + 1;
        if Option.is_some (Observed.to_option ctx_st.next_request) then
          r := !r + 1;
        (* Spacer + turn history section *)
        r := !r + 1;
        (match Fleet_store.turn_records_for ~keeper m.fleet with
        | Observed.Value { data; _ } ->
            let measured =
              List.filter_map Wire_fleet.turn_record_context_fill data.rows
            in
            r := !r + 1 + (if measured = [] then 1 else 2)
            + if data.skipped_rows > 0 then 1 else 0
        | Observed.Loading _ | Observed.Failed _ | Observed.Absent
        | Observed.Unreported ->
            r := !r + 1);
        (* Spacer + compaction facts *)
        r := !r + 2;
        !r
  in
  max 0 (total_rows - body_h)

let wiki_preview_max_scroll ~bp ~theme ~(rect : Rect.t)
    ~target_slug (k : Knowledge_store.t) =
  let inner = ui_card_inner rect in
  if Rect.is_empty inner then 0
  else
    let sel_summary =
      match target_slug with
      | Some slug -> (
          match Observed.to_option k.wiki_index with
          | Some idx ->
              List.find_opt
                (fun (p : Wire_knowledge.wiki_page_summary) ->
                  String.equal p.slug slug)
                idx.pages
          | None -> None)
      | None -> Knowledge_store.selected_wiki_page k
    in
    (
        let page_detail =
          match target_slug, sel_summary with
          | Some slug, _ ->
              Observed.to_option (Knowledge_store.wiki_page_for ~slug k)
          | None, Some s ->
              Observed.to_option (Knowledge_store.wiki_page_for ~slug:s.slug k)
          | None, None -> None
        in
        match page_detail with
        | Some d ->
            let band_h = if inner.h >= 7 then 2 else 1 in
            let below =
              Rect.make ~x:inner.x ~y:(inner.y + band_h) ~w:inner.w
                ~h:(max 0 (inner.h - band_h))
            in
            if Rect.is_empty below then 0
            else
              let show_toc_rail =
                Masc_tui_ui.Layout.equal_breakpoint bp Masc_tui_ui.Layout.Wide
                && below.w >= 68
                && below.h >= 8
              in
              if show_toc_rail then
                let toc_w = 22 in
                let prose_w = max 20 (below.w - toc_w - 1) in
                let prose_rect =
                  Rect.make ~x:below.x ~y:below.y ~w:prose_w
                    ~h:below.h
                  |> ui_pad_content ~bp ~pad_y:1
                in
                markdown_max_scroll ~theme ~width:prose_rect.w
                  ~height:prose_rect.h d.body_markdown
              else
                let content = ui_pad_content ~bp below in
                let md_h = max 0 (content.h - 2) in
                markdown_max_scroll ~theme ~width:content.w ~height:md_h
                  d.body_markdown
        | None -> (
            match sel_summary with
            | Some s ->
                let content = ui_pad_content ~bp inner in
                let md_h = max 0 (content.h - 3) in
                markdown_max_scroll ~theme ~width:content.w ~height:md_h
                  s.summary
            | None -> 0))

let wrap_lines ~width text =
  Chat_transcript.wrap_plain_lines ~width:(max 1 width) text

let fusion_detail_lines ~width (m : Model.t) ~run_id : string list =
  let w = max 20 width in
  let lines = ref [] in
  let push s = lines := s :: !lines in
  let push_wrapped prefix text =
    let wrapped = wrap_lines ~width:(max 10 (w - String.length prefix)) text in
    match wrapped with
    | [] -> push prefix
    | first :: rest ->
        push (prefix ^ first);
        let indent = String.make (String.length prefix) ' ' in
        List.iter (fun ln -> push (indent ^ ln)) rest
  in
  let detail_opt = Runtime_store.fusion_detail_for ~run_id m.runtime in
  let run_opt =
    match detail_opt with
    | Some d -> Some d.run
    | None ->
        List.find_opt
          (fun (r : Wire_runtime.fusion_run) -> String.equal r.run_id run_id)
          (Runtime_store.filtered_fusion_runs m.runtime)
  in
  (match m.runtime.fusion_replay with
  | Some (Wire_runtime.Replay_incomplete { reason; lines_read; malformed_lines }) ->
      push
        (Printf.sprintf "[REPLAY WARNING] incomplete (%s) · %d lines · %d malformed"
           reason lines_read malformed_lines)
  | Some (Wire_runtime.Replay_complete { malformed_lines; dropped_running; _ })
    when malformed_lines > 0 || dropped_running > 0 ->
      push
        (Printf.sprintf "[REPLAY NOTICE] %d malformed · %d dropped running"
           malformed_lines dropped_running)
  | Some (Wire_runtime.Replay_complete _ | Wire_runtime.Replay_not_replayed | Wire_runtime.Replay_absent)
  | None -> ());
  (match run_opt with
  | None -> push ("Run " ^ run_id ^ " (loading...)")
  | Some r ->
      let st =
        match r.status with
        | Wire_runtime.Fusion_running -> "running"
        | Wire_runtime.Fusion_completed -> "completed"
        | Wire_runtime.Fusion_failed { code; error } ->
            Printf.sprintf "failed (%s: %s)" code error
      in
      push
        (Printf.sprintf "Run: %s · Keeper: %s · Preset: %s · Topology: %s"
           r.run_id r.keeper r.preset
           (Wire_runtime.fusion_topology_to_string r.topology));
      push (Printf.sprintf "Status: %s · Stage: %s" st r.stage);
      Option.iter (fun dec -> push ("Decision: " ^ dec)) r.decision;
      Option.iter (fun sum -> push_wrapped "Summary: " sum) r.summary);
  let evidence_post_opt, reloaded_board_post =
    let detail_post_opt =
      match detail_opt with
      | Some { evidence = Wire_runtime.Evidence_recorded p; _ } -> Some p
      | Some
          {
            evidence = Wire_runtime.Evidence_pending | Wire_runtime.Evidence_absent;
            _;
          }
      | None -> None
    in
    let linked_post_id_opt =
      match detail_post_opt with
      | Some p when not (String.equal (String.trim p.post_id) "") ->
          Some p.post_id
      | Some _ | None ->
          Option.map
            (fun (h : Wire_runtime.fusion_historical_evidence) -> h.post_id)
            (Runtime_store.historical_evidence_for_run ~run_id m.runtime)
    in
    let reloaded_opt =
      Option.bind linked_post_id_opt (fun post_id ->
          Runtime_store.fusion_board_evidence_for ~post_id m.runtime)
    in
    match reloaded_opt with
    | Some p -> (Some p, true)
    | None -> (detail_post_opt, false)
  in
  (match detail_opt, evidence_post_opt with
  | _, Some ev ->
      push "── Pipeline: Question -> Panel -> Judge -> Evidence ──";
      push
        (Printf.sprintf "Board Evidence: %s (%s)%s" ev.post_id ev.title
           (if reloaded_board_post then " [board]" else ""));
      Option.iter (fun q -> push_wrapped "Question: " q) ev.question;
      if ev.panel <> [] then (
        push (Printf.sprintf "── Panel (%d) ──" (List.length ev.panel));
        List.iter
          (fun (pe : Wire_runtime.fusion_panel_entry) ->
            let st =
              match pe.status with
              | `Answered -> "OK"
              | `Failed -> "FAIL"
            in
            let toks =
              match pe.input_tokens, pe.output_tokens with
              | Some i, Some o -> Printf.sprintf " (%di/%do tok)" i o
              | _ -> ""
            in
            push (Printf.sprintf "  [%s] %s%s" st pe.model toks);
            (match pe.answer with
            | Some a when not (String.equal (String.trim a) "") ->
                push_wrapped "    " a
            | Some _ | None -> ());
            match pe.reason_code, pe.reason_detail with
            | Some c, Some d -> push_wrapped ("    err(" ^ c ^ "): ") d
            | Some c, None -> push ("    err: " ^ c)
            | None, Some d -> push_wrapped "    err: " d
            | None, None -> ())
          ev.panel);
      if ev.seat_routes <> [] then (
        push
          (Printf.sprintf "── Seat Routing (%d) ──"
             (List.length ev.seat_routes));
        List.iter
          (fun (sr : Wire_runtime.fusion_seat_route) ->
            let ans = Option.value ~default:"-" sr.answered_by in
            let role =
              match sr.judge_role with Some r -> "/" ^ r | None -> ""
            in
            push
              (Printf.sprintf "  %s%s [%s] route=%s -> %s" sr.phase role sr.seat
                 sr.route ans);
            List.iter
              (fun (att : Wire_runtime.fusion_seat_attempt) ->
                push_wrapped
                  (Printf.sprintf "    fallback fail %s [%s]: " att.runtime
                     att.code)
                  att.detail)
              sr.failed_attempts)
          ev.seat_routes);
      push "── Judge Synthesis ──";
      (match ev.judge_status, ev.judge_decision with
      | Some st, Some dec ->
          push (Printf.sprintf "  status=%s · decision=%s" st dec)
      | Some st, None -> push ("  status=" ^ st)
      | None, Some dec -> push ("  decision=" ^ dec)
      | None, None -> ());
      Option.iter (fun f -> push_wrapped "  failure: " f) ev.judge_failure;
      Option.iter (fun s -> push_wrapped "  synthesis: " s) ev.judge_synthesis;
      Option.iter
        (fun a -> push_wrapped "  resolved: " a)
        ev.judge_resolved_answer;
      if ev.judges <> [] then
        List.iter
          (fun (j : Wire_runtime.fusion_judge_node) ->
            let el =
              match j.elapsed_s with
              | Some s -> Printf.sprintf " %.1fs" s
              | None -> ""
            in
            let to_s =
              match j.timed_out with Some true -> " TIMEOUT" | _ -> ""
            in
            push
              (Printf.sprintf "  judge[%s] %s: %s (%di/%do%s%s)" j.role
                 j.identity j.status j.input_tokens j.output_tokens el to_s);
            Option.iter (fun s -> push_wrapped "    " s) j.synthesis;
            Option.iter (fun e -> push_wrapped "    err: " e) j.error)
          ev.judges;
      (match ev.tool_trace with
      | Some tr ->
          push
            (Printf.sprintf "── Tool Trace (%s · %d events · %d dropped) ──"
               tr.status tr.events_count tr.dropped_events);
          if tr.observed_actors <> [] then
            push ("  actors: " ^ String.concat ", " tr.observed_actors);
          List.iter (fun g -> push ("  gap: " ^ g)) tr.gaps;
          List.iter (fun p -> push ("  · " ^ p)) tr.events_preview
      | None -> ());
      if
        ev.panel = []
        && Option.is_none ev.judge_synthesis
        && not (String.equal (String.trim ev.body) "")
      then (
        push "── Board Body ──";
        List.iter push (wrap_lines ~width:w ev.body))
  | Some { evidence = Wire_runtime.Evidence_pending; _ }, None ->
      push "Evidence: pending (run in progress or board write pending)"
  | Some { evidence = Wire_runtime.Evidence_absent; _ }, None -> (
      match Runtime_store.historical_evidence_for_run ~run_id m.runtime with
      | Some hist ->
          push
            (Printf.sprintf
               "Historical Board Evidence available: %s (%s) — press [e] or \
                [Enter] to load"
               hist.post_id hist.title)
      | None -> push "Evidence: absent")
  | Some { evidence = Wire_runtime.Evidence_recorded _; _ }, None
  | None, None ->
      ());
  List.rev !lines

let harness_verdict_detail_lines ~width (m : Model.t) : string list =
  let w = max 20 width in
  let lines = ref [] in
  let push s = lines := s :: !lines in
  (match Work_store.selected_harness_verdict m.work with
  | None -> push "No harness verdict selected."
  | Some v ->
      push (Printf.sprintf "Task: %s (%s)" v.task_title v.task_id);
      push (Printf.sprintf "Keeper: %s · Gate: %s" v.agent_name v.gate);
      push
        (Printf.sprintf "Verdict: %s · Evaluator: %s" v.verdict
           v.evaluator_runtime);
      (match v.fallback_reason with
      | Some r ->
          List.iter push (wrap_lines ~width:w ("Fallback reason: " ^ r))
      | None -> push "Fallback reason: none");
      let hash_valid = Wire_work.is_valid_notes_hash v.notes_hash in
      push
        (Printf.sprintf "notes_hash (%s): %s"
           (if hash_valid then "valid 64-hex" else "invalid/missing")
           (if String.equal v.notes_hash "" then "-" else v.notes_hash));
      push
        "Actions: [y] Approve overrule · [n] Reject overrule · [H] Copy \
         notes_hash");
  (match Observed.to_option m.work.harness_health with
  | Some hh ->
      let c = hh.calibration in
      push "── Evaluator Calibration ──";
      push
        (Printf.sprintf "Status: %s · Fallback ratio: %.1f%%"
           hh.evaluator_status (hh.fallback_ratio *. 100.0));
      push
        (Printf.sprintf
           "Verdicts: %d (approve=%d reject=%d labeled=%d) · Agreement: %.1f%%"
           c.total_verdicts c.approve_count c.reject_count c.labeled_count
           (c.agreement_rate *. 100.0));
      push
        (Printf.sprintf "FP=%d · FN=%d · Fallbacks=%d · Unreadable=%d"
           c.false_positive_count c.false_negative_count c.fallback_count
           hh.unreadable_verdicts_count);
      (match c.distinct_runtime_rate with
      | Some rate ->
          push
            (Printf.sprintf "Distinct runtime rate: %.1f%% (%d/%d)"
               (rate *. 100.0) c.distinct_runtime_count
               c.verdicts_with_generator_runtime)
      | None -> ());
      if c.recent_fallback_reasons <> [] then (
        push "Recent fallback reasons:";
        List.iter (fun r -> push ("  · " ^ r)) c.recent_fallback_reasons);
      if not (String.equal (String.trim hh.scope_note) "") then
        List.iter push (wrap_lines ~width:w ("Scope: " ^ hh.scope_note))
  | None -> ());
  List.rev !lines

let addon_catalog_preview_lines ~width (p : Wire_runtime.addon_package_preview)
    : string list =
  let w = max 20 width in
  let lines = ref [] in
  let push s = lines := s :: !lines in
  push (Printf.sprintf "%s (%s @ %s)" p.title p.id p.revision);
  push ("Manifest: " ^ p.manifest_path);
  push
    (Printf.sprintf "Category: %s · Execution: %s"
       (Option.value ~default:"uncategorized" p.ui_category)
       p.execution_kind);
  (match p.image_name, p.image_state with
  | Some img, Some st ->
      push (Printf.sprintf "Image: %s [%s]" img st)
  | Some img, None -> push ("Image: " ^ img)
  | None, Some st -> push ("Image state: " ^ st)
  | None, None -> ());
  Option.iter (fun d -> push ("Directory: " ^ d)) p.directory;
  if p.command <> [] then
    List.iter push
      (wrap_lines ~width:w ("Command: " ^ String.concat " " p.command));
  push (Printf.sprintf "Exported tools (%d):" (List.length p.exported_tools));
  List.iter (fun t -> push ("  · " ^ t)) p.exported_tools;
  if p.contributions <> [] then (
    push (Printf.sprintf "Contributions (%d):" (List.length p.contributions));
    List.iter (fun c -> push ("  · " ^ c)) p.contributions);
  List.rev !lines

let knowledge_memory_subview_lines ~width (k : Knowledge_store.t) : string list =
  let w = max 20 width in
  let lines = ref [] in
  let push s = lines := s :: !lines in
  match k.memory_subview with
  | Knowledge_store.Mem_diff_flow -> []
  | Knowledge_store.Mem_health_ledger ->
      push "── Fleet Keeper Memory Health ──";
      (match Observed.to_option k.keeper_memory_health with
      | None -> push "  (loading /api/v1/dashboard/keeper-memory-health...)"
      | Some fl ->
          let total_facts, total_invalidations, total_alerts, warn_alerts, error_alerts =
            Wire_knowledge.memory_health_fleet_totals fl
          in
          push
            (Printf.sprintf
               "  Facts: %d · Invalidations: %d · Alerts: %d (warn=%d err=%d)"
               total_facts total_invalidations total_alerts warn_alerts
               error_alerts);
          List.iter
            (fun (row : Wire_knowledge.keeper_memory_health_row) ->
              push
                (Printf.sprintf
                   "  %s r%d · facts=%d (obs=%d der=%d src=%d) inv=%d \
                    alerts=%d"
                   row.keeper_id row.revision row.facts row.observed_facts
                   row.derived_facts row.source_facts row.support_invalidations
                   (List.length row.alerts));
              List.iter
                (fun (al : Wire_knowledge.memory_health_alert) ->
                  List.iter push
                    (wrap_lines ~width:w
                       (Printf.sprintf "    [%s/%s] %s"
                          (Wire_knowledge.memory_health_alert_severity_to_string
                             al.severity)
                          al.code al.message)))
                row.alerts)
            fl.keepers);
      push "── Workspace Memory Ledger ──";
      (match k.workspace_memory_ledger with
      | Observed.Failed { reason; _ } ->
          push
            ("  [auth/error] " ^ reason
            ^ (if k.workspace_memory_ledger_auth_denied then
                 " (requires CanReadState — press [r] to retry)"
               else ""))
      | Observed.Loading _ | Observed.Unreported | Observed.Absent ->
          push "  (loading /api/v1/dashboard/workspace-memory-ledger...)"
      | Observed.Value { data = led; _ } ->
          push
            (Printf.sprintf "  Status: %s · Claims: %d · Conflicts: %d · Facts: %d"
               led.status (List.length led.claims) (List.length led.conflicts)
               (List.length led.facts));
          Option.iter (fun sha -> push ("  SHA-256: " ^ sha)) led.ledger_sha256;
          List.iter
            (fun (cid, text) ->
              List.iter push
                (wrap_lines ~width:w (Printf.sprintf "  [claim %s] %s" cid text)))
            led.claims;
          List.iter
            (fun (cid, desc) ->
              List.iter push
                (wrap_lines ~width:w
                   (Printf.sprintf "  [conflict %s] %s" cid desc)))
            led.conflicts;
          List.iter
            (fun (f : Wire_knowledge.workspace_ledger_fact) ->
              let txt = Option.value ~default:"-" f.claim_text in
              List.iter push
                (wrap_lines ~width:w
                   (Printf.sprintf "  [%s/%s] %s" f.disposition_kind
                      f.source_state txt)))
            led.facts);
      List.rev !lines
  | Knowledge_store.Mem_context ->
      push "── Workspace Memory Context ──";
      (match k.workspace_memory_context with
      | Observed.Failed { reason; _ } ->
          push
            ("  [auth/error] " ^ reason
            ^ (if k.workspace_memory_context_auth_denied then
                 " (requires CanReadState — press [r] to retry)"
               else ""))
      | Observed.Loading _ | Observed.Unreported | Observed.Absent ->
          push "  (loading /api/v1/dashboard/workspace-memory-context...)"
      | Observed.Value { data = ctx; _ } ->
          push
            (Printf.sprintf "  Discovery: %s (%d keepers)" ctx.discovery_status
               (List.length ctx.keepers));
          Option.iter (fun d -> push ("  Detail: " ^ d)) ctx.discovery_detail;
          let obs_str = function
            | Wire_knowledge.Ctx_missing -> "missing"
            | Wire_knowledge.Ctx_unavailable r -> "unavailable(" ^ r ^ ")"
            | Wire_knowledge.Ctx_available { revision; fact_count } ->
                let r =
                  match revision with Some n -> Printf.sprintf "r%d " n | None -> ""
                in
                Printf.sprintf "%s%d facts" r fact_count
          in
          List.iter
            (fun (kp : Wire_knowledge.workspace_context_keeper) ->
              push
                (Printf.sprintf "  %-20s ordinary: %-18s source: %s"
                   kp.keeper_id (obs_str kp.ordinary)
                   (obs_str kp.source_bound)))
            ctx.keepers);
      List.rev !lines

let keeper_memory_subview_lines ~width ~name (k : Knowledge_store.t) :
    string list =
  let w = max 20 width in
  let lines = ref [] in
  let push s = lines := s :: !lines in
  match k.keeper_memory_subview with
  | Knowledge_store.Kmem_diff_flow -> []
  | Knowledge_store.Kmem_health ->
      push ("── Memory Health: " ^ name ^ " ──");
      (match Knowledge_store.memory_health_for_keeper ~keeper:name k with
      | None -> push "  (no health observation for this keeper yet)"
      | Some row ->
          push
            (Printf.sprintf
               "  Revision: r%d · Snapshot: %s (%d B)"
               row.revision
               (if row.snapshot_present then "present" else "absent")
               row.snapshot_bytes);
          push
            (Printf.sprintf
               "  Facts: %d (observed=%d · derived=%d · source=%d)"
               row.facts row.observed_facts row.derived_facts row.source_facts);
          push
            (Printf.sprintf
               "  Delta: +%d/-%d · Invalidations: %d (source=%d) · Failures: \
                lib=%d vis=%d"
               row.added row.removed row.support_invalidations
               row.source_invalidations row.librarian_failures
               row.vision_ingest_errors);
          Option.iter (fun e -> push ("  Read error: " ^ e)) row.read_error;
          Option.iter
            (fun e -> push ("  Source read error: " ^ e))
            row.source_read_error;
          if row.alerts = [] then push "  Alerts: none"
          else (
            push (Printf.sprintf "  Alerts (%d):" (List.length row.alerts));
            List.iter
              (fun (al : Wire_knowledge.memory_health_alert) ->
                List.iter push
                  (wrap_lines ~width:w
                     (Printf.sprintf "    [%s/%s] %s: %s"
                        (Wire_knowledge.memory_health_alert_severity_to_string
                           al.severity)
                        al.code al.label al.message)))
              row.alerts));
      List.rev !lines
  | Knowledge_store.Kmem_facts_tree ->
      push ("── Facts Tree: " ^ name ^ " ([Space/Enter] fold/expand) ──");
      (match Knowledge_store.memory_facts_for_keeper ~keeper:name k with
      | None -> (
          match Knowledge_store.keeper_memory_facts_for ~keeper:name k with
          | Observed.Failed { reason; _ } ->
              push
                ("  [auth/error] " ^ reason
                ^ (if
                     Knowledge_store.String_set.mem name
                       k.keeper_memory_facts_auth_denied
                   then " (requires CanAdmin — press [r] to retry)"
                   else ""))
          | Observed.Loading _ | Observed.Unreported | Observed.Absent
          | Observed.Value _ ->
              push "  (loading /api/v1/keepers/:name/memory-facts...)")
      | Some facts ->
          let ord_rev, ord_facts, ord_invs, ord_err =
            match facts.ordinary with
            | Wire_knowledge.Memory_store_present om ->
                ( Some om.revision
                , om.facts
                , List.length om.support_invalidations
                , None )
            | Wire_knowledge.Memory_store_absent -> (None, [], 0, None)
            | Wire_knowledge.Memory_store_read_error e -> (None, [], 0, Some e)
          in
          let src_facts, src_invs, src_err =
            match facts.source_bound with
            | Wire_knowledge.Memory_store_present sm ->
                (sm.facts, List.length sm.invalidations, None)
            | Wire_knowledge.Memory_store_absent -> ([], 0, None)
            | Wire_knowledge.Memory_store_read_error e -> ([], 0, Some e)
          in
          let rev_s =
            match ord_rev with Some r -> Printf.sprintf "r%d" r | None -> "-"
          in
          push
            (Printf.sprintf
               "  Ordinary (%s): %d · Source-bound: %d · Invalidations: %d+%d"
               rev_s (List.length ord_facts) (List.length src_facts) ord_invs
               src_invs);
          Option.iter (fun e -> push ("  Ordinary error: " ^ e)) ord_err;
          Option.iter (fun e -> push ("  Source error: " ^ e)) src_err;
          let cats = keeper_facts_categories facts in
          let sel =
            clamp_index (List.length cats) k.facts_selected_index
          in
          List.iteri
            (fun idx (cat, items) ->
              let collapsed =
                Knowledge_store.String_set.mem cat k.collapsed_fact_categories
              in
              let mark = if idx = sel then ">" else " " in
              let arrow = if collapsed then "▸" else "▾" in
              push
                (Printf.sprintf "%s %s %s (%d)" mark arrow cat
                   (List.length items));
              if not collapsed then
                List.iter
                  (fun (f : Wire_knowledge.keeper_ordinary_fact) ->
                    List.iter push
                      (wrap_lines ~width:w
                         (Printf.sprintf "    · [%s] %s"
                            (Wire_knowledge.memory_fact_origin_to_string f.origin)
                            f.claim)))
                  items)
            cats;
          if src_facts <> [] then (
            push
              (Printf.sprintf "── Source-Bound Facts (%d) ──"
                 (List.length src_facts));
            List.iter
              (fun (sf : Wire_knowledge.keeper_source_fact) ->
                List.iter push
                  (wrap_lines ~width:w
                     (Printf.sprintf "  · %s (%s)" sf.claim sf.path)))
              src_facts));
      List.rev !lines
  | Knowledge_store.Kmem_journal ->
      push ("── Memory Journal & Activity: " ^ name ^ " ──");
      (match Knowledge_store.memory_journal_for_keeper ~keeper:name k with
      | None -> (
          match k.keeper_memory_journal with
          | Observed.Failed { reason; _ } ->
              push
                ("  [auth/error] " ^ reason
                ^ (if
                     Knowledge_store.String_set.mem name
                       k.keeper_memory_journal_auth_denied
                   then " (requires CanAdmin — press [r] to retry)"
                   else ""))
          | Observed.Loading _ | Observed.Unreported | Observed.Absent
          | Observed.Value _ ->
              push "  (loading /api/v1/keepers/:name/memory-journal...)")
      | Some j ->
          push
            (Printf.sprintf "  Entries: %d · Activity: %d · Undecodable: %d"
               (List.length j.entries) (List.length j.activity_events)
               j.undecodable_lines);
          List.iter
            (fun (e : Wire_knowledge.memory_journal_entry) ->
              let rev_s =
                match e.revision with Some r -> Printf.sprintf "r%d" r | None -> "-"
              in
              let st = if e.ok then "OK" else "ERR" in
              let out = Option.value ~default:"-" e.outcome in
              push
                (Printf.sprintf "  [%s] %s %s (+%d/-%d ret=%d inv=%d) %s" st
                   rev_s out e.added e.removed e.retained e.invalidated
                   e.structural_id);
              Option.iter (fun err -> push ("    err: " ^ err)) e.error)
            j.entries;
          if j.activity_events <> [] then (
            push "── Activity Stream ──";
            List.iter
              (fun (ev : Wire_knowledge.journal_activity_event) ->
                push
                  (Printf.sprintf "  r%d [%s] %s (before=%d after=%d)"
                     ev.revision ev.kind ev.identity
                     (List.length ev.before_claims)
                     (List.length ev.after_claims));
                Option.iter (fun r -> push ("    reason: " ^ r)) ev.reason)
              j.activity_events);
          List.iter (fun note -> push ("  note: " ^ note)) j.activity_notes);
      List.rev !lines

let keeper_logs_lines ~width ~name (ks : Keeper_context_store.keeper_state) :
    string list =
  let w = max 20 width in
  let lines = ref [] in
  let push s = lines := s :: !lines in
  match ks.logs_subview with
  | Keeper_context_store.Logs_metrics ->
      push ("── Keeper Metrics: " ^ name ^ " ([v] Sandbox Logs) ──");
      (match ks.metrics with
      | Observed.Failed { reason; _ } ->
          push ("  [error] " ^ reason)
      | Observed.Loading _ | Observed.Unreported | Observed.Absent ->
          push "  (loading /api/v1/keepers/:name/metrics...)"
      | Observed.Value { data = snap; _ } ->
          push
            (Printf.sprintf
               "  Samples: %d (turns=%d hb=%d proactive=%d) · Tool calls: %d"
               snap.sample_points snap.turn_points snap.heartbeat_points
               snap.proactive_points snap.tool_call_count);
          push
            (Printf.sprintf "  Scanned rows: %d · Skipped: %d" snap.scanned_rows
               snap.skipped_rows);
          if snap.top_tools <> [] then (
            push "── Top Tools ──";
            List.iter
              (fun (tool, cnt) ->
                push (Printf.sprintf "  %-30s %d calls" tool cnt))
              snap.top_tools);
          push (Printf.sprintf "── Recent Points (%d) ──" (List.length snap.series));
          List.iter
            (fun (pt : Wire_keeper_context.keeper_metrics_point) ->
              let cost_s =
                match pt.cost_usd with
                | Some c -> Printf.sprintf "$%.4f" c
                | None -> "-"
              in
              push
                (Printf.sprintf "  [%s/%s] %dms %s tools=%d trace=%s"
                   pt.work_kind pt.channel pt.latency_ms cost_s
                   pt.tool_call_count pt.trace_id))
            snap.series);
      List.rev !lines
  | Keeper_context_store.Logs_sandbox ->
      push ("── Remote Sandbox Logs: " ^ name ^ " ([v] Metrics) ──");
      (match ks.sandbox_logs with
      | Observed.Failed { reason; _ } ->
          push ("  [error] " ^ reason)
      | Observed.Loading _ | Observed.Unreported | Observed.Absent ->
          push "  (loading /api/v1/gate/keeper-sandbox-logs...)"
      | Observed.Value { data = sl; _ } ->
          push
            (Printf.sprintf "  State: %s · Backend: %s · Tail: %d" sl.state
               (Option.value ~default:"-" sl.backend)
               sl.tail);
          Option.iter (fun r -> push ("  Reason: " ^ r)) sl.reason;
          if sl.instances = [] then push "  (no sandbox instances reported)"
          else
            List.iter
              (fun (inst : Wire_keeper_context.sandbox_log_instance) ->
                let run_s =
                  match inst.running with
                  | Some true -> "running"
                  | Some false -> "stopped"
                  | None -> "unknown"
                in
                push
                  (Printf.sprintf "── Instance %s (%s · %s) ──"
                     inst.instance_name inst.instance_id run_s);
                Option.iter (fun e -> push ("  error: " ^ e)) inst.error;
                if not (String.equal (String.trim inst.stdout) "") then (
                  push "  [stdout]";
                  List.iter
                    (fun ln -> List.iter push (wrap_lines ~width:w ("  " ^ ln)))
                    (String.split_on_char '\n' inst.stdout));
                if not (String.equal (String.trim inst.stderr) "") then (
                  push "  [stderr]";
                  List.iter
                    (fun ln -> List.iter push (wrap_lines ~width:w ("  " ^ ln)))
                    (String.split_on_char '\n' inst.stderr)))
              sl.instances);
      List.rev !lines

let keeper_identity_lines ~width ~name (m : Model.t) : string list =
  let w = max 20 width in
  let ks = Keeper_context_store.get_keeper ~keeper:name m.keeper_context in
  let entries = keeper_identity_entries m ~name in
  let sel = clamp_index (List.length entries) ks.identity_selected_idx in
  let lines = ref [] in
  let push s = lines := s :: !lines in
  push
    ("── Keeper Identity: " ^ name
   ^ " ([l] Login · [L] Poll · [r] Refresh · [a/Enter] Toggle · [U] Disconnect \
      · [K] GitHub PAT · [y] Copy) ──");
  if ks.oauth_auth_denied then
    push "  [CanAdmin required] OAuth identity endpoints returned 401/403";
  (match Observed.to_option m.keeper_context.oauth_providers with
  | Some p ->
      Option.iter (fun u -> push ("  OAuth callback: " ^ u)) p.callback_url;
      Option.iter (fun pr -> push ("  Callback problem: " ^ pr)) p.callback_problem
  | None -> ());
  push "── Providers & GitHub ──";
  List.iteri
    (fun idx entry ->
      let mark = if idx = sel then ">" else " " in
      match entry with
      | Identity_oauth { provider; label; attached; enabled } ->
          let st = if attached then "attached" else "unattached" in
          let en =
            match enabled with
            | Some true -> "enabled"
            | Some false -> "disabled"
            | None -> "-"
          in
          push (Printf.sprintf "%s [OAuth] %s (%s) · %s · %s" mark label provider st en)
      | Identity_github ->
          let gh_s =
            if ks.github_auth_denied then "CanAdmin required (401/403)"
            else
              match Observed.to_option ks.github_identity with
              | None -> "loading..."
              | Some g ->
                  let eff =
                    if g.effective.authenticated then
                      "@" ^ Option.value ~default:"ok" g.effective.login
                    else "unauthenticated"
                  in
                  Printf.sprintf "%s (%s)" eff g.hostname
          in
          push (Printf.sprintf "%s [GitHub] %s" mark gh_s))
    entries;
  (match ks.oauth_pending_login with
  | Some (Wire_keeper_context.Oauth_login_exchange ex) ->
      push
        (Printf.sprintf "── OAuth Login Pending (%s · attempt=%s) ──"
           ex.provider_label ex.attempt_id);
      List.iter push (wrap_lines ~width:w ("  URL: " ^ ex.authorize_url));
      push "  Press [y] to copy URL · [L] to poll attempt status"
  | Some (Wire_keeper_context.Oauth_login_direct d) ->
      push
        (Printf.sprintf "  OAuth direct (%s): %d tools · %s" d.provider_label
           d.tool_count d.message)
  | None -> ());
  (match ks.oauth_attempt_status with
  | Some st ->
      push
        (Printf.sprintf "  Attempt status: %s%s" st.kind
           (match st.detail with Some d -> " · " ^ d | None -> ""))
  | None -> ());
  (match Observed.to_option ks.oauth_attached with
  | Some att ->
      List.iter
        (fun (p : Wire_keeper_context.oauth_attached_provider) ->
          if p.tools <> [] then
            List.iter push
              (wrap_lines ~width:w
                 (Printf.sprintf "  [%s tools (%d)]: %s" p.provider
                    (List.length p.tools) (String.concat ", " p.tools)));
          Option.iter (fun pr -> push ("  [" ^ p.provider ^ " problem]: " ^ pr)) p.problem)
        att.providers
  | None -> ());
  push "── GitHub Identity Detail ──";
  if ks.github_auth_denied then
    push "  [CanAdmin required] GitHub identity endpoint returned 401/403"
  else (
    match Observed.to_option ks.github_identity with
    | None -> push "  (loading /api/v1/keepers/:name/github-identity...)"
    | Some g ->
        push
          (Printf.sprintf "  Host: %s · Scope: %s" g.hostname
             g.effective_probe_scope);
        push
          (Printf.sprintf "  Stored: %s (%s) · Effective: %s (%s)"
             (if g.stored.authenticated then "auth" else "none")
             (Option.value ~default:"-" g.stored.login)
             (if g.effective.authenticated then "auth" else "none")
             (Option.value ~default:"-" g.effective.login));
        if g.effective.scopes <> [] then
          push ("  Scopes: " ^ String.concat ", " g.effective.scopes);
        Option.iter (fun e -> push ("  Effective error: " ^ e)) g.effective.error);
  if
    ks.github_login.running
    || Option.is_some ks.github_login.device_url
    || Option.is_some ks.github_login.device_code
    || ks.github_login.output_lines <> []
    || Option.is_some ks.github_login.error
  then (
    push
      (Printf.sprintf "── GitHub Device Flow (%s) ──"
         (if ks.github_login.running then "running..." else "finished"));
    Option.iter
      (fun u -> push ("  Verification URL: " ^ u))
      ks.github_login.device_url;
    Option.iter
      (fun c -> push ("  One-time code: " ^ c ^ "  ([y] copy code)"))
      ks.github_login.device_code;
    Option.iter (fun e -> push ("  Error: " ^ e)) ks.github_login.error;
    List.iter
      (fun ln -> List.iter push (wrap_lines ~width:w ("  | " ^ ln)))
      (take_n 12 (List.rev ks.github_login.output_lines)));
  List.rev !lines

let verification_dive_tab_lines ~width (m : Model.t)
    (v : Wire_work.verification_request) : string list =
  let w = max 20 width in
  let lines = ref [] in
  let push s = lines := s :: !lines in
  match m.work.verification_dive_tab with
  | Work_store.Verif_tab_evidence ->
      if m.work.verification_evidence_auth_denied then (
        push "[CanAdmin required] GET /api/v1/verification/evidence returned 401/403";
        push "Configure an admin token or switch tabs with [v] for Summary / Specs / TLC.")
      else (
        match
          Work_store.verification_evidence_for ~verification_id:v.request_id
            m.work
        with
        | None ->
            push "(loading /api/v1/verification/evidence...)"
        | Some bundle ->
            push
              (Printf.sprintf "Authority: %s (%s) · Producer: %s · Available: %s"
                 bundle.authority_kind bundle.authority_actor
                 (Option.value ~default:"-" bundle.producer)
                 (if bundle.available then "yes" else "no"));
            Option.iter
              (fun r -> push ("Unavailable reason: " ^ r))
              bundle.unavailable_reason;
            if bundle.items = [] then push "(no evidence items recorded)"
            else
              List.iter
                (function
                  | Wire_work.Verif_ev_note txt ->
                      List.iter push (wrap_lines ~width:w ("[note] " ^ txt))
                  | Wire_work.Verif_ev_artifact
                      { reference; content; bytes; truncated } ->
                      push
                        (Printf.sprintf "[artifact] %s (%dB%s)" reference bytes
                           (if truncated then " truncated" else ""));
                      List.iter push (wrap_lines ~width:w ("  " ^ content))
                  | Wire_work.Verif_ev_binary
                      { reference; bytes; sha256; format; body } ->
                      push
                        (Printf.sprintf "[binary:%s] %s (%dB sha=%s)" format
                           reference bytes sha256);
                      Option.iter
                        (fun b -> List.iter push (wrap_lines ~width:w ("  " ^ b)))
                        body
                  | Wire_work.Verif_ev_collab { reference; content; sha256 } ->
                      push
                        (Printf.sprintf "[collab] %s (sha=%s)" reference sha256);
                      List.iter push (wrap_lines ~width:w ("  " ^ content))
                  | Wire_work.Verif_ev_unreadable { reference; code; detail } ->
                      push
                        (Printf.sprintf "[unreadable:%s] %s%s" code
                           (Option.value ~default:"-" reference)
                           (match detail with Some d -> " · " ^ d | None -> "")))
                bundle.items);
      List.rev !lines
  | Work_store.Verif_tab_summary ->
      (match Observed.to_option m.work.verification_summary with
      | None -> push "(loading /api/v1/verification/summary...)"
      | Some s ->
          let parts =
            [ "Updated: " ^ s.updated_at; Printf.sprintf "Total=%d" s.total ]
            @ (match s.pending with
              | Some n -> [ Printf.sprintf "Pending=%d" n ]
              | None -> [])
            @ (match s.approved with
              | Some n -> [ Printf.sprintf "Approved=%d" n ]
              | None -> [])
            @
            match s.rejected with
            | Some n -> [ Printf.sprintf "Rejected=%d" n ]
            | None -> []
          in
          push (String.concat " · " parts);
          let jlines =
            Masc_tui_ui.Json_tree.flatten ~max_depth:4 ~redact_secrets:true s.raw
          in
          let format_jval = function
            | Masc_tui_ui.Json_tree.Object_node { count } ->
                Printf.sprintf "{%d keys}" count
            | Masc_tui_ui.Json_tree.Array_node { count } ->
                Printf.sprintf "[%d items]" count
            | Masc_tui_ui.Json_tree.String_val s -> "\"" ^ s ^ "\""
            | Masc_tui_ui.Json_tree.Redacted_secret -> "[REDACTED]"
            | Masc_tui_ui.Json_tree.Int_val n -> Int.to_string n
            | Masc_tui_ui.Json_tree.Float_val f -> Printf.sprintf "%.4g" f
            | Masc_tui_ui.Json_tree.Bool_val b -> Bool.to_string b
            | Masc_tui_ui.Json_tree.Null_val -> "null"
          in
          List.iter
            (fun (jl : Masc_tui_ui.Json_tree.line) ->
              let indent = String.make (min 12 (jl.depth * 2)) ' ' in
              let k_s =
                match jl.key with Some k -> k ^ ": " | None -> ""
              in
              push (indent ^ k_s ^ format_jval jl.value))
            jlines);
      List.rev !lines
  | Work_store.Verif_tab_specs ->
      (match Observed.to_option m.work.verification_specs with
      | None -> push "(loading /api/v1/verification/specs...)"
      | Some sp ->
          push
            (Printf.sprintf "Updated: %s · Dir: %s · Specs: %d" sp.updated_at
               (Option.value ~default:"-" sp.specs_dir)
               (List.length sp.entries));
          List.iter
            (fun (e : Wire_work.tla_spec_entry) ->
              push
                (Printf.sprintf "  [%s] %s (clean=%s buggy=%s) · %s" e.category
                   e.name
                   (if e.has_clean_cfg then "y" else "n")
                   (if e.has_buggy_cfg then "y" else "n")
                   e.path))
            sp.entries);
      List.rev !lines
  | Work_store.Verif_tab_tlc ->
      (match Observed.to_option m.work.verification_tlc_results with
      | None -> push "(loading /api/v1/verification/tlc-results...)"
      | Some tlc ->
          push
            (Printf.sprintf "Updated: %s · Dir: %s · Results: %d" tlc.updated_at
               (Option.value ~default:"-" tlc.results_dir)
               (List.length tlc.entries));
          List.iter
            (fun (e : Wire_work.tlc_result_entry) ->
              let st_s =
                match e.states_explored, e.distinct_states with
                | Some tot, Some dist ->
                    Printf.sprintf " states=%d(%d)" tot dist
                | Some tot, None -> Printf.sprintf " states=%d" tot
                | _ -> ""
              in
              push
                (Printf.sprintf "  [%s] %s/%s (%s)%s" e.status e.spec_name
                   e.cfg_name e.category st_s);
              Option.iter
                (fun viol ->
                  List.iter push (wrap_lines ~width:w ("    violation: " ^ viol)))
                e.violation)
            tlc.entries);
      List.rev !lines

let code_right_pane_line_count (m : Model.t) : int =
  let c = m.infra.code in
  match c.right_mode with
  | Infra_store.Code_file -> (
      match Infra_store.open_file_for_current m.infra with
      | Some f -> List.length (String.split_on_char '\n' f.content)
      | None -> 0)
  | Infra_store.Code_search_results -> 0
  | Infra_store.Code_git_status -> (
      match Observed.to_option c.git_status with
      | Some (sc, st) when Wire_infra.equal_workspace_scope sc c.scope ->
          2 + List.length st.changes
      | Some _ | None -> 0)
  | Infra_store.Code_git_branches -> (
      match Observed.to_option c.git_branches with
      | Some (sc, bs) when Wire_infra.equal_workspace_scope sc c.scope ->
          List.length bs
      | Some _ | None -> 0)
  | Infra_store.Code_git_worktrees -> (
      match Observed.to_option c.git_worktrees with
      | Some (sc, ws) when Wire_infra.equal_workspace_scope sc c.scope ->
          List.length ws
      | Some _ | None -> 0)
  | Infra_store.Code_git_blame -> (
      let expected_path = Infra_store.active_code_file_path m.infra in
      match Observed.to_option c.git_blame with
      | Some (sc, path, bs)
        when Wire_infra.equal_workspace_scope sc c.scope
             && (match expected_path with
                | Some exp -> String.equal exp path
                | None -> true) ->
          List.length bs
      | Some _ | None -> 0)
  | Infra_store.Code_git_log -> (
      let expected_path = Infra_store.active_code_file_path m.infra in
      match Observed.to_option c.git_log with
      | Some (sc, path, cs)
        when Wire_infra.equal_workspace_scope sc c.scope
             && (match expected_path with
                | Some exp -> String.equal exp path
                | None -> true) ->
          List.length cs
      | Some _ | None -> 0)
  | Infra_store.Code_git_diff -> (
      let expected_path = Infra_store.active_code_file_path m.infra in
      match Observed.to_option c.git_diff with
      | Some (sc, path, df)
        when Wire_infra.equal_workspace_scope sc c.scope
             && (match expected_path with
                | Some exp -> String.equal exp path
                | None -> true) ->
          List.length df.lines
      | Some _ | None -> 0)

let memory_right_pane_max_scroll ~bp ~(rect : Rect.t)
    (k : Knowledge_store.t) =
  let inner = ui_card_inner rect in
  let content = ui_pad_content ~bp inner in
  if Rect.is_empty content then 0
  else
    match Observed.to_option (Knowledge_store.current_memory_diff k) with
    | None -> 0
    | Some _ ->
        (* Matches draw_temporal_memory_diff (screen_knowledge.ml):
           Row 0 summary (1) + Stacked_bar (2 if y+1 < bottom, unconditionally
           for both Keeper_diff and World_diff) + OS line (1 if keeper matches)
           + Memory_flow Braille chart (chart_height_for ~avail_h:(bottom - y))
           + divider (1). *)
        let y = ref 0 in
        let bottom = content.h in
        if !y < bottom then incr y;
        if !y + 1 < bottom then y := !y + 2;
        (match
           Option.bind k.memory_diff_keeper (fun keeper ->
               Observed.to_option
                 (Knowledge_store.memory_os_internals_for ~keeper k))
         with
        | Some _ when !y < bottom -> incr y
        | Some _ | None -> ());
        let flow_h =
          Masc_tui_ui.Memory_flow.chart_height_for ~avail_h:(bottom - !y)
        in
        if flow_h > 0 then y := !y + flow_h;
        if !y < bottom then incr y;
        let avail_h = max 1 (bottom - !y) in
        max 0 (Knowledge_store.memory_diff_line_count k - avail_h)

let knowledge_detail_max_scroll (m : Model.t) =
  let bp = ui_bp m in
  let br = ui_body_rect m in
  let theme = Theme.of_preset m.theme_preset in
  let k = m.knowledge in
  let body_after_bar =
    match
      Masc_tui_ui.Layout.split_v br
        [ Masc_tui_ui.Layout.Fixed 1; Masc_tui_ui.Layout.Flex 1 ]
    with
    | [ _; b ] -> b
    | _ -> br
  in
  match k.active_tab with
  | Nav.Knowledge_board -> (
      match Knowledge_store.selected_post k with
      | None -> 0
      | Some p ->
          let right_rect =
            if m.nav.zoomed then body_after_bar
            else
              snd
                (Masc_tui_ui.Layout.adaptive_split_2 ~stack_on_compact:true
                   ~left_ratio:0.48 ~top_ratio:0.54 bp body_after_bar)
          in
          let inner = ui_card_inner right_rect in
          let band_h = if inner.h >= 7 then 2 else 1 in
          let content =
            Rect.make ~x:inner.x ~y:(inner.y + band_h) ~w:inner.w
              ~h:(max 0 (inner.h - band_h))
            |> ui_pad_content ~bp
          in
          let header_used =
            match p.succession_chain_root_id, p.chain_depth with
            | Some _, Some d when d > 1 -> 2
            | _ -> if content.h >= 6 then 1 else 0
          in
          let rem = max 0 (content.h - header_used) in
          let comments =
            match Observed.to_option k.active_thread with
            | Some (tp, cs) when String.equal tp.id p.id -> cs
            | Some _ | None -> []
          in
          let comment_rows =
            if comments = [] || rem < 6 then 0
            else min 5 (1 + List.length comments)
          in
          let md_h = max 0 (rem - comment_rows) in
          markdown_max_scroll ~theme ~width:content.w ~height:md_h p.body)
  | Nav.Knowledge_wiki ->
      let right_rect =
        if m.nav.zoomed then body_after_bar
        else
          snd
            (Masc_tui_ui.Layout.adaptive_split_2 ~stack_on_compact:true
               ~left_ratio:0.38 ~top_ratio:0.48 bp body_after_bar)
      in
      wiki_preview_max_scroll ~bp ~theme ~rect:right_rect ~target_slug:None k
  | Nav.Knowledge_artifacts -> (
      match Knowledge_store.selected_artifact k with
      | None -> 0
      | Some a ->
          let right_rect =
            if m.nav.zoomed then body_after_bar
            else
              snd
                (Masc_tui_ui.Layout.adaptive_split_2 ~stack_on_compact:true
                   ~left_ratio:0.42 ~top_ratio:0.48 bp body_after_bar)
          in
          let inner = ui_card_inner right_rect in
          let band_h = if inner.h >= 7 then 2 else 1 in
          let content =
            Rect.make ~x:inner.x ~y:(inner.y + band_h) ~w:inner.w
              ~h:(max 0 (inner.h - band_h))
            |> ui_pad_content ~bp
          in
          let doc_h = max 1 (content.h - 2) in
          let detail_opt = Knowledge_store.artifact_detail_for_entry a k in
          let raw_body =
            match detail_opt with Some d -> d.content | None -> ""
          in
          let fmt = Wire_knowledge.artifact_format_of_entry a in
          let body_rows =
            if String.equal (String.trim raw_body) "" then 0
            else
              match (k.artifact_view_mode, fmt) with
              | `Raw_source, (`Html | `Markdown) ->
                  List.length (String.split_on_char '\n' raw_body)
              | `Document, `Html ->
                  List.length
                    (Masc_tui_ui.Html_doc.render_lines ~width:(max 1 content.w)
                       ~theme ~lang:m.lang raw_body)
              | `Document, `Markdown ->
                  let is_json =
                    String.starts_with ~prefix:"application/json"
                      (String.lowercase_ascii (String.trim a.body.mime))
                    || Filename.check_suffix
                         (String.lowercase_ascii (String.trim a.title))
                         ".json"
                  in
                  if is_json then
                    match Yojson.Safe.from_string raw_body with
                    | json ->
                        List.length
                          (String.split_on_char '\n'
                             (Yojson.Safe.pretty_to_string json))
                    | exception Yojson.Json_error _ ->
                        List.length (String.split_on_char '\n' raw_body)
                  else
                    List.length
                      (Masc_tui_ui.Markdown.render_lines ~width:(max 1 content.w)
                         ~theme raw_body)
          in
          max 0 (body_rows - doc_h))
  | Nav.Knowledge_memory -> (
      let right_rect =
        if m.nav.zoomed then body_after_bar
        else
          snd
            (Masc_tui_ui.Layout.adaptive_split_2 ~stack_on_compact:true
               ~left_ratio:0.48 ~top_ratio:0.48 bp body_after_bar)
      in
      match k.memory_subview with
      | Knowledge_store.Mem_diff_flow ->
          memory_right_pane_max_scroll ~bp ~rect:right_rect k
      | Knowledge_store.Mem_health_ledger | Knowledge_store.Mem_context ->
          let inner = ui_card_inner right_rect |> ui_pad_content ~bp in
          if Rect.is_empty inner then 0
          else
            let total =
              List.length (knowledge_memory_subview_lines ~width:inner.w k)
            in
            max 0 (total - max 1 inner.h))

let work_detail_max_scroll (m : Model.t) =
  let bp = ui_bp m in
  let br = ui_body_rect m in
  let theme = Theme.of_preset m.theme_preset in
  match m.work.active_tab with
  | Nav.Work_pipeline -> (
      match Work_store.selected_goal m.work with
      | None -> 0
      | Some g ->
          let right_rect =
            if br.w >= 96 then
              match
                Masc_tui_ui.Layout.split_h_bp bp br
                  [ Masc_tui_ui.Layout.Ratio 0.46; Masc_tui_ui.Layout.Flex 1 ]
              with
              | [ _; r ] -> r
              | _ -> Rect.empty
            else
              let goals_n = List.length (Work_store.filtered_goals m.work) in
              let top_h =
                min
                  (max 5 (br.h / 2))
                  (Masc_tui_ui.Layout.adaptive_list_height ~items:goals_n
                     ~overhead:4 ~min_h:5 ~max_h:10 ())
              in
              match
                Masc_tui_ui.Layout.split_v_bp bp br
                  [ Masc_tui_ui.Layout.Fixed top_h; Masc_tui_ui.Layout.Flex 1 ]
              with
              | [ _; b ] -> b
              | _ -> Rect.empty
          in
          let r_inner = ui_card_inner right_rect in
          let content = ops_pad_content r_inner in
          if Rect.is_empty content then 0
          else
            let y = ref r_inner.y in
            let bottom = Rect.bottom r_inner in
            if r_inner.h >= 8 then
              y := !y + 2 + if r_inner.h >= 16 then 1 else 0
            else if !y < bottom then incr y;
            let action_h =
              if bottom - !y >= 4 then 2
              else if bottom - !y >= 2 then 1
              else 0
            in
            let body_bot = bottom - action_h in
            if !y < body_bot then begin
              let step_avail = body_bot - !y in
              let step_used =
                match g.phase with
                | Wire_work.Paused _ | Wire_work.Blocked _
                  when min 2 step_avail >= 2 ->
                    2
                | Wire_work.Executing
                | Wire_work.Verifying
                | Wire_work.Awaiting_confirmation
                | Wire_work.Paused _
                | Wire_work.Blocked _
                | Wire_work.Completed
                | Wire_work.Dropped ->
                    1
              in
              y := !y + step_used + if step_avail >= 12 then 1 else 0
            end;
            if body_bot - !y >= 5 then y := !y + min 2 (body_bot - !y);
            (match g.last_review_note with
            | Some note
              when !y < body_bot && not (String.equal (String.trim note) "") ->
                incr y
            | Some _ | None -> ());
            let all_tasks = Work_store.tasks m.work in
            let unlinked_n = Work_store.unlinked_task_count m.work in
            let unattrib_n =
              match Observed.to_option m.work.candle_ledger with
              | Some l -> l.diagnostics.unattributed_count
              | None -> 0
            in
            if
              (not (Model.work_pipeline_has_linked_card m))
              && (unlinked_n > 0 || unattrib_n > 0)
              && !y < body_bot
            then incr y;
            let rem_h = max 0 (body_bot - !y) in
            let linked_ids =
              List.filter_map
                (fun (tk : Wire_work.task) ->
                  match tk.goal_link with
                  | Wire_work.Linked gid when String.equal gid g.id -> Some tk.id
                  | Wire_work.Linked _ | Wire_work.Unlinked -> None)
                all_tasks
            in
            let related_verifs =
              List.filter
                (fun (v : Wire_work.verification_request) ->
                  List.exists (String.equal v.task_id) linked_ids)
                (Work_store.verifications_list m.work)
            in
            let rejected_verif =
              List.find_opt
                (fun (v : Wire_work.verification_request) ->
                  match v.review_observation with
                  | Some obs -> (
                      match obs.state with
                      | Wire_work.Review_rejected | Wire_work.Review_failed ->
                          true
                      | Wire_work.Review_unobserved
                      | Wire_work.Review_running
                      | Wire_work.Review_approved
                      | Wire_work.Review_unavailable
                      | Wire_work.Review_not_reviewed
                      | Wire_work.Review_commit_failed
                      | Wire_work.Review_execution_pending
                      | Wire_work.Review_execution_repair_required
                      | Wire_work.Review_cancelled
                      | Wire_work.Review_superseded ->
                          false)
                  | None -> false)
                related_verifs
            in
            let diff_h =
              match rejected_verif with
              | Some _ when rem_h >= 10 -> min 6 (rem_h / 3)
              | Some _ | None -> 0
            in
            let ev_h =
              match rejected_verif, related_verifs with
              | None, _ :: _ when rem_h >= 9 -> min 4 (rem_h / 3)
              | _ -> 0
            in
            let md_avail = max 0 (rem_h - diff_h - ev_h) in
            let md_max =
              if md_avail >= 3 then begin
                incr y;
                let md_h = max 0 (md_avail - 1) in
                let md_src =
                  Printf.sprintf "**%s:** %s\n\n**%s:** %s"
                    (Say.resolve m.lang
                       (Say.make ~ko:"성공 조건" ~en:"Success Measure"))
                    (Chat_transcript.rewrite_masc_links_for_markdown g.measure)
                    (Say.resolve m.lang
                       (Say.make ~ko:"측정 절차" ~en:"Procedure"))
                    (Chat_transcript.rewrite_masc_links_for_markdown g.procedure)
                in
                y := !y + md_h;
                markdown_max_scroll ~theme ~width:content.w ~height:md_h md_src
              end
              else if md_avail >= 1 then begin
                let md_src =
                  Chat_transcript.rewrite_masc_links_for_markdown
                    (g.measure ^ " · " ^ g.procedure)
                in
                y := !y + md_avail;
                markdown_max_scroll ~theme ~width:content.w ~height:md_avail
                  md_src
              end
              else 0
            in
            let diff_max =
              match rejected_verif with
              | Some rv when diff_h >= 2 && !y < body_bot ->
                  incr y;
                  let drect_h = max 0 (min (diff_h - 1) (body_bot - !y)) in
                  if drect_h <= 0 then 0
                  else
                    max 0 (rejection_diff_row_count ~lang:m.lang rv - drect_h)
              | Some _ | None -> 0
            in
            max md_max diff_max)
  | Nav.Work_inbox -> (
      match
        Attention.current_filtered_item ~query:m.work.filter_query m.attention
      with
      | None -> 0
      | Some entry -> (
          let right_rect =
            if br.w >= 96 then
              match
                Masc_tui_ui.Layout.split_h_bp bp br
                  [ Masc_tui_ui.Layout.Ratio 0.42; Masc_tui_ui.Layout.Flex 1 ]
              with
              | [ _; r ] -> r
              | _ -> Rect.empty
            else
              match
                Masc_tui_ui.Layout.split_v_bp bp br
                  [ Masc_tui_ui.Layout.Ratio 0.38; Masc_tui_ui.Layout.Flex 1 ]
              with
              | [ _; b ] -> b
              | _ -> Rect.empty
          in
          let r_inner = ui_card_inner right_rect in
          let content_full = ops_pad_content r_inner in
          if Rect.is_empty content_full then 0
          else
            let band_h =
              if r_inner.h >= 7 then 2 + if r_inner.h >= 12 then 1 else 0 else 0
            in
            let avail_h = max 0 (r_inner.h - band_h) in
            let w = content_full.w in
            match entry.payload with
            | Attention.Payload_tool_approval ta ->
                let used = 1 + if Option.is_some ta.because then 1 else 0 in
                let rem = max 0 (avail_h - used) in
                let q_h = min 4 (max 0 (rem - 4)) in
                let q_max =
                  if q_h >= 1 then
                    markdown_max_scroll ~theme ~width:w ~height:q_h
                      (Chat_transcript.rewrite_masc_links_for_markdown
                         ta.question)
                  else 0
                in
                let after_q = max 0 (rem - q_h) in
                let jt_max =
                  if after_q > 2 then
                    let jt_h = max 0 (after_q - 2) in
                    let json =
                      parse_json_or_wrap_store ~key:"args" ta.args_preview
                    in
                    let lines =
                      Masc_tui_ui.Json_tree.flatten ~max_depth:3
                        ~redact_secrets:true json
                    in
                    if jt_h <= 0 then 0 else max 0 (List.length lines - jt_h)
                  else 0
                in
                max q_max jt_max
            | Attention.Payload_gate g ->
                let jt_h = max 0 (avail_h - 2) in
                if jt_h <= 0 then 0
                else
                  let raw_in = Option.value g.input_preview ~default:"{}" in
                  let lines =
                    Masc_tui_ui.Json_tree.flatten ~max_depth:3
                      ~redact_secrets:true
                      (parse_json_or_wrap_store ~key:"input" raw_in)
                  in
                  max 0 (List.length lines - jt_h)
            | Attention.Payload_ask ask ->
                let ctx_md =
                  match ask.context with
                  | Some c when not (String.equal (String.trim c) "") ->
                      c ^ "\n\n"
                  | Some _ | None -> ""
                in
                let q_opt =
                  match ask.questions with q :: _ -> Some q | [] -> None
                in
                let prompt_md =
                  match q_opt with
                  | Some q ->
                      Printf.sprintf "%s**%s**\n\n%s" ctx_md q.header
                        (Chat_transcript.rewrite_masc_links_for_markdown
                           q.prompt)
                  | None -> ctx_md
                in
                let after_meta = max 0 (avail_h - 1) in
                let keycap_h = if avail_h > 0 then 1 else 0 in
                let content_h = max 0 (after_meta - keycap_h) in
                let choices_h =
                  match q_opt with
                  | Some q ->
                      let desired = List.length q.choices + 2 in
                      min (max 3 (content_h / 2)) desired
                  | None -> 0
                in
                let md_h =
                  if content_h = 0 then 0
                  else min content_h (max 1 (content_h - choices_h))
                in
                markdown_max_scroll ~theme ~width:w ~height:md_h prompt_md
            | Attention.Payload_goal_confirmation g ->
                let md_h = max 0 (avail_h - 2) in
                if md_h <= 0 then 0
                else
                  markdown_max_scroll ~theme ~width:w ~height:md_h
                    (Chat_transcript.rewrite_masc_links_for_markdown
                       (g.measure ^ "\n\n" ^ g.procedure))))
  | Nav.Work_harness ->
      let _, right_rect =
        Masc_tui_ui.Layout.adaptive_split_2 ~stack_on_compact:true
          ~left_ratio:0.48 ~top_ratio:0.48 bp br
      in
      let content = ui_card_inner right_rect |> ops_pad_content in
      if Rect.is_empty content then 0
      else
        let total =
          List.length (harness_verdict_detail_lines ~width:content.w m)
        in
        max 0 (total - max 1 content.h)
  | Nav.Work_tasks -> (
      match Work_store.selected_task m.work with
      | None -> 0
      | Some tk -> (
          match tk.description with
          | None -> 0
          | Some desc ->
              let body_r =
                match
                  Masc_tui_ui.Layout.split_v br
                    [ Masc_tui_ui.Layout.Fixed 1; Masc_tui_ui.Layout.Flex 1 ]
                with
                | [ _; b ] -> b
                | _ -> br
              in
              let detail_rect =
                if body_r.w >= 96 then
                  match
                    Masc_tui_ui.Layout.split_h_bp bp body_r
                      [ Masc_tui_ui.Layout.Ratio 0.54; Masc_tui_ui.Layout.Flex 1 ]
                  with
                  | [ _; r ] -> r
                  | _ -> Rect.empty
                else
                  match
                    Masc_tui_ui.Layout.split_v_bp bp body_r
                      [ Masc_tui_ui.Layout.Ratio 0.52; Masc_tui_ui.Layout.Flex 1 ]
                  with
                  | [ _; b ] -> b
                  | _ -> Rect.empty
              in
              let d_inner = ui_card_inner detail_rect in
              let content = ops_pad_content d_inner in
              if Rect.is_empty content then 0
              else
                let overhead =
                  (if d_inner.h >= 7 then
                     2 + if d_inner.h >= 12 then 1 else 0
                   else 0)
                  + 4
                in
                let md_h = max 1 (content.h - overhead) in
                let theme = Theme.of_preset m.theme_preset in
                markdown_max_scroll ~theme ~width:content.w ~height:md_h
                  (Chat_transcript.rewrite_masc_links_for_markdown desc)))
  | Nav.Work_schedules -> (
      match Work_store.selected_schedule m.work with
      | None -> 0
      | Some sc -> (
          match sc.payload_summary with
          | None -> 0
          | Some s when String.equal (String.trim s) "" -> 0
          | Some summary_txt ->
              let detail_rect =
                if br.w >= 96 then
                  match
                    Masc_tui_ui.Layout.split_h_bp bp br
                      [ Masc_tui_ui.Layout.Ratio 0.60; Masc_tui_ui.Layout.Flex 1 ]
                  with
                  | [ _; r ] -> r
                  | _ -> Rect.empty
                else
                  match
                    Masc_tui_ui.Layout.split_v_bp bp br
                      [ Masc_tui_ui.Layout.Ratio 0.58; Masc_tui_ui.Layout.Flex 1 ]
                  with
                  | [ _; b ] -> b
                  | _ -> Rect.empty
              in
              let d_inner = ui_card_inner detail_rect in
              let content = ops_pad_content d_inner in
              if Rect.is_empty content then 0
              else
                let overhead =
                  (if d_inner.h >= 6 then
                     2 + if d_inner.h >= 10 then 1 else 0
                   else 0)
                  + 5
                in
                let md_h = max 1 (content.h - overhead) in
                let theme = Theme.of_preset m.theme_preset in
                markdown_max_scroll ~theme ~width:content.w ~height:md_h
                  summary_txt))
  | Nav.Work_candle_scorecard -> (
      match Observed.to_option m.work.candle_ledger with
      | None -> 0
      | Some ledger ->
          let kpi_h = if br.h >= 22 then 5 else 0 in
          let main_r =
            Rect.make ~x:br.x ~y:(br.y + kpi_h) ~w:br.w
              ~h:(max 0 (br.h - kpi_h))
          in
          let left_r =
            if main_r.w >= 110 then
              match
                Masc_tui_ui.Layout.split_h_bp bp main_r
                  [ Masc_tui_ui.Layout.Ratio 0.62; Masc_tui_ui.Layout.Flex 1 ]
              with
              | [ l; _ ] -> l
              | _ -> main_r
            else main_r
          in
          let ev_rect =
            match
              Masc_tui_ui.Layout.split_v_bp bp left_r
                [ Masc_tui_ui.Layout.Ratio 0.54; Masc_tui_ui.Layout.Flex 1 ]
            with
            | [ _; b ] -> b
            | _ -> Rect.empty
          in
          let e_inner = ui_card_inner ev_rect in
          let table_rows = max 1 (e_inner.h - 2) in
          max 0 (List.length ledger.recent_events - table_rows))

let runtime_detail_max_scroll (m : Model.t) =
  let bp = ui_bp m in
  let br = ui_body_rect m in
  let body_rect =
    match
      Masc_tui_ui.Layout.split_v br
        [ Masc_tui_ui.Layout.Fixed 1; Masc_tui_ui.Layout.Flex 1 ]
    with
    | [ _; b ] -> b
    | _ -> br
  in
  match m.runtime.active_tab with
  | Nav.Runtime_quotas_credits ->
      let left_rect, _ =
        Masc_tui_ui.Layout.adaptive_split_2 ~stack_on_compact:true
          ~left_ratio:0.46 ~top_ratio:0.48 bp body_rect
      in
      let total = Runtime_store.subscription_window_count m.runtime in
      let top_sub_h =
        Masc_tui_ui.Layout.adaptive_list_height ~items:total ~overhead:4
          ~min_h:5
          ~max_h:(max 5 (left_rect.h * 52 / 100))
          ()
      in
      let sub_rect =
        if left_rect.h >= 11 then
          match
            Masc_tui_ui.Layout.split_v_bp bp left_rect
              [ Masc_tui_ui.Layout.Fixed top_sub_h; Masc_tui_ui.Layout.Flex 1 ]
          with
          | [ a; _ ] -> a
          | _ -> left_rect
        else left_rect
      in
      let content = ui_card_inner sub_rect |> ui_pad_content ~bp in
      if Rect.is_empty content then 0
      else
        let vis = content.h in
        let truncated = total > vis && vis >= 2 in
        let visible_limit = if truncated then vis - 1 else vis in
        max 0 (total - visible_limit)
  | Nav.Runtime_failover_lanes -> (
      match Runtime_store.selected_lane m.runtime with
      | None -> 0
      | Some lane ->
          let _, right_rect =
            Masc_tui_ui.Layout.adaptive_split_2 ~stack_on_compact:true
              ~left_ratio:0.56 ~top_ratio:0.54 bp body_rect
          in
          let insp_rect =
            match
              Masc_tui_ui.Layout.split_v_bp bp right_rect
                [ Masc_tui_ui.Layout.Ratio 0.52; Masc_tui_ui.Layout.Flex 1 ]
            with
            | [ a; _ ] -> a
            | _ -> right_rect
          in
          let insp_inner = ui_card_inner insp_rect in
          if Rect.is_empty insp_inner then 0
          else
            let band_h = if insp_inner.h >= 6 then 2 else 1 in
            let body_area =
              Rect.make ~x:insp_inner.x ~y:(insp_inner.y + band_h)
                ~w:insp_inner.w
                ~h:(max 0 (insp_inner.h - band_h))
              |> ui_pad_content ~bp
            in
            if Rect.is_empty body_area then 0
            else
              (* gauge (1) + divider (1) = 2 rows before slot probes *)
              let avail_slot_rows = max 1 (body_area.h - 2) in
              max 0 (List.length lane.runtime_ids - avail_slot_rows))
  | Nav.Runtime_tools_usage -> (
      match m.runtime.tools_subview with
      | Runtime_store.Tools_keeper_skills -> (
          let body_rect =
            match
              Masc_tui_ui.Layout.split_v br
                [ Masc_tui_ui.Layout.Fixed 1; Masc_tui_ui.Layout.Flex 1 ]
            with
            | [ _; b ] -> b
            | _ -> br
          in
          let _, right_rect =
            Masc_tui_ui.Layout.adaptive_split_2 ~stack_on_compact:true
              ~left_ratio:0.52 ~top_ratio:0.50 bp body_rect
          in
          let rc = ui_card_inner right_rect |> ui_pad_content ~bp in
          if Rect.is_empty rc then 0
          else
            match Observed.to_option m.runtime.skills with
            | None -> 0
            | Some sk ->
                let hdr_rows =
                  1
                  + (if sk.rejections <> [] then 1 else 0)
                  + (if sk.shadows <> [] then 1 else 0)
                  + 1
                in
                let vis = max 1 (rc.h - hdr_rows) in
                max 0 (List.length sk.surfaces - vis))
      | Runtime_store.Tools_usage_calls | Runtime_store.Tools_catalog_tree -> 0)
  | Nav.Runtime_fusion -> (
      match Runtime_store.selected_fusion_run m.runtime with
      | None -> 0
      | Some run ->
          let _, right_rect =
            Masc_tui_ui.Layout.adaptive_split_2 ~stack_on_compact:true
              ~left_ratio:0.44 ~top_ratio:0.46 bp body_rect
          in
          let rc = ui_card_inner right_rect |> ui_pad_content ~bp in
          if Rect.is_empty rc then 0
          else
            let total =
              List.length (fusion_detail_lines ~width:rc.w m ~run_id:run.run_id)
            in
            max 0 (total - max 1 rc.h))
  | Nav.Runtime_addons_browser when m.runtime.addon_catalog_mode -> (
      match Runtime_store.selected_addon_catalog_entry m.runtime with
      | Some (Wire_runtime.Catalog_package { manifest_path; _ }) -> (
          match Runtime_store.addon_preview_for ~manifest_path m.runtime with
          | None -> 0
          | Some preview ->
              let _, right_rect =
                Masc_tui_ui.Layout.adaptive_split_2 ~stack_on_compact:true
                  ~left_ratio:0.52 ~top_ratio:0.50 bp body_rect
              in
              let rc = ui_card_inner right_rect |> ui_pad_content ~bp in
              if Rect.is_empty rc then 0
              else
                let total =
                  List.length (addon_catalog_preview_lines ~width:rc.w preview)
                in
                max 0 (total - max 1 rc.h))
      | Some (Wire_runtime.Catalog_folder _ | Wire_runtime.Catalog_issue _)
      | None ->
          0)
  | Nav.Runtime_efficiency_spend
  | Nav.Runtime_connectors
  | Nav.Runtime_addons_browser ->
      0

let infra_detail_max_scroll (m : Model.t) =
  let bp = ui_bp m in
  let br = ui_body_rect m in
  match m.infra.active_tab with
  | Nav.Infra_sandboxes -> (
      match Infra_store.selected_sandbox_keeper m.infra with
      | None -> 0
      | Some kp -> (
          let top_h = if br.w >= 100 then 6 else 4 in
          let body_rect =
            match
              Masc_tui_ui.Layout.split_v_bp bp br
                [ Masc_tui_ui.Layout.Fixed top_h; Masc_tui_ui.Layout.Flex 1 ]
            with
            | [ _; b ] -> b
            | _ -> br
          in
          if body_rect.w < 100 then 0
          else
            let right_rect =
              match
                Masc_tui_ui.Layout.split_h_bp bp body_rect
                  [ Masc_tui_ui.Layout.Ratio 0.60; Masc_tui_ui.Layout.Flex 1 ]
              with
              | [ _; r ] -> r
              | _ -> Rect.empty
            in
            let inner = ui_card_inner right_rect in
            if Rect.is_empty inner then 0
            else
              match
                sandbox_entry_info_for_keeper ~use_keeper_detail:false
                  ~keeper:kp m.infra
              with
              | None -> 0
              | Some info ->
                  let rem_rows =
                    sandbox_inspector_rem_rows ~inner_h:inner.h info
                  in
                  if rem_rows <= 0 then 0
                  else
                    max 0
                      (Infra_store.sandbox_inspector_event_count ~keeper:kp
                         m.infra
                      - rem_rows)))
  | Nav.Infra_repos_changes -> (
      match Infra_store.selected_change m.infra with
      | Some fc -> (
          match Infra_store.change_preview_rows fc with
          | [] -> 0
          | rows ->
              let _, right_rect =
                Masc_tui_ui.Layout.adaptive_split_2 ~stack_on_compact:true
                  ~left_ratio:0.42 ~top_ratio:0.46 bp br
              in
              let inner = ui_card_inner right_rect in
              if Rect.is_empty inner then 0
              else
                let band_h = if inner.h >= 5 then 2 else 1 in
                let link_h =
                  if Option.is_some (Infra_store.selected_repository m.infra)
                  then 1
                  else 0
                in
                let diff_h = max 1 (inner.h - band_h - link_h - 1) in
                max 0 (List.length rows - diff_h))
      | None -> 0)
  | Nav.Infra_code ->
      let body_rect =
        match
          Masc_tui_ui.Layout.split_v br
            [ Masc_tui_ui.Layout.Fixed 1; Masc_tui_ui.Layout.Flex 1 ]
        with
        | [ _; b ] -> b
        | _ -> br
      in
      let _, right_rect =
        Masc_tui_ui.Layout.adaptive_split_2 ~stack_on_compact:true
          ~left_ratio:0.32 ~top_ratio:0.42 bp body_rect
      in
      let rc = ui_card_inner right_rect |> ui_pad_content ~bp in
      if Rect.is_empty rc then 0
      else
        let vis_h = max 1 (rc.h - 1) in
        max 0 (code_right_pane_line_count m - vis_h)
  | Nav.Infra_activity_logs -> (
      match Infra_store.selected_timeline_entry m.infra with
      | None -> 0
      | Some entry ->
          let body_rect =
            match
              Masc_tui_ui.Layout.split_v br
                [ Masc_tui_ui.Layout.Fixed 1; Masc_tui_ui.Layout.Flex 1 ]
            with
            | [ _; b ] -> b
            | _ -> br
          in
          let _, right_rect =
            if m.infra.acting_rail_open && body_rect.w >= 104 then
              match
                Masc_tui_ui.Layout.split_h_bp bp body_rect
                  [
                    Masc_tui_ui.Layout.Ratio 0.50;
                    Masc_tui_ui.Layout.Ratio 0.32;
                    Masc_tui_ui.Layout.Flex 1;
                  ]
              with
              | [ l; r; _ ] -> (l, r)
              | _ ->
                  Masc_tui_ui.Layout.adaptive_split_2 ~stack_on_compact:true
                    ~left_ratio:0.62 ~top_ratio:0.56 bp body_rect
            else
              Masc_tui_ui.Layout.adaptive_split_2 ~stack_on_compact:true
                ~left_ratio:0.62 ~top_ratio:0.56 bp body_rect
          in
          let inner = ui_card_inner right_rect in
          if Rect.is_empty inner then 0
          else
            let band_h = if inner.h >= 6 then 2 else 1 in
            let content =
              Rect.make ~x:inner.x ~y:(inner.y + band_h) ~w:inner.w
                ~h:(max 0 (inner.h - band_h))
              |> ui_pad_content ~bp
            in
            if Rect.is_empty content then 0
            else (
              match entry with
              | Infra_store.Entry_log e ->
                  let msg_lines =
                    Chat_transcript.wrap_plain_lines
                      ~width:(max 1 (content.w - 2))
                      e.message
                  in
                  let tree_lines =
                    Masc_tui_ui.Json_tree.flatten ~max_depth:4
                      ~redact_secrets:true e.details
                  in
                  let total =
                    List.length msg_lines + 1 + List.length tree_lines
                  in
                  max 0 (total - max 1 content.h)
              | Infra_store.Entry_event ev ->
                  let detail_lines =
                    match ev.detail with
                    | Some d when not (String.equal (String.trim d) "") ->
                        Chat_transcript.wrap_plain_lines
                          ~width:(max 1 (content.w - 2))
                          d
                    | Some _ | None -> []
                  in
                  let sum_lines =
                    Chat_transcript.wrap_plain_lines
                      ~width:(max 1 (content.w - 2))
                      ev.summary
                  in
                  let total =
                    List.length sum_lines + 3 + List.length detail_lines
                  in
                  max 0 (total - max 1 content.h)))

let keeper_tab_max_scroll ~embedded (m : Model.t) ~name ~tab =
  let content_w, content_h =
    Chat_transcript.keeper_content_rect_size ~embedded ~model:m
  in
  if content_w <= 0 || content_h <= 0 then 0
  else
    match tab with
    | Nav.Keeper_memory -> (
        let subbar_h = if content_h >= 4 then 1 else 0 in
        let body_h = max 0 (content_h - subbar_h) in
        match m.knowledge.keeper_memory_subview with
        | Knowledge_store.Kmem_diff_flow ->
            let footer_h = if body_h >= 7 then 2 else 0 in
            let inner_h = max 0 (body_h - footer_h) in
            let hdr_rows =
              match
                Observed.to_option
                  (Knowledge_store.memory_diff_for ~keeper:(Some name)
                     ~window:m.knowledge.memory_diff_window m.knowledge)
              with
              | Some
                  {
                    retrieval_heat = heat;
                    body = Wire_knowledge.Keeper_diff _;
                    _;
                  } ->
                  let has_os =
                    Option.is_some
                      (Observed.to_option
                         (Knowledge_store.memory_os_internals_for ~keeper:name
                            m.knowledge))
                  in
                  let heat_total =
                    heat.hot + heat.warm + heat.cold + heat.never_retrieved
                  in
                  let base = 2 + if has_os then 1 else 0 in
                  let heat_rows =
                    if heat_total > 0 && inner_h - base >= 4 then 3 else 0
                  in
                  let y_after_heat = base + heat_rows in
                  let flow_h =
                    Masc_tui_ui.Memory_flow.chart_height_for
                      ~avail_h:(inner_h - y_after_heat)
                  in
                  let flow_rows =
                    if flow_h > 0 then
                      let rem_after = inner_h - (y_after_heat + flow_h) in
                      flow_h + if rem_after > 0 then 1 else 0
                    else 0
                  in
                  y_after_heat + flow_rows
              | Some { body = Wire_knowledge.World_diff _; _ } | None -> 0
            in
            let vis_h = max 1 (inner_h - hdr_rows) in
            let total =
              Knowledge_store.keeper_memory_diff_line_count ~name m.knowledge
            in
            max 0 (total - vis_h)
        | Knowledge_store.Kmem_health
        | Knowledge_store.Kmem_facts_tree
        | Knowledge_store.Kmem_journal ->
            let pad_x =
              if content_w < 20 then 0
              else if content_w < 44 then 1
              else Masc_tui_ui.Layout.card_pad_x (ui_bp m)
            in
            let inner_w = max 1 (content_w - (2 * pad_x)) in
            let total =
              List.length
                (keeper_memory_subview_lines ~width:inner_w ~name m.knowledge)
            in
            max 0 (total - max 1 body_h))
    | Nav.Keeper_logs ->
        let pad_x =
          if content_w < 20 then 0
          else if content_w < 44 then 1
          else Masc_tui_ui.Layout.card_pad_x (ui_bp m)
        in
        let inner_w = max 1 (content_w - (2 * pad_x)) in
        let ks = Keeper_context_store.get_keeper ~keeper:name m.keeper_context in
        let total = List.length (keeper_logs_lines ~width:inner_w ~name ks) in
        max 0 (total - max 1 content_h)
    | Nav.Keeper_identity ->
        let pad_x =
          if content_w < 20 then 0
          else if content_w < 44 then 1
          else Masc_tui_ui.Layout.card_pad_x (ui_bp m)
        in
        let inner_w = max 1 (content_w - (2 * pad_x)) in
        let total =
          List.length (keeper_identity_lines ~width:inner_w ~name m)
        in
        max 0 (total - max 1 content_h)
    | Nav.Keeper_work_candle ->
        let left_h =
          if content_w >= 76 then content_h
          else
            match
              Masc_tui_ui.Layout.split_v ~gap:1
                (Rect.make ~x:0 ~y:0 ~w:content_w ~h:content_h)
                [ Masc_tui_ui.Layout.Ratio 0.56; Masc_tui_ui.Layout.Flex 1 ]
            with
            | t :: _ -> t.h
            | [] -> content_h
        in
        let n_tasks =
          List.length
            (List.filter
               (fun (tk : Wire_work.task) ->
                 match tk.status with
                 | Wire_work.Claimed { assignee; _ }
                 | Wire_work.InProgress { assignee; _ }
                 | Wire_work.AwaitingVerification { assignee; _ }
                 | Wire_work.Done { assignee; _ } ->
                     String.equal assignee name
                 | Wire_work.Cancelled { cancelled_by; _ } ->
                     String.equal cancelled_by name
                 | Wire_work.Todo -> false)
               (Work_store.tasks m.work))
        in
        let n_scheds =
          List.length
            (Keeper_cadence.keeper_schedules ~name (Work_store.schedules_list m.work))
        in
        let n_posts =
          List.length
            (List.filter
               (fun (p : Wire_knowledge.board_post) -> String.equal p.author name)
               (Knowledge_store.filtered_posts m.knowledge))
        in
        (* Fixed rows besides the cadence block: the Board recovery hint line and
           the three section hairlines (tasks, schedules, posts). *)
        let total_rows =
          Keeper_cadence.block_rows (Fleet_store.turn_pulse m.fleet name)
          + 4 + max 1 n_tasks + max 1 n_scheds + max 1 n_posts
        in
        max 0 (total_rows - max 1 left_h)
    | Nav.Keeper_sandbox ->
        let top_h = min 10 (max 4 (content_h / 2)) in
        let rest_h = max 0 (content_h - top_h) in
        let metrics_h =
          if rest_h >= 8 then 5 else if rest_h >= 5 then 3 else 0
        in
        let logs_h = max 0 (rest_h - metrics_h) in
        let body_logs_h = max 1 (logs_h - 1) in
        let n_logs =
          List.length
            (List.filter
               (fun (l : Wire_infra.system_log_entry) ->
                 Option.equal String.equal l.keeper (Some name))
               m.infra.logs)
        in
        max 0 (n_logs - body_logs_h)
    | Nav.Keeper_chat
    | Nav.Keeper_context
    | Nav.Keeper_tool_calls
    | Nav.Keeper_config ->
        0

let memory_reading_max_scroll (m : Model.t) =
  match m.knowledge.memory_reading with
  | None -> 0
  | Some entry ->
      let bp = ui_bp m in
      let br = ui_body_rect m in
      let keeper_padded_w cw =
        let pad_x =
          if cw < 20 then 0
          else if cw < 44 then 1
          else Masc_tui_ui.Layout.card_pad_x bp
        in
        max 0 (cw - (2 * pad_x))
      in
      let rect_w, rect_h =
        match Model.active_dive m with
        | Some (Nav.Dive_keeper { tab = Nav.Keeper_memory; _ }) ->
            let cw, ch =
              Chat_transcript.keeper_content_rect_size ~embedded:false ~model:m
            in
            let subbar_h = if ch >= 4 then 1 else 0 in
            let ch_after = max 0 (ch - subbar_h) in
            let footer_h = if ch_after >= 7 then 2 else 0 in
            (keeper_padded_w cw, max 0 (ch_after - footer_h))
        | Some (Nav.Dive_knowledge (Nav.Memory_diff_dive _)) ->
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
                     ~left_ratio:0.48 ~top_ratio:0.48 bp body_after_bar)
            in
            let content = right_rect |> ui_card_inner |> ui_pad_content ~bp in
            (content.w, content.h)
        | Some
            ( Nav.Dive_keeper
                {
                  tab =
                    ( Nav.Keeper_chat
                    | Nav.Keeper_context
                    | Nav.Keeper_tool_calls
                    | Nav.Keeper_work_candle
                    | Nav.Keeper_sandbox
                    | Nav.Keeper_config
                    | Nav.Keeper_logs
                    | Nav.Keeper_identity );
                  _;
                }
            | Nav.Dive_work _
            | Nav.Dive_knowledge
                (Nav.Thread_dive _ | Nav.Wiki_dive _ | Nav.Artifact_dive _)
            | Nav.Dive_runtime _
            | Nav.Dive_infra _ ) ->
            (0, 0)
        | None -> (
            match m.nav.workspace with
            | Nav.Keepers
              when Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_memory
              ->
                let zoomed_keeper =
                  m.nav.zoomed && Model.can_zoom_current_view m
                in
                let cw, ch =
                  Chat_transcript.keeper_content_rect_size
                    ~embedded:(not zoomed_keeper) ~model:m
                in
                let subbar_h = if ch >= 4 then 1 else 0 in
                let ch_after = max 0 (ch - subbar_h) in
                let footer_h = if ch_after >= 7 then 2 else 0 in
                (keeper_padded_w cw, max 0 (ch_after - footer_h))
            | Nav.Knowledge
              when Nav.equal_knowledge_tab m.knowledge.active_tab
                     Nav.Knowledge_memory ->
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
                      (Masc_tui_ui.Layout.adaptive_split_2
                         ~stack_on_compact:true ~left_ratio:0.48 ~top_ratio:0.48
                         bp body_after_bar)
                in
                let content =
                  right_rect |> ui_card_inner |> ui_pad_content ~bp
                in
                (content.w, content.h)
            | Nav.Pulse
            | Nav.Work
            | Nav.Keepers
            | Nav.Knowledge
            | Nav.Runtime
            | Nav.Infra ->
                (0, 0))
      in
      if rect_w <= 0 || rect_h <= 1 then 0
      else
        (* [render_full_reading] reserves 1 row for the Full Reading header. *)
        let body_h = max 1 (rect_h - 1) in
        let total =
          List.length
            (Knowledge_store.project_memory_reading_lines ~width:rect_w
               ~lang:m.lang ~now_unix:m.freshness.last_wall_unix entry)
        in
        max 0 (total - body_h)

let memory_diagram_max_scroll (m : Model.t) =
  match
    Memory_diagram.active_diagram m, Memory_diagram.active_memory_content_rect m
  with
  | Some d, Some (_, content_rect) ->
      let body_rect, _ = Memory_diagram.diagram_body_rect ~content_rect d in
      if Rect.is_empty body_rect then 0
      else
        let total =
          match Observed.to_option d.payload with
          | Some (Knowledge_store.Diagram_text { lines; _ }) ->
              List.length lines
          | Some (Knowledge_store.Diagram_pele_png { fallback_lines; _ }) ->
              if Memory_diagram.can_render_png_in_rect ~content_rect d then 0
              else List.length fallback_lines
          | None -> 0
        in
        max 0 (total - body_rect.h)
  | (Some _ | None), (Some _ | None) -> 0

let dive_max_scroll (m : Model.t) active =
  let bp = ui_bp m in
  let br = ui_body_rect m in
  let theme = Theme.of_preset m.theme_preset in
  match active with
  | Nav.Dive_keeper { name; tab } ->
      keeper_tab_max_scroll ~embedded:false m ~name ~tab
  | Nav.Dive_knowledge (Nav.Memory_diff_dive { keeper; from_rev; to_rev }) ->
      let k_scoped =
        {
          (Knowledge_store.scope_memory_diff_dive ~keeper ~from_rev ~to_rev
             m.knowledge)
          with
          memory_subview = Knowledge_store.Mem_diff_flow;
          memory_view_mode = Knowledge_store.View_diff;
        }
      in
      memory_right_pane_max_scroll ~bp ~rect:br k_scoped
  | Nav.Dive_knowledge (Nav.Thread_dive post_id) -> (
      let post_opt, comments =
        match Observed.to_option m.knowledge.active_thread with
        | Some (tp, cs) when String.equal tp.id post_id -> (Some tp, cs)
        | active_opt -> (
            let all_posts =
              match Observed.to_option m.knowledge.board with
              | Some f -> f.posts
              | None -> []
            in
            match
              List.find_opt
                (fun (p : Wire_knowledge.board_post) ->
                  String.equal p.id post_id)
                all_posts
            with
            | Some p -> (Some p, [])
            | None -> (
                match active_opt with
                | Some (tp, cs) -> (Some tp, cs)
                | None -> (None, [])))
      in
      match post_opt with
      | None -> 0
      | Some p ->
          let body_rect =
            match
              Masc_tui_ui.Layout.split_v br
                [ Masc_tui_ui.Layout.Fixed 1; Masc_tui_ui.Layout.Flex 1 ]
            with
            | [ _; b ] -> b
            | _ -> br
          in
          let inner = ui_card_inner body_rect in
          let band_h = if inner.h >= 7 then 2 else 1 in
          let content =
            Rect.make ~x:inner.x ~y:(inner.y + band_h) ~w:inner.w
              ~h:(max 0 (inner.h - band_h))
            |> ui_pad_content ~bp
          in
          let comments_h =
            if comments = [] then 0
            else min (max 3 (content.h / 3)) (2 + (List.length comments * 2))
          in
          let body_h = max 0 (content.h - comments_h) in
          let body_max =
            markdown_max_scroll ~theme ~width:content.w ~height:body_h p.body
          in
          let comments_body_h = max 0 (comments_h - 1) in
          let comments_max =
            if comments_body_h > 0 then
              max 0 ((List.length comments * 2) - comments_body_h)
            else 0
          in
          body_max + comments_max)
  | Nav.Dive_knowledge (Nav.Wiki_dive slug) ->
      let main_rect, _ =
        Masc_tui_ui.Layout.adaptive_split_2 ~stack_on_compact:true
          ~left_ratio:0.66 ~top_ratio:0.68 bp br
      in
      wiki_preview_max_scroll ~bp ~theme ~rect:main_rect
        ~target_slug:(Some slug) m.knowledge
  | Nav.Dive_knowledge (Nav.Artifact_dive target) ->
      let inner = ui_card_inner br in
      let band_h = if inner.h >= 7 then 2 else 1 in
      let content =
        Rect.make ~x:inner.x ~y:(inner.y + band_h) ~w:inner.w
          ~h:(max 0 (inner.h - band_h))
        |> ui_pad_content ~bp
      in
      let fixed_hdr =
        if not (String.equal (String.trim m.knowledge.artifact_search_query) "")
        then 3
        else 2
      in
      let doc_h = max 1 (content.h - fixed_hdr) in
      let art_opt =
        Knowledge_store.find_artifact_by_id_or_sha target m.knowledge
      in
      let total_rows =
        match art_opt with
        | None -> 0
        | Some a ->
            let detail_opt =
              Knowledge_store.artifact_detail_for_entry a m.knowledge
            in
            let raw_body =
              match detail_opt with
              | Some d -> d.content
              | None -> ""
            in
            let fmt = Wire_knowledge.artifact_format_of_entry a in
            let body_rows =
              if String.equal (String.trim raw_body) "" then 0
              else
                match (m.knowledge.artifact_view_mode, fmt) with
                | `Raw_source, (`Html | `Markdown) ->
                    List.length (String.split_on_char '\n' raw_body)
                | `Document, `Html ->
                    List.length
                      (Masc_tui_ui.Html_doc.render_lines
                         ~width:(max 1 content.w) ~theme ~lang:m.lang raw_body)
                | `Document, `Markdown ->
                    let is_json =
                      String.starts_with ~prefix:"application/json"
                        (String.lowercase_ascii (String.trim a.body.mime))
                      || Filename.check_suffix
                           (String.lowercase_ascii (String.trim a.title))
                           ".json"
                    in
                    if is_json then
                      match Yojson.Safe.from_string raw_body with
                      | json ->
                          List.length
                            (String.split_on_char '\n'
                               (Yojson.Safe.pretty_to_string json))
                      | exception Yojson.Json_error _ ->
                          List.length (String.split_on_char '\n' raw_body)
                    else
                      List.length
                        (Masc_tui_ui.Markdown.render_lines
                           ~width:(max 1 content.w) ~theme raw_body)
            in
            let rev_rows =
              match detail_opt with
              | Some d when d.revisions <> [] -> 1 + List.length d.revisions
              | Some _ | None -> (
                  match Observed.to_option m.knowledge.artifacts with
                  | Some items when List.length items > 1 ->
                      1 + List.length items
                  | Some _ | None -> 0)
            in
            if rev_rows = 0 then body_rows
            else if body_rows = 0 then rev_rows
            else body_rows + 1 + rev_rows
      in
      max 0 (total_rows - doc_h)
  | Nav.Dive_runtime (Nav.Tool_dive tool_name) -> (
      let entry_opt =
        match Observed.to_option m.runtime.tools_dashboard with
        | Some d ->
            List.find_opt
              (fun (e : Wire_runtime.tool_catalog_entry) ->
                String.equal e.name tool_name)
              d.entries
        | None -> None
      in
      match entry_opt with
      | None -> 0
      | Some e -> (
          let top_h = if br.h >= 20 then 9 else 6 in
          let meta_rect =
            match
              Masc_tui_ui.Layout.split_v_bp bp br
                [ Masc_tui_ui.Layout.Fixed top_h; Masc_tui_ui.Layout.Flex 1 ]
            with
            | a :: _ -> a
            | [] -> br
          in
          let mc = ui_card_inner meta_rect |> ui_pad_content ~bp in
          let hdr_rows = 1 + if e.doc_refs <> [] then 1 else 0 in
          let md_h = max 0 (mc.h - hdr_rows) in
          match e.description with
          | Some desc when md_h > 0 && mc.w > 0 ->
              markdown_max_scroll ~theme ~width:mc.w ~height:md_h desc
          | Some _ | None -> 0))
  | Nav.Dive_runtime (Nav.Fusion_dive run_id) ->
      let content = ui_card_inner br |> ui_pad_content ~bp in
      if Rect.is_empty content then 0
      else
        let total =
          List.length (fusion_detail_lines ~width:content.w m ~run_id)
        in
        max 0 (total - max 1 content.h)
  | Nav.Dive_work (Nav.Goal_dive goal_id) -> (
      match
        List.find_opt
          (fun (g : Wire_work.goal) -> String.equal g.id goal_id)
          (Work_store.goals m.work)
      with
      | None -> 0
      | Some g ->
          let main_card_rect, json_card_rect =
            split_dive_with_json_store ~bp ~show_raw_json:m.infra.show_raw_json
              br
          in
          let main_max =
            let inner = ui_card_inner main_card_rect in
            if Rect.is_empty inner then 0
            else
              let y = ref inner.y in
              let bot = Rect.bottom inner in
              if inner.h >= 8 then begin
                let has_sub =
                  match g.last_review_note with
                  | Some n when not (String.equal (String.trim n) "") -> true
                  | Some _ | None -> Option.is_some g.criterion_revision
                in
                let band_h = if has_sub then 2 else 1 in
                y := !y + band_h + if inner.h >= 14 then 1 else 0
              end;
              let content = ops_pad_content inner in
              let action_h = if bot - !y >= 6 then 1 else 0 in
              let body_bot = bot - action_h in
              if !y < body_bot then begin
                let step_h =
                  match g.phase with
                  | Wire_work.Paused _ | Wire_work.Blocked _
                    when min 2 (body_bot - !y) >= 2 ->
                      2
                  | Wire_work.Executing
                  | Wire_work.Verifying
                  | Wire_work.Awaiting_confirmation
                  | Wire_work.Paused _
                  | Wire_work.Blocked _
                  | Wire_work.Completed
                  | Wire_work.Dropped ->
                      1
                in
                y := !y + step_h
              end;
              let linked =
                List.filter
                  (fun (tk : Wire_work.task) ->
                    match tk.goal_link with
                    | Wire_work.Linked gid -> String.equal gid g.id
                    | Wire_work.Unlinked -> false)
                  (Work_store.tasks m.work)
              in
              let linked_ids =
                List.map (fun (tk : Wire_work.task) -> tk.id) linked
              in
              let verifs =
                List.filter
                  (fun (v : Wire_work.verification_request) ->
                    List.exists (String.equal v.task_id) linked_ids)
                  (Work_store.verifications_list m.work)
              in
              let rem_h = max 0 (body_bot - !y) in
              let md_h =
                if rem_h <= 0 then 0
                else
                  min 7
                    (min rem_h (if rem_h >= 2 then max 2 (rem_h / 3) else rem_h))
              in
              let md_max =
                if md_h > 0 then begin
                  let md_src =
                    Printf.sprintf "**%s:** %s\n\n**%s:** %s"
                      (Say.resolve m.lang
                         (Say.make ~ko:"성공 조건" ~en:"Measure"))
                      (Chat_transcript.rewrite_masc_links_for_markdown g.measure)
                      (Say.resolve m.lang
                         (Say.make ~ko:"측정 절차" ~en:"Procedure"))
                      (Chat_transcript.rewrite_masc_links_for_markdown
                         g.procedure)
                  in
                  y := !y + md_h;
                  markdown_max_scroll ~theme ~width:content.w ~height:md_h md_src
                end
                else 0
              in
              let rest_rect =
                Rect.make ~x:content.x ~y:!y ~w:content.w
                  ~h:(max 0 (body_bot - !y))
              in
              if Rect.is_empty rest_rect then md_max
              else
                let tasks_r, verif_r =
                  match
                    Masc_tui_ui.Layout.split_v ~gap:0 rest_rect
                      [ Masc_tui_ui.Layout.Ratio 0.42; Masc_tui_ui.Layout.Flex 1 ]
                  with
                  | [ t; b ] -> (t, b)
                  | _ -> (rest_rect, Rect.empty)
                in
                let t_body_h = max 1 (max 0 (tasks_r.h - 1)) in
                let linked_max = max 0 (List.length linked - t_body_h) in
                let chk_max, diff_max =
                  if Rect.is_empty verif_r then (0, 0)
                  else
                    let v_body =
                      Rect.make ~x:verif_r.x ~y:(verif_r.y + 1) ~w:verif_r.w
                        ~h:(max 0 (verif_r.h - 1))
                    in
                    match verifs with
                    | [] -> (0, 0)
                    | v :: _ ->
                        let check_r, diff_r =
                          match
                            Masc_tui_ui.Layout.split_v ~gap:0 v_body
                              [
                                Masc_tui_ui.Layout.Ratio 0.45;
                                Masc_tui_ui.Layout.Flex 1;
                              ]
                          with
                          | [ a; b ] -> (a, b)
                          | _ -> (v_body, Rect.empty)
                        in
                        let cm =
                          if Rect.is_empty check_r then 0
                          else
                            max 0
                              (evidence_checklist_row_count v
                              - max 1 check_r.h)
                        in
                        let dm =
                          if Rect.is_empty diff_r then 0
                          else
                            max 0
                              (rejection_diff_row_count ~lang:m.lang v
                              - diff_r.h)
                        in
                        (cm, dm)
                in
                max (max md_max linked_max) (max chk_max diff_max)
          in
          let json_max =
            if Rect.is_empty json_card_rect then 0
            else
              json_card_max_scroll ~max_depth:4 json_card_rect
                (json_of_goal_store g)
          in
          max main_max json_max)
  | Nav.Dive_work (Nav.Task_dive task_id) -> (
      match
        List.find_opt
          (fun (tk : Wire_work.task) -> String.equal tk.id task_id)
          (Work_store.tasks m.work)
      with
      | None -> 0
      | Some tk ->
          let main_card_rect, json_card_rect =
            split_dive_with_json_store ~bp ~show_raw_json:m.infra.show_raw_json
              br
          in
          let main_max =
            let inner = ui_card_inner main_card_rect in
            if Rect.is_empty inner then 0
            else
              let content = ops_pad_content inner in
              let y = ref inner.y in
              let bot = Rect.bottom inner in
              if inner.h >= 8 then begin
                let has_who =
                  match tk.status with
                  | Wire_work.Todo -> false
                  | Wire_work.Claimed _
                  | Wire_work.InProgress _
                  | Wire_work.AwaitingVerification _
                  | Wire_work.Done _
                  | Wire_work.Cancelled _ ->
                      true
                in
                let band_h = if has_who then 2 else 1 in
                y := !y + band_h + if inner.h >= 14 then 1 else 0
              end;
              let action_h = if bot - !y >= 6 then 1 else 0 in
              let body_bot = bot - action_h in
              (* stepper + assignee + started_at + goal_link = 4 rows *)
              y := min body_bot (!y + 4);
              let v_opt =
                List.find_opt
                  (fun (v : Wire_work.verification_request) ->
                    String.equal v.task_id tk.id)
                  (Work_store.verifications_list m.work)
              in
              let rest_h = max 0 (body_bot - !y) in
              let desc_h =
                if rest_h <= 0 then 0
                else
                  match tk.description, v_opt with
                  | Some _, Some _ -> min rest_h (max 1 (rest_h / 2))
                  | Some _, None -> rest_h
                  | None, _ -> 0
              in
              let md_max =
                match tk.description with
                | Some d when desc_h > 0 ->
                    if desc_h >= 3 then incr y;
                    let actual_h = max 0 (min desc_h (body_bot - !y)) in
                    y := !y + actual_h;
                    markdown_max_scroll ~theme ~width:content.w ~height:actual_h
                      (Chat_transcript.rewrite_masc_links_for_markdown d)
                | Some _ | None -> 0
              in
              let chk_max, diff_max =
                match v_opt with
                | Some v when !y < body_bot ->
                    incr y;
                    let vr =
                      Rect.make ~x:content.x ~y:!y ~w:content.w
                        ~h:(max 0 (body_bot - !y))
                    in
                    let chk_r, diff_r =
                      match
                        Masc_tui_ui.Layout.split_v ~gap:0 vr
                          [
                            Masc_tui_ui.Layout.Ratio 0.45;
                            Masc_tui_ui.Layout.Flex 1;
                          ]
                      with
                      | [ a; b ] -> (a, b)
                      | _ -> (vr, Rect.empty)
                    in
                    let cm =
                      if Rect.is_empty chk_r then 0
                      else
                        max 0 (evidence_checklist_row_count v - max 1 chk_r.h)
                    in
                    let dm =
                      if Rect.is_empty diff_r then 0
                      else
                        max 0
                          (rejection_diff_row_count ~lang:m.lang v - diff_r.h)
                    in
                    (cm, dm)
                | Some _ | None -> (0, 0)
              in
              max md_max (max chk_max diff_max)
          in
          let json_max =
            if Rect.is_empty json_card_rect then 0
            else
              json_card_max_scroll ~max_depth:4 json_card_rect
                (json_of_task_store tk)
          in
          max main_max json_max)
  | Nav.Dive_work (Nav.Verification_dive req_id) -> (
      match
        List.find_opt
          (fun (v : Wire_work.verification_request) ->
            String.equal v.request_id req_id)
          (Work_store.verifications_list m.work)
      with
      | None -> 0
      | Some v ->
          let main_card_rect, json_card_rect =
            split_dive_with_json_store ~bp ~show_raw_json:m.infra.show_raw_json
              br
          in
          let main_max =
            let inner = ui_card_inner main_card_rect in
            if Rect.is_empty inner then 0
            else
              let content = ops_pad_content inner in
              let y = ref inner.y in
              let bot = Rect.bottom inner in
              if inner.h >= 8 then y := !y + 2 + if inner.h >= 14 then 1 else 0;
              let action_h = if bot - !y >= 6 then 1 else 0 in
              let body_bot = bot - action_h in
              let kv_rows =
                3 + if Option.is_some v.review_observation then 1 else 0
              in
              y := min body_bot (!y + kv_rows);
              let rest =
                Rect.make ~x:content.x ~y:!y ~w:content.w
                  ~h:(max 0 (body_bot - !y))
              in
              let tab_lines = verification_dive_tab_lines ~width:content.w m v in
              let tab_max = max 0 (List.length tab_lines - max 1 rest.h) in
              match m.work.verification_dive_tab with
              | Work_store.Verif_tab_summary
              | Work_store.Verif_tab_specs
              | Work_store.Verif_tab_tlc ->
                  tab_max
              | Work_store.Verif_tab_evidence ->
                  let chk_r, diff_r =
                    match
                      Masc_tui_ui.Layout.split_v ~gap:0 rest
                        [ Masc_tui_ui.Layout.Ratio 0.56; Masc_tui_ui.Layout.Flex 1 ]
                    with
                    | [ a; b ] -> (a, b)
                    | _ -> (rest, Rect.empty)
                  in
                  let ev_max =
                    if Rect.is_empty chk_r then 0
                    else
                      let ev_h = max 1 (chk_r.h - 1) in
                      max 0 (List.length tab_lines - ev_h)
                  in
                  let diff_max =
                    if Rect.is_empty diff_r then 0
                    else
                      let dr_h = max 0 (diff_r.h - 1) in
                      if dr_h <= 0 then 0
                      else max 0 (rejection_diff_row_count ~lang:m.lang v - dr_h)
                  in
                  max ev_max diff_max
          in
          let json_max =
            if Rect.is_empty json_card_rect then 0
            else
              json_card_max_scroll ~max_depth:4 json_card_rect
                (json_of_verification_store v)
          in
          max main_max json_max)
  | Nav.Dive_infra (Nav.Sandbox_dive keeper) -> (
      let inner = ui_card_inner br in
      if Rect.is_empty inner then 0
      else
        match
          sandbox_entry_info_for_keeper ~use_keeper_detail:true ~keeper m.infra
        with
        | None -> 0
        | Some info ->
            if m.infra.show_raw_json then
              let content = ui_pad_content ~bp inner in
              if Rect.is_empty content then 0
              else
                let lines =
                  Masc_tui_ui.Json_tree.flatten ~max_depth:5
                    ~redact_secrets:true info.json
                in
                max 0 (List.length lines - content.h)
            else
              let body_rect =
                match
                  Masc_tui_ui.Layout.split_v inner
                    [ Masc_tui_ui.Layout.Fixed 3; Masc_tui_ui.Layout.Flex 1 ]
                with
                | [ _; b ] -> b
                | _ -> Rect.empty
              in
              if Rect.is_empty body_rect then 0
              else
                let rem_rows =
                  sandbox_inspector_rem_rows ~inner_h:body_rect.h info
                in
                if rem_rows <= 0 then 0
                else
                  max 0
                    (Infra_store.sandbox_inspector_event_count ~keeper m.infra
                    - rem_rows))
  | Nav.Dive_infra (Nav.Lane_dive lane_id) ->
      let inner = ui_card_inner br in
      let content = ui_pad_content ~bp inner in
      if m.infra.show_raw_json then
        let slot_n =
          match Observed.to_option m.runtime.runtime_resolved with
          | Some snap -> (
              match
                List.find_opt
                  (fun (l : Wire_runtime.failover_lane) ->
                    String.equal l.id lane_id)
                  snap.lanes
              with
              | Some l -> List.length l.runtime_ids
              | None -> 0)
          | None -> 0
        in
        max 0 (4 + slot_n - max 1 content.h)
      else
        let tail_h =
          match
            Masc_tui_ui.Layout.split_v content
              [
                Masc_tui_ui.Layout.Fixed 2;
                Masc_tui_ui.Layout.Ratio 0.54;
                Masc_tui_ui.Layout.Flex 1;
              ]
          with
          | [ _; _; t ] -> max 1 (t.h - 1)
          | _ -> max 1 (content.h / 3)
        in
        max 0 (List.length m.infra.logs - tail_h)
  | Nav.Dive_infra (Nav.Incident_dive incident_id) -> (
      match Incidents.find_by_id incident_id m.incidents with
      | None -> 0
      | Some inc ->
          let inner = ui_card_inner br in
          if m.infra.show_raw_json then
            let detail_lines =
              match extract_embedded_json_store inc.detail with
              | Some (_, json) ->
                  List.length
                    (Masc_tui_ui.Json_tree.flatten ~max_depth:5
                       ~redact_secrets:true json)
              | None -> 1
            in
            max 0 (6 + detail_lines - max 1 inner.h)
          else
            let band_h = if inner.h >= 6 then 2 else 1 in
            let content =
              Rect.make ~x:inner.x ~y:(inner.y + band_h) ~w:inner.w
                ~h:(max 0 (inner.h - band_h))
              |> ui_pad_content ~bp
            in
            let detail_h = max 1 (content.h / 2) in
            let detail_max =
              match extract_embedded_json_store inc.detail with
              | Some (prefix, parsed_json) ->
                  let used = if String.equal prefix "" then 0 else 1 in
                  let tree_h = max 1 (detail_h - used) in
                  let lines =
                    Masc_tui_ui.Json_tree.flatten ~max_depth:4
                      ~redact_secrets:true parsed_json
                  in
                  max 0 (List.length lines - tree_h)
              | None ->
                  markdown_max_scroll ~theme ~width:content.w ~height:detail_h
                    inc.detail
            in
            let filter_opt =
              match inc.source with
              | Health.Source_keeper k -> Some k
              | Health.Source_sandbox s -> Some s
              | Health.Source_runtime _
              | Health.Source_client_http
              | Health.Source_stream ->
                  None
            in
            let filtered_logs =
              match filter_opt with
              | None -> m.infra.logs
              | Some kp ->
                  List.filter
                    (fun (e : Wire_infra.system_log_entry) ->
                      Option.equal String.equal e.keeper (Some kp)
                      || String.equal e.module_name kp)
                    m.infra.logs
            in
            let log_h = max 1 (content.h - detail_h - 1) in
            let log_max = max 0 (List.length filtered_logs - log_h) in
            detail_max + log_max)
  | Nav.Dive_infra (Nav.Runtime_trace_dive keeper) -> (
      match Infra_store.runtime_trace_for ~keeper m.infra with
      | None -> 0
      | Some tr ->
          let content = ui_card_inner br |> ui_pad_content ~bp in
          if Rect.is_empty content then 0
          else
            let tree_h = max 1 (content.h - 3) in
            let lines =
              Masc_tui_ui.Json_tree.flatten ~max_depth:4 ~redact_secrets:true
                tr.raw
            in
            max 0 (List.length lines - tree_h))
  | Nav.Dive_infra (Nav.Log_detail_dive seq) -> (
      match Infra_store.find_log_by_seq seq m.infra with
      | None -> 0
      | Some e ->
          let content = ui_card_inner br |> ui_pad_content ~bp in
          if Rect.is_empty content then 0
          else
            let msg_lines =
              wrap_lines ~width:(max 1 (content.w - 2)) e.message
            in
            let jlines =
              Masc_tui_ui.Json_tree.flatten ~max_depth:5 ~redact_secrets:true
                e.details
            in
            let body_h = max 1 (content.h - 1) in
            let total = List.length msg_lines + 1 + List.length jlines in
            max 0 (total - body_h))

let move_keeper_config_selection ~embedded ~name ~delta (m : Model.t) =
  let _, content_h =
    Chat_transcript.keeper_content_rect_size ~embedded ~model:m
  in
  let viewport_rows = max 1 (content_h - 4) in
  let fallback_count =
    if Option.is_some (Fleet_store.find_keeper ~name m.fleet) then 5 else 0
  in
  let config =
    Config_store.move_keeper_selection ~viewport_rows ~lang:m.lang
      ~fallback_count ~delta m.config
  in
  ({ m with nav = { m.nav with dive_scroll_offset = 0 }; config }, [])

let clamp_for_pane (m : Model.t) =
  let pane_count = Model.focusable_pane_count m in
  let clamped_pane =
    if pane_count <= 1 then 0
    else Int.max 0 (Int.min (pane_count - 1) m.nav.pane_index)
  in
  let m =
    if Int.equal clamped_pane m.nav.pane_index then m
    else { m with nav = { m.nav with pane_index = clamped_pane } }
  in
  let viewport_rows = estimated_viewport_rows m in
  let pane_index = m.nav.pane_index in
  match m.nav.overlay with
  | Some _ -> m
  | None -> (
      match Model.active_dive m with
      | Some _ -> m
      | None -> (
          match m.nav.workspace with
          | Nav.Work ->
              let max_detail_scroll = work_detail_max_scroll m in
              {
                m with
                work =
                  Work_store.move_selection ~pane_index
                    ~has_linked_card:(Model.work_pipeline_has_linked_card m)
                    ~viewport_rows ~max_detail_scroll ~delta:0 m.work;
              }
          | Nav.Runtime ->
              let rt = sync_runtime_companies_if_needed m in
              let max_detail_scroll = runtime_detail_max_scroll m in
              {
                m with
                runtime =
                  Runtime_store.move_selection ~pane_index ~viewport_rows
                    ~max_detail_scroll ~delta:0 rt;
              }
          | Nav.Knowledge ->
              let max_detail_scroll = knowledge_detail_max_scroll m in
              {
                m with
                knowledge =
                  Knowledge_store.move_selection ~pane_index ~viewport_rows
                    ~max_detail_scroll ~delta:0 m.knowledge;
              }
          | Nav.Infra ->
              let max_detail_scroll = infra_detail_max_scroll m in
              {
                m with
                infra =
                  Infra_store.move_selection ~pane_index ~viewport_rows
                    ~max_detail_scroll ~delta:0 m.infra;
              }
          | Nav.Pulse | Nav.Keepers -> m))

let apply_move (m : Model.t) dir =
  let allow_in_filter =
    match dir with
    | Keymap.Up | Keymap.Down | Keymap.Page_up | Keymap.Page_down -> true
    | Keymap.Left | Keymap.Right | Keymap.Home | Keymap.End -> false
  in
  if m.nav.filter_focused && not allow_in_filter then (m, [])
  else if Option.is_none m.nav.overlay && Drafts.is_focused m.drafts then
    let drafts =
      match dir with
      | Keymap.Left -> Drafts.move_cursor `Left m.drafts
      | Keymap.Right -> Drafts.move_cursor `Right m.drafts
      | Keymap.Home -> Drafts.move_cursor `Home m.drafts
      | Keymap.End -> Drafts.move_cursor `End m.drafts
      | Keymap.Up | Keymap.Down | Keymap.Page_up | Keymap.Page_down -> m.drafts
    in
    ({ m with drafts }, [])
  else
    let viewport_rows = estimated_viewport_rows m in
    match m.nav.overlay with
    | Some Nav.Palette ->
        let delta = move_delta dir in
        let len = palette_len m in
        let selected = clamp_index len (m.palette.selected + delta) in
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
    | Some (Nav.Settings _) ->
        let two_pane = Config_store.is_two_pane_width ~cols:m.viewport.cols in
        let cfg0 =
          if not two_pane then
            Config_store.set_pane Config_store.Pane_inspector m.config
          else m.config
        in
        let config =
          match dir with
          | Keymap.Left ->
              if not two_pane then cfg0
              else Config_store.collapse_or_leave cfg0
          | Keymap.Right ->
              if not two_pane then cfg0
              else Config_store.expand_or_enter cfg0
          | Keymap.Up | Keymap.Down | Keymap.Page_up | Keymap.Page_down
          | Keymap.Home | Keymap.End ->
              let delta = move_delta dir in
              Config_store.move_selection ~viewport_rows ~delta cfg0
        in
        let nav = { m.nav with overlay = Some (Nav.Settings config.active_tab) } in
        ({ m with nav; config }, [])
    | Some Nav.Incidents ->
        let delta = move_delta dir in
        ( {
            m with
            incidents =
              Incidents.move_selection ~viewport_rows ~delta m.incidents;
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
                  | Nav.Schedule_form
                  | Nav.Connector_form
                  | Nav.Repo_add_form
                  | Nav.Board_new_post
                  | Nav.Board_comment _
                  | Nav.Github_token_form _
                  | Nav.Code_finder_form
                  | Nav.Code_search_form )
                , _ ) ->
                  true
            in
            if not editable then
              match modal.kind with
              | Nav.Btw_query ->
                  let delta = scroll_delta dir in
                  let max_scroll = btw_max_scroll m in
                  let btw_scroll_offset =
                    Store_scroll.clamp_scroll ~max_scroll
                      (m.nav.btw_scroll_offset + delta)
                  in
                  ({ m with nav = { m.nav with btw_scroll_offset } }, [])
              | Nav.Gate_reject _
              | Nav.Verification_reject _
              | Nav.Harness_overrule _
              | Nav.Task_cancel _
              | Nav.Schedule_form
              | Nav.Connector_form
              | Nav.Repo_add_form
              | Nav.Board_new_post
              | Nav.Board_comment _
              | Nav.Github_token_form _
              | Nav.Code_finder_form
              | Nav.Code_search_form ->
                  (m, [])
            else
              let next_modal =
                match dir with
                | Keymap.Up -> Model.modal_cycle_field ~delta:(-1) modal
                | Keymap.Down -> Model.modal_cycle_field ~delta:1 modal
                | Keymap.Left
                | Keymap.Right
                | Keymap.Home
                | Keymap.End
                | Keymap.Page_up
                | Keymap.Page_down ->
                    modal
              in
              let modal_edit_cursor =
                match dir with
                | Keymap.Up | Keymap.Down ->
                    String.length (Model.modal_active_field_value next_modal)
                | Keymap.Left
                | Keymap.Right
                | Keymap.Home
                | Keymap.End
                | Keymap.Page_up
                | Keymap.Page_down ->
                    m.nav.modal_edit_cursor
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
            let next_modal =
              if modal.editing_free_text then
                match dir with
                | Keymap.Left -> Model.ask_modal_move_free_text_cursor `Left modal
                | Keymap.Right ->
                    Model.ask_modal_move_free_text_cursor `Right modal
                | Keymap.Home -> Model.ask_modal_move_free_text_cursor `Home modal
                | Keymap.End -> Model.ask_modal_move_free_text_cursor `End modal
                | Keymap.Up | Keymap.Down | Keymap.Page_up | Keymap.Page_down ->
                    modal
              else
                match dir with
                | Keymap.Up -> Model.ask_modal_move_cursor ~delta:(-1) modal
                | Keymap.Down -> Model.ask_modal_move_cursor ~delta:1 modal
                | Keymap.Page_up -> Model.ask_modal_move_cursor ~delta:(-5) modal
                | Keymap.Page_down -> Model.ask_modal_move_cursor ~delta:5 modal
                | Keymap.Home -> Model.ask_modal_set_cursor 0 modal
                | Keymap.End -> Model.ask_modal_set_cursor 100000 modal
                | Keymap.Left | Keymap.Right -> modal
            in
            ({ m with ask_modal = Some next_modal }, []))
    | Some (Nav.Queue_context tab) -> (
        match dir with
        | Keymap.Left | Keymap.Right -> (m, [])
        | Keymap.Up | Keymap.Down | Keymap.Page_up | Keymap.Page_down
        | Keymap.Home | Keymap.End ->
            let delta = scroll_delta dir in
            let max_scroll = queue_context_max_scroll m tab in
            let queue_scroll_offset =
              Store_scroll.clamp_scroll ~max_scroll
                (m.nav.queue_scroll_offset + delta)
            in
            ({ m with nav = { m.nav with queue_scroll_offset } }, []))
    | Some Nav.Help ->
        let delta = scroll_delta dir in
        let max_scroll = help_max_scroll m in
        let help_scroll_offset =
          Store_scroll.clamp_scroll ~max_scroll
            (m.nav.help_scroll_offset + delta)
        in
        ({ m with nav = { m.nav with help_scroll_offset } }, [])
    | Some (Nav.System_gate Nav.Media_viewer) -> (
        match dir with
        | Keymap.Left | Keymap.Right -> (m, [])
        | Keymap.Up | Keymap.Down | Keymap.Page_up | Keymap.Page_down
        | Keymap.Home | Keymap.End ->
            let delta = scroll_delta dir in
            let max_scroll =
              let w = min (max 0 (m.viewport.cols - 4)) 78 in
              let h = min (max 0 (m.viewport.rows - 2)) 15 in
              if w < 2 || h < 2 then 0
              else
                let inner_w = max 0 (w - 2) in
                let inner_h = max 0 (h - 2) in
                let pad_x = if inner_w >= 48 then 2 else 1 in
                let content_w = max 1 (inner_w - (2 * pad_x)) in
                let content_h = inner_h in
                let body_h = max 0 (content_h - 3) in
                if body_h <= 0 then 0
                else
                  let total_lines =
                    match Model.focused_artifact m with
                    | None -> 0
                    | Some art -> (
                        let detail_opt =
                          Knowledge_store.artifact_detail_for_entry art
                            m.knowledge
                        in
                        let raw_body =
                          match detail_opt with
                          | Some d -> d.content
                          | None -> ""
                        in
                        if String.equal (String.trim raw_body) "" then 0
                        else
                          let theme = Theme.of_preset m.theme_preset in
                          match
                            ( m.knowledge.artifact_view_mode
                            , Wire_knowledge.artifact_format_of_entry art )
                          with
                          | `Document, `Html ->
                              List.length
                                (Masc_tui_ui.Html_doc.render_lines ~theme
                                   ~width:content_w ~lang:m.lang raw_body)
                          | `Document, `Markdown ->
                              let is_json = Knowledge_store.is_json_artifact art in
                              if is_json then
                                let pretty =
                                  match Yojson.Safe.from_string raw_body with
                                  | j -> Yojson.Safe.pretty_to_string j
                                  | exception Yojson.Json_error _ -> raw_body
                                in
                                List.length (String.split_on_char '\n' pretty)
                              else
                                List.length
                                  (Masc_tui_ui.Markdown.render_lines ~theme
                                     ~width:content_w raw_body)
                          | `Raw_source, (`Html | `Markdown) ->
                              List.length (String.split_on_char '\n' raw_body))
                  in
                  max 0 (total_lines - body_h)
            in
            let detail_scroll_offset =
              Store_scroll.clamp_scroll ~max_scroll
                (m.knowledge.detail_scroll_offset + delta)
            in
            ( { m with knowledge = { m.knowledge with detail_scroll_offset } }
            , [] ))
    | Some
        (Nav.System_gate
          (Nav.Auth_gate | Nav.Server_offline | Nav.Micro_viewport)) ->
        (m, [])
    | None ->
        if Model.sidebar_has_focus m then
          match dir with
          | Keymap.Up | Keymap.Down | Keymap.Page_up | Keymap.Page_down
          | Keymap.Home | Keymap.End ->
              move_sidebar m dir
          | Keymap.Right -> (
              match Nav.menu_item_of_index m.nav.sidebar_cursor with
              | Some it
                when (not (Nav.is_overlay_menu_target it.target))
                     && not
                          (Nav.equal_menu_target it.target
                             (Model.active_menu_target m)) ->
                  activate_sidebar_cursor m
              | Some it ->
                  let base = exit_sidebar_focus m in
                  let target_pane =
                    match it.target with
                    | Nav.Menu_keeper_tab _
                      when Option.is_none (Model.active_dive base)
                           && (not base.nav.zoomed)
                           && Model.focusable_pane_count base >= 2 ->
                        1
                    | Nav.Menu_keeper_tab _
                    | Nav.Menu_pulse
                    | Nav.Menu_work _
                    | Nav.Menu_knowledge _
                    | Nav.Menu_keepers
                    | Nav.Menu_runtime _
                    | Nav.Menu_infra _
                    | Nav.Menu_settings
                    | Nav.Menu_incidents
                    | Nav.Menu_queue_context
                    | Nav.Menu_help ->
                        0
                  in
                  ( clamp_for_pane
                      { base with nav = { base.nav with pane_index = target_pane } }
                  , [] )
              | None ->
                  let base = exit_sidebar_focus m in
                  ( clamp_for_pane
                      { base with nav = { base.nav with pane_index = 0 } }
                  , [] ))
          | Keymap.Left -> (m, [])
        else (
        let step_spatial_pane next_pane =
          let next =
            clamp_for_pane
              { m with nav = { m.nav with pane_index = next_pane } }
            |> sync_config_for_keeper_view
          in
          let cmds =
            if
              not
                (Config_store.equal_config_target m.config.target
                   next.config.target)
            then View_fetches.fetches_for_current_view next
            else []
          in
          (next, cmds)
        in
        match dir with
        | Keymap.Left ->
            if m.nav.pane_index > 0 then
              step_spatial_pane (m.nav.pane_index - 1)
            else if Model.sidebar_visible m then (enter_sidebar_focus m, [])
            else (m, [])
        | Keymap.Right ->
            let n = Model.focusable_pane_count m in
            if m.nav.pane_index + 1 < n then
              step_spatial_pane (m.nav.pane_index + 1)
            else (m, [])
        | Keymap.Up | Keymap.Down | Keymap.Page_up | Keymap.Page_down
        | Keymap.Home | Keymap.End -> (
            let move_keeper_context ~embedded ~name =
              let ks =
                Keeper_context_store.get_keeper ~keeper:name m.keeper_context
              in
              let cw, ch =
                Chat_transcript.keeper_content_rect_size ~embedded ~model:m
              in
              let hdr_h = 2 + if ch >= 6 then 1 else 0 in
              let body_h = max 1 (ch - hdr_h) in
              let pad_x = if cw >= 88 then 2 else 1 in
              let inner_w = max 1 (cw - (2 * pad_x)) in
              let theme = Theme.of_preset m.theme_preset in
              let keeper_context =
                match ks.subtab with
                | Keeper_context_store.Ctx_exact_input ->
                    let scroll_part =
                      ((not embedded) && m.nav.pane_index = 1)
                      ||
                      match dir with
                      | Keymap.Page_up | Keymap.Page_down -> true
                      | Keymap.Up | Keymap.Down | Keymap.Left | Keymap.Right
                      | Keymap.Home | Keymap.End ->
                          false
                    in
                    if scroll_part then
                      let max_scroll =
                        match
                          Keeper_context_store.part_content_for_selected ks
                        with
                        | None -> 0
                        | Some pc ->
                            let cache_rows =
                              match
                                Keeper_context_store.cache_outcome_for_selected_turn
                                  ks
                              with
                              | Some _ when body_h > 2 -> 4
                              | Some _ | None -> 0
                            in
                            let parts_h = max 1 (body_h - cache_rows) in
                            let parts_r =
                              Rect.make ~x:0 ~y:0 ~w:inner_w ~h:parts_h
                            in
                            let right_r =
                              if parts_r.w >= 72 then
                                match
                                  Masc_tui_ui.Layout.split_h ~gap:2 parts_r
                                    [
                                      Masc_tui_ui.Layout.Ratio 0.44;
                                      Masc_tui_ui.Layout.Flex 1;
                                    ]
                                with
                                | [ _; r ] -> r
                                | _ -> parts_r
                              else
                                match
                                  Masc_tui_ui.Layout.split_v ~gap:1 parts_r
                                    [
                                      Masc_tui_ui.Layout.Ratio 0.48;
                                      Masc_tui_ui.Layout.Flex 1;
                                    ]
                                with
                                | [ _; b ] -> b
                                | _ -> parts_r
                            in
                            let text_h = max 1 (right_r.h - 1) in
                            markdown_max_scroll ~theme ~width:(max 1 right_r.w)
                              ~height:text_h pc.text
                      in
                      Keeper_context_store.move_scroll ~keeper:name ~max_scroll
                        ~delta:(scroll_delta dir) m.keeper_context
                    else
                      Keeper_context_store.move_part_selection ~keeper:name
                        ~delta:(move_delta dir) m.keeper_context
                | Keeper_context_store.Ctx_composition ->
                    let max_scroll =
                      match Keeper_context_store.selected_turn_entry ks with
                      | None -> 0
                      | Some entry ->
                          let r = entry.record in
                          let used = ref 0 in
                          if body_h > 1 then
                            used := !used + if body_h >= 14 then 2 else 1;
                          if !used < body_h then incr used;
                          (match Observed.to_option ks.turn_records with
                          | Some page
                            when List.length page.entries >= 2 && !used < body_h
                            ->
                              incr used
                          | Some _ | None -> ());
                          if Option.is_some r.model_input_window && !used < body_h
                          then incr used;
                          let has_comp =
                            match r.input_components with
                            | Some cs ->
                                List.exists
                                  (fun (c : Turn_record.input_component) ->
                                    c.bytes > 0)
                                  cs
                            | None ->
                                List.exists
                                  (fun (b : Turn_record.prompt_block) ->
                                    b.bytes > 0)
                                  r.blocks
                          in
                          if has_comp && !used + 1 < body_h then
                            used := !used + 2;
                          (match entry.diff_vs_prev with
                          | Some d
                            when (d.added <> [] || d.removed <> []
                                 || d.changed <> [])
                                 && !used < body_h ->
                              incr used
                          | Some _ | None -> ());
                          if !used + 1 < body_h then incr used;
                          let avail = max 1 (body_h - !used) in
                          let forecast_rows =
                            match ks.next_request with
                            | Observed.Value { data = fc; _ } ->
                                1
                                + List.fold_left
                                    (fun acc
                                         (c :
                                           Wire_keeper_context.forecast_candidate) ->
                                      let extra =
                                        match c.assembly with
                                        | Some (_ :: _) -> 1
                                        | Some [] | None -> 0
                                      in
                                      acc + 1 + extra)
                                    0 fc.candidates
                            | Observed.Loading _
                            | Observed.Absent
                            | Observed.Unreported
                            | Observed.Failed _ ->
                                1
                          in
                          max 0 (forecast_rows - avail)
                    in
                    Keeper_context_store.move_scroll ~keeper:name ~max_scroll
                      ~delta:(scroll_delta dir) m.keeper_context
                | Keeper_context_store.Ctx_input_map ->
                    let max_scroll =
                      match Keeper_context_store.selected_turn_entry ks with
                      | None -> 0
                      | Some entry ->
                          let r = entry.record in
                          let n_rows =
                            match r.input_components with
                            | Some cs when cs <> [] -> List.length cs
                            | Some _ | None -> List.length r.blocks
                          in
                          let vis = max 1 (body_h - 2) in
                          max 0 (n_rows - vis)
                    in
                    Keeper_context_store.move_scroll ~keeper:name ~max_scroll
                      ~delta:(scroll_delta dir) m.keeper_context
                | Keeper_context_store.Ctx_response ->
                    let max_scroll =
                      match Keeper_context_store.selected_turn_entry ks with
                      | None -> 0
                      | Some entry ->
                          let r = entry.record in
                          let wrap_w = max 12 (inner_w - 4) in
                          let tr_rows =
                            match
                              Keeper_context_store.transcript_for_selected_turn
                                ks
                            with
                            | Some tr when tr.found ->
                                let sum_lines xs =
                                  if xs = [] then 0
                                  else
                                    1
                                    + List.fold_left
                                        (fun acc
                                             (l :
                                               Wire_keeper_context.transcript_line) ->
                                          acc
                                          + List.length
                                              (Chat_transcript.wrap_plain_lines
                                                 ~width:wrap_w l.content))
                                        0 xs
                                in
                                sum_lines tr.user + sum_lines tr.assistant
                            | Some _ -> 1
                            | None -> (
                                match ks.turn_transcript with
                                | Observed.Loading _ | Observed.Failed _ -> 1
                                | Observed.Value _
                                | Observed.Absent
                                | Observed.Unreported ->
                                    0)
                          in
                          let ev_rows =
                            if r.execution_ids = [] then 0
                            else if ks.call_evidence_auth_denied then 2
                            else
                              let ev_tbl :
                                  ( string
                                  , Wire_keeper_context.tool_call_entry )
                                  Hashtbl.t =
                                Hashtbl.create 16
                              in
                              (match
                                 Keeper_context_store.call_evidence_for_selected_turn
                                   ks
                               with
                              | Some calls ->
                                  List.iter
                                    (fun (c :
                                           Wire_keeper_context.tool_call_entry) ->
                                      match c.execution_id with
                                      | Some eid -> Hashtbl.replace ev_tbl eid c
                                      | None -> ())
                                    calls
                              | None -> ());
                              1
                              + List.fold_left
                                  (fun acc eid_val ->
                                    let eid = Ids.Execution_id.to_string eid_val in
                                    match Hashtbl.find_opt ev_tbl eid with
                                    | Some c
                                      when not
                                             (String.equal (String.trim c.output)
                                                "") ->
                                        acc + 2
                                    | Some _ | None -> acc + 1)
                                  0 r.execution_ids
                          in
                          let total = 1 + tr_rows + ev_rows in
                          max 0 (total - body_h)
                    in
                    Keeper_context_store.move_scroll ~keeper:name ~max_scroll
                      ~delta:(scroll_delta dir) m.keeper_context
              in
              ({ m with keeper_context }, [])
            in
            let move_keeper_tool_calls ~embedded ~name =
              let ks =
                Keeper_context_store.get_keeper ~keeper:name m.keeper_context
              in
              let cw, ch =
                Chat_transcript.keeper_content_rect_size ~embedded ~model:m
              in
              let hdr_h = 1 + if ch >= 6 then 1 else 0 in
              let body_r = Rect.make ~x:0 ~y:0 ~w:cw ~h:(max 1 (ch - hdr_h)) in
              let left_r, right_r =
                if body_r.w >= 76 then
                  match
                    Masc_tui_ui.Layout.split_h ~gap:2 body_r
                      [
                        Masc_tui_ui.Layout.Ratio 0.50;
                        Masc_tui_ui.Layout.Flex 1;
                      ]
                  with
                  | [ l; r ] -> (l, r)
                  | _ -> (body_r, Rect.empty)
                else
                  match
                    Masc_tui_ui.Layout.split_v ~gap:1 body_r
                      [
                        Masc_tui_ui.Layout.Ratio 0.46;
                        Masc_tui_ui.Layout.Flex 1;
                      ]
                  with
                  | [ t; b ] -> (t, b)
                  | _ -> (body_r, Rect.empty)
              in
              let scroll_detail =
                ((not embedded) && m.nav.pane_index = 1)
                ||
                match dir with
                | Keymap.Page_up | Keymap.Page_down -> true
                | Keymap.Up | Keymap.Down | Keymap.Left | Keymap.Right
                | Keymap.Home | Keymap.End ->
                    false
              in
              let keeper_context =
                if scroll_detail then
                  let max_scroll =
                    match Keeper_context_store.selected_tool_call ks with
                    | None -> 0
                    | Some call ->
                        let output_json =
                          match
                            Keeper_context_store.tool_result_for_selected_call ks
                          with
                          | Some (Wire_keeper_context.Tool_result_page p) -> (
                              match Yojson.Safe.from_string p.content with
                              | j -> Wire_keeper_context.unfold_json_strings j
                              | exception Yojson.Json_error _ ->
                                  `String p.content)
                          | Some Wire_keeper_context.Tool_result_pending ->
                              `String "(tool result pending)"
                          | Some
                              (Wire_keeper_context.Tool_result_unavailable r) ->
                              `String ("(unavailable: " ^ r ^ ")")
                          | None -> (
                              match Yojson.Safe.from_string call.output with
                              | j -> Wire_keeper_context.unfold_json_strings j
                              | exception Yojson.Json_error _ ->
                                  `String call.output)
                        in
                        let unfolded_in =
                          Wire_keeper_context.unfold_json_strings call.input
                        in
                        let tree_json =
                          `Assoc
                            [ ("input", unfolded_in); ("output", output_json) ]
                        in
                        let lines =
                          Masc_tui_ui.Json_tree.flatten ~max_depth:5
                            ~redact_secrets:true tree_json
                        in
                        let tree_h = max 1 (right_r.h - 2) in
                        max 0 (List.length lines - tree_h)
                  in
                  Keeper_context_store.move_call_detail_scroll ~keeper:name
                    ~max_scroll ~delta:(scroll_delta dir) m.keeper_context
                else
                  let list_vis = max 1 (left_r.h - 2) in
                  Keeper_context_store.move_call_selection ~keeper:name
                    ~viewport_rows:list_vis ~delta:(move_delta dir)
                    m.keeper_context
              in
              ({ m with keeper_context }, [])
            in
            match Model.active_dive m with
            | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_chat }) ->
                let delta = -(move_delta dir) in
                let max_scroll =
                  Chat_transcript.max_scroll_for_model_in ~embedded:false
                    ~model:m ~keeper:name
                in
                ( {
                    m with
                    fleet =
                      Fleet_store.move_chat_scroll ~max_scroll ~delta m.fleet;
                  }
                , [] )
            | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_context }) ->
                move_keeper_context ~embedded:false ~name
            | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_tool_calls }) ->
                move_keeper_tool_calls ~embedded:false ~name
            | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_config }) ->
                move_keeper_config_selection ~embedded:false ~name
                  ~delta:(move_delta dir) m
            | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_logs }) ->
                let max_scroll =
                  keeper_tab_max_scroll ~embedded:false m ~name
                    ~tab:Nav.Keeper_logs
                in
                let keeper_context =
                  Keeper_context_store.move_logs_scroll ~keeper:name ~max_scroll
                    ~delta:(scroll_delta dir) m.keeper_context
                in
                ({ m with keeper_context }, [])
            | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_identity }) ->
                let entries_count =
                  List.length (keeper_identity_entries m ~name)
                in
                let max_scroll =
                  keeper_tab_max_scroll ~embedded:false m ~name
                    ~tab:Nav.Keeper_identity
                in
                let keeper_context =
                  match dir with
                  | Keymap.Page_up | Keymap.Page_down ->
                      Keeper_context_store.move_identity_scroll ~keeper:name
                        ~max_scroll ~delta:(scroll_delta dir) m.keeper_context
                  | Keymap.Up | Keymap.Down | Keymap.Home | Keymap.End
                  | Keymap.Left | Keymap.Right ->
                      m.keeper_context
                      |> Keeper_context_store.move_identity_selection
                           ~keeper:name ~count:entries_count
                           ~delta:(move_delta dir)
                      |> Keeper_context_store.move_identity_scroll ~keeper:name
                           ~max_scroll ~delta:(scroll_delta dir)
                in
                ({ m with keeper_context }, [])
            | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_memory }) ->
                if
                  not
                    (Knowledge_store.equal_keeper_memory_subview
                       m.knowledge.keeper_memory_subview
                       Knowledge_store.Kmem_diff_flow)
                then
                  let sd = scroll_delta dir in
                  let max_scroll =
                    keeper_tab_max_scroll ~embedded:false m ~name
                      ~tab:Nav.Keeper_memory
                  in
                  let knowledge =
                    match m.knowledge.keeper_memory_subview with
                    | Knowledge_store.Kmem_facts_tree -> (
                        match
                          Knowledge_store.memory_facts_for_keeper ~keeper:name
                            m.knowledge
                        with
                        | Some facts ->
                            let cnt =
                              List.length (keeper_facts_categories facts)
                            in
                            Knowledge_store.move_facts_selection ~count:cnt
                              ~delta:(move_delta dir) m.knowledge
                        | None -> m.knowledge)
                    | Knowledge_store.Kmem_diff_flow
                    | Knowledge_store.Kmem_health
                    | Knowledge_store.Kmem_journal ->
                        m.knowledge
                  in
                  let dive_scroll_offset =
                    Store_scroll.clamp_scroll ~max_scroll
                      (m.nav.dive_scroll_offset + sd)
                  in
                  ( {
                      m with
                      nav = { m.nav with dive_scroll_offset };
                      knowledge;
                    }
                  , [] )
                else
                  let has_matching_diagram =
                    Option.is_some (Memory_diagram.active_diagram m)
                  in
                  let has_matching_reading =
                    match m.knowledge.memory_reading with
                    | Some entry ->
                        Knowledge_store.memory_reading_matches_scope
                          ~keeper_opt:(Some name) entry
                    | None -> false
                  in
                  if has_matching_diagram then
                    let sd = scroll_delta dir in
                    let max_scroll = memory_diagram_max_scroll m in
                    let knowledge =
                      Knowledge_store.scroll_memory_diagram ~max_scroll ~delta:sd
                        m.knowledge
                    in
                    ({ m with knowledge }, [])
                  else if has_matching_reading then
                    let sd = scroll_delta dir in
                    let max_scroll = memory_reading_max_scroll m in
                    let knowledge =
                      Knowledge_store.scroll_memory_reading ~max_scroll ~delta:sd
                        m.knowledge
                    in
                    ({ m with knowledge }, [])
                  else (
                    match m.knowledge.memory_view_mode with
                    | Knowledge_store.View_evolution ->
                        let knowledge =
                          Knowledge_store.move_memory_activity ~keeper:name
                            ~viewport_rows ~delta:(move_delta dir) m.knowledge
                        in
                        ({ m with knowledge }, [])
                    | Knowledge_store.View_facts ->
                        let knowledge =
                          Knowledge_store.move_memory_facts ~keeper:name
                            ~viewport_rows ~delta:(move_delta dir) m.knowledge
                        in
                        ({ m with knowledge }, [])
                    | Knowledge_store.View_diff ->
                        let sd = scroll_delta dir in
                        let max_scroll =
                          keeper_tab_max_scroll ~embedded:false m ~name
                            ~tab:Nav.Keeper_memory
                        in
                        let dive_scroll_offset =
                          Store_scroll.clamp_scroll ~max_scroll
                            (m.nav.dive_scroll_offset + sd)
                        in
                        let knowledge =
                          Knowledge_store.move_memory_diff_cursor
                            ~delta:(move_delta dir) m.knowledge
                        in
                        ( {
                            m with
                            nav = { m.nav with dive_scroll_offset };
                            knowledge;
                          }
                        , [] ))
            | Some
                (Nav.Dive_knowledge
                   (Nav.Memory_diff_dive { keeper; from_rev; to_rev }) as active)
              ->
                let has_matching_reading =
                  match m.knowledge.memory_reading with
                  | Some entry ->
                      Knowledge_store.memory_reading_matches_scope
                        ~keeper_opt:keeper entry
                  | None -> false
                in
                if has_matching_reading then
                  let sd = scroll_delta dir in
                  let max_scroll = memory_reading_max_scroll m in
                  let knowledge =
                    Knowledge_store.scroll_memory_reading ~max_scroll ~delta:sd
                      m.knowledge
                  in
                  ({ m with knowledge }, [])
                else
                  let delta = scroll_delta dir in
                  let max_scroll = dive_max_scroll m active in
                  let dive_scroll_offset =
                    Store_scroll.clamp_scroll ~max_scroll
                      (m.nav.dive_scroll_offset + delta)
                  in
                  let knowledge =
                    Knowledge_store.move_memory_diff_dive_cursor ~keeper
                      ~from_rev ~to_rev ~delta:(move_delta dir) m.knowledge
                  in
                  ( { m with nav = { m.nav with dive_scroll_offset }; knowledge }
                  , [] )
            | Some (Nav.Dive_work _ as active) ->
                let delta = scroll_delta dir in
                if m.infra.show_raw_json && m.nav.pane_index = 1 then
                  let max_scroll = dive_max_scroll m active in
                  let json_scroll_offset =
                    Store_scroll.clamp_scroll ~max_scroll
                      (m.nav.json_scroll_offset + delta)
                  in
                  ({ m with nav = { m.nav with json_scroll_offset } }, [])
                else
                  let max_scroll = dive_max_scroll m active in
                  let dive_scroll_offset =
                    Store_scroll.clamp_scroll ~max_scroll
                      (m.nav.dive_scroll_offset + delta)
                  in
                  ({ m with nav = { m.nav with dive_scroll_offset } }, [])
            | Some
                (( Nav.Dive_keeper
                     {
                       tab = (Nav.Keeper_work_candle | Nav.Keeper_sandbox);
                       _;
                     }
                 | Nav.Dive_knowledge
                     (Nav.Thread_dive _ | Nav.Wiki_dive _ | Nav.Artifact_dive _)
                 | Nav.Dive_runtime _
                 | Nav.Dive_infra _ ) as active) ->
                let delta = scroll_delta dir in
                let max_scroll = dive_max_scroll m active in
                let dive_scroll_offset =
                  Store_scroll.clamp_scroll ~max_scroll
                    (m.nav.dive_scroll_offset + delta)
                in
                ({ m with nav = { m.nav with dive_scroll_offset } }, [])
            | None -> (
                let delta = move_delta dir in
                let pane_index = m.nav.pane_index in
                match m.nav.workspace with
                | Nav.Pulse -> (
                    match Model.active_pulse_pane m with
                    | Model.Pulse_attention ->
                        let attention =
                          Attention.move_triage ~viewport_rows ~delta m.attention
                        in
                        ({ m with attention }, [])
                    | Model.Pulse_companies ->
                        let fleet =
                          Fleet_store.move_company_selection ~viewport_rows
                            ~delta m.fleet
                        in
                        let drafts =
                          match fleet.selected_keeper with
                          | Some name -> Drafts.set_active_keeper name m.drafts
                          | None -> m.drafts
                        in
                        ({ m with fleet; drafts }, [])
                    | Model.Pulse_goals ->
                        let work = Work_store.move_pulse_goal ~delta m.work in
                        ({ m with work }, [])
                    | Model.Pulse_world ->
                        let knowledge =
                          Knowledge_store.move_pulse_thread ~delta m.knowledge
                        in
                        ({ m with knowledge }, []))
                | Nav.Keepers ->
                    let zoomed_keeper =
                      m.nav.zoomed && Model.can_zoom_current_view m
                    in
                    if pane_index = 1 || zoomed_keeper then
                      let embedded = not zoomed_keeper in
                      match Fleet_store.selected_keeper_summary m.fleet with
                      | None -> (m, [])
                      | Some k -> (
                          match m.fleet.keeper_dive_tab with
                          | Nav.Keeper_chat ->
                              let chat_delta = -(move_delta dir) in
                              let max_scroll =
                                Chat_transcript.max_scroll_for_model_in
                                  ~embedded ~model:m ~keeper:k.name
                              in
                              ( {
                                  m with
                                  fleet =
                                    Fleet_store.move_chat_scroll ~max_scroll
                                      ~delta:chat_delta m.fleet;
                                }
                              , [] )
                          | Nav.Keeper_context ->
                              move_keeper_context ~embedded ~name:k.name
                          | Nav.Keeper_tool_calls ->
                              move_keeper_tool_calls ~embedded ~name:k.name
                          | Nav.Keeper_config ->
                              move_keeper_config_selection ~embedded
                                ~name:k.name ~delta:(move_delta dir) m
                          | Nav.Keeper_logs ->
                              let max_scroll =
                                keeper_tab_max_scroll ~embedded m ~name:k.name
                                  ~tab:Nav.Keeper_logs
                              in
                              let keeper_context =
                                Keeper_context_store.move_logs_scroll
                                  ~keeper:k.name ~max_scroll
                                  ~delta:(scroll_delta dir) m.keeper_context
                              in
                              ({ m with keeper_context }, [])
                          | Nav.Keeper_identity ->
                              let entries_count =
                                List.length
                                  (keeper_identity_entries m ~name:k.name)
                              in
                              let max_scroll =
                                keeper_tab_max_scroll ~embedded m ~name:k.name
                                  ~tab:Nav.Keeper_identity
                              in
                              let keeper_context =
                                match dir with
                                | Keymap.Page_up | Keymap.Page_down ->
                                    Keeper_context_store.move_identity_scroll
                                      ~keeper:k.name ~max_scroll
                                      ~delta:(scroll_delta dir) m.keeper_context
                                | Keymap.Up | Keymap.Down | Keymap.Home
                                | Keymap.End | Keymap.Left | Keymap.Right ->
                                    m.keeper_context
                                    |> Keeper_context_store.move_identity_selection
                                         ~keeper:k.name ~count:entries_count
                                         ~delta:(move_delta dir)
                                    |> Keeper_context_store.move_identity_scroll
                                         ~keeper:k.name ~max_scroll
                                         ~delta:(scroll_delta dir)
                              in
                              ({ m with keeper_context }, [])
                          | Nav.Keeper_memory ->
                              if
                                not
                                  (Knowledge_store.equal_keeper_memory_subview
                                     m.knowledge.keeper_memory_subview
                                     Knowledge_store.Kmem_diff_flow)
                              then
                                let sd = scroll_delta dir in
                                let max_scroll =
                                  keeper_tab_max_scroll ~embedded m ~name:k.name
                                    ~tab:Nav.Keeper_memory
                                in
                                let knowledge =
                                  match m.knowledge.keeper_memory_subview with
                                  | Knowledge_store.Kmem_facts_tree -> (
                                      match
                                        Knowledge_store.memory_facts_for_keeper
                                          ~keeper:k.name m.knowledge
                                      with
                                      | Some facts ->
                                          let cnt =
                                            List.length
                                              (keeper_facts_categories facts)
                                          in
                                          Knowledge_store.move_facts_selection
                                            ~count:cnt ~delta:(move_delta dir)
                                            m.knowledge
                                      | None -> m.knowledge)
                                  | Knowledge_store.Kmem_diff_flow
                                  | Knowledge_store.Kmem_health
                                  | Knowledge_store.Kmem_journal ->
                                      m.knowledge
                                in
                                let dive_scroll_offset =
                                  Store_scroll.clamp_scroll ~max_scroll
                                    (m.nav.dive_scroll_offset + sd)
                                in
                                ( {
                                    m with
                                    nav = { m.nav with dive_scroll_offset };
                                    knowledge;
                                  }
                                , [] )
                              else
                                let has_matching_diagram =
                                  Option.is_some (Memory_diagram.active_diagram m)
                                in
                                let has_matching_reading =
                                  match m.knowledge.memory_reading with
                                  | Some entry ->
                                      Knowledge_store.memory_reading_matches_scope
                                        ~keeper_opt:(Some k.name) entry
                                  | None -> false
                                in
                                if has_matching_diagram then
                                  let sd = scroll_delta dir in
                                  let max_scroll = memory_diagram_max_scroll m in
                                  let knowledge =
                                    Knowledge_store.scroll_memory_diagram
                                      ~max_scroll ~delta:sd m.knowledge
                                  in
                                  ({ m with knowledge }, [])
                                else if has_matching_reading then
                                  let sd = scroll_delta dir in
                                  let max_scroll = memory_reading_max_scroll m in
                                  let knowledge =
                                    Knowledge_store.scroll_memory_reading
                                      ~max_scroll ~delta:sd m.knowledge
                                  in
                                  ({ m with knowledge }, [])
                                else (
                                  match m.knowledge.memory_view_mode with
                                  | Knowledge_store.View_evolution ->
                                      let knowledge =
                                        Knowledge_store.move_memory_activity
                                          ~keeper:k.name ~viewport_rows
                                          ~delta:(move_delta dir) m.knowledge
                                      in
                                      ({ m with knowledge }, [])
                                  | Knowledge_store.View_facts ->
                                      let knowledge =
                                        Knowledge_store.move_memory_facts
                                          ~keeper:k.name ~viewport_rows
                                          ~delta:(move_delta dir) m.knowledge
                                      in
                                      ({ m with knowledge }, [])
                                  | Knowledge_store.View_diff ->
                                      let sd = scroll_delta dir in
                                      let max_scroll =
                                        keeper_tab_max_scroll ~embedded m
                                          ~name:k.name ~tab:Nav.Keeper_memory
                                      in
                                      let dive_scroll_offset =
                                        Store_scroll.clamp_scroll ~max_scroll
                                          (m.nav.dive_scroll_offset + sd)
                                      in
                                      let knowledge =
                                        Knowledge_store.move_memory_diff_cursor
                                          ~delta:(move_delta dir) m.knowledge
                                      in
                                      ( {
                                          m with
                                          nav = { m.nav with dive_scroll_offset };
                                          knowledge;
                                        }
                                      , [] ))
                          | (Nav.Keeper_work_candle | Nav.Keeper_sandbox) as tab
                            ->
                              let sd = scroll_delta dir in
                              let max_scroll =
                                keeper_tab_max_scroll ~embedded m ~name:k.name
                                  ~tab
                              in
                              let dive_scroll_offset =
                                Store_scroll.clamp_scroll ~max_scroll
                                  (m.nav.dive_scroll_offset + sd)
                              in
                              ( { m with nav = { m.nav with dive_scroll_offset } }
                              , [] ))
                    else
                      let prev_selected = m.fleet.selected_keeper in
                      let fleet =
                        Fleet_store.move_selection ~viewport_rows ~delta m.fleet
                      in
                      let drafts =
                        match fleet.selected_keeper with
                        | Some name -> Drafts.set_active_keeper name m.drafts
                        | None -> m.drafts
                      in
                      let selection_changed =
                        not
                          (Option.equal String.equal prev_selected
                             fleet.selected_keeper)
                      in
                      let nav =
                        if selection_changed then
                          { m.nav with dive_scroll_offset = 0 }
                        else m.nav
                      in
                      let next =
                        { m with nav; fleet; drafts }
                        |> sync_config_for_keeper_view
                      in
                      let cmds =
                        if selection_changed then
                          View_fetches.fetches_for_current_view next
                        else []
                      in
                      (next, cmds)
                | Nav.Work -> (
                    match m.work.active_tab with
                    | Nav.Work_inbox ->
                        if pane_index = 1 then
                          let sd = scroll_delta dir in
                          let max_detail_scroll = work_detail_max_scroll m in
                          ( {
                              m with
                              work =
                                Work_store.move_selection ~pane_index:1
                                  ~viewport_rows ~max_detail_scroll ~delta:sd
                                  m.work;
                            }
                          , [] )
                        else if
                          Attention.filtered_items ~query:m.work.filter_query
                            m.attention
                          <> []
                        then
                          let attention =
                            Attention.move_triage ~query:m.work.filter_query
                              ~viewport_rows ~delta m.attention
                          in
                          let work0 = Work_store.reset_detail_scroll m.work in
                          let work =
                            match
                              Attention.current_filtered_item
                                ~query:m.work.filter_query attention
                            with
                            | Some { payload = Attention.Payload_ask ask; _ } ->
                                let asks = Work_store.open_asks work0 in
                                let rec find i = function
                                  | [] -> None
                                  | (a : Wire_work.ask_row) :: rest ->
                                      if String.equal a.ask_id ask.ask_id then
                                        Some i
                                      else find (i + 1) rest
                                in
                                (match find 0 asks with
                                | Some idx -> { work0 with selected_index = idx }
                                | None -> work0)
                            | Some
                                {
                                  payload =
                                    ( Attention.Payload_tool_approval _
                                    | Attention.Payload_gate _
                                    | Attention.Payload_goal_confirmation _ );
                                  _;
                                }
                            | None ->
                                work0
                          in
                          ({ m with attention; work }, [])
                        else
                          ( {
                              m with
                              work =
                                Work_store.move_selection ~pane_index:0
                                  ~viewport_rows ~delta m.work;
                            }
                          , [] )
                    | Nav.Work_tasks | Nav.Work_schedules ->
                        let eff_delta =
                          if pane_index = 1 then scroll_delta dir else delta
                        in
                        let max_detail_scroll =
                          if pane_index = 1 then Some (work_detail_max_scroll m)
                          else None
                        in
                        let work =
                          Work_store.move_selection ~pane_index ~viewport_rows
                            ?max_detail_scroll ~delta:eff_delta m.work
                        in
                        ({ m with work }, [])
                    | Nav.Work_pipeline ->
                        let has_linked_card =
                          Model.work_pipeline_has_linked_card m
                        in
                        let is_detail =
                          pane_index = 2
                          || (pane_index = 1 && not has_linked_card)
                        in
                        let eff_delta =
                          if is_detail then scroll_delta dir else delta
                        in
                        let max_detail_scroll =
                          if is_detail then Some (work_detail_max_scroll m)
                          else None
                        in
                        ( {
                            m with
                            work =
                              Work_store.move_selection ~pane_index
                                ~has_linked_card ~viewport_rows
                                ?max_detail_scroll ~delta:eff_delta m.work;
                          }
                        , [] )
                    | Nav.Work_candle_scorecard ->
                        let eff_delta =
                          if pane_index = 1 then scroll_delta dir else delta
                        in
                        let max_detail_scroll =
                          if pane_index = 1 then Some (work_detail_max_scroll m)
                          else None
                        in
                        ( {
                            m with
                            work =
                              Work_store.move_selection ~pane_index
                                ~viewport_rows ?max_detail_scroll
                                ~delta:eff_delta m.work;
                          }
                        , [] )
                    | Nav.Work_harness ->
                        let is_detail = pane_index = 1 in
                        let eff_delta =
                          if is_detail then scroll_delta dir else delta
                        in
                        let max_detail_scroll =
                          if is_detail then Some (work_detail_max_scroll m)
                          else None
                        in
                        ( {
                            m with
                            work =
                              Work_store.move_selection ~pane_index
                                ~viewport_rows ?max_detail_scroll
                                ~delta:eff_delta m.work;
                          }
                        , [] ))
                | Nav.Knowledge ->
                    let eff_pane =
                      if m.nav.zoomed && Model.can_zoom_current_view m then 1
                      else pane_index
                    in
                    let prev_mem_keeper = m.knowledge.memory_diff_keeper in
                    let has_matching_diagram =
                      Nav.equal_knowledge_tab m.knowledge.active_tab
                        Nav.Knowledge_memory
                      && Option.is_some (Memory_diagram.active_diagram m)
                    in
                    let has_matching_reading =
                      Nav.equal_knowledge_tab m.knowledge.active_tab
                        Nav.Knowledge_memory
                      &&
                      match m.knowledge.memory_reading with
                      | Some entry ->
                          Knowledge_store.memory_reading_matches_scope
                            ~keeper_opt:m.knowledge.memory_diff_keeper entry
                      | None -> false
                    in
                    let is_memory_list_cursor =
                      Nav.equal_knowledge_tab m.knowledge.active_tab
                        Nav.Knowledge_memory
                      && eff_pane = 1
                      && (not has_matching_diagram)
                      && (not has_matching_reading)
                      && Option.is_some m.knowledge.memory_diff_keeper
                      &&
                      match m.knowledge.memory_view_mode with
                      | Knowledge_store.View_evolution
                      | Knowledge_store.View_facts ->
                          true
                      | Knowledge_store.View_diff -> false
                    in
                    let prev_art_id =
                      match Knowledge_store.selected_artifact m.knowledge with
                      | Some a -> Some a.id
                      | None -> None
                    in
                    let eff_delta =
                      if eff_pane = 1 && not is_memory_list_cursor then
                        scroll_delta dir
                      else delta
                    in
                    let max_detail_scroll =
                      if eff_pane = 1 then
                        if has_matching_diagram then
                          Some (memory_diagram_max_scroll m)
                        else if has_matching_reading then
                          Some (memory_reading_max_scroll m)
                        else Some (knowledge_detail_max_scroll m)
                      else None
                    in
                    let knowledge =
                      if
                        Nav.equal_knowledge_tab m.knowledge.active_tab
                          Nav.Knowledge_memory
                        && eff_pane = 1
                        && not
                             (Knowledge_store.equal_memory_subview
                                m.knowledge.memory_subview
                                Knowledge_store.Mem_diff_flow)
                      then
                        let max_scroll = knowledge_detail_max_scroll m in
                        Knowledge_store.move_memory_subview_scroll ~max_scroll
                          ~delta:(scroll_delta dir) m.knowledge
                      else
                        Knowledge_store.move_selection ~pane_index:eff_pane
                          ~viewport_rows ?max_detail_scroll ~delta:eff_delta
                          m.knowledge
                    in
                    let next = { m with knowledge } in
                    let nav_cmds =
                      match knowledge.active_tab, eff_pane with
                      | Nav.Knowledge_wiki, 0 ->
                          View_fetches.selected_wiki_page_fetch next
                      | Nav.Knowledge_memory, 0 ->
                          if
                            not
                              (Option.equal String.equal prev_mem_keeper
                                 knowledge.memory_diff_keeper)
                          then View_fetches.fetches_for_current_view next
                          else []
                      | Nav.Knowledge_artifacts, 0 -> (
                          match Knowledge_store.selected_artifact knowledge with
                          | Some a ->
                              let loaded_matches =
                                Option.is_some
                                  (Knowledge_store.artifact_detail_for_entry a
                                     knowledge)
                              in
                              if
                                (not
                                   (Option.equal String.equal prev_art_id
                                      (Some a.id)))
                                || not loaded_matches
                              then
                                [
                                  Cmd.Http_get
                                    {
                                      epoch = m.epoch;
                                      req =
                                        Cmd.Get_artifact_detail
                                          { id = a.id; revision = Some a.revision };
                                    };
                                ]
                              else []
                          | None -> [])
                      | Nav.Knowledge_wiki, _
                      | Nav.Knowledge_artifacts, _
                      | Nav.Knowledge_board, _
                      | Nav.Knowledge_memory, _ ->
                          []
                    in
                    (next, nav_cmds)
                | Nav.Runtime ->
                    let rt = sync_runtime_companies_if_needed m in
                    let prev_browser_cid =
                      Option.map
                        (fun (c : Wire_runtime.browser_client_row) -> c.client_id)
                        (Runtime_store.selected_browser_client rt)
                    in
                    let prev_fusion_id =
                      Option.map
                        (fun (r : Wire_runtime.fusion_run) -> r.run_id)
                        (Runtime_store.selected_fusion_run rt)
                    in
                    let prev_catalog_manifest =
                      match Runtime_store.selected_addon_catalog_entry rt with
                      | Some (Wire_runtime.Catalog_package { manifest_path; _ })
                        ->
                          Some manifest_path
                      | Some
                          ( Wire_runtime.Catalog_folder _
                          | Wire_runtime.Catalog_issue _ )
                      | None ->
                          None
                    in
                    let prev_connector_id =
                      Option.map
                        (fun (c : Wire_runtime.connector_row) -> c.connector_id)
                        (Runtime_store.selected_connector rt)
                    in
                    let is_detail_scroll =
                      match rt.active_tab, pane_index with
                      | Nav.Runtime_quotas_credits, 0
                      | Nav.Runtime_failover_lanes, 1
                      | Nav.Runtime_fusion, 1 ->
                          true
                      | Nav.Runtime_addons_browser, 1 when rt.addon_catalog_mode
                        ->
                          true
                      | Nav.Runtime_tools_usage, 1
                        when Runtime_store.equal_tools_subview rt.tools_subview
                               Runtime_store.Tools_keeper_skills ->
                          true
                      | ( ( Nav.Runtime_quotas_credits
                          | Nav.Runtime_efficiency_spend
                          | Nav.Runtime_failover_lanes
                          | Nav.Runtime_fusion
                          | Nav.Runtime_tools_usage
                          | Nav.Runtime_connectors
                          | Nav.Runtime_addons_browser )
                        , _ ) ->
                          false
                    in
                    let eff_delta =
                      if is_detail_scroll then scroll_delta dir else delta
                    in
                    let max_detail_scroll =
                      if is_detail_scroll then
                        Some (runtime_detail_max_scroll m)
                      else None
                    in
                    let eff_viewport_rows =
                      match rt.active_tab, pane_index with
                      | Nav.Runtime_failover_lanes, 0 ->
                          let bp = ui_bp m in
                          let br = ui_body_rect m in
                          let body_rect =
                            match
                              Masc_tui_ui.Layout.split_v br
                                [
                                  Masc_tui_ui.Layout.Fixed 1;
                                  Masc_tui_ui.Layout.Flex 1;
                                ]
                            with
                            | [ _; b ] -> b
                            | _ -> br
                          in
                          let left_rect, _ =
                            Masc_tui_ui.Layout.adaptive_split_2
                              ~stack_on_compact:true ~left_ratio:0.56
                              ~top_ratio:0.54 bp body_rect
                          in
                          let inner = ui_card_inner left_rect in
                          let _, outside =
                            Runtime_store.active_and_outside_probes rt
                          in
                          let reserve_ext =
                            if rt.show_outside_lane_probes && outside <> [] then
                              min 5 (1 + List.length outside)
                            else 0
                          in
                          max 1 (inner.h - reserve_ext)
                      | Nav.Runtime_addons_browser, pane ->
                          let bp = ui_bp m in
                          let br = ui_body_rect m in
                          let body_rect =
                            match
                              Masc_tui_ui.Layout.split_v br
                                [
                                  Masc_tui_ui.Layout.Fixed 1;
                                  Masc_tui_ui.Layout.Flex 1;
                                ]
                            with
                            | [ _; b ] -> b
                            | _ -> br
                          in
                          let left_rect, right_rect =
                            Masc_tui_ui.Layout.adaptive_split_2
                              ~stack_on_compact:true ~left_ratio:0.52
                              ~top_ratio:0.50 bp body_rect
                          in
                          let table_data_rows ~(rect : Rect.t)
                              (columns : Masc_tui_ui.Table.column list) =
                            if rect.w <= 0 || rect.h <= 0 then 1
                            else
                              let col_gap =
                                Masc_tui_ui.Layout.table_col_gap bp
                              in
                              let _, dropped =
                                Masc_tui_ui.Table.resolve_columns ~col_gap
                                  ~avail_w:rect.w columns
                              in
                              let has_hidden_notice =
                                dropped <> [] && rect.h >= 3
                              in
                              let header_rows = if rect.h >= 2 then 1 else 0 in
                              let footer_rows =
                                if has_hidden_notice then 1 else 0
                              in
                              let sep_rows =
                                if
                                  header_rows = 1
                                  && rect.h - header_rows - footer_rows >= 3
                                then 1
                                else 0
                              in
                              max 1
                                (rect.h - header_rows - sep_rows - footer_rows)
                          in
                          let col ~id ~priority ~min_width ?max_width ~weight
                              ~align () : Masc_tui_ui.Table.column =
                            {
                              id;
                              header = Say.literal id;
                              priority;
                              min_width;
                              max_width;
                              weight;
                              align;
                            }
                          in
                          if pane = 0 then
                            let left_inner = ui_card_inner left_rect in
                            let detail_h =
                              if
                                left_inner.h >= 10
                                && Option.is_some
                                     (Runtime_store.selected_addon_instance rt)
                              then 4
                              else 0
                            in
                            let tbl_rect =
                              Rect.make ~x:left_inner.x ~y:left_inner.y
                                ~w:left_inner.w
                                ~h:(max 0 (left_inner.h - detail_h))
                            in
                            table_data_rows ~rect:tbl_rect
                              [
                                col ~id:"addon" ~priority:0 ~min_width:14
                                  ~weight:3 ~align:Masc_tui_ui.Table.Left ();
                                col ~id:"pres" ~priority:1 ~min_width:5
                                  ~max_width:8 ~weight:1
                                  ~align:Masc_tui_ui.Table.Left ();
                                col ~id:"phase" ~priority:1 ~min_width:5
                                  ~max_width:7 ~weight:1
                                  ~align:Masc_tui_ui.Table.Left ();
                                col ~id:"exec" ~priority:2 ~min_width:6
                                  ~max_width:10 ~weight:1
                                  ~align:Masc_tui_ui.Table.Left ();
                                col ~id:"obs" ~priority:2 ~min_width:8
                                  ~max_width:12 ~weight:1
                                  ~align:Masc_tui_ui.Table.Right ();
                                col ~id:"decl" ~priority:3 ~min_width:7
                                  ~max_width:12 ~weight:1
                                  ~align:Masc_tui_ui.Table.Left ();
                              ]
                          else
                            let right_inner = ui_card_inner right_rect in
                            let browser_issues =
                              match Observed.to_option rt.browser_lane with
                              | Some bl -> bl.issues
                              | None -> []
                            in
                            let issues_h =
                              if browser_issues <> [] && right_inner.h >= 12
                              then min 3 (List.length browser_issues)
                              else 0
                            in
                            let main_h = max 0 (right_inner.h - issues_h) in
                            let clients_h =
                              if main_h <= 0 then 0
                              else min main_h (max 4 ((main_h * 45) / 100))
                            in
                            let tabs_h = max 0 (main_h - clients_h) in
                            (match rt.browser_right_focus with
                            | `Clients ->
                                let clients_rect =
                                  Rect.make ~x:right_inner.x ~y:right_inner.y
                                    ~w:right_inner.w ~h:clients_h
                                in
                                table_data_rows ~rect:clients_rect
                                  [
                                    col ~id:"client" ~priority:0 ~min_width:14
                                      ~weight:3 ~align:Masc_tui_ui.Table.Left ();
                                    col ~id:"browser" ~priority:1 ~min_width:10
                                      ~max_width:18 ~weight:2
                                      ~align:Masc_tui_ui.Table.Left ();
                                    col ~id:"presence" ~priority:1 ~min_width:10
                                      ~max_width:16 ~weight:1
                                      ~align:Masc_tui_ui.Table.Left ();
                                    col ~id:"activity" ~priority:2 ~min_width:12
                                      ~weight:2 ~align:Masc_tui_ui.Table.Left ();
                                  ]
                            | `Tabs ->
                                let tabs_body =
                                  Rect.make ~x:right_inner.x
                                    ~y:(right_inner.y + clients_h + issues_h + 1)
                                    ~w:right_inner.w
                                    ~h:(max 0 (tabs_h - 1))
                                in
                                table_data_rows ~rect:tabs_body
                                  [
                                    col ~id:"id" ~priority:1 ~min_width:4
                                      ~max_width:6 ~weight:1
                                      ~align:Masc_tui_ui.Table.Right ();
                                    col ~id:"act" ~priority:1 ~min_width:2
                                      ~max_width:3 ~weight:1
                                      ~align:Masc_tui_ui.Table.Center ();
                                    col ~id:"origin" ~priority:2 ~min_width:5
                                      ~max_width:8 ~weight:1
                                      ~align:Masc_tui_ui.Table.Left ();
                                    col ~id:"title" ~priority:0 ~min_width:12
                                      ~weight:2 ~align:Masc_tui_ui.Table.Left ();
                                    col ~id:"url" ~priority:0 ~min_width:16
                                      ~weight:3 ~align:Masc_tui_ui.Table.Left ();
                                  ])
                      | Nav.Runtime_tools_usage, pane -> (
                          let bp = ui_bp m in
                          let br = ui_body_rect m in
                          let body_rect =
                            match
                              Masc_tui_ui.Layout.split_v br
                                [
                                  Masc_tui_ui.Layout.Fixed 1;
                                  Masc_tui_ui.Layout.Flex 1;
                                ]
                            with
                            | [ _; b ] -> b
                            | _ -> br
                          in
                          match rt.tools_subview with
                          | Runtime_store.Tools_usage_calls ->
                              let main_rect =
                                match
                                  Masc_tui_ui.Layout.split_v body_rect
                                    [
                                      Masc_tui_ui.Layout.Fixed 1;
                                      Masc_tui_ui.Layout.Flex 1;
                                    ]
                                with
                                | [ _; b ] -> b
                                | _ -> body_rect
                              in
                              let charts_h =
                                if main_rect.h >= 22 then 9
                                else if main_rect.h >= 14 then 6
                                else 0
                              in
                              let bottom_rect =
                                if charts_h > 0 then
                                  match
                                    Masc_tui_ui.Layout.split_v_bp bp main_rect
                                      [
                                        Masc_tui_ui.Layout.Fixed charts_h;
                                        Masc_tui_ui.Layout.Flex 1;
                                      ]
                                  with
                                  | [ _; b ] -> b
                                  | _ -> main_rect
                                else main_rect
                              in
                              let tbl_rect =
                                if bottom_rect.w >= 86 then
                                  match
                                    Masc_tui_ui.Layout.split_h_bp bp bottom_rect
                                      [
                                        Masc_tui_ui.Layout.Ratio 0.62;
                                        Masc_tui_ui.Layout.Flex 1;
                                      ]
                                  with
                                  | l :: _ -> l
                                  | [] -> bottom_rect
                                else bottom_rect
                              in
                              let tbl_inner = ui_card_inner tbl_rect in
                              max 1 (tbl_inner.h - 2)
                          | Runtime_store.Tools_catalog_tree ->
                              let inner = ui_card_inner body_rect in
                              max 1 (inner.h - 2)
                          | Runtime_store.Tools_keeper_skills ->
                              let left_rect, right_rect =
                                Masc_tui_ui.Layout.adaptive_split_2
                                  ~stack_on_compact:true ~left_ratio:0.52
                                  ~top_ratio:0.50 bp body_rect
                              in
                              let target_r =
                                if pane = 1 then right_rect else left_rect
                              in
                              let c =
                                ui_card_inner target_r |> ui_pad_content ~bp
                              in
                              max 1 (c.h - 5))
                      | ( ( Nav.Runtime_quotas_credits
                          | Nav.Runtime_efficiency_spend
                          | Nav.Runtime_failover_lanes
                          | Nav.Runtime_fusion
                          | Nav.Runtime_connectors )
                        , _ ) ->
                          viewport_rows
                    in
                    let eff_max_detail_scroll =
                      match (rt.active_tab, rt.tools_subview, pane_index) with
                      | ( Nav.Runtime_tools_usage
                        , Runtime_store.Tools_keeper_skills
                        , 0 ) -> (
                          let bp = ui_bp m in
                          let br = ui_body_rect m in
                          let body_rect =
                            match
                              Masc_tui_ui.Layout.split_v br
                                [
                                  Masc_tui_ui.Layout.Fixed 1;
                                  Masc_tui_ui.Layout.Flex 1;
                                ]
                            with
                            | [ _; b ] -> b
                            | _ -> br
                          in
                          let left_rect, _ =
                            Masc_tui_ui.Layout.adaptive_split_2
                              ~stack_on_compact:true ~left_ratio:0.52
                              ~top_ratio:0.50 bp body_rect
                          in
                          let lc =
                            ui_card_inner left_rect |> ui_pad_content ~bp
                          in
                          match Observed.to_option rt.tools_dashboard with
                          | Some
                              ({
                                 effective_keeper_surface =
                                   Some
                                     (Wire_runtime.Keeper_surface_available s);
                                 _;
                               } as dash) ->
                              let hdr_rows =
                                3
                                + (if s.skills_left_out <> [] then 1 else 0)
                                + (if s.lane_addon_conflicts <> [] then 1 else 0)
                                + (if
                                     Option.is_some dash.volume_gc_summary
                                     || Option.is_some
                                          dash.keeper_cleanup_summary
                                   then 1
                                   else 0)
                                + 1
                              in
                              let vis = max 1 (lc.h - hdr_rows) in
                              Some (max 0 (List.length s.tools - vis))
                          | Some
                              {
                                effective_keeper_surface =
                                  Some
                                    (Wire_runtime.Keeper_surface_unavailable _)
                                  | None;
                                _;
                              }
                          | None ->
                              Some 0)
                      | ( ( Nav.Runtime_quotas_credits
                          | Nav.Runtime_efficiency_spend
                          | Nav.Runtime_failover_lanes
                          | Nav.Runtime_fusion
                          | Nav.Runtime_tools_usage
                          | Nav.Runtime_connectors
                          | Nav.Runtime_addons_browser )
                        , ( Runtime_store.Tools_usage_calls
                          | Runtime_store.Tools_catalog_tree
                          | Runtime_store.Tools_keeper_skills )
                        , _ ) ->
                          max_detail_scroll
                    in
                    let next_rt =
                      Runtime_store.move_selection ~pane_index
                        ~viewport_rows:eff_viewport_rows
                        ?max_detail_scroll:eff_max_detail_scroll ~delta:eff_delta
                        rt
                    in
                    let tab_cmds =
                      if
                        Nav.equal_runtime_tab next_rt.active_tab
                          Nav.Runtime_addons_browser
                        && (not next_rt.addon_catalog_mode)
                        && pane_index = 1
                        && next_rt.browser_right_focus = `Clients
                      then
                        match Runtime_store.selected_browser_client next_rt with
                        | Some cl
                          when not
                                 (Option.equal String.equal prev_browser_cid
                                    (Some cl.client_id)) -> (
                            match
                              Runtime_store.browser_tabs_for
                                ~client_id:cl.client_id next_rt
                            with
                            | Observed.Value { stale = false; _ }
                            | Observed.Failed { retryable = false; _ } ->
                                []
                            | Observed.Loading _
                            | Observed.Value { stale = true; _ }
                            | Observed.Absent
                            | Observed.Unreported
                            | Observed.Failed { retryable = true; _ } ->
                                [
                                  Cmd.Http_post
                                    {
                                      epoch = m.epoch;
                                      req =
                                        Cmd.Post_browser_tabs
                                          { client_id = cl.client_id };
                                    };
                                ])
                        | Some _ | None -> []
                      else if
                        Nav.equal_runtime_tab next_rt.active_tab
                          Nav.Runtime_addons_browser
                        && next_rt.addon_catalog_mode && pane_index = 0
                      then
                        match
                          Runtime_store.selected_addon_catalog_entry next_rt
                        with
                        | Some
                            (Wire_runtime.Catalog_package { manifest_path; _ })
                          when not
                                 (Option.equal String.equal
                                    prev_catalog_manifest (Some manifest_path))
                          ->
                            [
                              Cmd.Http_get
                                {
                                  epoch = m.epoch;
                                  req =
                                    Cmd.Get_addon_package_preview
                                      { manifest_path };
                                };
                            ]
                        | Some
                            ( Wire_runtime.Catalog_package _
                            | Wire_runtime.Catalog_folder _
                            | Wire_runtime.Catalog_issue _ )
                        | None ->
                            []
                      else if
                        Nav.equal_runtime_tab next_rt.active_tab
                          Nav.Runtime_fusion
                        && pane_index = 0
                      then
                        match Runtime_store.selected_fusion_run next_rt with
                        | Some run
                          when not
                                 (Option.equal String.equal prev_fusion_id
                                    (Some run.run_id)) ->
                            [
                              Cmd.Http_get
                                {
                                  epoch = m.epoch;
                                  req =
                                    Cmd.Get_fusion_run_detail
                                      { run_id = run.run_id };
                                };
                            ]
                        | Some _ | None -> []
                      else if
                        Nav.equal_runtime_tab next_rt.active_tab
                          Nav.Runtime_connectors
                        && pane_index = 0
                      then
                        match Runtime_store.selected_connector next_rt with
                        | Some conn
                          when (not
                                  (Option.equal String.equal prev_connector_id
                                     (Some conn.connector_id)))
                               && not
                                    (Runtime_store.String_map.mem
                                       conn.connector_id next_rt.connector_names)
                          ->
                            [
                              Cmd.Http_get
                                {
                                  epoch = m.epoch;
                                  req =
                                    Cmd.Get_connector_names
                                      {
                                        connector = conn.connector_id;
                                        scope = "channel";
                                      };
                                };
                            ]
                        | Some _ | None -> []
                      else []
                    in
                    ({ m with runtime = next_rt }, tab_cmds)
                | Nav.Infra ->
                    if
                      Nav.equal_infra_tab m.infra.active_tab
                        Nav.Infra_activity_logs
                      && m.infra.acting_rail_open && pane_index = 2
                    then
                      let count = List.length (acting_keepers m) in
                      let infra =
                        Infra_store.move_acting_selection ~count ~delta m.infra
                      in
                      ({ m with infra }, [])
                    else
                    let is_code_search_select =
                      Nav.equal_infra_tab m.infra.active_tab Nav.Infra_code
                      && pane_index = 1
                      && Infra_store.equal_code_right_mode
                           m.infra.code.right_mode
                           Infra_store.Code_search_results
                    in
                    let is_repos_diff_pane =
                      Nav.equal_infra_tab m.infra.active_tab
                        Nav.Infra_repos_changes
                      &&
                      let has_ch = Infra_store.repo_changes m.infra <> [] in
                      if has_ch then pane_index = 2 else pane_index = 1
                    in
                    let is_repos_changes_pane =
                      Nav.equal_infra_tab m.infra.active_tab
                        Nav.Infra_repos_changes
                      && pane_index = 1
                      && Infra_store.repo_changes m.infra <> []
                    in
                    let is_infra_detail_scroll =
                      is_repos_diff_pane
                      || (pane_index = 1
                         && (not is_code_search_select)
                         && not is_repos_changes_pane)
                    in
                    let eff_delta =
                      if is_infra_detail_scroll then scroll_delta dir else delta
                    in
                    let max_detail_scroll =
                      if is_infra_detail_scroll then
                        Some (infra_detail_max_scroll m)
                      else None
                    in
                    let prev_code_path =
                      Infra_store.active_code_file_path m.infra
                    in
                    let infra0 =
                      Infra_store.move_selection ~pane_index ~viewport_rows
                        ?max_detail_scroll ~delta:eff_delta m.infra
                    in
                    if
                      Nav.equal_infra_tab infra0.active_tab Nav.Infra_code
                      && pane_index = 0
                      && not
                           (Option.equal String.equal prev_code_path
                              (Infra_store.active_code_file_path infra0))
                    then
                      let next_m = { m with infra = infra0 } in
                      (next_m, View_fetches.fetches_for_current_view next_m)
                    else
                      follow_selected_repository { m with infra = infra0 })))
