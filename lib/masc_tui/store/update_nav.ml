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
      config

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
          { m with config = sync_config_for_keeper_tab ~name ~tab m.config }
      | Some (Nav.Dive_work _ | Nav.Dive_knowledge _ | Nav.Dive_infra _) -> m
      | None -> (
          match m.nav.workspace, Fleet_store.selected_keeper_summary m.fleet with
          | Nav.Keepers, Some k ->
              {
                m with
                config =
                  sync_config_for_keeper_tab ~name:k.name
                    ~tab:m.fleet.keeper_dive_tab m.config;
              }
          | Nav.Keepers, None
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
  let next =
    { m with nav; drafts; inline_modal = None } |> sync_config_for_keeper_view
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
  let nav =
    {
      m.nav with
      overlay = Some overlay;
      filter_focused = false;
      help_scroll_offset;
    }
  in
  let drafts = Drafts.set_focus false m.drafts in
  let next = { m with nav; drafts; inline_modal = None } in
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
  ({ m with nav; drafts; inline_modal = Some modal }, [])

let open_palette (m : Model.t) mode =
  let palette = { Model.mode; query = ""; selected = 0 } in
  let nav = { m.nav with overlay = Some Nav.Palette; filter_focused = false } in
  let drafts = Drafts.set_focus false m.drafts in
  let next = { m with nav; drafts; palette; inline_modal = None } in
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
    | Nav.Dive_work _ | Nav.Dive_knowledge _ | Nav.Dive_infra _ -> m.fleet
  in
  let config =
    match dive with
    | Nav.Dive_keeper { name; tab } ->
        sync_config_for_keeper_tab ~name ~tab m.config
    | Nav.Dive_work _ | Nav.Dive_knowledge _ | Nav.Dive_infra _ -> m.config
  in
  let next = { m with nav; drafts; fleet; config; inline_modal = None } in
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
      ( { m with nav = { m.nav with overlay = Some (Nav.Queue_context next_tab) } }
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
          let fleet = Fleet_store.set_keeper_dive_tab next_tab m.fleet in
          let config =
            sync_config_for_keeper_tab ~name ~tab:next_tab m.config
          in
          let next = { m with nav; drafts; fleet; config } in
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
              if m.nav.pane_index = 1 then
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
  | None -> (
      match Model.active_dive m with
      | Some (Nav.Dive_keeper { tab = Nav.Keeper_config; _ }) ->
          m.config.search_query
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
      | None -> (
          match m.nav.workspace with
          | Nav.Pulse | Nav.Keepers -> m.fleet.filter_query
          | Nav.Work -> m.work.filter_query
          | Nav.Knowledge -> m.knowledge.filter_query
          | Nav.Runtime -> m.runtime.filter_query
          | Nav.Infra -> m.infra.filter_query))

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
    | None -> (
        match Model.active_dive m with
        | Some (Nav.Dive_keeper { tab = Nav.Keeper_config; _ }) ->
            {
              m with
              nav = { m.nav with dive_scroll_offset = 0 };
              config = Config_store.set_search_query q m.config;
            }
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
        | None -> (
            match m.nav.workspace with
            | Nav.Pulse | Nav.Keepers ->
                { m with fleet = Fleet_store.set_filter q m.fleet }
            | Nav.Work -> { m with work = Work_store.set_filter q m.work }
            | Nav.Knowledge ->
                { m with knowledge = Knowledge_store.set_filter q m.knowledge }
            | Nav.Runtime ->
                { m with runtime = Runtime_store.set_filter q m.runtime }
            | Nav.Infra -> { m with infra = Infra_store.set_filter q m.infra }))
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
    | Drafts.Mode_follow_up -> Wire_fleet.Follow_up
    | Drafts.Mode_steer -> (
        match Fleet_store.chat_control_token_for ~keeper:tx.keeper m.fleet with
        | Some control_token ->
            let target =
              match Fleet_store.active_turn_for ~keeper:tx.keeper m.fleet with
              | Some turn -> Wire_fleet.Interrupt_turn_token turn.interrupt_token
              | None -> Wire_fleet.Interrupt_none
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

let dive_selected (m : Model.t) =
  (* Never push duplicate or cross-workspace dives when already inside a dive! *)
  match Model.active_dive m with
  | Some _ -> (m, [])
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
                    ] )))
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
  | Keymap.End -> 80
  | Keymap.Left | Keymap.Right -> 0

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
              {
                m with
                work =
                  Work_store.move_selection ~pane_index
                    ~has_linked_card:(Model.work_pipeline_has_linked_card m)
                    ~viewport_rows ~delta:0 m.work;
              }
          | Nav.Runtime ->
              let rt = sync_runtime_companies_if_needed m in
              {
                m with
                runtime =
                  Runtime_store.move_selection ~pane_index ~viewport_rows
                    ~delta:0 rt;
              }
          | Nav.Knowledge ->
              {
                m with
                knowledge =
                  Knowledge_store.move_selection ~pane_index ~viewport_rows
                    ~delta:0 m.knowledge;
              }
          | Nav.Infra ->
              {
                m with
                infra =
                  Infra_store.move_selection ~pane_index ~viewport_rows ~delta:0
                    m.infra;
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
    | Some (Nav.Queue_context _) -> (
        match dir with
        | Keymap.Left -> cycle_sub_tab m Keymap.Prev
        | Keymap.Right -> cycle_sub_tab m Keymap.Next
        | Keymap.Up | Keymap.Down | Keymap.Page_up | Keymap.Page_down
        | Keymap.Home | Keymap.End ->
            (m, []))
    | Some Nav.Help ->
        let delta = scroll_delta dir in
        let help_scroll_offset =
          Store_scroll.clamp_scroll ~max_scroll:60
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
                  Chat_transcript.max_scroll_for_model ~model:m ~keeper:name
                in
                ( {
                    m with
                    fleet =
                      Fleet_store.move_chat_scroll ~max_scroll ~delta m.fleet;
                  }
                , [] )
            | Some
                (( Nav.Dive_keeper
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
                 | Nav.Dive_infra _ ) as active) ->
                let delta = scroll_delta dir in
                let max_scroll =
                  match active with
                  | Nav.Dive_keeper { tab = Nav.Keeper_config; _ } ->
                      max 0
                        (List.length (Config_store.visible_fields m.config) - 1)
                  | Nav.Dive_knowledge (Nav.Memory_diff_dive _) ->
                      max 0
                        (Knowledge_store.memory_diff_entry_count m.knowledge - 1)
                  | Nav.Dive_keeper
                      {
                        tab =
                          ( Nav.Keeper_chat
                          | Nav.Keeper_memory
                          | Nav.Keeper_work_candle
                          | Nav.Keeper_sandbox );
                        _;
                      }
                  | Nav.Dive_work _
                  | Nav.Dive_knowledge
                      (Nav.Thread_dive _ | Nav.Wiki_dive _ | Nav.Artifact_dive _)
                  | Nav.Dive_infra _ ->
                      160
                in
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
                    if pane_index = 1 then
                      if
                        Nav.equal_keeper_tab m.fleet.keeper_dive_tab
                          Nav.Keeper_chat
                      then
                        match Fleet_store.selected_keeper_summary m.fleet with
                        | None -> (m, [])
                        | Some k ->
                            let chat_delta = -(move_delta dir) in
                            let max_scroll =
                              Chat_transcript.max_scroll_for_model ~model:m
                                ~keeper:k.name
                            in
                            ( {
                                m with
                                fleet =
                                  Fleet_store.move_chat_scroll ~max_scroll
                                    ~delta:chat_delta m.fleet;
                              }
                            , [] )
                      else
                        let sd = scroll_delta dir in
                        let max_scroll =
                          match m.fleet.keeper_dive_tab with
                          | Nav.Keeper_config ->
                              max 0
                                (List.length
                                   (Config_store.visible_fields m.config)
                                 - 1)
                          | Nav.Keeper_chat
                          | Nav.Keeper_memory
                          | Nav.Keeper_work_candle
                          | Nav.Keeper_sandbox ->
                              160
                        in
                        let dive_scroll_offset =
                          Store_scroll.clamp_scroll ~max_scroll
                            (m.nav.dive_scroll_offset + sd)
                        in
                        ({ m with nav = { m.nav with dive_scroll_offset } }, [])
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
                          ( {
                              m with
                              work =
                                Work_store.move_selection ~pane_index:1
                                  ~viewport_rows ~delta:sd m.work;
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
                        let eff_delta =
                          if
                            pane_index = 2
                            || (pane_index = 1 && not has_linked_card)
                          then scroll_delta dir
                          else delta
                        in
                        ( {
                            m with
                            work =
                              Work_store.move_selection ~pane_index
                                ~has_linked_card ~viewport_rows ~delta:eff_delta
                                m.work;
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
                    let prev_slug =
                      match Knowledge_store.selected_wiki_page m.knowledge with
                      | Some p -> Some p.slug
                      | None -> None
                    in
                    let eff_delta =
                      if pane_index = 1 then scroll_delta dir else delta
                    in
                    let knowledge =
                      Knowledge_store.move_selection ~pane_index ~viewport_rows
                        ~delta:eff_delta m.knowledge
                    in
                    let next = { m with knowledge } in
                    let wiki_cmds =
                      match
                        knowledge.active_tab
                      , knowledge.wiki_artifacts_submode
                      , pane_index
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
                      | Nav.Knowledge_wiki_artifacts, `Wiki, _
                      | Nav.Knowledge_wiki_artifacts, `Artifacts, _
                      | (Nav.Knowledge_board | Nav.Knowledge_memory), _, _ ->
                          []
                    in
                    (next, wiki_cmds)
                | Nav.Runtime ->
                    let rt = sync_runtime_companies_if_needed m in
                    let eff_delta =
                      match rt.active_tab, pane_index with
                      | Nav.Runtime_quotas_credits, 0
                      | Nav.Runtime_failover_lanes, 1 ->
                          scroll_delta dir
                      | ( ( Nav.Runtime_quotas_credits
                          | Nav.Runtime_efficiency_spend
                          | Nav.Runtime_failover_lanes
                          | Nav.Runtime_tools_connectors )
                        , _ ) ->
                          delta
                    in
                    ( {
                        m with
                        runtime =
                          Runtime_store.move_selection ~pane_index
                            ~viewport_rows ~delta:eff_delta rt;
                      }
                    , [] )
                | Nav.Infra ->
                    let prev_repo = Infra_store.selected_repository m.infra in
                    let eff_delta =
                      if pane_index = 1 then scroll_delta dir else delta
                    in
                    let infra0 =
                      Infra_store.move_selection ~pane_index ~viewport_rows
                        ~delta:eff_delta m.infra
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
