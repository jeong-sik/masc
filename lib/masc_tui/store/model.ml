open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

type viewport = {
  cols : int;
  rows : int;
}

type breakpoint =
  | Wide
  | Standard
  | Compact
  | Micro

type composer_mode =
  | Auto_folded_pill
  | Collapsed_bar
  | Expanded_multiline

type nav_state = {
  workspace : Nav.workspace;
  dive_stack : Nav.dive list;
  overlay : Nav.overlay option;
  pane_index : int;
  pre_zoom_pane_index : int option;
  zoomed : bool;
  filter_focused : bool;
  sidebar_open : bool option;
  sidebar_focused : bool;
  sidebar_cursor : int;
  sidebar_scroll : int;
  dive_scroll_offset : int;
  help_scroll_offset : int;
  queue_scroll_offset : int;
  btw_scroll_offset : int;
  palette_scroll_offset : int;
  modal_edit_cursor : int;
  return_overlay : Nav.overlay option;
}

type pulse_pane =
  | Pulse_attention
  | Pulse_companies
  | Pulse_goals
  | Pulse_world

type freshness_state = {
  observer : Health.source_freshness;
  fleet : Health.source_freshness;
  view_stream : Health.source_freshness option;
  last_observer_cursor : int option;
  last_wall_unix : float;
  last_mono : Clock.Mono.t;
  server_offline : bool;
}

type view_ssot_mode =
  | Live_sse of {
      stream_name : string;
      freshness : Health.source_freshness;
      live_count : int;
      planned_count : int;
    }
  | Synced_snapshot of {
      observer : Health.source_freshness;
      observed_at : Clock.Mono.t option;
    }
  | Snapshot_only of { observed_at : Clock.Mono.t option }

type mismatch_state =
  | Mismatch_none
  | Mismatch_recovering
  | Mismatch_halted

type server_identity = {
  health : Wire_common.server_health option;
  workspace : Wire_common.workspace_identity option;
  observer_instance_id : string option;
  observer_version : string option;
  observer_commit : string option;
  mismatch_state : mismatch_state;
  last_mismatch_epoch : Epoch.t option;
  autostart_attempted : bool;
}

type palette_mode =
  | Palette_commands
  | Palette_keepers
  | Palette_models

type palette_state = {
  mode : palette_mode;
  query : string;
  selected : int;
}

type modal_form_field = {
  key : string;
  label : Say.t;
  value : string;
  required : bool;
  secret : bool;
}

type inline_modal_state = {
  kind : Nav.inline_action_kind;
  fields : modal_form_field list;
  active_field : int;
  submitting : bool;
  error : string option;
}

module Ask_draft_key = struct
  type t = string * string

  let compare (a1, q1) (a2, q2) =
    let c = String.compare a1 a2 in
    if c <> 0 then c else String.compare q1 q2
end

module Ask_draft_map = Map.Make (Ask_draft_key)

type ask_answer_mode =
  | Ask_mode_unanswered
  | Ask_mode_choices
  | Ask_mode_free_text
  | Ask_mode_skipped

type ask_question_draft = {
  choice_ids : string list;
  free_text : string;
  free_text_cursor : int;
  mode : ask_answer_mode;
}

type ask_modal_row =
  | Ask_row_choice of int * Wire_work.ask_choice
  | Ask_row_free_text
  | Ask_row_skip

type ask_live_status =
  | Ask_live_open
  | Ask_live_in_flight
  | Ask_live_closed

type ask_modal = {
  ask : Wire_work.ask_row;
  question_idx : int;
  cursor : int;
  prompt_scroll : int;
  per_question : ask_question_draft Ask_draft_map.t;
  editing_free_text : bool;
  submitting : bool;
  error : Say.t option;
}

type toast_level =
  | Toast_info
  | Toast_success
  | Toast_warning
  | Toast_error

type toast = {
  message : Say.t;
  level : toast_level;
  expires_at : Clock.Mono.t;
}

type t = {
  epoch : Epoch.t;
  viewport : viewport;
  breakpoint : breakpoint;
  lang : Say.lang;
  theme_preset : Theme.preset;
  cli_lang_override : bool;
  cli_theme_override : bool;
  tz_offset_sec : int;
  tui_version : string;
  tui_commit : string option;
  nav : nav_state;
  freshness : freshness_state;
  server_identity : server_identity;
  attention : Attention.t;
  incidents : Incidents.t;
  drafts : Drafts.t;
  fleet : Fleet_store.t;
  keeper_context : Keeper_context_store.t;
  work : Work_store.t;
  knowledge : Knowledge_store.t;
  runtime : Runtime_store.t;
  infra : Infra_store.t;
  config : Config_store.t;
  palette : palette_state;
  inline_modal : inline_modal_state option;
  ask_modal : ask_modal option;
  toast : toast option;
}

let equal_breakpoint a b =
  match a, b with
  | Wide, Wide | Standard, Standard | Compact, Compact | Micro, Micro -> true
  | Wide, (Standard | Compact | Micro)
  | Standard, (Wide | Compact | Micro)
  | Compact, (Wide | Standard | Micro)
  | Micro, (Wide | Standard | Compact) ->
      false

let equal_composer_mode a b =
  match a, b with
  | Auto_folded_pill, Auto_folded_pill
  | Collapsed_bar, Collapsed_bar
  | Expanded_multiline, Expanded_multiline ->
      true
  | Auto_folded_pill, (Collapsed_bar | Expanded_multiline)
  | Collapsed_bar, (Auto_folded_pill | Expanded_multiline)
  | Expanded_multiline, (Auto_folded_pill | Collapsed_bar) ->
      false

let equal_palette_mode a b =
  match a, b with
  | Palette_commands, Palette_commands
  | Palette_keepers, Palette_keepers
  | Palette_models, Palette_models ->
      true
  | Palette_commands, (Palette_keepers | Palette_models)
  | Palette_keepers, (Palette_commands | Palette_models)
  | Palette_models, (Palette_commands | Palette_keepers) ->
      false

let equal_mismatch_state a b =
  match a, b with
  | Mismatch_none, Mismatch_none
  | Mismatch_recovering, Mismatch_recovering
  | Mismatch_halted, Mismatch_halted ->
      true
  | Mismatch_none, (Mismatch_recovering | Mismatch_halted)
  | Mismatch_recovering, (Mismatch_none | Mismatch_halted)
  | Mismatch_halted, (Mismatch_none | Mismatch_recovering) ->
      false

let equal_pulse_pane a b =
  match a, b with
  | Pulse_attention, Pulse_attention
  | Pulse_companies, Pulse_companies
  | Pulse_goals, Pulse_goals
  | Pulse_world, Pulse_world ->
      true
  | Pulse_attention, (Pulse_companies | Pulse_goals | Pulse_world)
  | Pulse_companies, (Pulse_attention | Pulse_goals | Pulse_world)
  | Pulse_goals, (Pulse_attention | Pulse_companies | Pulse_world)
  | Pulse_world, (Pulse_attention | Pulse_companies | Pulse_goals) ->
      false

let classify_viewport { cols; rows } =
  if cols >= 140 && rows >= 36 then Wide
  else if cols >= 100 && rows >= 28 then Standard
  else if cols >= 80 && rows >= 24 then Compact
  else Micro

let is_too_small_viewport { cols; rows } = cols < 40 || rows < 12

let initial ?(cols = 140) ?(rows = 40) ?(lang = Say.Lang_ko)
    ?(theme_preset = Theme.Midnight) ?(cli_lang_override = false)
    ?(cli_theme_override = false) ?(tz_offset_sec = 0) ?(wall_unix = 0.0)
    ?(tui_version = "") ?(tui_commit = None) () =
  let viewport = { cols = max 0 cols; rows = max 0 rows } in
  let breakpoint = classify_viewport viewport in
  let last_wall_unix =
    if Float.is_finite wall_unix && wall_unix > 0.0 then wall_unix else 0.0
  in
  {
    epoch = Epoch.initial;
    viewport;
    breakpoint;
    lang;
    theme_preset;
    cli_lang_override;
    cli_theme_override;
    tz_offset_sec;
    tui_version;
    tui_commit;
    nav =
      {
        workspace = Nav.Pulse;
        dive_stack = [];
        overlay = None;
        pane_index = 0;
        pre_zoom_pane_index = None;
        zoomed = false;
        filter_focused = false;
        sidebar_open = None;
        sidebar_focused = false;
        sidebar_cursor = 0;
        sidebar_scroll = 0;
        dive_scroll_offset = 0;
        help_scroll_offset = 0;
        queue_scroll_offset = 0;
        btw_scroll_offset = 0;
        palette_scroll_offset = 0;
        modal_edit_cursor = 0;
        return_overlay = None;
      };
    freshness =
      {
        observer = Health.Connecting;
        fleet = Health.Connecting;
        view_stream = None;
        last_observer_cursor = None;
        last_wall_unix;
        last_mono = Clock.Mono.zero;
        server_offline = false;
      };
    server_identity =
      {
        health = None;
        workspace = None;
        observer_instance_id = None;
        observer_version = None;
        observer_commit = None;
        mismatch_state = Mismatch_none;
        last_mismatch_epoch = None;
        autostart_attempted = false;
      };
    attention = Attention.empty;
    incidents = Incidents.empty;
    drafts = Drafts.empty;
    fleet = Fleet_store.set_wall_unix last_wall_unix Fleet_store.empty;
    keeper_context = Keeper_context_store.empty;
    work = Work_store.empty;
    knowledge = Knowledge_store.empty;
    runtime = Runtime_store.empty;
    infra = Infra_store.empty;
    config = Config_store.empty;
    palette = { mode = Palette_commands; query = ""; selected = 0 };
    inline_modal = None;
    ask_modal = None;
    toast = None;
  }

let active_dive m =
  match m.nav.dive_stack with d :: _ -> Some d | [] -> None

let target_keeper m =
  match m.drafts.active_keeper with
  | Some k when not (String.equal (String.trim k) "") -> Some (String.trim k)
  | Some _ | None ->
      Option.map
        (fun (k : Wire_fleet.keeper_summary) -> k.name)
        (Fleet_store.selected_keeper_summary m.fleet)

let pulse_panes m =
  if Attention.is_empty m.attention then
    [ Pulse_companies; Pulse_goals; Pulse_world ]
  else [ Pulse_attention; Pulse_companies; Pulse_goals; Pulse_world ]

let active_pulse_pane m =
  let panes = pulse_panes m in
  let idx = Store_scroll.clamp_index (List.length panes) m.nav.pane_index in
  match List.nth_opt panes idx with
  | Some p -> p
  | None -> Pulse_companies

let is_in_keeper_chat m =
  match active_dive m with
  | Some (Nav.Dive_keeper { tab = Nav.Keeper_chat; _ }) -> true
  | Some
      ( Nav.Dive_keeper
          {
            tab =
              ( Nav.Keeper_context
              | Nav.Keeper_tool_calls
              | Nav.Keeper_memory
              | Nav.Keeper_work_candle
              | Nav.Keeper_sandbox
              | Nav.Keeper_config
              | Nav.Keeper_logs
              | Nav.Keeper_identity );
            _;
          }
      | Nav.Dive_work _
      | Nav.Dive_knowledge _
      | Nav.Dive_runtime _
      | Nav.Dive_infra _ )
  | None ->
      false

let fast_approval_strip_item m =
  if is_too_small_viewport m.viewport || equal_breakpoint m.breakpoint Micro then
    None
  else
    match m.nav.overlay with
    | Some (Nav.System_gate _) -> None
    | Some
        ( Nav.Palette
        | Nav.Settings _
        | Nav.Incidents
        | Nav.Queue_context _
        | Nav.Inline_action _
        | Nav.Ask_answer
        | Nav.Help ) ->
        Attention.top_fast_path m.attention
    | None ->
        if
          m.nav.dive_stack = []
          && Nav.equal_workspace m.nav.workspace Nav.Work
          && Nav.equal_work_tab m.work.active_tab Nav.Work_inbox
        then
          match
            Attention.current_filtered_item ~query:m.work.filter_query
              m.attention
          with
          | Some e when not (Attention.is_in_flight ~id:e.id m.attention) -> (
              match e.payload with
              | Attention.Payload_tool_approval _
              | Attention.Payload_gate _
              | Attention.Payload_goal_confirmation _ ->
                  Some e
              | Attention.Payload_ask _ -> None)
          | Some _ | None -> None
        else if
          m.nav.dive_stack = []
          && Nav.equal_workspace m.nav.workspace Nav.Pulse
          && (not (Attention.is_empty m.attention))
          && Int.equal m.nav.pane_index 0
        then
          match Attention.current_filtered_item ~query:"" m.attention with
          | Some e when not (Attention.is_in_flight ~id:e.id m.attention) ->
              Some e
          | Some _ | None -> Attention.top_fast_path m.attention
        else Attention.top_fast_path m.attention

