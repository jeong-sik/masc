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

let contains_ci = Store_scroll.contains_ci
let clamp_index = Store_scroll.clamp_index

let fuzzy_score ~query target =
  let q = String.lowercase_ascii (String.trim query) in
  let q_len = String.length q in
  if q_len = 0 then Some 100
  else
    let t = String.lowercase_ascii target in
    let t_len = String.length t in
    if q_len > t_len then None
    else if String.equal q t then Some 1000
    else if String.starts_with ~prefix:q t then Some (800 - (t_len - q_len))
    else if contains_ci ~needle:q t then Some (500 - (t_len - q_len))
    else
      let rec match_seq qi ti score consecutive =
        if qi >= q_len then Some (Int.max 1 score)
        else if ti >= t_len then None
        else if Char.equal q.[qi] t.[ti] then
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
      {
        m with
        drafts =
          Drafts.set_current_text_and_cursor ~text:next_text ~cursor:next_cursor
            m.drafts;
      }

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
  | Pal_switch_workspace of Nav.workspace
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
  | Nav.Keeper_memory
  | Nav.Keeper_work_candle
  | Nav.Keeper_sandbox ->
      Config_store.cancel_edit_field config

let sync_fleet_for_keeper_tab ~name ~tab fleet =
  match tab with
  | Nav.Keeper_chat -> Fleet_store.mark_chat_history_loading ~keeper:name fleet
  | Nav.Keeper_memory
  | Nav.Keeper_work_candle
  | Nav.Keeper_sandbox
  | Nav.Keeper_config ->
      fleet

let sync_config_for_keeper_view (m : Model.t) =
  match m.nav.overlay with
  | Some (Nav.Settings _) -> m
  | Some
      ( Nav.Palette
      | Nav.Incidents
      | Nav.Queue_context _
      | Nav.Inline_action _
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
      | Some (Nav.Dive_work _ | Nav.Dive_knowledge _ | Nav.Dive_infra _) -> m
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
                else Knowledge_store.close_memory_reading m.knowledge
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
                knowledge = Knowledge_store.close_memory_reading m.knowledge;
              }
          | (Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Runtime | Nav.Infra), _ ->
              m))

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
      dive_scroll_offset = 0;
    }
  in
  let drafts = Drafts.set_focus false m.drafts in
  let config = Config_store.cancel_edit_field m.config in
  let knowledge = Knowledge_store.close_memory_reading m.knowledge in
  let next =
    { m with nav; drafts; config; knowledge; inline_modal = None }
    |> sync_config_for_keeper_view
  in
  (next, View_fetches.fetches_for_current_view next)

let open_overlay (m : Model.t) overlay =
  let help_scroll_offset =
    match overlay with
    | Nav.Help -> 0
    | Nav.Palette
    | Nav.Settings _
    | Nav.Incidents
    | Nav.Queue_context _
    | Nav.Inline_action _
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
    | Nav.Help
    | Nav.System_gate _ ->
        m.nav.queue_scroll_offset
  in
  let nav =
    {
      m.nav with
      overlay = Some overlay;
      filter_focused = false;
      help_scroll_offset;
      queue_scroll_offset;
    }
  in
  let drafts = Drafts.set_focus false m.drafts in
  let config =
    match overlay, m.config.target with
    | Nav.Settings _, Wire_config.Target_keeper_create -> m.config
    | ( ( Nav.Settings _
        | Nav.Palette
        | Nav.Incidents
        | Nav.Queue_context _
        | Nav.Inline_action _
        | Nav.Help
        | Nav.System_gate _ )
      , ( Wire_config.Target_runtime
        | Wire_config.Target_keeper _
        | Wire_config.Target_keeper_create ) ) ->
        Config_store.cancel_edit_field m.config
  in
  let next = { m with nav; drafts; config; inline_modal = None } in
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

let open_inline_modal (m : Model.t) kind =
  let modal = Model.inline_modal_for kind in
  let nav =
    { m.nav with overlay = Some (Nav.Inline_action kind); filter_focused = false }
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
      | Nav.Board_new_post )
      , ( Drafts.Btw_idle
        | Drafts.Btw_sending _
        | Drafts.Btw_streaming _
        | Drafts.Btw_answered _
        | Drafts.Btw_failed _ ) ->
        d0
  in
  let config = Config_store.cancel_edit_field m.config in
  ({ m with nav; drafts; config; inline_modal = Some modal }, [])

let open_palette (m : Model.t) mode =
  let palette = { Model.mode; query = ""; selected = 0 } in
  let nav = { m.nav with overlay = Some Nav.Palette; filter_focused = false } in
  let drafts = Drafts.set_focus false m.drafts in
  let config = Config_store.cancel_edit_field m.config in
  let next = { m with nav; drafts; config; palette; inline_modal = None } in
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