let composer_mode m =
  if
    Drafts.is_focused m.drafts
    || Drafts.is_voice_active m.drafts
    || Drafts.current_draft_is_multiline m.drafts
  then Expanded_multiline
  else
    match m.breakpoint with
    | Wide | Standard -> Collapsed_bar
    | Compact | Micro ->
        let keeper = Drafts.target_keeper_key m.drafts in
        let has_tx =
          Drafts.has_active_tx_for ~keeper m.drafts
          || Fleet_store.has_active_chat_stream ~keeper m.fleet
        in
        if
          (not (Drafts.has_non_empty_draft m.drafts))
          && (not (is_in_keeper_chat m))
          && not has_tx
        then Auto_folded_pill
        else Collapsed_bar

let sidebar_width = 24
let sidebar_gap = 1
let sidebar_docked_min_cols = 132

let sidebar_docked m =
  (not (is_too_small_viewport m.viewport))
  && (not (equal_breakpoint m.breakpoint Micro))
  && m.viewport.cols >= sidebar_docked_min_cols
  &&
  match m.nav.sidebar_open with
  | Some false -> false
  | None | Some true -> true

let sidebar_drawer_open m =
  (not (is_too_small_viewport m.viewport))
  && (not (equal_breakpoint m.breakpoint Micro))
  && (not (sidebar_docked m))
  &&
  match m.nav.sidebar_open with
  | Some true -> true
  | None | Some false -> false

let sidebar_visible m = sidebar_docked m || sidebar_drawer_open m

let sidebar_has_focus m =
  sidebar_visible m
  && m.nav.sidebar_focused
  && Option.is_none m.nav.overlay
  && (not m.nav.filter_focused)
  && not (Drafts.is_focused m.drafts)

type sidebar_row =
  | Sidebar_section of Nav.menu_section
  | Sidebar_item of {
      index : int;
      item : Nav.menu_item;
    }

let sidebar_visual_rows =
  let acc = ref [] in
  let prev_sec = ref None in
  List.iteri
    (fun index (item : Nav.menu_item) ->
      let changed =
        match !prev_sec with
        | Some s -> not (Nav.equal_menu_section s item.section)
        | None -> true
      in
      if changed then begin
        acc := Sidebar_section item.section :: !acc;
        prev_sec := Some item.section
      end;
      acc := Sidebar_item { index; item } :: !acc)
    Nav.all_menu_items;
  List.rev !acc

let sidebar_cursor_visual_row ~cursor =
  let rec find row = function
    | [] -> 0
    | Sidebar_item { index; _ } :: _ when Int.equal index cursor -> row
    | (Sidebar_section _ | Sidebar_item _) :: rest -> find (row + 1) rest
  in
  find 0 sidebar_visual_rows

let sidebar_viewport_start ~inner_h ~scroll ~cursor =
  let total = List.length sidebar_visual_rows in
  if inner_h <= 0 || total <= inner_h then 0
  else
    let vis_row = sidebar_cursor_visual_row ~cursor in
    let max_start = max 0 (total - inner_h) in
    let s0 = max 0 (min max_start scroll) in
    let target_top = if cursor = 0 then 0 else max 0 (vis_row - 1) in
    let s1 =
      if target_top < s0 then target_top
      else if vis_row >= s0 + inner_h then vis_row - inner_h + 1
      else s0
    in
    max 0 (min max_start s1)

let active_menu_target m =
  match m.nav.overlay with
  | Some (Nav.Settings _) -> Nav.Menu_settings
  | Some Nav.Incidents -> Nav.Menu_incidents
  | Some (Nav.Queue_context _) -> Nav.Menu_queue_context
  | Some Nav.Help -> Nav.Menu_help
  | Some (Nav.Palette | Nav.Inline_action _ | Nav.Ask_answer | Nav.System_gate _) | None -> (
      match m.nav.workspace with
      | Nav.Pulse -> Nav.Menu_pulse
      | Nav.Work -> Nav.Menu_work m.work.active_tab
      | Nav.Knowledge -> Nav.Menu_knowledge m.knowledge.active_tab
      | Nav.Keepers -> (
          let tab_opt =
            match active_dive m with
            | Some (Nav.Dive_keeper { tab; _ }) -> Some tab
            | Some
                ( Nav.Dive_work _
                | Nav.Dive_knowledge _
                | Nav.Dive_runtime _
                | Nav.Dive_infra _ ) ->
                None
            | None -> Some m.fleet.keeper_dive_tab
          in
          match tab_opt with
          | Some
              (( Nav.Keeper_context
               | Nav.Keeper_tool_calls
               | Nav.Keeper_logs
               | Nav.Keeper_identity ) as tab) ->
              Nav.Menu_keeper_tab tab
          | Some
              ( Nav.Keeper_chat
              | Nav.Keeper_memory
              | Nav.Keeper_work_candle
              | Nav.Keeper_sandbox
              | Nav.Keeper_config )
          | None ->
              Nav.Menu_keepers)
      | Nav.Runtime -> Nav.Menu_runtime m.runtime.active_tab
      | Nav.Infra -> Nav.Menu_infra m.infra.active_tab)

let sync_sidebar_cursor m =
  let idx = Nav.menu_item_index (active_menu_target m) in
  { m with nav = { m.nav with sidebar_cursor = idx } }

let outer_margin_for = function
  | Wide | Standard -> 1
  | Compact | Micro -> 0

let full_inset_width m =
  let cols = max 0 m.viewport.cols in
  let margin = outer_margin_for m.breakpoint in
  if margin <= 0 || cols <= margin * 2 then cols else cols - (margin * 2)

let inner_body_width m =
  let full = full_inset_width m in
  if sidebar_docked m && full >= sidebar_width + 20 then
    max 0 (full - sidebar_width - sidebar_gap)
  else full

let has_sub_tab_bar_for_model m =
  match active_dive m with
  | Some _ -> true
  | None -> (
      match m.nav.workspace with
      | Nav.Pulse -> false
      | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Runtime | Nav.Infra -> true)

let vertical_chrome_bands m =
  let rows = max 0 m.viewport.rows in
  let top_rail_h = if rows >= 1 then 1 else 0 in
  let footer_h = if rows >= 2 then 1 else 0 in
  if is_too_small_viewport m.viewport || equal_breakpoint m.breakpoint Micro
  then
    let body_h = max 0 (rows - top_rail_h - footer_h) in
    (top_rail_h, body_h, 0, 0)
  else
    let sub_h = if has_sub_tab_bar_for_model m && rows >= 5 then 1 else 0 in
    let top_h = top_rail_h + sub_h in
    let avail = max 0 (rows - top_h - footer_h) in
    let raw_comp_h =
      match composer_mode m with
      | Auto_folded_pill -> 0
      | Collapsed_bar -> 1
      | Expanded_multiline ->
          let max_h = max 2 (min 6 (rows / 4)) in
          let cap = max 1 (min 6 max_h) in
          let draft_lines =
            List.length
              (String.split_on_char '\n' (Drafts.current_draft m.drafts).text)
          in
          let extra = if Drafts.is_voice_active m.drafts then 1 else 0 in
          max 2 (min cap (draft_lines + 1 + extra))
    in
    let comp_h = min raw_comp_h (max 0 (avail - 3)) in
    let approval_h =
      if Option.is_some (fast_approval_strip_item m) && avail - comp_h >= 4 then
        1
      else 0
    in
    let footer_sep_h =
      if
        equal_breakpoint m.breakpoint Wide
        && rows >= 36
        && avail - comp_h - approval_h >= 24
      then 1
      else 0
    in
    let comp_y = rows - footer_h - footer_sep_h - comp_h in
    let approval_y = comp_y - approval_h in
    let body_h = max 0 (approval_y - top_h) in
    (top_h, body_h, comp_y, comp_h)

let inner_body_height m =
  let _, body_h, _, _ = vertical_chrome_bands m in
  body_h

let composer_rect m =
  let cols = max 0 m.viewport.cols in
  let _, _, comp_y, comp_h = vertical_chrome_bands m in
  if comp_h > 0 && cols > 0 then
    Some (Rect.make ~x:0 ~y:comp_y ~w:cols ~h:comp_h)
  else None

let body_top_y m =
  let rows = max 0 m.viewport.rows in
  let top_rail_h = if rows >= 1 then 1 else 0 in
  if is_too_small_viewport m.viewport || equal_breakpoint m.breakpoint Micro
  then top_rail_h
  else
    let sub_h = if has_sub_tab_bar_for_model m && rows >= 5 then 1 else 0 in
    top_rail_h + sub_h

let sidebar_rect m =
  let cols = max 0 m.viewport.cols in
  let top_h = body_top_y m in
  let body_h = inner_body_height m in
  let margin = outer_margin_for m.breakpoint in
  let full_w = full_inset_width m in
  if body_h <= 0 then None
  else if sidebar_docked m && full_w >= sidebar_width + 20 then
    Some (Rect.make ~x:margin ~y:top_h ~w:sidebar_width ~h:body_h)
  else if sidebar_drawer_open m && full_w >= 20 then
    let dw = min (sidebar_width + 2) (max 18 (cols - 4)) in
    let dx = if cols > dw + 2 then 1 else 0 in
    Some (Rect.make ~x:dx ~y:top_h ~w:dw ~h:body_h)
  else None

let body_rect m =
  let top_h = body_top_y m in
  let body_h = inner_body_height m in
  let margin = outer_margin_for m.breakpoint in
  let full_w = full_inset_width m in
  if sidebar_docked m && full_w >= sidebar_width + 20 then
    Rect.make
      ~x:(margin + sidebar_width + sidebar_gap)
      ~y:top_h
      ~w:(max 0 (full_w - sidebar_width - sidebar_gap))
      ~h:body_h
  else Rect.make ~x:margin ~y:top_h ~w:full_w ~h:body_h

let work_pipeline_has_linked_card m =
  inner_body_width m >= 96 && inner_body_height m >= 15

let can_zoom_current_view m =
  if
    is_too_small_viewport m.viewport
    || equal_breakpoint m.breakpoint Micro
    || Option.is_some m.nav.overlay
    || Option.is_some (active_dive m)
  then false
  else
    match m.nav.workspace with
    | Nav.Keepers -> Option.is_some (Fleet_store.selected_keeper_summary m.fleet)
    | Nav.Knowledge -> (
        match m.knowledge.active_tab with
        | Nav.Knowledge_board
        | Nav.Knowledge_wiki
        | Nav.Knowledge_artifacts
        | Nav.Knowledge_memory ->
            true)
    | Nav.Pulse | Nav.Work | Nav.Runtime | Nav.Infra -> false

let focusable_pane_count m =
  if is_too_small_viewport m.viewport || equal_breakpoint m.breakpoint Micro then
    1
  else
    match m.nav.overlay with
    | Some (Nav.Settings _) ->
        if Config_store.is_two_pane_width ~cols:m.viewport.cols then 2 else 1
    | Some
        ( Nav.Palette
        | Nav.Incidents
        | Nav.Queue_context _
        | Nav.Inline_action _
        | Nav.Ask_answer
        | Nav.Help
        | Nav.System_gate _ ) ->
        1
    | None -> (
        match active_dive m with
        | Some (Nav.Dive_keeper { tab = Nav.Keeper_tool_calls; _ }) -> 2
        | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_context }) ->
            let ks = Keeper_context_store.get_keeper ~keeper:name m.keeper_context in
            if
              Keeper_context_store.equal_context_subtab ks.subtab
                Keeper_context_store.Ctx_exact_input
            then 2
            else 1
        | Some
            ( Nav.Dive_keeper
                {
                  tab =
                    ( Nav.Keeper_chat
                    | Nav.Keeper_memory
                    | Nav.Keeper_work_candle
                    | Nav.Keeper_sandbox
                    | Nav.Keeper_config
                    | Nav.Keeper_logs
                    | Nav.Keeper_identity );
                  _;
                }
            | Nav.Dive_work _
            | Nav.Dive_knowledge _
            | Nav.Dive_runtime _
            | Nav.Dive_infra _ ) ->
            1
        | None ->
            if m.nav.zoomed && can_zoom_current_view m then 1
            else
          match m.nav.workspace with
          | Nav.Pulse -> List.length (pulse_panes m)
          | Nav.Work -> (
              match m.work.active_tab with
              | Nav.Work_pipeline ->
                  if work_pipeline_has_linked_card m then 3 else 2
              | Nav.Work_tasks | Nav.Work_schedules -> 1
              | Nav.Work_inbox ->
                  if
                    Attention.filtered_items ~query:m.work.filter_query
                      m.attention
                    = []
                  then 1
                  else 2
              | Nav.Work_candle_scorecard -> 1
              | Nav.Work_harness -> 2)
          | Nav.Knowledge -> 2
          | Nav.Keepers ->
              if
                (equal_breakpoint m.breakpoint Wide
                 || equal_breakpoint m.breakpoint Standard)
                && inner_body_width m >= 104
              then 2
              else 1
          | Nav.Runtime -> (
              match m.runtime.active_tab with
              | Nav.Runtime_efficiency_spend -> 1
              | Nav.Runtime_tools_usage -> (
                  match m.runtime.tools_subview with
                  | Runtime_store.Tools_keeper_skills -> 2
                  | Runtime_store.Tools_usage_calls
                  | Runtime_store.Tools_catalog_tree ->
                      1)
              | Nav.Runtime_quotas_credits
              | Nav.Runtime_failover_lanes
              | Nav.Runtime_fusion
              | Nav.Runtime_connectors
              | Nav.Runtime_addons_browser ->
                  2)
          | Nav.Infra -> (
              match m.infra.active_tab with
              | Nav.Infra_sandboxes ->
                  if inner_body_width m >= 100 then 2 else 1
              | Nav.Infra_code -> 2
              | Nav.Infra_activity_logs ->
                  if m.infra.acting_rail_open && inner_body_width m >= 104 then 3
                  else 2
              | Nav.Infra_repos_changes ->
                  if Infra_store.repo_changes m.infra <> [] then 3 else 2))

let active_focus_scope m =
  if is_too_small_viewport m.viewport then
    Nav.Overlay_focused (Nav.System_gate Nav.Micro_viewport)
  else
    match m.nav.overlay with
    | Some ov -> Nav.Overlay_focused ov
    | None ->
        if equal_breakpoint m.breakpoint Micro then
          Nav.Overlay_focused (Nav.System_gate Nav.Micro_viewport)
        else (
        if Drafts.is_focused m.drafts then Nav.Composer_focused
        else
          match active_dive m with
          | Some d -> Nav.Dive_focused d
          | None ->
              if
                Nav.equal_workspace m.nav.workspace Nav.Work
                && Nav.equal_work_tab m.work.active_tab Nav.Work_inbox
                &&
                if not (Attention.is_empty m.attention) then
                  match
                    Attention.current_filtered_item ~query:m.work.filter_query
                      m.attention
                  with
                  | Some { payload = Attention.Payload_ask _; id; _ } ->
                      not (Attention.is_in_flight ~id m.attention)
                  | Some
                      {
                        payload =
                          ( Attention.Payload_tool_approval _
                          | Attention.Payload_gate _
                          | Attention.Payload_goal_confirmation _ );
                        _;
                      }
                  | None ->
                      false
                else Option.is_some (Work_store.selected_open_ask m.work)
              then Nav.Ask_choice_focused
              else Nav.Workspace_focused m.nav.workspace)

let focus_scope_chain m =
  let micro_locked =
    is_too_small_viewport m.viewport || equal_breakpoint m.breakpoint Micro
  in
  let approval_strip_active =
    if
      (not micro_locked)
      && Option.is_none m.nav.overlay
      && m.nav.dive_stack = []
      && Nav.equal_workspace m.nav.workspace Nav.Work
      && Nav.equal_work_tab m.work.active_tab Nav.Work_inbox
    then
      match
        Attention.current_filtered_item ~query:m.work.filter_query m.attention
      with
      | Some e -> not (Attention.is_in_flight ~id:e.id m.attention)
      | None -> false
    else Option.is_some (fast_approval_strip_item m)
  in
  Keymap.scope_chain_of_focus ~approval_strip_active (active_focus_scope m)

let body_has_focus m =
  (not (is_too_small_viewport m.viewport))
  && (not (equal_breakpoint m.breakpoint Micro))
  && Option.is_none m.nav.overlay
  && (not m.nav.filter_focused)
  && (not (sidebar_has_focus m))
  && not (Drafts.is_focused m.drafts)

let pane_focused m idx = body_has_focus m && Int.equal m.nav.pane_index idx

let active_focus_label m =
  let pane_prefix ~ko ~en =
    let n = focusable_pane_count m in
    if n > 1 then
      let idx = Int.min n (Int.max 1 (m.nav.pane_index + 1)) in
      Say.make
        ~ko:(Printf.sprintf "%d/%d %s" idx n ko)
        ~en:(Printf.sprintf "%d/%d %s" idx n en)
    else Say.make ~ko ~en
  in
  if is_too_small_viewport m.viewport then
    Say.make ~ko:"화면 너무 작음" ~en:"VIEWPORT TOO SMALL"
  else
  match m.nav.overlay with
  | Some Nav.Help -> Say.make ~ko:"오버레이 · 도움말" ~en:"OVERLAY · Help"
  | Some Nav.Palette -> Say.make ~ko:"오버레이 · 팔레트" ~en:"OVERLAY · Palette"
  | Some (Nav.Settings _) ->
      if Config_store.is_two_pane_width ~cols:m.viewport.cols then
        if
          Config_store.equal_settings_pane m.config.settings_pane
            Config_store.Pane_tree
        then Say.make ~ko:"설정 · 트리" ~en:"SETTINGS · Tree"
        else Say.make ~ko:"설정 · 인스펙터" ~en:"SETTINGS · Inspector"
      else Say.make ~ko:"오버레이 · 설정" ~en:"OVERLAY · Settings"
  | Some Nav.Incidents ->
      Say.make ~ko:"오버레이 · 이력" ~en:"OVERLAY · Incidents"
  | Some (Nav.Queue_context _) ->
      Say.make ~ko:"오버레이 · 큐/컨텍스트" ~en:"OVERLAY · Queue/Ctx"
  | Some (Nav.Inline_action _) ->
      Say.make ~ko:"입력 모달" ~en:"MODAL"
  | Some Nav.Ask_answer -> (
      match m.ask_modal with
      | Some modal when modal.editing_free_text ->
          Say.make ~ko:"질문 답변 · 직접 입력" ~en:"ASK · Free-text"
      | Some _ | None -> Say.make ~ko:"질문 답변" ~en:"ASK ANSWER")
  | Some (Nav.System_gate _) ->
      Say.make ~ko:"시스템 게이트" ~en:"SYSTEM GATE"
  | None -> (
      if equal_breakpoint m.breakpoint Micro then
        Say.make ~ko:"마이크로 (입력 잠금)" ~en:"MICRO (LOCKED)"
      else if m.nav.filter_focused then Say.make ~ko:"필터 입력" ~en:"FILTER"
      else if Drafts.is_focused m.drafts then
        let k =
          match m.drafts.active_keeper with
          | Some name when not (String.equal (String.trim name) "") ->
              " @" ^ name
          | Some _ | None -> ""
        in
        Say.make ~ko:("입력창" ^ k) ~en:("COMPOSER" ^ k)
      else if sidebar_has_focus m then
        Say.make ~ko:"메뉴" ~en:"MENU"
      else
        match active_dive m with
        | Some (Nav.Dive_keeper { name; tab }) -> (
            if focusable_pane_count m > 1 then
              match tab with
              | Nav.Keeper_tool_calls ->
                  if m.nav.pane_index = 1 then
                    pane_prefix ~ko:(name ^ " · 상세") ~en:(name ^ " · Detail")
                  else pane_prefix ~ko:(name ^ " · 호출") ~en:(name ^ " · Calls")
              | Nav.Keeper_context ->
                  if m.nav.pane_index = 1 then
                    pane_prefix ~ko:(name ^ " · 원문") ~en:(name ^ " · Prompt")
                  else
                    pane_prefix ~ko:(name ^ " · 섹션") ~en:(name ^ " · Sections")
              | Nav.Keeper_chat
              | Nav.Keeper_memory
              | Nav.Keeper_work_candle
              | Nav.Keeper_sandbox
              | Nav.Keeper_config
              | Nav.Keeper_logs
              | Nav.Keeper_identity ->
                  Say.make ~ko:("상세 · " ^ name) ~en:("DIVE · " ^ name)
            else Say.make ~ko:("상세 · " ^ name) ~en:("DIVE · " ^ name))
        | Some (Nav.Dive_work _) ->
            Say.make ~ko:"작업 상세" ~en:"WORK DIVE"
        | Some (Nav.Dive_knowledge _) ->
            Say.make ~ko:"지식 상세" ~en:"KNOWLEDGE DIVE"
        | Some (Nav.Dive_runtime (Nav.Tool_dive name)) ->
            Say.make ~ko:("도구 · " ^ name) ~en:("TOOL · " ^ name)
        | Some (Nav.Dive_runtime (Nav.Fusion_dive id)) ->
            Say.make ~ko:("퓨전 · " ^ id) ~en:("FUSION · " ^ id)
        | Some (Nav.Dive_infra (Nav.Lane_dive id)) ->
            Say.make ~ko:("레인 · " ^ id) ~en:("LANE · " ^ id)
        | Some (Nav.Dive_infra (Nav.Runtime_trace_dive keeper)) ->
            Say.make ~ko:("추적 · " ^ keeper) ~en:("TRACE · " ^ keeper)
        | Some (Nav.Dive_infra (Nav.Log_detail_dive seq)) ->
            Say.make
              ~ko:(Printf.sprintf "로그 · #%d" seq)
              ~en:(Printf.sprintf "LOG · #%d" seq)
        | Some (Nav.Dive_infra (Nav.Sandbox_dive _ | Nav.Incident_dive _)) ->
            Say.make ~ko:"인프라 상세" ~en:"INFRA DIVE"
        | None -> (
            match m.nav.workspace with
            | Nav.Pulse -> (
                match active_pulse_pane m with
                | Pulse_attention -> pane_prefix ~ko:"확인 대기" ~en:"Attention"
                | Pulse_companies -> pane_prefix ~ko:"조직" ~en:"Companies"
                | Pulse_goals -> pane_prefix ~ko:"목표" ~en:"Goals"
                | Pulse_world -> pane_prefix ~ko:"월드 펄스" ~en:"World")
            | Nav.Work -> (
                match m.work.active_tab with
                | Nav.Work_pipeline -> (
                    match m.nav.pane_index with
                    | 0 -> pane_prefix ~ko:"목표" ~en:"Goals"
                    | 1 when work_pipeline_has_linked_card m ->
                        pane_prefix ~ko:"검증" ~en:"Verifs"
                    | _ -> pane_prefix ~ko:"목표 상세" ~en:"Detail")
                | Nav.Work_tasks ->
                    if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"작업 상세" ~en:"Task Detail"
                    else pane_prefix ~ko:"작업 목록" ~en:"Tasks"
                | Nav.Work_schedules ->
                    if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"일정 상세" ~en:"Schedule Detail"
                    else pane_prefix ~ko:"예약 일정" ~en:"Schedules"
                | Nav.Work_inbox ->
                    if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"인스펙터" ~en:"Inspector"
                    else pane_prefix ~ko:"수신함" ~en:"Inbox"
                | Nav.Work_candle_scorecard ->
                    Say.make ~ko:"캔들 · 원장" ~en:"Candle"
                | Nav.Work_harness ->
                    if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"하네스 상세" ~en:"Run Detail"
                    else pane_prefix ~ko:"하네스 실행" ~en:"Harness")
            | Nav.Knowledge -> (
                let zoomed = m.nav.zoomed && can_zoom_current_view m in
                match m.knowledge.active_tab with
                | Nav.Knowledge_board ->
                    if zoomed then Say.make ~ko:"확대 · 타래 보기" ~en:"ZOOM · Thread"
                    else if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"타래 보기" ~en:"Thread"
                    else pane_prefix ~ko:"보드" ~en:"Board"
                | Nav.Knowledge_wiki ->
                    if zoomed then Say.make ~ko:"확대 · 위키 보기" ~en:"ZOOM · Wiki View"
                    else if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"위키 보기" ~en:"Wiki View"
                    else pane_prefix ~ko:"위키 트리" ~en:"Wiki Tree"
                | Nav.Knowledge_artifacts ->
                    if zoomed then Say.make ~ko:"확대 · 산출물 상세" ~en:"ZOOM · Artifact"
                    else if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"산출물 상세" ~en:"Artifact"
                    else pane_prefix ~ko:"산출물 목록" ~en:"Artifacts"
                | Nav.Knowledge_memory ->
                    if zoomed then Say.make ~ko:"확대 · 기억 탐색" ~en:"ZOOM · Explorer"
                    else if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"기억 탐색" ~en:"Explorer"
                    else pane_prefix ~ko:"기억 범위" ~en:"Memory Scope")
            | Nav.Keepers ->
                if m.nav.zoomed && can_zoom_current_view m then
                  let tab_lbl = Nav.keeper_tab_label m.fleet.keeper_dive_tab in
                  Say.make
                    ~ko:("확대 · " ^ Say.resolve Say.Lang_ko tab_lbl)
                    ~en:("ZOOM · " ^ Say.resolve Say.Lang_en tab_lbl)
                else if m.nav.pane_index = 1 then
                  pane_prefix ~ko:"키퍼 프리뷰" ~en:"Preview"
                else pane_prefix ~ko:"키퍼 목록" ~en:"Fleet"
            | Nav.Runtime -> (
                match m.runtime.active_tab with
                | Nav.Runtime_quotas_credits ->
                    if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"크레딧" ~en:"Credits"
                    else pane_prefix ~ko:"할당량" ~en:"Quotas"
                | Nav.Runtime_efficiency_spend ->
                    Say.make ~ko:"효율 · 지출" ~en:"Efficiency"
                | Nav.Runtime_failover_lanes ->
                    if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"레인 상세" ~en:"Lane Health"
                    else pane_prefix ~ko:"페일오버" ~en:"Lanes"
                | Nav.Runtime_fusion ->
                    if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"퓨전 상세" ~en:"Fusion Detail"
                    else pane_prefix ~ko:"퓨전 실행" ~en:"Fusion"
                | Nav.Runtime_tools_usage ->
                    if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"도구 상세" ~en:"Tool Detail"
                    else pane_prefix ~ko:"도구·사용량" ~en:"Tools"
                | Nav.Runtime_connectors ->
                    if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"MCP·브라우저" ~en:"MCP & Browser"
                    else pane_prefix ~ko:"커넥터" ~en:"Connectors"
                | Nav.Runtime_addons_browser ->
                    if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"브라우저·탭" ~en:"Browser"
                    else pane_prefix ~ko:"애드온 레인" ~en:"Addons")
            | Nav.Infra -> (
                match m.infra.active_tab with
                | Nav.Infra_sandboxes ->
                    if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"샌드박스 상세" ~en:"Inspector"
                    else pane_prefix ~ko:"샌드박스" ~en:"Sandboxes"
                | Nav.Infra_repos_changes -> (
                    match m.nav.pane_index with
                    | 0 -> pane_prefix ~ko:"저장소" ~en:"Repos"
                    | 2 -> pane_prefix ~ko:"파일 변경" ~en:"Changes"
                    | _ -> pane_prefix ~ko:"Diff" ~en:"Diff")
                | Nav.Infra_activity_logs -> (
                    match m.nav.pane_index with
                    | 1 -> pane_prefix ~ko:"로그 상세" ~en:"Detail"
                    | 2 -> pane_prefix ~ko:"실행 중" ~en:"Acting"
                    | _ -> pane_prefix ~ko:"활동·로그" ~en:"Logs")
                | Nav.Infra_code ->
                    if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"코드 뷰" ~en:"Code"
                    else pane_prefix ~ko:"파일 트리" ~en:"Files")))