let push_dive (m : Model.t) dive =
  let nav =
    {
      m.nav with
      dive_stack = dive :: m.nav.dive_stack;
      overlay = None;
      pane_index = 0;
      zoomed = false;
      filter_focused = false;
      dive_scroll_offset = 0;
    }
  in
  let drafts =
    match dive with
    | Nav.Dive_keeper { name; _ } ->
        m.drafts |> Drafts.set_active_keeper name |> Drafts.set_focus false
    | Nav.Dive_work _ | Nav.Dive_knowledge _ | Nav.Dive_infra _ ->
        Drafts.set_focus false m.drafts
  in
  let fleet =
    match dive with
    | Nav.Dive_keeper { name; tab } ->
        m.fleet
        |> Fleet_store.select_keeper name
        |> Fleet_store.set_keeper_dive_tab tab
        |> sync_fleet_for_keeper_tab ~name ~tab
    | Nav.Dive_work _ | Nav.Dive_knowledge _ | Nav.Dive_infra _ -> m.fleet
  in
  let config =
    match dive with
    | Nav.Dive_keeper { name; tab } ->
        sync_config_for_keeper_tab ~name ~tab m.config
    | Nav.Dive_work _ | Nav.Dive_knowledge _ | Nav.Dive_infra _ ->
        Config_store.cancel_edit_field m.config
  in
  let knowledge =
    match dive with
    | Nav.Dive_keeper { name; tab = Nav.Keeper_memory } ->
        Knowledge_store.set_memory_diff_keeper (Some name) m.knowledge
    | Nav.Dive_knowledge (Nav.Memory_diff_dive { keeper; _ }) ->
        if Option.equal String.equal m.knowledge.memory_diff_keeper keeper then
          Knowledge_store.close_memory_reading m.knowledge
        else Knowledge_store.set_memory_diff_keeper keeper m.knowledge
    | Nav.Dive_keeper
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
    | Nav.Dive_infra _ ->
        Knowledge_store.close_memory_reading m.knowledge
  in
  let next =
    { m with nav; drafts; fleet; config; knowledge; inline_modal = None }
  in
  (next, View_fetches.fetches_for_current_view next)

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
      ( {
          m with
          nav =
            {
              m.nav with
              overlay = Some (Nav.Queue_context next_tab);
              queue_scroll_offset = 0;
            };
        }
      , [] )
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
                Knowledge_store.set_memory_diff_keeper (Some name) m.knowledge
            | Nav.Keeper_chat
            | Nav.Keeper_work_candle
            | Nav.Keeper_sandbox
            | Nav.Keeper_config ->
                Knowledge_store.close_memory_reading m.knowledge
          in
          let next = { m with nav; drafts; fleet; config; knowledge } in
          (next, View_fetches.fetches_for_current_view next)
      | (Nav.Dive_work _ | Nav.Dive_knowledge _ | Nav.Dive_infra _) :: _ ->
          (m, [])
      | [] -> (
          match m.nav.workspace with
          | Nav.Pulse -> (m, [])
          | Nav.Work ->
              let work = Work_store.cycle_tab dir m.work in
              let nav = { m.nav with pane_index = 0; zoomed = false } in
              let next = { m with nav; work } in
              (next, View_fetches.fetches_for_current_view next)
          | Nav.Knowledge ->
              let knowledge = Knowledge_store.cycle_tab dir m.knowledge in
              let nav = { m.nav with pane_index = 0; zoomed = false } in
              let next = { m with nav; knowledge } in
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
              let next = { m with nav; runtime } in
              (next, View_fetches.fetches_for_current_view next)
          | Nav.Infra ->
              let infra = Infra_store.cycle_tab dir m.infra in
              let nav = { m.nav with pane_index = 0; zoomed = false } in
              let next = { m with nav; infra } in
              (next, View_fetches.fetches_for_current_view next)))

let current_filter_query (m : Model.t) =
  match m.nav.overlay with
  | Some Nav.Incidents -> m.incidents.filter_query
  | Some (Nav.Settings _) -> m.config.search_query
  | Some
      ( Nav.Palette
      | Nav.Queue_context _
      | Nav.Inline_action _
      | Nav.Help
      | Nav.System_gate _ )
  | None ->
      if Model.is_keeper_config_active m then m.config.search_query
      else
        match m.nav.workspace with
        | Nav.Pulse | Nav.Keepers -> m.fleet.filter_query
        | Nav.Work -> m.work.filter_query
        | Nav.Knowledge -> m.knowledge.filter_query
        | Nav.Runtime -> m.runtime.filter_query
        | Nav.Infra -> m.infra.filter_query

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
        | Nav.Help
        | Nav.System_gate _ )
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
          | Nav.Infra -> { m with infra = Infra_store.set_filter q m.infra }
  in
  let max_pane = max 0 (Model.focusable_pane_count updated - 1) in
  if updated.nav.pane_index > max_pane then
    { updated with nav = { updated.nav with pane_index = max_pane } }
  else updated

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

let palette_entries (m : Model.t) : palette_entry list =
  let lang = m.lang in
  let q = String.trim m.palette.query in
  let fuzzy_opt s = fuzzy_score ~query:q s in
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
    Nav.all_workspaces
    |> List.filter_map (fun ws ->
           let lbl = Say.resolve lang (Nav.workspace_label ws) in
           let idx = Nav.workspace_index ws in
           let search_s = Printf.sprintf "%d %s" idx lbl in
           match fuzzy_opt search_s with
           | None -> None
           | Some _ ->
               Some
                 {
                   section = Pal_sec_workspaces;
                   badge = Printf.sprintf "[%d]" idx;
                   title = lbl;
                   meta =
                     Say.resolve lang
                       (Say.make ~ko:"워크스페이스" ~en:"Workspace");
                   tone = Some Theme.Status_ok;
                   action = Pal_switch_workspace ws;
                 })
    |> take_n (if String.equal q "" then 3 else 6)
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
    |> take_n (if String.equal q "" then 3 else 6)
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
    |> take_n (if String.equal q "" then 2 else 5)
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
    take_n (if String.equal q "" then 2 else 5) (goal_entries @ task_entries)
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
    take_n (if String.equal q "" then 2 else 5) (board_entries @ wiki_entries)
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
    take_n (if String.equal q "" then 2 else 4) items
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
    take_n (if String.equal q "" then 2 else 5) items
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
  cmd_entries @ ws_entries @ keeper_entries @ company_entries
  @ goals_tasks_entries @ board_wiki_entries @ sandbox_entries
  @ settings_entries @ slash_entries

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

let build_chat_submit_cmd (m : Model.t) (tx : Drafts.pending_message) ~is_btw =
  let mode =
    match tx.mode with
    | Drafts.Mode_direct | Drafts.Mode_follow_up -> Wire_fleet.Follow_up
    | Drafts.Mode_steer -> (
        match Fleet_store.chat_control_token_for ~keeper:tx.keeper m.fleet with
        | Some control_token ->
            let target =
              match Fleet_store.active_turn_for ~keeper:tx.keeper m.fleet with
              | Some turn -> Wire_fleet.Interrupt_turn_token turn.interrupt_token
              | None -> (
                  match
                    Fleet_store.String_map.find_opt tx.keeper
                      m.fleet.chat_streams
                  with
                  | Some s when s.active ->
                      Wire_fleet.Interrupt_operation_id
                        (Option.value s.operation_id ~default:s.request_id)
                  | Some _ | None -> Wire_fleet.Interrupt_none)
            in
            Wire_fleet.Steer { control_token; target }
        | None -> Wire_fleet.Follow_up)
  in
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
            filter_focused = false;
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