let is_keeper_config_active m =
  Option.is_none m.nav.overlay
  &&
  match active_dive m with
  | Some (Nav.Dive_keeper { tab = Nav.Keeper_config; _ }) -> true
  | Some
      ( Nav.Dive_keeper
          {
            tab =
              ( Nav.Keeper_chat
              | Nav.Keeper_context
              | Nav.Keeper_tool_calls
              | Nav.Keeper_memory
              | Nav.Keeper_work_candle
              | Nav.Keeper_sandbox
              | Nav.Keeper_logs
              | Nav.Keeper_identity );
            _;
          }
      | Nav.Dive_work _
      | Nav.Dive_knowledge _
      | Nav.Dive_runtime _
      | Nav.Dive_infra _ ) ->
      false
  | None ->
      Nav.equal_workspace m.nav.workspace Nav.Keepers
      && Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_config
      && (m.nav.pane_index = 1 || (m.nav.zoomed && can_zoom_current_view m))

let is_text_capture_active m =
  if m.nav.filter_focused || Drafts.is_focused m.drafts then true
  else
    match m.nav.overlay with
    | Some Nav.Palette | Some (Nav.Inline_action _) -> true
    | Some Nav.Ask_answer -> (
        match m.ask_modal with
        | Some modal -> modal.editing_free_text
        | None -> false)
    | Some (Nav.Settings _) -> Config_store.is_editing_field m.config
    | Some (Nav.Incidents | Nav.Queue_context _ | Nav.Help | Nav.System_gate _) ->
        false
    | None -> is_keeper_config_active m && Config_store.is_editing_field m.config

let inline_modal_for kind =
  let fields =
    match kind with
    | Nav.Btw_query ->
        [
          {
            key = "prompt";
            label = Say.make ~ko:"임시 질문 (/btw)" ~en:"Side query (/btw)";
            value = "";
            required = true;
            secret = false;
          };
        ]
    | Nav.Gate_reject _ ->
        [
          {
            key = "reason";
            label = Say.make ~ko:"거절 사유" ~en:"Rejection reason";
            value = "";
            required = true;
            secret = false;
          };
        ]
    | Nav.Verification_reject _ ->
        [
          {
            key = "reason";
            label = Say.make ~ko:"검증 거절 사유" ~en:"Verification rejection reason";
            value = "";
            required = true;
            secret = false;
          };
          {
            key = "notes";
            label = Say.make ~ko:"추가 메모" ~en:"Notes";
            value = "";
            required = false;
            secret = false;
          };
        ]
    | Nav.Harness_overrule notes_hash ->
        [
          {
            key = "notes_hash";
            label = Say.make ~ko:"노트 해시 (64 hex)" ~en:"Notes hash (64 hex)";
            value = notes_hash;
            required = true;
            secret = false;
          };
          {
            key = "verdict";
            label = Say.make ~ko:"판정 (approve/reject)" ~en:"Verdict (approve/reject)";
            value = "approve";
            required = true;
            secret = false;
          };
          {
            key = "reason";
            label = Say.make ~ko:"판정 재정의 사유" ~en:"Overrule reason";
            value = "";
            required = true;
            secret = false;
          };
        ]
    | Nav.Task_cancel _ ->
        [
          {
            key = "reason";
            label = Say.make ~ko:"취소 사유" ~en:"Cancellation reason";
            value = "";
            required = false;
            secret = false;
          };
        ]
    | Nav.Schedule_form ->
        [
          {
            key = "keeper";
            label = Say.make ~ko:"대상 키퍼" ~en:"Target keeper";
            value = "";
            required = true;
            secret = false;
          };
          {
            key = "recurrence";
            label =
              Say.make ~ko:"반복 (once 또는 every 1h)"
                ~en:"Repeat (once or every 1h)";
            value = "every 1h";
            required = true;
            secret = false;
          };
          {
            key = "first_run_in";
            label =
              Say.make ~ko:"첫 실행까지 (예: 10m)" ~en:"First run in (e.g. 10m)";
            value = "";
            required = true;
            secret = false;
          };
          {
            key = "prompt";
            label = Say.make ~ko:"실행 지시" ~en:"Prompt";
            value = "";
            required = true;
            secret = false;
          };
        ]
    | Nav.Connector_form ->
        [
          {
            key = "connector";
            label = Say.make ~ko:"커넥터 이름" ~en:"Connector";
            value = "";
            required = true;
            secret = false;
          };
          {
            key = "channel";
            label = Say.make ~ko:"채널 ID" ~en:"Channel ID";
            value = "";
            required = true;
            secret = false;
          };
          {
            key = "keeper";
            label = Say.make ~ko:"연결할 키퍼" ~en:"Keeper to bind";
            value = "";
            required = true;
            secret = false;
          };
        ]
    | Nav.Repo_add_form ->
        [
          {
            key = "url";
            label = Say.make ~ko:"저장소 URL" ~en:"Repository URL";
            value = "";
            required = true;
            secret = false;
          };
          {
            key = "branch";
            label = Say.make ~ko:"기본 브랜치" ~en:"Default branch";
            value = "main";
            required = false;
            secret = false;
          };
        ]
    | Nav.Board_new_post ->
        [
          {
            key = "title";
            label = Say.make ~ko:"제목" ~en:"Title";
            value = "";
            required = true;
            secret = false;
          };
          {
            key = "hearth";
            label = Say.make ~ko:"서브보드" ~en:"Sub-board";
            value = "";
            required = false;
            secret = false;
          };
          {
            key = "body";
            label = Say.make ~ko:"내용" ~en:"Body";
            value = "";
            required = true;
            secret = false;
          };
        ]
    | Nav.Board_comment _ ->
        [
          {
            key = "content";
            label = Say.make ~ko:"댓글 내용" ~en:"Comment";
            value = "";
            required = true;
            secret = false;
          };
        ]
    | Nav.Github_token_form _ ->
        [
          {
            key = "token";
            label = Say.make ~ko:"GitHub PAT" ~en:"GitHub PAT";
            value = "";
            required = true;
            secret = true;
          };
          {
            key = "hostname";
            label = Say.make ~ko:"호스트명" ~en:"Hostname";
            value = "github.com";
            required = false;
            secret = false;
          };
        ]
    | Nav.Code_finder_form ->
        [
          {
            key = "query";
            label = Say.make ~ko:"파일 경로" ~en:"File path";
            value = "";
            required = true;
            secret = false;
          };
        ]
    | Nav.Code_search_form ->
        [
          {
            key = "query";
            label = Say.make ~ko:"코드 검색어" ~en:"Search query";
            value = "";
            required = true;
            secret = false;
          };
        ]
  in
  { kind; fields; active_field = 0; submitting = false; error = None }

let modal_field_value ~key modal =
  match
    List.find_opt (fun (f : modal_form_field) -> String.equal f.key key) modal.fields
  with
  | Some f -> String.trim f.value
  | None -> ""

let modal_active_field_value modal =
  match List.nth_opt modal.fields modal.active_field with
  | Some f -> f.value
  | None -> ""

let modal_field_help ~key =
  match key with
  | "memory_act" ->
      Some
        (Say.make
           ~ko:"허용: resume | adopt | restart_reading | skip_item | skip_line"
           ~en:"Allowed: resume | adopt | restart_reading | skip_item | skip_line")
  | "memory_arg" ->
      Some
        (Say.make
           ~ko:"선택 인자: observed / turn_log:line / offset"
           ~en:"Optional arg: observed / turn_log:line / offset")
  | "fusion_topology" ->
      Some
        (Say.make
           ~ko:"선택: simple | refine | conditional | judge_of_judges"
           ~en:"Optional: simple | refine | conditional | judge_of_judges")
  | "assign_keeper" ->
      Some
        (Say.make
           ~ko:"비우거나 default 입력 시 기본 경로 변경"
           ~en:"Leave blank or 'default' to change the default route")
  | "assign_runtime_id" ->
      Some
        (Say.make
           ~ko:"런타임/레인 ID (키퍼 배정 해제 시 비움)"
           ~en:"Runtime or lane ID (leave blank to clear assignment)")
  | "setup_key_integration" ->
      Some
        (Say.make
           ~ko:"예: anthropic, openai, gemini, openrouter"
           ~en:"e.g. anthropic, openai, gemini, openrouter")
  | "setup_login_integration" ->
      Some
        (Say.make
           ~ko:"예: claude-code, codex, vibe_acp, kimi_acp"
           ~en:"e.g. claude-code, codex, vibe_acp, kimi_acp")
  | "confirm_request_id" ->
      Some
        (Say.make
           ~ko:"GET /goals/confirmation 에서 서버가 발급한 request_id"
           ~en:"Server-issued request_id from GET /goals/confirmation")
  | "confirm_verification_run_id" ->
      Some
        (Say.make
           ~ko:"서버가 발급한 verification_run_id"
           ~en:"Server-issued verification_run_id")
  | "confirm_operator_id" ->
      Some
        (Say.make
           ~ko:"expected_operator_id 값"
           ~en:"Expected operator ID (expected_operator_id)")
  | "connector" ->
      Some
        (Say.make
           ~ko:"예: discord, slack, telegram (←→ 로 순환)"
           ~en:"e.g. discord, slack, telegram (←→ to cycle)")
  | "verdict" ->
      Some
        (Say.make ~ko:"허용: approve | reject" ~en:"Allowed: approve | reject")
  | "notes_hash" ->
      Some
        (Say.make
           ~ko:"64자리 소문자 16진수 해시"
           ~en:"64 lowercase hex characters")
  | "recurrence" ->
      Some
        (Say.make
           ~ko:"예: once, every 30m, every 2h, daily"
           ~en:"e.g. once, every 30m, every 2h, daily")
  | "first_run_in" ->
      Some
        (Say.make
           ~ko:"예: now, 5m, 1h, 300s"
           ~en:"e.g. now, 5m, 1h, 300s")
  | "query" ->
      Some
        (Say.make
           ~ko:"검색어 입력 (코드 검색은 2..200바이트)"
           ~en:"Enter query (ripgrep search: 2..200 bytes)")
  | "token" ->
      Some
        (Say.make
           ~ko:"마스킹 처리됨 — 화면·로그에 평문 미노출"
           ~en:"Masked input — never echoed in plain text")
  | _ -> None

let modal_update_active_field f modal =
  let fields =
    List.mapi
      (fun idx (fld : modal_form_field) ->
        if Int.equal idx modal.active_field then { fld with value = f fld.value }
        else fld)
      modal.fields
  in
  { modal with fields; error = None }

let modal_cycle_field ~delta modal =
  let len = List.length modal.fields in
  if len <= 0 then modal
  else
    let next = (modal.active_field + delta) mod len in
    let active_field = if next < 0 then next + len else next in
    { modal with active_field }

let equal_ask_answer_mode a b =
  match a, b with
  | Ask_mode_unanswered, Ask_mode_unanswered
  | Ask_mode_choices, Ask_mode_choices
  | Ask_mode_free_text, Ask_mode_free_text
  | Ask_mode_skipped, Ask_mode_skipped ->
      true
  | Ask_mode_unanswered, (Ask_mode_choices | Ask_mode_free_text | Ask_mode_skipped)
  | Ask_mode_choices, (Ask_mode_unanswered | Ask_mode_free_text | Ask_mode_skipped)
  | Ask_mode_free_text, (Ask_mode_unanswered | Ask_mode_choices | Ask_mode_skipped)
  | Ask_mode_skipped, (Ask_mode_unanswered | Ask_mode_choices | Ask_mode_free_text) ->
      false

let equal_ask_live_status a b =
  match a, b with
  | Ask_live_open, Ask_live_open
  | Ask_live_in_flight, Ask_live_in_flight
  | Ask_live_closed, Ask_live_closed ->
      true
  | Ask_live_open, (Ask_live_in_flight | Ask_live_closed)
  | Ask_live_in_flight, (Ask_live_open | Ask_live_closed)
  | Ask_live_closed, (Ask_live_open | Ask_live_in_flight) ->
      false

let ask_choice_letters = "abcdefhlmnopqrstuvwxyz"

let ask_choice_hotkey_char idx =
  if idx >= 0 && idx < String.length ask_choice_letters then
    Some ask_choice_letters.[idx]
  else None

let ask_choice_index_of_char ch =
  let len = String.length ask_choice_letters in
  let rec find i =
    if i >= len then None
    else if Char.equal ask_choice_letters.[i] ch then Some i
    else find (i + 1)
  in
  find 0

let empty_ask_question_draft : ask_question_draft =
  {
    choice_ids = [];
    free_text = "";
    free_text_cursor = 0;
    mode = Ask_mode_unanswered;
  }

let ask_modal_rows (q : Wire_work.ask_question) : ask_modal_row list =
  let choices = List.mapi (fun i ch -> Ask_row_choice (i, ch)) q.choices in
  let free = if q.allow_free_text then [ Ask_row_free_text ] else [] in
  choices @ free @ [ Ask_row_skip ]

let ask_modal_current_question (modal : ask_modal) : Wire_work.ask_question option =
  let n = List.length modal.ask.questions in
  if n <= 0 then None
  else List.nth_opt modal.ask.questions (Store_scroll.clamp_index n modal.question_idx)

let ask_modal_current_row (modal : ask_modal) : ask_modal_row option =
  match ask_modal_current_question modal with
  | None -> None
  | Some q ->
      let rows = ask_modal_rows q in
      List.nth_opt rows (Store_scroll.clamp_index (List.length rows) modal.cursor)

let ask_question_draft_for (modal : ask_modal) (q : Wire_work.ask_question) :
    ask_question_draft =
  match Ask_draft_map.find_opt (modal.ask.ask_id, q.question_id) modal.per_question with
  | Some d -> d
  | None -> empty_ask_question_draft

let ask_question_response (modal : ask_modal) (q : Wire_work.ask_question) :
    Wire_work.ask_response option =
  let d = ask_question_draft_for modal q in
  match d.mode with
  | Ask_mode_choices ->
      if d.choice_ids = [] then None
      else Some (Wire_work.Ask_chose d.choice_ids)
  | Ask_mode_free_text ->
      let trimmed = String.trim d.free_text in
      if String.equal trimmed "" then None
      else Some (Wire_work.Ask_wrote trimmed)
  | Ask_mode_skipped -> Some Wire_work.Ask_skipped
  | Ask_mode_unanswered -> None

let ask_modal_all_answered (modal : ask_modal) =
  modal.ask.questions <> []
  && List.for_all
       (fun q -> Option.is_some (ask_question_response modal q))
       modal.ask.questions

let ask_modal_build_answers (modal : ask_modal) =
  let rec loop idx acc = function
    | [] ->
        if acc = [] then Error 0 else Ok (List.rev acc)
    | (q : Wire_work.ask_question) :: rest -> (
        match ask_question_response modal q with
        | Some resp -> loop (idx + 1) ((q.question_id, resp) :: acc) rest
        | None -> Error idx)
  in
  loop 0 [] modal.ask.questions

let ask_live_status (m : t) (ask_id : string) : ask_live_status =
  let attn_id = "ask:" ^ ask_id in
  if Attention.is_in_flight ~id:attn_id m.attention then Ask_live_in_flight
  else
    let open_in_attention =
      List.exists
        (fun (e : Attention.entry) ->
          match e.payload with
          | Attention.Payload_ask a -> (
              String.equal a.ask_id ask_id
              &&
              match a.resolution with
              | Wire_work.Ask_open -> true
              | Wire_work.Ask_answered _ | Wire_work.Ask_withdrawn _ -> false)
          | Attention.Payload_tool_approval _
          | Attention.Payload_gate _
          | Attention.Payload_goal_confirmation _ ->
              false)
        m.attention.items
    in
    if open_in_attention then Ask_live_open else Ask_live_closed

let ask_modal_for ?preselect_choice_1based (ask : Wire_work.ask_row) : ask_modal =
  let per_question, cursor =
    match preselect_choice_1based, ask.questions with
    | Some n, q :: _ when n >= 1 -> (
        match List.nth_opt q.choices (n - 1) with
        | Some ch ->
            let draft =
              {
                empty_ask_question_draft with
                choice_ids = [ ch.choice_id ];
                mode = Ask_mode_choices;
              }
            in
            ( Ask_draft_map.singleton (ask.ask_id, q.question_id) draft
            , n - 1 )
        | None -> (Ask_draft_map.empty, 0))
    | Some _, _ | None, _ -> (Ask_draft_map.empty, 0)
  in
  {
    ask;
    question_idx = 0;
    cursor;
    prompt_scroll = 0;
    per_question;
    editing_free_text = false;
    submitting = false;
    error = None;
  }

let with_current_ask_draft f (modal : ask_modal) : ask_modal =
  match ask_modal_current_question modal with
  | None -> modal
  | Some q ->
      let key = (modal.ask.ask_id, q.question_id) in
      let prev = ask_question_draft_for modal q in
      let next = f q prev in
      {
        modal with
        per_question = Ask_draft_map.add key next modal.per_question;
      }

let ask_modal_set_cursor idx (modal : ask_modal) : ask_modal =
  match ask_modal_current_question modal with
  | None -> modal
  | Some q ->
      let rows = ask_modal_rows q in
      let clamped = Store_scroll.clamp_index (List.length rows) idx in
      let editing_free_text =
        modal.editing_free_text
        &&
        match List.nth_opt rows clamped with
        | Some Ask_row_free_text -> q.allow_free_text
        | Some (Ask_row_choice _ | Ask_row_skip) | None -> false
      in
      { modal with cursor = clamped; editing_free_text }

let ask_modal_move_cursor ~delta (modal : ask_modal) : ask_modal =
  ask_modal_set_cursor (modal.cursor + delta) modal

let ask_modal_scroll_prompt ?max_scroll ~delta (modal : ask_modal) : ask_modal =
  let raw = Int.max 0 (modal.prompt_scroll + delta) in
  let prompt_scroll =
    match max_scroll with
    | Some hi -> Int.min (Int.max 0 hi) raw
    | None -> raw
  in
  { modal with prompt_scroll }

let ask_modal_prompt_markdown ~compact (ask : Wire_work.ask_row)
    (q : Wire_work.ask_question) : string =
  let ctx_opt =
    match ask.context with
    | Some c ->
        let t = String.trim c in
        if String.equal t "" then None else Some t
    | None -> None
  in
  let hdr = String.trim q.header in
  let pr = String.trim q.prompt in
  if compact then
    let head_line =
      if String.equal hdr "" then pr
      else if String.equal pr "" then Printf.sprintf "**%s**" hdr
      else Printf.sprintf "**%s** — %s" hdr pr
    in
    match ctx_opt with
    | Some c -> head_line ^ "\n" ^ c
    | None -> head_line
  else
    let main =
      if String.equal hdr "" then pr
      else if String.equal pr "" then Printf.sprintf "**%s**" hdr
      else Printf.sprintf "**%s**\n%s" hdr pr
    in
    match ctx_opt with
    | Some c -> main ^ "\n\n> " ^ c
    | None -> main

let ask_modal_select_question idx (modal : ask_modal) : ask_modal =
  let n = List.length modal.ask.questions in
  if n <= 0 then modal
  else
    let question_idx = Store_scroll.clamp_index n idx in
    let cursor =
      match List.nth_opt modal.ask.questions question_idx with
      | None -> 0
      | Some q -> (
          let d = ask_question_draft_for modal q in
          match d.mode with
          | Ask_mode_choices -> (
              match d.choice_ids with
              | first_id :: _ ->
                  let rec find i = function
                    | [] -> 0
                    | (ch : Wire_work.ask_choice) :: rest ->
                        if String.equal ch.choice_id first_id then i
                        else find (i + 1) rest
                  in
                  find 0 q.choices
              | [] -> 0)
          | Ask_mode_free_text when q.allow_free_text -> List.length q.choices
          | Ask_mode_free_text -> 0
          | Ask_mode_skipped ->
              List.length q.choices + if q.allow_free_text then 1 else 0
          | Ask_mode_unanswered -> 0)
    in
    {
      modal with
      question_idx;
      cursor;
      prompt_scroll = 0;
      editing_free_text = false;
    }

let ask_modal_step_question ~delta (modal : ask_modal) : ask_modal =
  let n = List.length modal.ask.questions in
  if n <= 1 then modal
  else
    let raw = (modal.question_idx + delta) mod n in
    let idx = if raw < 0 then raw + n else raw in
    ask_modal_select_question idx modal

let ask_modal_set_editing_free_text editing (modal : ask_modal) : ask_modal =
  if not editing then { modal with editing_free_text = false }
  else
    match ask_modal_current_question modal with
    | Some q when q.allow_free_text ->
        let free_idx = List.length q.choices in
        { modal with cursor = free_idx; editing_free_text = true }
    | Some _ | None -> { modal with editing_free_text = false }

let ask_modal_enter_free_text (modal : ask_modal) : ask_modal =
  ask_modal_set_editing_free_text true modal

let ask_modal_toggle_or_select_choice choice_idx (modal : ask_modal) : ask_modal =
  match ask_modal_current_question modal with
  | None -> modal
  | Some q -> (
      match List.nth_opt q.choices choice_idx with
      | None -> modal
      | Some ch ->
          let modal1 =
            { modal with cursor = choice_idx; editing_free_text = false }
          in
          with_current_ask_draft
            (fun (q : Wire_work.ask_question) d ->
              match q.mode with
              | Wire_work.Ask_single ->
                  {
                    d with
                    choice_ids = [ ch.choice_id ];
                    mode = Ask_mode_choices;
                  }
              | Wire_work.Ask_multi ->
                  let already =
                    List.exists (String.equal ch.choice_id) d.choice_ids
                  in
                  let next_set =
                    if already then
                      List.filter
                        (fun id -> not (String.equal id ch.choice_id))
                        d.choice_ids
                    else ch.choice_id :: d.choice_ids
                  in
                  (* Keep canonical choice order from q.choices *)
                  let choice_ids =
                    List.filter_map
                      (fun (c : Wire_work.ask_choice) ->
                        if List.exists (String.equal c.choice_id) next_set then
                          Some c.choice_id
                        else None)
                      q.choices
                  in
                  let mode =
                    if choice_ids <> [] then Ask_mode_choices
                    else if not (String.equal (String.trim d.free_text) "") then
                      Ask_mode_free_text
                    else Ask_mode_unanswered
                  in
                  { d with choice_ids; mode })
            modal1)