let actionable_approval_item (m : Model.t) =
  let on_work_inbox =
    Option.is_none m.nav.overlay
    && m.nav.dive_stack = []
    && Nav.equal_workspace m.nav.workspace Nav.Work
    && Nav.equal_work_tab m.work.active_tab Nav.Work_inbox
  in
  if on_work_inbox then
    match
      Attention.current_filtered_item ~query:m.work.filter_query m.attention
    with
    | Some e when not (Attention.is_in_flight ~id:e.id m.attention) -> Some e
    | Some _ | None -> None
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
      | Attention.Payload_ask ask -> submit_ask_choice ~now ask ~choice_1based:1 m
      | Attention.Payload_goal_confirmation g ->
          (* Goal completion confirmation requires exact server-issued proof run
             and operator credentials; never fabricate tokens from the strip. *)
          let next, cmds = push_dive m (Nav.Dive_work (Nav.Goal_dive g.id)) in
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:"목표 상세에서 검증 증명을 확인한 뒤 완료 확정하세요"
                 ~en:"Review verified proof in Goal Dive before confirming completion")
              next
          , cmds )
      | Attention.Payload_quarantine q ->
          let attention = Attention.mark_in_flight ~id:entry.id m.attention in
          let cmd =
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
              }
          in
          ({ m with attention }, [ cmd ]))

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
      | Attention.Payload_ask ask -> (
          match ask.questions with
          | [] -> (m, [])
          | q :: _ ->
              let attention = Attention.mark_in_flight ~id:entry.id m.attention in
              let cmd =
                Cmd.Http_post
                  {
                    epoch = m.epoch;
                    req =
                      Cmd.Post_ask_answer
                        {
                          keeper = ask.keeper;
                          ask_id = ask.ask_id;
                          answers = [ (q.question_id, Wire_work.Ask_skipped) ];
                        };
                  }
              in
              ({ m with attention }, [ cmd ]))
      | Attention.Payload_goal_confirmation g ->
          let next, cmds = push_dive m (Nav.Dive_work (Nav.Goal_dive g.id)) in
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:"목표 상세에서 보류·중단·거절을 진행하세요"
                 ~en:"Open Goal Dive to pause, block, or reject completion")
              next
          , cmds )
      | Attention.Payload_quarantine _ ->
          let query =
            if
              Nav.equal_workspace m.nav.workspace Nav.Work
              && Nav.equal_work_tab m.work.active_tab Nav.Work_inbox
            then m.work.filter_query
            else ""
          in
          let attention = Attention.move_triage ~query ~delta:1 m.attention in
          ( Model.with_toast ~now ~level:Model.Toast_info
              (Say.make ~ko:"격리 항목 건너뜀" ~en:"Skipped quarantine item")
              { m with attention }
          , [] ))

let teleport_blocked ~now (m : Model.t) =
  match Attention.top_fast_path m.attention with
  | None ->
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make ~ko:"즉시 조치가 필요한 항목이 없습니다"
             ~en:"No items currently awaiting operator action")
          m
      , [] )
  | Some entry -> (
      match entry.kind with
      | Health.Pending_ask _ | Health.Held_tool_approval _ ->
          let work = Work_store.set_tab Nav.Work_inbox m.work in
          switch_workspace { m with work } Nav.Work
      | Health.Goal_confirmation { goal_id } ->
          let work = Work_store.set_tab Nav.Work_pipeline m.work in
          let m1, cmds1 = switch_workspace { m with work } Nav.Work in
          let m2, cmds2 = push_dive m1 (Nav.Dive_work (Nav.Goal_dive goal_id)) in
          (m2, cmds1 @ cmds2)
      | Health.Board_quarantine _ ->
          let knowledge =
            Knowledge_store.set_tab Nav.Knowledge_board m.knowledge
          in
          switch_workspace { m with knowledge } Nav.Knowledge)

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
  | Drafts.Voice_transcribing | Drafts.Voice_speaking ->
      let drafts = Drafts.voice_set_off m.drafts in
      ({ m with drafts }, [ Cmd.Voice_cmd Cmd.Cancel_ptt ])

let dive_attention_entry (m : Model.t) (entry : Attention.entry) =
  match entry.payload with
  | Attention.Payload_goal_confirmation g ->
      push_dive m (Nav.Dive_work (Nav.Goal_dive g.id))
  | Attention.Payload_ask ask ->
      push_dive m (Nav.Dive_keeper { name = ask.keeper; tab = Nav.Keeper_chat })
  | Attention.Payload_tool_approval ta ->
      push_dive m (Nav.Dive_keeper { name = ta.keeper; tab = Nav.Keeper_chat })
  | Attention.Payload_gate g ->
      push_dive m (Nav.Dive_keeper { name = g.keeper; tab = Nav.Keeper_chat })
  | Attention.Payload_quarantine _ ->
      let knowledge =
        Knowledge_store.set_tab Nav.Knowledge_memory m.knowledge
      in
      switch_workspace { m with knowledge } Nav.Knowledge

let open_memory_reading_for ?(force_diff = false) ~keeper_opt (m : Model.t) =
  let k = m.knowledge in
  if Option.is_some k.memory_reading then (m, [])
  else
    let entry_opt =
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
                  match Observed.to_option k.keeper_memory_activity with
                  | Some act when String.equal act.keeper kp -> act.notes
                  | Some _ | None -> []
                in
                Some
                  (Knowledge_store.Reading_activity { keeper = kp; event; notes }))
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
                  (Knowledge_store.Reading_diff_item
                     { keeper = keeper_opt; item })
            | None -> None)
    in
    match entry_opt with
    | Some entry ->
        ({ m with knowledge = Knowledge_store.open_memory_reading entry k }, [])
    | None -> (m, [])

let dive_selected (m : Model.t) =
  (* Never push duplicate or cross-workspace dives when already inside a dive! *)
  match Model.active_dive m with
  | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_memory }) ->
      open_memory_reading_for ~keeper_opt:(Some name) m
  | Some (Nav.Dive_knowledge (Nav.Memory_diff_dive { keeper; _ })) ->
      open_memory_reading_for ~force_diff:true ~keeper_opt:keeper m
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
      (m, [])
  | None -> (
      match m.nav.workspace with
      | Nav.Pulse -> (
          match Model.active_pulse_pane m with
          | Model.Pulse_attention -> (
              match Attention.current_triage_item m.attention with
              | Some entry -> dive_attention_entry m entry
              | None -> (m, []))
          | Model.Pulse_companies -> (
              match Fleet_store.selected_company_keeper m.fleet with
              | Some k ->
                  push_dive m
                    (Nav.Dive_keeper
                       { name = k.name; tab = m.fleet.keeper_dive_tab })
              | None -> (m, []))
          | Model.Pulse_goals -> (
              match Work_store.selected_pulse_goal m.work with
              | Some g -> push_dive m (Nav.Dive_work (Nav.Goal_dive g.id))
              | None -> (m, []))
          | Model.Pulse_world -> (
              match Knowledge_store.selected_pulse_thread m.knowledge with
              | Some p -> push_dive m (Nav.Dive_knowledge (Nav.Thread_dive p.id))
              | None -> (m, [])))
      | Nav.Keepers -> (
          match Fleet_store.selected_keeper_summary m.fleet with
          | Some k ->
              if
                (m.nav.pane_index = 1 || m.nav.zoomed)
                && Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                     Nav.Keeper_memory
              then open_memory_reading_for ~keeper_opt:(Some k.name) m
              else
                push_dive m
                  (Nav.Dive_keeper
                     { name = k.name; tab = m.fleet.keeper_dive_tab })
          | None -> (m, []))
      | Nav.Work -> (
          match m.work.active_tab with
          | Nav.Work_pipeline -> (
              match m.nav.pane_index with
              | 1 when Model.work_pipeline_has_linked_card m -> (
                  match Work_store.selected_verification m.work with
                  | Some v ->
                      push_dive m
                        (Nav.Dive_work (Nav.Verification_dive v.request_id))
                  | None -> (m, []))
              | _ -> (
                  match Work_store.selected_goal m.work with
                  | Some g -> push_dive m (Nav.Dive_work (Nav.Goal_dive g.id))
                  | None -> (m, [])))
          | Nav.Work_tasks_schedules -> (
              match Work_store.selected_task m.work with
              | Some task -> push_dive m (Nav.Dive_work (Nav.Task_dive task.id))
              | None -> (m, []))
          | Nav.Work_inbox -> (
              match
                Attention.current_filtered_item ~query:m.work.filter_query
                  m.attention
              with
              | Some entry -> dive_attention_entry m entry
              | None -> (m, []))
          | Nav.Work_candle_scorecard -> (m, []))
      | Nav.Knowledge -> (
          match m.knowledge.active_tab with
          | Nav.Knowledge_board -> (
              match Knowledge_store.selected_post m.knowledge with
              | Some p -> push_dive m (Nav.Dive_knowledge (Nav.Thread_dive p.id))
              | None -> (m, []))
          | Nav.Knowledge_wiki_artifacts -> (
              match m.knowledge.wiki_artifacts_submode with
              | `Wiki -> (
                  match Knowledge_store.selected_wiki_page m.knowledge with
                  | Some p ->
                      push_dive m (Nav.Dive_knowledge (Nav.Wiki_dive p.slug))
                  | None -> (m, []))
              | `Artifacts -> (
                  match Knowledge_store.selected_artifact m.knowledge with
                  | Some a ->
                      push_dive m
                        (Nav.Dive_knowledge (Nav.Artifact_dive a.sha256))
                  | None -> (m, [])))
          | Nav.Knowledge_memory -> (
              let enter_diff_dive () =
                let rev_bounds =
                  match Observed.to_option m.knowledge.memory_diff with
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
                    push_dive m
                      (Nav.Dive_knowledge
                         (Nav.Memory_diff_dive
                            {
                              keeper = m.knowledge.memory_diff_keeper;
                              from_rev;
                              to_rev;
                            }))
                | None ->
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
              in
              if m.nav.pane_index = 1 || m.nav.zoomed then
                let opened, cmds =
                  open_memory_reading_for
                    ~keeper_opt:m.knowledge.memory_diff_keeper m
                in
                if Option.is_some opened.knowledge.memory_reading then
                  (opened, cmds)
                else enter_diff_dive ()
              else
                match Knowledge_store.selected_memory_left_row m.knowledge with
                | Some (Knowledge_store.Left_writer w) ->
                    let knowledge =
                      Knowledge_store.set_memory_diff_keeper (Some w.keeper)
                        m.knowledge
                    in
                    let next =
                      {
                        m with
                        nav = { m.nav with pane_index = 1 };
                        knowledge;
                      }
                    in
                    (next, View_fetches.fetches_for_current_view next)
                | Some Knowledge_store.Left_world_scope ->
                    let knowledge =
                      Knowledge_store.set_memory_diff_keeper None m.knowledge
                    in
                    let next =
                      {
                        m with
                        nav = { m.nav with pane_index = 1 };
                        knowledge;
                      }
                    in
                    (next, View_fetches.fetches_for_current_view next)
                | Some (Knowledge_store.Left_conflict _) | None ->
                    enter_diff_dive ()))
      | Nav.Runtime -> (
          match m.runtime.active_tab with
          | Nav.Runtime_quotas_credits ->
              if
                m.nav.pane_index = 1
                && Runtime_store.is_unreported_toggle_row_selected m.runtime
              then
                ( {
                    m with
                    runtime =
                      Runtime_store.toggle_unreported_accounts m.runtime;
                  }
                , [] )
              else (m, [])
          | Nav.Runtime_failover_lanes -> (
              match Runtime_store.selected_lane m.runtime with
              | Some lane -> push_dive m (Nav.Dive_infra (Nav.Lane_dive lane.id))
              | None -> (m, []))
          | Nav.Runtime_efficiency_spend -> (
              match Runtime_store.selected_keeper_spend_row m.runtime with
              | Some row ->
                  push_dive m
                    (Nav.Dive_keeper
                       { name = row.keeper; tab = Nav.Keeper_work_candle })
              | None -> (m, []))
          | Nav.Runtime_tools_connectors -> (m, []))
      | Nav.Infra -> (
          match m.infra.active_tab with
          | Nav.Infra_sandboxes -> (
              match Infra_store.selected_sandbox_keeper m.infra with
              | Some keeper ->
                  push_dive m (Nav.Dive_infra (Nav.Sandbox_dive keeper))
              | None -> (m, []))
          | Nav.Infra_repos_changes | Nav.Infra_activity_logs -> (m, [])))

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
    | Nav.Repo_add_form ) as std ->
      Form_standard std