let ask_modal_toggle_skip (modal : ask_modal) : ask_modal =
  with_current_ask_draft
    (fun _q d ->
      if equal_ask_answer_mode d.mode Ask_mode_skipped then
        let mode =
          if d.choice_ids <> [] then Ask_mode_choices
          else if not (String.equal (String.trim d.free_text) "") then
            Ask_mode_free_text
          else Ask_mode_unanswered
        in
        { d with mode }
      else { d with mode = Ask_mode_skipped })
    { modal with editing_free_text = false }

let ask_modal_set_skipped (modal : ask_modal) : ask_modal =
  with_current_ask_draft
    (fun _q d -> { d with mode = Ask_mode_skipped })
    { modal with editing_free_text = false }

let grapheme_boundaries_of s =
  let text, clusters = Masc_tui_term.Grapheme.segment s in
  let ends =
    List.map (fun (c : Masc_tui_term.Grapheme.cluster) -> c.end_offset) clusters
  in
  (text, 0 :: ends)

let clamp_grapheme_cursor text bounds off =
  let len = String.length text in
  let target = Int.max 0 (Int.min len off) in
  List.fold_left
    (fun best b -> if b <= target then b else best)
    0 bounds

let prev_grapheme_boundary bounds cursor =
  List.fold_left
    (fun best b -> if b < cursor then b else best)
    0 bounds

let next_grapheme_boundary text bounds cursor =
  let len = String.length text in
  match List.find_opt (fun b -> b > cursor) bounds with
  | Some b -> b
  | None -> len

let ask_modal_insert_free_text raw (modal : ask_modal) : ask_modal =
  if not modal.editing_free_text then modal
  else
    let flat =
      raw
      |> String.map (function '\n' | '\r' | '\t' -> ' ' | c -> c)
      |> Masc_tui_term.Grapheme.sanitize_controls
    in
    if String.equal flat "" then modal
    else
      with_current_ask_draft
        (fun _q d ->
          let text, bounds = grapheme_boundaries_of d.free_text in
          let cur = clamp_grapheme_cursor text bounds d.free_text_cursor in
          let prefix = String.sub text 0 cur in
          let suffix = String.sub text cur (String.length text - cur) in
          let free_text = prefix ^ flat ^ suffix in
          let free_text_cursor = cur + String.length flat in
          let mode =
            if not (String.equal (String.trim free_text) "") then
              Ask_mode_free_text
            else d.mode
          in
          { d with free_text; free_text_cursor; mode })
        modal

let ask_modal_backspace_free_text (modal : ask_modal) : ask_modal =
  if not modal.editing_free_text then modal
  else
    with_current_ask_draft
      (fun _q d ->
        let text, bounds = grapheme_boundaries_of d.free_text in
        let cur = clamp_grapheme_cursor text bounds d.free_text_cursor in
        if cur <= 0 then { d with free_text = text; free_text_cursor = 0 }
        else
          let prev = prev_grapheme_boundary bounds cur in
          let prefix = String.sub text 0 prev in
          let suffix = String.sub text cur (String.length text - cur) in
          let free_text = prefix ^ suffix in
          let mode =
            if not (String.equal (String.trim free_text) "") then
              Ask_mode_free_text
            else if d.choice_ids <> [] then Ask_mode_choices
            else Ask_mode_unanswered
          in
          { d with free_text; free_text_cursor = prev; mode })
      modal

let ask_modal_delete_free_text (modal : ask_modal) : ask_modal =
  if not modal.editing_free_text then modal
  else
    with_current_ask_draft
      (fun _q d ->
        let text, bounds = grapheme_boundaries_of d.free_text in
        let len = String.length text in
        let cur = clamp_grapheme_cursor text bounds d.free_text_cursor in
        if cur >= len then { d with free_text = text; free_text_cursor = len }
        else
          let next = next_grapheme_boundary text bounds cur in
          let prefix = String.sub text 0 cur in
          let suffix = String.sub text next (len - next) in
          let free_text = prefix ^ suffix in
          let mode =
            if not (String.equal (String.trim free_text) "") then
              Ask_mode_free_text
            else if d.choice_ids <> [] then Ask_mode_choices
            else Ask_mode_unanswered
          in
          { d with free_text; free_text_cursor = cur; mode })
      modal

let ask_modal_move_free_text_cursor dir (modal : ask_modal) : ask_modal =
  if not modal.editing_free_text then modal
  else
    with_current_ask_draft
      (fun _q d ->
        let text, bounds = grapheme_boundaries_of d.free_text in
        let len = String.length text in
        let cur = clamp_grapheme_cursor text bounds d.free_text_cursor in
        let next_cur =
          match dir with
          | `Left -> prev_grapheme_boundary bounds cur
          | `Right -> next_grapheme_boundary text bounds cur
          | `Home -> 0
          | `End -> len
        in
        { d with free_text = text; free_text_cursor = next_cur })
      modal

let ask_modal_kill_free_text_start (modal : ask_modal) : ask_modal =
  if not modal.editing_free_text then modal
  else
    with_current_ask_draft
      (fun _q d ->
        let text, bounds = grapheme_boundaries_of d.free_text in
        let len = String.length text in
        let cur = clamp_grapheme_cursor text bounds d.free_text_cursor in
        let free_text = String.sub text cur (len - cur) in
        let mode =
          if not (String.equal (String.trim free_text) "") then
            Ask_mode_free_text
          else if d.choice_ids <> [] then Ask_mode_choices
          else Ask_mode_unanswered
        in
        { d with free_text; free_text_cursor = 0; mode })
      modal

let ask_modal_confirm_free_text (modal : ask_modal) : ask_modal * bool =
  match ask_modal_current_question modal with
  | None -> ({ modal with editing_free_text = false }, false)
  | Some q ->
      let d = ask_question_draft_for modal q in
      let trimmed = String.trim d.free_text in
      let has_text = not (String.equal trimmed "") in
      let next_modal =
        with_current_ask_draft
          (fun _q d ->
            if has_text then
              { d with mode = Ask_mode_free_text }
            else
              let mode =
                if d.choice_ids <> [] then Ask_mode_choices
                else Ask_mode_unanswered
              in
              { d with mode })
          { modal with editing_free_text = false }
      in
      (next_modal, has_text)

let is_viewing_wiki_slug ~slug m =
  Option.is_none m.nav.overlay
  && Option.is_none m.inline_modal
  && (not (sidebar_has_focus m))
  && (not m.nav.filter_focused)
  && (not (Drafts.is_focused m.drafts))
  &&
  match active_dive m with
  | Some (Nav.Dive_knowledge (Nav.Wiki_dive dive_slug)) ->
      String.equal dive_slug slug
  | Some
      ( Nav.Dive_keeper _
      | Nav.Dive_work _
      | Nav.Dive_runtime _
      | Nav.Dive_infra _
      | Nav.Dive_knowledge
          (Nav.Thread_dive _ | Nav.Memory_diff_dive _ | Nav.Artifact_dive _) )
    ->
      false
  | None -> (
      Nav.equal_workspace m.nav.workspace Nav.Knowledge
      && Nav.equal_knowledge_tab m.knowledge.active_tab Nav.Knowledge_wiki
      &&
      match Knowledge_store.selected_wiki_page m.knowledge with
      | Some entry -> String.equal entry.slug slug
      | None -> false)