let submit_inline_modal ~now (m : Model.t) =
  match m.inline_modal with
  | None -> (m, [])
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
          | Form_standard (Nav.Harness_overrule target_id) ->
              let reason = Model.modal_field_value ~key:"reason" modal in
              ( mark_submitting m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req = Cmd.Post_harness_overrule { target_id; reason };
                    };
                ] )
          | Form_standard (Nav.Task_cancel task_id) ->
              let reason_raw = Model.modal_field_value ~key:"reason" modal in
              let reason =
                if String.equal reason_raw "" then None else Some reason_raw
              in
              ( mark_submitting m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req = Cmd.Post_task_cancel { task_id; reason };
                    };
                ] )
          | Form_standard Nav.Schedule_form ->
              let keeper = Model.modal_field_value ~key:"keeper" modal in
              let recurrence = Model.modal_field_value ~key:"recurrence" modal in
              let prompt = Model.modal_field_value ~key:"prompt" modal in
              ( mark_submitting m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req =
                        Cmd.Post_schedule_create { keeper; recurrence; prompt };
                    };
                ] )
          | Form_standard Nav.Connector_form ->
              let connector = Model.modal_field_value ~key:"connector" modal in
              let channel = Model.modal_field_value ~key:"channel" modal in
              ( mark_submitting m
              , [
                  Cmd.Http_post
                    {
                      epoch = m.epoch;
                      req = Cmd.Post_connector_create { connector; channel };
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
              let expected_revision, expected_sha256, source, tags =
                match Observed.to_option m.knowledge.wiki_page with
                | Some detail when String.equal detail.slug slug ->
                    ( Some detail.frontmatter.revision
                    , Some detail.sha256
                    , detail.frontmatter.source
                    , detail.frontmatter.tags )
                | Some _ | None -> (
                    match Observed.to_option m.knowledge.wiki_index with
                    | Some idx -> (
                        match
                          List.find_opt
                            (fun (p : Wire_knowledge.wiki_page_summary) ->
                              String.equal p.slug slug)
                            idx.pages
                        with
                        | Some s ->
                            ( Some s.revision
                            , Some s.sha256
                            , s.source
                            , s.tags )
                        | None ->
                            (None, None, Wire_knowledge.Source_observation, []))
                    | None ->
                        (None, None, Wire_knowledge.Source_observation, []))
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
                  m
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
          | Nav.Work_tasks_schedules -> max 4 (rows - 18)
          | Nav.Work_inbox | Nav.Work_candle_scorecard -> max 4 (rows - 12))
      | Nav.Knowledge -> max 4 (rows - 14)
      | Nav.Runtime -> (
          match m.runtime.active_tab with
          | Nav.Runtime_efficiency_spend -> max 4 ((rows - 10) * 40 / 100)
          | Nav.Runtime_tools_connectors -> max 4 (rows - 21)
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
      match Observed.to_option inf.keeper_sandbox with
      | Some resp when String.equal resp.keeper keeper ->
          Some (sandbox_entry_info_of_detail ~sandboxes resp.sandbox)
      | Some _ | None -> None
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
    let content_h = max 1 inner_h in
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
        let txs = Drafts.pending_txs_for_keeper ~keeper m.drafts in
        let others = Drafts.other_keepers_draft_count m.drafts in
        1 + max 1 (List.length txs) + 1 + 1 + 1 + (if others > 0 then 1 else 0)
    | Nav.Drawer_schedules -> List.length (Work_store.schedules_list m.work)
    | Nav.Drawer_context -> 0
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
    let active_draft =
      match target_slug with
      | None -> k.wiki_edit_draft
      | Some want -> (
          match k.wiki_edit_draft with
          | Some d when String.equal d.slug want -> Some d
          | Some _ | None -> None)
    in
    match active_draft with
    | Some d ->
        let md_rect =
          Rect.make ~x:inner.x ~y:(inner.y + 1) ~w:inner.w
            ~h:(max 0 (inner.h - 1))
          |> ui_pad_content ~bp
        in
        markdown_max_scroll ~theme ~width:md_rect.w ~height:md_rect.h d.body
    | None -> (
        let page_detail =
          match Observed.to_option k.wiki_page with
          | Some d -> (
              match target_slug, sel_summary with
              | Some want, _ when String.equal d.slug want -> Some d
              | None, Some s when String.equal d.slug s.slug -> Some d
              | None, None -> Some d
              | Some _, _ | None, Some _ -> None)
          | None -> None
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

let memory_right_pane_max_scroll ~bp ~(rect : Rect.t)
    (k : Knowledge_store.t) =
  let inner = ui_card_inner rect in
  let content = ui_pad_content ~bp inner in
  if Rect.is_empty content then 0
  else
    match Observed.to_option k.memory_diff with
    | None -> 0
    | Some _ ->
        (* Matches draw_temporal_memory_diff (screen_knowledge.ml:2183-2317):
           Row 0 summary (1) + Stacked_bar (2 if y+1 < bottom, unconditionally
           for both Keeper_diff and World_diff) + OS line (1 if keeper matches)
           + divider (1). *)
        let y = ref 0 in
        let bottom = content.h in
        if !y < bottom then incr y;
        if !y + 1 < bottom then y := !y + 2;
        (match k.memory_diff_keeper, Observed.to_option k.memory_os_internals with
        | Some kp, Some intr when String.equal intr.keeper kp && !y < bottom ->
            incr y
        | Some _, Some _ | Some _, None | None, Some _ | None, None -> ());
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
  | Nav.Knowledge_wiki_artifacts -> (
      match k.wiki_artifacts_submode with
      | `Wiki ->
          let right_rect =
            if m.nav.zoomed then body_after_bar
            else
              snd
                (Masc_tui_ui.Layout.adaptive_split_2 ~stack_on_compact:true
                   ~left_ratio:0.38 ~top_ratio:0.48 bp body_after_bar)
          in
          wiki_preview_max_scroll ~bp ~theme ~rect:right_rect ~target_slug:None
            k
      | `Artifacts -> (
          match Knowledge_store.selected_artifact k with
          | None -> 0
          | Some a ->
              let _, right_rect =
                Masc_tui_ui.Layout.adaptive_split_2 ~stack_on_compact:true
                  ~left_ratio:0.56 ~top_ratio:0.54 bp body_after_bar
              in
              let inner = ui_card_inner right_rect in
              let band_h = if inner.h >= 7 then 2 else 1 in
              let content =
                Rect.make ~x:inner.x ~y:(inner.y + band_h) ~w:inner.w
                  ~h:(max 0 (inner.h - band_h))
                |> ui_pad_content ~bp
              in
              let content_h = max 1 content.h in
              let total_rows =
                2
                + (if Option.is_some a.producer then 1 else 0)
                + (if Option.is_some a.created_at_unix then 1 else 0)
                + 1
              in
              max 0 (total_rows - content_h)))
  | Nav.Knowledge_memory ->
      let right_rect =
        if m.nav.zoomed then body_after_bar
        else
          snd
            (Masc_tui_ui.Layout.adaptive_split_2 ~stack_on_compact:true
               ~left_ratio:0.48 ~top_ratio:0.48 bp body_after_bar)
      in
      memory_right_pane_max_scroll ~bp ~rect:right_rect k

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
                let choices_h =
                  match q_opt with
                  | Some q -> min 6 (List.length q.choices + 2)
                  | None -> 1
                in
                let md_h =
                  if avail_h = 0 then 0
                  else min avail_h (max 1 (avail_h - choices_h))
                in
                markdown_max_scroll ~theme ~width:w ~height:md_h prompt_md
            | Attention.Payload_goal_confirmation g ->
                let md_h = max 0 (avail_h - 3) in
                if md_h <= 0 then 0
                else
                  markdown_max_scroll ~theme ~width:w ~height:md_h
                    (Chat_transcript.rewrite_masc_links_for_markdown
                       (g.measure ^ "\n\n" ^ g.procedure))
            | Attention.Payload_quarantine _ -> 0))
  | Nav.Work_tasks_schedules | Nav.Work_candle_scorecard -> 0

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
  | Nav.Runtime_efficiency_spend | Nav.Runtime_tools_connectors -> 0

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
      match Infra_store.selected_repo_file_change m.infra with
      | Some fc -> (
          match fc.diff_preview with
          | Some dp when not (String.equal dp "") ->
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
                max 0 (List.length (Masc_tui_ui.Diff.parse_unified dp) - diff_h)
          | Some _ | None -> 0)
      | None -> 0)
  | Nav.Infra_activity_logs -> (
      match Infra_store.selected_log m.infra with
      | None -> 0
      | Some e ->
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
            else
              let max_msg_rows = min 6 (max 1 (content.h - 2)) in
              let msg_lines =
                Chat_transcript.wrap_plain_lines
                  ~width:(max 1 (content.w - 2))
                  e.message
              in
              let msg_n = min max_msg_rows (List.length msg_lines) in
              let tree_h = max 1 (content.h - msg_n - 1) in
              let total =
                List.length
                  (Masc_tui_ui.Json_tree.flatten ~max_depth:4
                     ~redact_secrets:true e.details)
              in
              max 0 (total - tree_h))

let keeper_tab_max_scroll ~embedded (m : Model.t) ~name ~tab =
  let content_w, content_h =
    Chat_transcript.keeper_content_rect_size ~embedded ~model:m
  in
  if content_w <= 0 || content_h <= 0 then 0
  else
    match tab with
    | Nav.Keeper_memory ->
        let footer_h = if content_h >= 7 then 2 else 0 in
        let body_h = max 0 (content_h - footer_h) in
        let hdr_rows =
          match Observed.to_option m.knowledge.memory_diff with
          | Some
              {
                scope = Wire_knowledge.Scope_keeper k;
                retrieval_heat = heat;
                body = Wire_knowledge.Keeper_diff _;
                _;
              }
            when String.equal k name ->
              let has_os =
                match Observed.to_option m.knowledge.memory_os_internals with
                | Some intr -> String.equal intr.keeper name
                | None -> false
              in
              let heat_total =
                heat.hot + heat.warm + heat.cold + heat.never_retrieved
              in
              let base = 2 + if has_os then 1 else 0 in
              let heat_rows =
                if heat_total > 0 && body_h - base >= 4 then 3 else 0
              in
              base + heat_rows
          | Some
              {
                scope = Wire_knowledge.Scope_world | Wire_knowledge.Scope_keeper _;
                body = Wire_knowledge.Keeper_diff _ | Wire_knowledge.World_diff _;
                _;
              }
          | None ->
              0
        in
        let vis_h = max 1 (body_h - hdr_rows) in
        let total =
          Knowledge_store.keeper_memory_diff_line_count ~name m.knowledge
        in
        max 0 (total - vis_h)
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
            (List.filter
               (fun (sc : Wire_work.schedule_row) ->
                 Option.equal String.equal sc.payload_keeper_name (Some name)
                 || Option.equal String.equal sc.payload_target (Some name))
               (Work_store.schedules_list m.work))
        in
        let n_posts =
          List.length
            (List.filter
               (fun (p : Wire_knowledge.board_post) -> String.equal p.author name)
               (Knowledge_store.filtered_posts m.knowledge))
        in
        let total_rows = 3 + max 1 n_tasks + max 1 n_scheds + max 1 n_posts in
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
    | Nav.Keeper_chat | Nav.Keeper_config -> 0

let memory_reading_max_scroll (m : Model.t) =
  match m.knowledge.memory_reading with
  | None -> 0
  | Some entry ->
      let bp = ui_bp m in
      let br = ui_body_rect m in
      let rect_w, rect_h =
        match Model.active_dive m with
        | Some (Nav.Dive_keeper { tab = Nav.Keeper_memory; _ }) ->
            let cw, ch =
              Chat_transcript.keeper_content_rect_size ~embedded:false ~model:m
            in
            let footer_h = if ch >= 7 then 2 else 0 in
            (cw, max 0 (ch - footer_h))
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
                    | Nav.Keeper_work_candle
                    | Nav.Keeper_sandbox
                    | Nav.Keeper_config );
                  _;
                }
            | Nav.Dive_work _
            | Nav.Dive_knowledge
                (Nav.Thread_dive _ | Nav.Wiki_dive _ | Nav.Artifact_dive _)
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
                let footer_h = if ch >= 7 then 2 else 0 in
                (cw, max 0 (ch - footer_h))
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