let open_wiki_edit_modal_for_detail (d : Wire_knowledge.wiki_page_detail) m =
  let modal : inline_modal_state =
    {
      kind = Nav.Board_new_post;
      fields =
        [
          {
            key = "wiki_slug";
            label = Say.make ~ko:"위키 슬러그" ~en:"Wiki slug";
            value = d.slug;
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
      return_overlay = None;
      filter_focused = false;
      modal_edit_cursor = String.length (modal_active_field_value modal);
    }
  in
  let drafts = Drafts.set_focus false m.drafts in
  let knowledge = Knowledge_store.begin_wiki_edit d m.knowledge in
  { m with nav; drafts; knowledge; inline_modal = Some modal }

let with_toast ~now ?duration_s ~level message m =
  let eff_duration =
    match duration_s with
    | Some d -> d
    | None -> (
        match level with
        | Toast_error -> 7.0
        | Toast_info | Toast_success | Toast_warning -> 4.0)
  in
  (* Do not let a transient Toast_info silently clobber an active, unexpired
     Toast_error so critical failure notices remain readable. *)
  let keep_existing_error =
    match m.toast, level with
    | Some existing, Toast_info ->
        (match existing.level with
         | Toast_error -> Clock.Mono.compare now existing.expires_at < 0
         | Toast_info | Toast_success | Toast_warning -> false)
    | Some _, (Toast_success | Toast_warning | Toast_error) | None, _ -> false
  in
  if keep_existing_error then m
  else
    let expires_at = Clock.Mono.after_s now eff_duration in
    { m with toast = Some { message; level; expires_at } }

let expire_toast ~now m =
  match m.toast with
  | None -> m
  | Some t ->
      if Clock.Mono.compare now t.expires_at >= 0 then { m with toast = None }
      else m

let rebuild_attention m =
  let attention =
    Attention.rebuild
      ~asks:(Work_store.asks_list m.work)
      ~tool_approvals:(Work_store.tool_approvals_list m.work)
      ~gate_pending:(Work_store.gate_pending_list m.work)
      ~goals:(Work_store.goals m.work)
      m.attention
  in
  { m with attention }

let mark_all_domains_stale m =
  {
    m with
    fleet = Fleet_store.mark_stale_all m.fleet;
    keeper_context = Keeper_context_store.mark_stale_all m.keeper_context;
    work = Work_store.mark_stale_all m.work;
    knowledge = Knowledge_store.mark_stale_all m.knowledge;
    runtime = Runtime_store.mark_stale_all m.runtime;
    infra = Infra_store.mark_stale_all m.infra;
    config = Config_store.mark_stale_all m.config;
  }

type pulse_hero_metrics = {
  running_keepers : int;
  total_keepers : int;
  company_count : int;
  turns_24h : int Observed.t;
  tool_calls_24h : int Observed.t;
  tool_error_rate_pct : float Observed.t;
  p95_latency_ms : float Observed.t;
  cache_hit_pct : float Observed.t;
  spend_24h_usd : float Observed.t;
  microvm_count : int;
  ssh_count : int;
  docker_count : int;
  tasks_done_24h : int Observed.t;
  tasks_done_total : int Observed.t;
  tasks_in_progress : int Observed.t;
  active_goals_count : int;
  verifications_passed : int;
  verifications_rejected : int;
  verifications_awaiting : int;
  candle_circulating_milli : string option;
}

let empty_scorecard : Wire_fleet.daily_scorecard =
  {
    tasks_done_24h = Observed.unreported;
    tasks_done_total = Observed.unreported;
    tasks_in_progress = Observed.unreported;
    tasks_claimed = Observed.unreported;
    tasks_awaiting_verification = Observed.unreported;
    tasks_todo = Observed.unreported;
    tasks_cancelled = Observed.unreported;
    goals_completed_24h = Observed.unreported;
    verifications_passed_24h = Observed.unreported;
    verifications_rejected_24h = Observed.unreported;
    board_posts_24h = Observed.unreported;
    turns_24h = Observed.unreported;
    cost_24h_usd = Observed.unreported;
  }

let or_observed primary fallback =
  if Observed.is_value primary then primary else fallback

let effective_scorecard m : Wire_fleet.daily_scorecard =
  let base, obs_at =
    match m.fleet.shell with
    | Observed.Value { data; observed_at; _ } ->
        let raw =
          match m.fleet.raw_shell_scorecard with
          | Some r -> r
          | None -> data.scorecard_24h
        in
        (raw, observed_at)
    | Observed.Loading _ | Observed.Absent | Observed.Unreported | Observed.Failed _ ->
        (empty_scorecard, Clock.Mono.zero)
  in
  let backlog_opt = Work_store.effective_task_counts m.work in
  let from_backlog f =
    match backlog_opt with
    | Some c -> Observed.value ~observed_at:obs_at (f c)
    | None -> Observed.unreported
  in
  let turns_from_fleet =
    match
      Fleet_store.total_turns_24h ~now_unix:m.freshness.last_wall_unix m.fleet
    with
    | Some n -> Observed.value ~observed_at:obs_at n
    | None -> Observed.unreported
  in
  let spend_from_rt = Runtime_store.effective_spend_24h_usd m.runtime in
  let v_pass, v_rej, _v_await = Work_store.verification_pass_summary m.work in
  let verif_loaded = Observed.is_value m.work.verifications in
  let verif_passed_fb =
    if verif_loaded then Observed.value ~observed_at:obs_at v_pass
    else Observed.unreported
  in
  let verif_rejected_fb =
    if verif_loaded then Observed.value ~observed_at:obs_at v_rej
    else Observed.unreported
  in
  let goals_completed_fb =
    if Observed.is_value m.work.planning then
      let n =
        List.fold_left
          (fun acc (g : Wire_work.goal) ->
            match g.phase with
            | Wire_work.Completed -> acc + 1
            | Wire_work.Executing | Wire_work.Verifying
            | Wire_work.Awaiting_confirmation | Wire_work.Dropped
            | Wire_work.Paused _ | Wire_work.Blocked _ ->
                acc)
          0 (Work_store.goals m.work)
      in
      Observed.value ~observed_at:obs_at n
    else Observed.unreported
  in
  let board_posts_fb =
    match Observed.to_option m.knowledge.board with
    | None -> Observed.unreported
    | Some feed ->
        let now_u = m.freshness.last_wall_unix in
        let n =
          if now_u > 0.0 then
            List.fold_left
              (fun acc (p : Wire_knowledge.board_post) ->
                if p.is_signal && p.created_at_unix >= now_u -. 86400.0 then
                  acc + 1
                else acc)
              0 feed.posts
          else
            List.fold_left
              (fun acc (p : Wire_knowledge.board_post) ->
                if p.is_signal then acc + 1 else acc)
              0 feed.posts
        in
        Observed.value ~observed_at:obs_at n
  in
  {
    tasks_done_24h = base.tasks_done_24h;
    tasks_done_total =
      or_observed base.tasks_done_total
        (from_backlog (fun c -> c.Wire_work.done_total));
    tasks_in_progress =
      or_observed base.tasks_in_progress
        (from_backlog (fun c -> c.Wire_work.in_progress));
    tasks_claimed =
      or_observed base.tasks_claimed
        (from_backlog (fun c -> c.Wire_work.claimed));
    tasks_awaiting_verification =
      or_observed base.tasks_awaiting_verification
        (from_backlog (fun c -> c.Wire_work.awaiting_verification));
    tasks_todo =
      or_observed base.tasks_todo (from_backlog (fun c -> c.Wire_work.todo));
    tasks_cancelled =
      or_observed base.tasks_cancelled
        (from_backlog (fun c -> c.Wire_work.cancelled));
    goals_completed_24h =
      or_observed base.goals_completed_24h goals_completed_fb;
    verifications_passed_24h =
      or_observed base.verifications_passed_24h verif_passed_fb;
    verifications_rejected_24h =
      or_observed base.verifications_rejected_24h verif_rejected_fb;
    board_posts_24h = or_observed base.board_posts_24h board_posts_fb;
    turns_24h = or_observed base.turns_24h turns_from_fleet;
    cost_24h_usd = or_observed base.cost_24h_usd spend_from_rt;
  }

let pulse_hero_metrics m =
  let sc = effective_scorecard m in
  let obs_at =
    match m.fleet.shell with
    | Observed.Value { observed_at; _ } -> observed_at
    | Observed.Loading _ | Observed.Absent | Observed.Unreported | Observed.Failed _ ->
        Clock.Mono.zero
  in
  let keepers =
    match Observed.to_option m.fleet.keepers with Some ks -> ks | None -> []
  in
  let running_keepers, total_keepers =
    match Observed.to_option m.fleet.fleet_reading with
    | Some fr -> (fr.running_count, max fr.executable_count (List.length keepers))
    | None ->
        let run =
          List.fold_left
            (fun acc (k : Wire_fleet.keeper_summary) ->
              if k.keepalive_running && not k.paused then acc + 1 else acc)
            0 keepers
        in
        (run, List.length keepers)
  in
  let company_count = List.length (Fleet_store.company_groups m.fleet) in
  let tool_calls_24h, tool_error_rate_pct, p95_latency_ms =
    match Runtime_store.tool_series_totals m.runtime with
    | Some (calls, fails, p95_opt) when calls > 0 ->
        let err_pct = 100.0 *. Float.of_int fails /. Float.of_int calls in
        let p95 =
          match p95_opt with
          | Some ms -> Observed.value ~observed_at:obs_at ms
          | None -> Observed.unreported
        in
        ( Observed.value ~observed_at:obs_at calls
        , Observed.value ~observed_at:obs_at err_pct
        , p95 )
    | Some _ | None -> (
        match Observed.to_option m.infra.sandboxes with
        | Some sb when sb.fleet_metrics_24h.calls > 0 ->
            let calls = sb.fleet_metrics_24h.calls in
            let fails = sb.fleet_metrics_24h.failures in
            let err_pct = 100.0 *. Float.of_int fails /. Float.of_int calls in
            ( Observed.value ~observed_at:obs_at calls
            , Observed.value ~observed_at:obs_at err_pct
            , sb.fleet_metrics_24h.p95_ms )
        | Some _ | None -> (
            match Observed.to_option m.runtime.models_metrics with
            | Some mm when mm.total_entries > 0 ->
                let err_pct =
                  100.0
                  *. Float.of_int mm.total_error_entries
                  /. Float.of_int mm.total_entries
                in
                let p95 =
                  match mm.fleet_p95_latency_ms with
                  | Some ms -> Observed.value ~observed_at:obs_at ms
                  | None -> Observed.unreported
                in
                ( Observed.value ~observed_at:obs_at mm.total_entries
                , Observed.value ~observed_at:obs_at err_pct
                , p95 )
            | Some _ | None ->
                (Observed.unreported, Observed.unreported, Observed.unreported)))
  in
  let microvm_count, ssh_count, docker_count =
    match Observed.to_option m.infra.sandboxes with
    | Some sb ->
        (sb.microvm_declared, sb.ssh_keepers_count, sb.docker_keepers_count)
    | None -> Fleet_store.fleet_infra_counts m.fleet
  in
  let active_goals_count =
    List.fold_left
      (fun acc (g : Wire_work.goal) ->
        match g.phase with
        | Wire_work.Executing | Wire_work.Verifying
        | Wire_work.Awaiting_confirmation ->
            acc + 1
        | Wire_work.Completed | Wire_work.Dropped | Wire_work.Paused _
        | Wire_work.Blocked _ ->
            acc)
      0 (Work_store.goals m.work)
  in
  let verifications_passed, verifications_rejected, verifications_awaiting =
    Work_store.verification_pass_summary m.work
  in
  let candle_circulating_milli =
    match Observed.to_option m.work.candle_ledger with
    | Some l -> Some l.circulating_milli
    | None -> (
        match m.fleet.candle_summary_fallback with
        | Some (Wire_fleet.Candle_ready supply) -> Some supply.circulating_milli
        | Some (Wire_fleet.Candle_off | Wire_fleet.Candle_disabled _) | None ->
            None)
  in
  {
    running_keepers;
    total_keepers;
    company_count;
    turns_24h = sc.turns_24h;
    tool_calls_24h;
    tool_error_rate_pct;
    p95_latency_ms;
    cache_hit_pct = Runtime_store.effective_cache_hit_pct m.runtime;
    spend_24h_usd = Runtime_store.effective_spend_24h_usd m.runtime;
    microvm_count;
    ssh_count;
    docker_count;
    tasks_done_24h = sc.tasks_done_24h;
    tasks_done_total = sc.tasks_done_total;
    tasks_in_progress = sc.tasks_in_progress;
    active_goals_count;
    verifications_passed;
    verifications_rejected;
    verifications_awaiting;
    candle_circulating_milli;
  }

let sync_effective_scorecard ~now:_ m =
  let eff = effective_scorecard m in
  let fleet = Fleet_store.enrich_scorecard (fun _ -> eff) m.fleet in
  { m with fleet }

let observed_at_opt = function
  | Observed.Value { observed_at; _ } -> Some observed_at
  | Observed.Loading _
  | Observed.Absent
  | Observed.Unreported
  | Observed.Failed _ ->
      None

let latest_observed_at xs =
  List.fold_left
    (fun acc ts_opt ->
      match acc, ts_opt with
      | None, Some t -> Some t
      | Some a, Some b -> Some (Clock.Mono.max a b)
      | (Some _ | None), None -> acc)
    None xs

let is_freshness_live = function
  | Health.Live _ -> true
  | Health.Connecting
  | Health.Reconnecting _
  | Health.Stale _
  | Health.Disconnected _
  | Health.Workspace_mismatch _ ->
      false

let freshness_severity = function
  | Health.Live _ -> 0
  | Health.Connecting -> 1
  | Health.Stale _ -> 2
  | Health.Reconnecting _ -> 3
  | Health.Disconnected _ -> 4
  | Health.Workspace_mismatch _ -> 5

let worse_freshness a b =
  if freshness_severity b > freshness_severity a then b else a

let active_view_ssot_mode m =
  let blocked =
    m.freshness.server_offline
    || (match m.server_identity.mismatch_state with
       | Mismatch_none -> false
       | Mismatch_recovering | Mismatch_halted -> true)
    ||
    match m.nav.overlay with
    | Some (Nav.System_gate (Nav.Auth_gate | Nav.Server_offline)) -> true
    | Some
        ( Nav.System_gate (Nav.Micro_viewport | Nav.Media_viewer)
        | Nav.Palette
        | Nav.Settings _
        | Nav.Incidents
        | Nav.Queue_context _
        | Nav.Inline_action _
        | Nav.Ask_answer
        | Nav.Help )
    | None ->
        false
  in
  let has_view_stream =
    match active_dive m with
    | Some _ -> false
    | None -> (
        match m.nav.workspace with
        | Nav.Runtime -> (
            match m.runtime.active_tab with
            | Nav.Runtime_efficiency_spend | Nav.Runtime_tools_usage -> true
            | Nav.Runtime_quotas_credits
            | Nav.Runtime_failover_lanes
            | Nav.Runtime_fusion
            | Nav.Runtime_connectors
            | Nav.Runtime_addons_browser ->
                false)
        | Nav.Infra -> (
            match m.infra.active_tab with
            | Nav.Infra_activity_logs -> true
            | Nav.Infra_sandboxes | Nav.Infra_repos_changes | Nav.Infra_code ->
                false)
        | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers -> false)
  in
  let planned_count = if blocked then 0 else if has_view_stream then 3 else 2 in
  let live_count =
    if blocked then 0
    else
      (if is_freshness_live m.freshness.observer then 1 else 0)
      + (if is_freshness_live m.freshness.fleet then 1 else 0)
      +
      if
        has_view_stream
        && Option.fold ~none:false ~some:is_freshness_live m.freshness.view_stream
      then 1
      else 0
  in
  let view_or_connecting =
    match m.freshness.view_stream with
    | Some f -> f
    | None -> Health.Connecting
  in
  match active_dive m with
  | Some (Nav.Dive_keeper { tab = Nav.Keeper_chat; _ }) ->
      Live_sse
        {
          stream_name = "fleet/stream";
          freshness = m.freshness.fleet;
          live_count;
          planned_count;
        }
  | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_context }) ->
      let ks = Keeper_context_store.get_keeper ~keeper:name m.keeper_context in
      Synced_snapshot
        {
          observer = m.freshness.observer;
          observed_at =
            latest_observed_at
              [
                observed_at_opt ks.turn_records;
                observed_at_opt ks.next_request;
                observed_at_opt ks.cache_outcome;
              ];
        }
  | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_tool_calls }) ->
      let ks = Keeper_context_store.get_keeper ~keeper:name m.keeper_context in
      Synced_snapshot
        {
          observer = m.freshness.observer;
          observed_at =
            latest_observed_at
              [
                observed_at_opt ks.tool_stats;
                observed_at_opt ks.tool_calls;
              ];
        }
  | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_memory }) ->
      Synced_snapshot
        {
          observer = m.freshness.observer;
          observed_at =
            latest_observed_at
              [
                observed_at_opt
                  (Knowledge_store.memory_diff_for ~keeper:(Some name)
                     ~window:m.knowledge.memory_diff_window m.knowledge);
                observed_at_opt
                  (Knowledge_store.memory_os_internals_for ~keeper:name
                     m.knowledge);
              ];
        }
  | Some (Nav.Dive_keeper { tab = Nav.Keeper_work_candle; _ }) ->
      Synced_snapshot
        {
          observer = m.freshness.observer;
          observed_at =
            latest_observed_at
              [
                observed_at_opt m.work.planning;
                observed_at_opt m.work.candle_ledger;
              ];
        }
  | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_sandbox }) ->
      Synced_snapshot
        {
          observer = m.freshness.observer;
          observed_at =
            latest_observed_at
              [
                observed_at_opt
                  (Infra_store.keeper_sandbox_for ~keeper:name m.infra);
                observed_at_opt m.infra.sandboxes;
              ];
        }
  | Some (Nav.Dive_keeper { tab = Nav.Keeper_config; _ }) ->
      Synced_snapshot
        {
          observer = m.freshness.observer;
          observed_at =
            latest_observed_at
              [
                observed_at_opt m.runtime.runtime_config_raw;
                observed_at_opt m.config.schema;
              ];
        }
  | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_logs }) ->
      let ks = Keeper_context_store.get_keeper ~keeper:name m.keeper_context in
      Synced_snapshot
        {
          observer = m.freshness.observer;
          observed_at =
            latest_observed_at
              [
                observed_at_opt ks.metrics;
                observed_at_opt ks.sandbox_logs;
              ];
        }
  | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_identity }) ->
      let ks = Keeper_context_store.get_keeper ~keeper:name m.keeper_context in
      Synced_snapshot
        {
          observer = m.freshness.observer;
          observed_at =
            latest_observed_at
              [
                observed_at_opt m.keeper_context.oauth_providers;
                observed_at_opt ks.oauth_attached;
                observed_at_opt ks.github_identity;
              ];
        }
  | Some (Nav.Dive_work _) ->
      Synced_snapshot
        {
          observer = m.freshness.observer;
          observed_at =
            latest_observed_at
              [
                observed_at_opt m.work.planning;
                observed_at_opt m.work.verifications;
              ];
        }
  | Some (Nav.Dive_knowledge target) -> (
      match target with
      | Nav.Thread_dive _ ->
          Synced_snapshot
            {
              observer = m.freshness.observer;
              observed_at =
                latest_observed_at
                  [
                    observed_at_opt m.knowledge.active_thread;
                    observed_at_opt m.knowledge.board;
                  ];
            }
      | Nav.Wiki_dive slug ->
          Snapshot_only
            {
              observed_at =
                observed_at_opt (Knowledge_store.wiki_page_for ~slug m.knowledge);
            }
      | Nav.Artifact_dive _ ->
          Snapshot_only
            {
              observed_at =
                latest_observed_at
                  [
                    observed_at_opt m.knowledge.active_artifact_detail;
                    observed_at_opt m.knowledge.artifacts;
                  ];
            }
      | Nav.Memory_diff_dive { keeper; from_rev; to_rev } ->
          Synced_snapshot
            {
              observer = m.freshness.observer;
              observed_at =
                observed_at_opt
                  (Knowledge_store.memory_diff_for ~keeper
                     ~window:(Knowledge_store.Window_revs { from_rev; to_rev })
                     m.knowledge);
            })
  | Some (Nav.Dive_runtime (Nav.Tool_dive _)) ->
      Synced_snapshot
        {
          observer = m.freshness.observer;
          observed_at =
            latest_observed_at
              [
                observed_at_opt m.runtime.tool_detail_series;
                observed_at_opt m.runtime.tools_dashboard;
              ];
        }
  | Some (Nav.Dive_runtime (Nav.Fusion_dive _)) ->
      Synced_snapshot
        {
          observer = m.freshness.observer;
          observed_at =
            latest_observed_at
              [
                observed_at_opt m.runtime.fusion_detail;
                observed_at_opt m.runtime.fusion_runs;
              ];
        }
  | Some (Nav.Dive_infra target) -> (
      match target with
      | Nav.Sandbox_dive keeper ->
          Synced_snapshot
            {
              observer = m.freshness.observer;
              observed_at =
                latest_observed_at
                  [
                    observed_at_opt
                      (Infra_store.keeper_sandbox_for ~keeper m.infra);
                    observed_at_opt m.infra.sandboxes;
                  ];
            }
      | Nav.Lane_dive _ ->
          Synced_snapshot
            {
              observer = m.freshness.observer;
              observed_at = observed_at_opt m.runtime.runtime_resolved;
            }
      | Nav.Runtime_trace_dive _ ->
          Synced_snapshot
            {
              observer = m.freshness.observer;
              observed_at = observed_at_opt m.infra.runtime_trace;
            }
      | Nav.Incident_dive _ | Nav.Log_detail_dive _ ->
          Snapshot_only { observed_at = None })
  | None -> (
      match m.nav.workspace with
      | Nav.Pulse ->
          Live_sse
            {
              stream_name = "fleet+observer";
              freshness = worse_freshness m.freshness.observer m.freshness.fleet;
              live_count;
              planned_count;
            }
      | Nav.Keepers ->
          Live_sse
            {
              stream_name = "fleet/stream";
              freshness = m.freshness.fleet;
              live_count;
              planned_count;
            }
      | Nav.Work ->
          let observed_at =
            match m.work.active_tab with
            | Nav.Work_pipeline ->
                latest_observed_at
                  [
                    observed_at_opt m.work.planning;
                    observed_at_opt m.work.verifications;
                  ]
            | Nav.Work_tasks -> observed_at_opt m.work.planning
            | Nav.Work_schedules -> observed_at_opt m.work.schedules
            | Nav.Work_inbox ->
                latest_observed_at
                  [
                    observed_at_opt m.work.asks;
                    observed_at_opt m.work.tool_approvals;
                    observed_at_opt m.work.gate_pending;
                  ]
            | Nav.Work_candle_scorecard ->
                observed_at_opt m.work.candle_ledger
            | Nav.Work_harness -> observed_at_opt m.work.harness_health
          in
          Synced_snapshot { observer = m.freshness.observer; observed_at }
      | Nav.Knowledge -> (
          match m.knowledge.active_tab with
          | Nav.Knowledge_board ->
              Synced_snapshot
                {
                  observer = m.freshness.observer;
                  observed_at = observed_at_opt m.knowledge.board;
                }
          | Nav.Knowledge_wiki ->
              let page_obs =
                match Knowledge_store.selected_wiki_page m.knowledge with
                | Some s ->
                    observed_at_opt
                      (Knowledge_store.wiki_page_for ~slug:s.slug m.knowledge)
                | None -> None
              in
              Synced_snapshot
                {
                  observer = m.freshness.observer;
                  observed_at =
                    latest_observed_at
                      [ observed_at_opt m.knowledge.wiki_index; page_obs ];
                }
          | Nav.Knowledge_artifacts ->
              Synced_snapshot
                {
                  observer = m.freshness.observer;
                  observed_at =
                    latest_observed_at
                      [
                        observed_at_opt m.knowledge.artifacts;
                        observed_at_opt m.knowledge.active_artifact_detail;
                      ];
                }
          | Nav.Knowledge_memory ->
              Synced_snapshot
                {
                  observer = m.freshness.observer;
                  observed_at =
                    latest_observed_at
                      [
                        observed_at_opt m.knowledge.world_memory;
                        observed_at_opt
                          (Knowledge_store.current_memory_diff m.knowledge);
                      ];
                })
      | Nav.Runtime -> (
          match m.runtime.active_tab with
          | Nav.Runtime_efficiency_spend ->
              Live_sse
                {
                  stream_name = "models/metrics";
                  freshness = view_or_connecting;
                  live_count;
                  planned_count;
                }
          | Nav.Runtime_tools_usage ->
              Live_sse
                {
                  stream_name = "tool-metrics";
                  freshness = view_or_connecting;
                  live_count;
                  planned_count;
                }
          | Nav.Runtime_quotas_credits ->
              Synced_snapshot
                {
                  observer = m.freshness.observer;
                  observed_at =
                    latest_observed_at
                      [
                        observed_at_opt m.runtime.usage_history;
                        observed_at_opt m.runtime.usage_windows;
                        observed_at_opt m.runtime.runtime_resolved;
                      ];
                }
          | Nav.Runtime_failover_lanes ->
              Synced_snapshot
                {
                  observer = m.freshness.observer;
                  observed_at =
                    latest_observed_at
                      [
                        observed_at_opt m.runtime.runtime_resolved;
                        observed_at_opt m.runtime.runtime_probe;
                      ];
                }
          | Nav.Runtime_fusion ->
              Synced_snapshot
                {
                  observer = m.freshness.observer;
                  observed_at =
                    latest_observed_at
                      [
                        observed_at_opt m.runtime.fusion_runs;
                        observed_at_opt m.runtime.exact_lane_runs;
                      ];
                }
          | Nav.Runtime_connectors ->
              Synced_snapshot
                {
                  observer = m.freshness.observer;
                  observed_at =
                    latest_observed_at
                      [
                        observed_at_opt m.runtime.connectors;
                        observed_at_opt m.runtime.mcp_clients;
                      ];
                }
          | Nav.Runtime_addons_browser ->
              Synced_snapshot
                {
                  observer = m.freshness.observer;
                  observed_at =
                    latest_observed_at
                      [
                        observed_at_opt m.runtime.lane_addons;
                        observed_at_opt m.runtime.browser_lane;
                      ];
                })
      | Nav.Infra -> (
          match m.infra.active_tab with
          | Nav.Infra_activity_logs ->
              Live_sse
                {
                  stream_name = "logs/stream";
                  freshness = view_or_connecting;
                  live_count;
                  planned_count;
                }
          | Nav.Infra_sandboxes ->
              Synced_snapshot
                {
                  observer = m.freshness.observer;
                  observed_at = observed_at_opt m.infra.sandboxes;
                }
          | Nav.Infra_code ->
              Snapshot_only
                {
                  observed_at =
                    latest_observed_at
                      [
                        observed_at_opt m.infra.code.open_file;
                        observed_at_opt m.infra.code.git_status;
                      ];
                }
          | Nav.Infra_repos_changes ->
              Snapshot_only
                {
                  observed_at =
                    latest_observed_at
                      [
                        observed_at_opt m.infra.repositories;
                        Option.bind m.infra.repo_activity
                          (fun (a : Infra_store.repo_activity) ->
                            observed_at_opt a.activity);
                      ];
                }))