let dive_max_scroll (m : Model.t) active =
  let bp = ui_bp m in
  let br = ui_body_rect m in
  let theme = Theme.of_preset m.theme_preset in
  match active with
  | Nav.Dive_keeper { name; tab } ->
      keeper_tab_max_scroll ~embedded:false m ~name ~tab
  | Nav.Dive_knowledge (Nav.Memory_diff_dive { keeper; from_rev; to_rev }) ->
      let body_rect =
        match
          Masc_tui_ui.Layout.split_v br
            [ Masc_tui_ui.Layout.Fixed 1; Masc_tui_ui.Layout.Flex 1 ]
        with
        | [ _; b ] -> b
        | _ -> br
      in
      let right_rect =
        if m.nav.zoomed then body_rect
        else
          snd
            (Masc_tui_ui.Layout.adaptive_split_2 ~stack_on_compact:true
               ~left_ratio:0.48 ~top_ratio:0.48 bp body_rect)
      in
      let k_scoped =
        {
          m.knowledge with
          memory_diff_keeper = keeper;
          memory_diff_window = Knowledge_store.Window_revs { from_rev; to_rev };
        }
      in
      memory_right_pane_max_scroll ~bp ~rect:right_rect k_scoped
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
  | Nav.Dive_knowledge (Nav.Artifact_dive sha256) ->
      let inner = ui_card_inner br in
      let content = ui_pad_content ~bp inner in
      let artifacts =
        match Observed.to_option m.knowledge.artifacts with
        | Some xs -> xs
        | None -> []
      in
      let header_rows =
        match
          List.find_opt
            (fun (a : Wire_knowledge.artifact_entry) ->
              String.equal a.sha256 sha256)
            artifacts
        with
        | None -> 0
        | Some a ->
            5
            + (if Option.is_some a.title then 1 else 0)
            + (if Option.is_some a.producer then 1 else 0)
      in
      if artifacts = [] || header_rows + 1 >= content.h then 0
      else
        let rev_vis_h = max 1 (content.h - header_rows - 1) in
        max 0 (List.length artifacts - rev_vis_h)
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
                2 + if Option.is_some v.review_observation then 1 else 0
              in
              y := min body_bot (!y + kv_rows);
              let rest =
                Rect.make ~x:content.x ~y:!y ~w:content.w
                  ~h:(max 0 (body_bot - !y))
              in
              let chk_r, diff_r =
                match
                  Masc_tui_ui.Layout.split_v ~gap:0 rest
                    [ Masc_tui_ui.Layout.Ratio 0.44; Masc_tui_ui.Layout.Flex 1 ]
                with
                | [ a; b ] -> (a, b)
                | _ -> (rest, Rect.empty)
              in
              let chk_max =
                if Rect.is_empty chk_r then 0
                else
                  let chk_body_h = max 0 (chk_r.h - 1) in
                  if chk_body_h <= 0 then 0
                  else max 0 (evidence_checklist_row_count v - chk_body_h)
              in
              let diff_max =
                if Rect.is_empty diff_r then 0
                else
                  let dr_h = max 0 (diff_r.h - 1) in
                  if dr_h <= 0 then 0
                  else max 0 (rejection_diff_row_count ~lang:m.lang v - dr_h)
              in
              max chk_max diff_max
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
            max detail_max log_max)

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
        ({ m with palette = { m.palette with selected } }, [])
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
                  | Nav.Board_new_post )
                , _ ) ->
                  true
            in
            if not editable then (m, [])
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
              ({ m with inline_modal = Some next_modal }, []))
    | Some (Nav.Queue_context tab) -> (
        match dir with
        | Keymap.Left -> cycle_sub_tab m Keymap.Prev
        | Keymap.Right -> cycle_sub_tab m Keymap.Next
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
    | Some (Nav.System_gate _) -> (m, [])
    | None -> (
        match dir with
        | Keymap.Left -> cycle_sub_tab m Keymap.Prev
        | Keymap.Right -> cycle_sub_tab m Keymap.Next
        | Keymap.Up | Keymap.Down | Keymap.Page_up | Keymap.Page_down
        | Keymap.Home | Keymap.End -> (
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
            | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_config }) ->
                move_keeper_config_selection ~embedded:false ~name
                  ~delta:(move_delta dir) m
            | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_memory }) ->
                let has_matching_reading =
                  match m.knowledge.memory_reading with
                  | Some entry ->
                      Knowledge_store.memory_reading_matches_scope
                        ~keeper_opt:(Some name) entry
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
            | Some (Nav.Dive_knowledge (Nav.Memory_diff_dive { keeper; _ }) as active)
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
                    Knowledge_store.move_memory_diff_cursor
                      ~delta:(move_delta dir) m.knowledge
                  in
                  ( { m with nav = { m.nav with dive_scroll_offset }; knowledge }
                  , [] )
            | Some
                (( Nav.Dive_keeper
                     {
                       tab = (Nav.Keeper_work_candle | Nav.Keeper_sandbox);
                       _;
                     }
                 | Nav.Dive_work _
                 | Nav.Dive_knowledge
                     (Nav.Thread_dive _ | Nav.Wiki_dive _ | Nav.Artifact_dive _)
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
                          | Nav.Keeper_config ->
                              move_keeper_config_selection ~embedded
                                ~name:k.name ~delta:(move_delta dir) m
                          | Nav.Keeper_memory ->
                              let has_matching_reading =
                                match m.knowledge.memory_reading with
                                | Some entry ->
                                    Knowledge_store.memory_reading_matches_scope
                                      ~keeper_opt:(Some k.name) entry
                                | None -> false
                              in
                              if has_matching_reading then
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
                                    | Attention.Payload_goal_confirmation _
                                    | Attention.Payload_quarantine _ );
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
                    | Nav.Work_tasks_schedules ->
                        let work =
                          Work_store.move_selection ~pane_index ~viewport_rows
                            ~delta m.work
                        in
                        let n_tasks = List.length (Work_store.filtered_tasks work) in
                        let n_sched =
                          List.length (Work_store.filtered_schedules work)
                        in
                        let next_pane =
                          if
                            Model.focusable_pane_count m >= 2
                            && n_sched > 0
                            && work.selected_index >= n_tasks
                          then 1
                          else 0
                        in
                        ({ m with nav = { m.nav with pane_index = next_pane }; work }, [])
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
                        ( {
                            m with
                            work =
                              Work_store.move_selection ~pane_index
                                ~viewport_rows ~delta m.work;
                          }
                        , [] ))
                | Nav.Knowledge ->
                    let eff_pane =
                      if m.nav.zoomed && Model.can_zoom_current_view m then 1
                      else pane_index
                    in
                    let prev_slug =
                      match Knowledge_store.selected_wiki_page m.knowledge with
                      | Some p -> Some p.slug
                      | None -> None
                    in
                    let prev_mem_keeper = m.knowledge.memory_diff_keeper in
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
                      && (not has_matching_reading)
                      && Option.is_some m.knowledge.memory_diff_keeper
                      &&
                      match m.knowledge.memory_view_mode with
                      | Knowledge_store.View_evolution
                      | Knowledge_store.View_facts ->
                          true
                      | Knowledge_store.View_diff -> false
                    in
                    let eff_delta =
                      if eff_pane = 1 && not is_memory_list_cursor then
                        scroll_delta dir
                      else delta
                    in
                    let max_detail_scroll =
                      if eff_pane = 1 then
                        if has_matching_reading then
                          Some (memory_reading_max_scroll m)
                        else Some (knowledge_detail_max_scroll m)
                      else None
                    in
                    let knowledge =
                      Knowledge_store.move_selection ~pane_index:eff_pane
                        ~viewport_rows ?max_detail_scroll ~delta:eff_delta
                        m.knowledge
                    in
                    let next = { m with knowledge } in
                    let nav_cmds =
                      match
                        knowledge.active_tab
                      , knowledge.wiki_artifacts_submode
                      , eff_pane
                      with
                      | Nav.Knowledge_wiki_artifacts, `Wiki, 0 -> (
                          match Knowledge_store.selected_wiki_page knowledge with
                          | Some p ->
                              let loaded_matches =
                                match Observed.to_option knowledge.wiki_page with
                                | Some d -> String.equal d.slug p.slug
                                | None -> false
                              in
                              if
                                (not
                                   (Option.equal String.equal prev_slug
                                      (Some p.slug)))
                                || not loaded_matches
                              then
                                [
                                  Cmd.Http_get
                                    {
                                      epoch = m.epoch;
                                      req = Cmd.Get_wiki_page { page = p.slug };
                                    };
                                ]
                              else []
                          | None -> [])
                      | Nav.Knowledge_memory, _, 0 ->
                          if
                            not
                              (Option.equal String.equal prev_mem_keeper
                                 knowledge.memory_diff_keeper)
                          then View_fetches.fetches_for_current_view next
                          else []
                      | Nav.Knowledge_wiki_artifacts, `Wiki, _
                      | Nav.Knowledge_wiki_artifacts, `Artifacts, _
                      | Nav.Knowledge_board, _, _
                      | Nav.Knowledge_memory, _, _ ->
                          []
                    in
                    (next, nav_cmds)
                | Nav.Runtime ->
                    let rt = sync_runtime_companies_if_needed m in
                    let is_detail_scroll =
                      match rt.active_tab, pane_index with
                      | Nav.Runtime_quotas_credits, 0
                      | Nav.Runtime_failover_lanes, 1 ->
                          true
                      | ( ( Nav.Runtime_quotas_credits
                          | Nav.Runtime_efficiency_spend
                          | Nav.Runtime_failover_lanes
                          | Nav.Runtime_tools_connectors )
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
                      | ( ( Nav.Runtime_quotas_credits
                          | Nav.Runtime_efficiency_spend
                          | Nav.Runtime_failover_lanes
                          | Nav.Runtime_tools_connectors )
                        , _ ) ->
                          viewport_rows
                    in
                    ( {
                        m with
                        runtime =
                          Runtime_store.move_selection ~pane_index
                            ~viewport_rows:eff_viewport_rows ?max_detail_scroll
                            ~delta:eff_delta rt;
                      }
                    , [] )
                | Nav.Infra ->
                    let prev_repo = Infra_store.selected_repository m.infra in
                    let eff_delta =
                      if pane_index = 1 then scroll_delta dir else delta
                    in
                    let max_detail_scroll =
                      if pane_index = 1 then Some (infra_detail_max_scroll m)
                      else None
                    in
                    let infra0 =
                      Infra_store.move_selection ~pane_index ~viewport_rows
                        ?max_detail_scroll ~delta:eff_delta m.infra
                    in
                    let infra, cmds =
                      if
                        Nav.equal_infra_tab infra0.active_tab
                          Nav.Infra_repos_changes
                        && pane_index = 0
                      then
                        match
                          (prev_repo, Infra_store.selected_repository infra0)
                        with
                        | prev, Some cur
                          when not
                                 (Option.equal
                                    (fun (a : Wire_infra.repository) b ->
                                      String.equal a.id b.id)
                                    prev (Some cur)) -> (
                            match cur.keepers with
                            | keeper :: _ ->
                                let infra1 =
                                  if
                                    Option.equal String.equal
                                      infra0.file_changes_keeper (Some keeper)
                                  then infra0
                                  else
                                    infra0 |> Infra_store.clear_file_changes
                                    |> Infra_store.mark_file_changes_requested
                                         ~keeper
                                in
                                ( infra1
                                , [
                                    Cmd.Http_get
                                      {
                                        epoch = m.epoch;
                                        req =
                                          Cmd.Get_file_changes
                                            { keeper; window_hours = Some 24.0 };
                                      };
                                  ] )
                            | [] -> (Infra_store.clear_file_changes infra0, []))
                        | Some _, Some _
                        | None, Some _
                        | Some _, None
                        | None, None ->
                            (infra0, [])
                      else (infra0, [])
                    in
                    ({ m with infra }, cmds))))