let trimmed_nonempty_opt = function
  | None -> None
  | Some s ->
      let t = String.trim s in
      if String.equal t "" then None else Some t

let short_commit_opt commit_opt =
  match trimmed_nonempty_opt commit_opt with
  | None -> None
  | Some t ->
      if String.length t <= 8 then Some t else Some (String.sub t 0 8)

let format_version_tag raw_ver =
  let v = String.trim raw_ver in
  let len = String.length v in
  if len = 0 then ""
  else if Char.equal v.[0] 'v' || Char.equal v.[0] 'V' then v
  else "v" ^ v

let format_build_label ~version ~commit =
  let ver_tag = format_version_tag version in
  match (ver_tag, short_commit_opt commit) with
  | "", None -> ""
  | "", Some short -> short
  | v, None -> v
  | v, Some short -> Printf.sprintf "%s (%s)" v short

let effective_server_build (m : t) =
  let ver =
    match trimmed_nonempty_opt m.server_identity.observer_version with
    | Some _ as v -> v
    | None -> (
        match m.server_identity.health with
        | Some h -> trimmed_nonempty_opt (Some h.version)
        | None -> None)
  in
  let commit =
    match trimmed_nonempty_opt m.server_identity.observer_commit with
    | Some _ as c -> c
    | None -> (
        match m.server_identity.health with
        | Some h -> trimmed_nonempty_opt h.binary_commit
        | None -> None)
  in
  (ver, commit)

let tui_build_label m =
  format_build_label ~version:m.tui_version ~commit:m.tui_commit

let server_build_label m =
  let ver_opt, commit_opt = effective_server_build m in
  let version = match ver_opt with Some v -> v | None -> "" in
  let label = format_build_label ~version ~commit:commit_opt in
  if String.equal label "" then None else Some label

let build_commit_mismatch m =
  let _, server_commit = effective_server_build m in
  match (trimmed_nonempty_opt m.tui_commit, server_commit) with
  | Some tc, Some sc ->
      let a = String.lowercase_ascii tc in
      let b = String.lowercase_ascii sc in
      let la = String.length a in
      let lb = String.length b in
      if Int.equal la lb then not (String.equal a b)
      else
        let n = Int.min la lb in
        not (String.equal (String.sub a 0 n) (String.sub b 0 n))
  | (Some _ | None), (Some _ | None) -> false

let focused_artifact m =
  match active_dive m with
  | Some (Nav.Dive_knowledge (Nav.Artifact_dive target)) ->
      Knowledge_store.find_artifact_by_id_or_sha target m.knowledge
  | Some
      ( Nav.Dive_keeper _
      | Nav.Dive_work _
      | Nav.Dive_runtime _
      | Nav.Dive_infra _
      | Nav.Dive_knowledge
          (Nav.Thread_dive _ | Nav.Wiki_dive _ | Nav.Memory_diff_dive _) )
  | None ->
      Knowledge_store.selected_artifact m.knowledge
