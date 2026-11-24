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
  zoomed : bool;
  filter_focused : bool;
  sidebar_open : bool option;
  sidebar_focused : bool;
  sidebar_cursor : int;
  sidebar_scroll : int;
  dive_scroll_offset : int;
  help_scroll_offset : int;
  queue_scroll_offset : int;
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
  server_offline : bool;
}

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
  tz_offset_sec : int;
  nav : nav_state;
  freshness : freshness_state;
  server_identity : server_identity;
  attention : Attention.t;
  incidents : Incidents.t;
  drafts : Drafts.t;
  fleet : Fleet_store.t;
  work : Work_store.t;
  knowledge : Knowledge_store.t;
  runtime : Runtime_store.t;
  infra : Infra_store.t;
  config : Config_store.t;
  palette : palette_state;
  inline_modal : inline_modal_state option;
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
    ?(theme_preset = Theme.Midnight) ?(tz_offset_sec = 0) ?(wall_unix = 0.0) () =
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
    tz_offset_sec;
    nav =
      {
        workspace = Nav.Pulse;
        dive_stack = [];
        overlay = None;
        pane_index = 0;
        zoomed = false;
        filter_focused = false;
        sidebar_open = None;
        sidebar_focused = false;
        sidebar_cursor = 0;
        sidebar_scroll = 0;
        dive_scroll_offset = 0;
        help_scroll_offset = 0;
        queue_scroll_offset = 0;
      };
    freshness =
      {
        observer = Health.Connecting;
        fleet = Health.Connecting;
        view_stream = None;
        last_observer_cursor = None;
        last_wall_unix;
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
    fleet = Fleet_store.empty;
    work = Work_store.empty;
    knowledge = Knowledge_store.empty;
    runtime = Runtime_store.empty;
    infra = Infra_store.empty;
    config = Config_store.empty;
    palette = { mode = Palette_commands; query = ""; selected = 0 };
    inline_modal = None;
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
      false

let fast_approval_strip_item m =
  if is_too_small_viewport m.viewport then None
  else
    match m.nav.overlay with
    | Some (Nav.System_gate _) -> None
    | Some
        ( Nav.Palette
        | Nav.Settings _
        | Nav.Incidents
        | Nav.Queue_context _
        | Nav.Inline_action _
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
  | Some (Nav.Palette | Nav.Inline_action _ | Nav.System_gate _) | None -> (
      match m.nav.workspace with
      | Nav.Pulse -> Nav.Menu_pulse
      | Nav.Work -> Nav.Menu_work m.work.active_tab
      | Nav.Knowledge -> Nav.Menu_knowledge m.knowledge.active_tab
      | Nav.Keepers -> Nav.Menu_keepers
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
        | Nav.Knowledge_board | Nav.Knowledge_wiki | Nav.Knowledge_memory ->
            true
        | Nav.Knowledge_artifacts -> false)
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
        | Nav.Help
        | Nav.System_gate _ ) ->
        1
    | None -> (
        if Option.is_some (active_dive m) || (m.nav.zoomed && can_zoom_current_view m)
        then 1
        else
          match m.nav.workspace with
          | Nav.Pulse -> List.length (pulse_panes m)
          | Nav.Work -> (
              match m.work.active_tab with
              | Nav.Work_pipeline ->
                  if work_pipeline_has_linked_card m then 3 else 2
              | Nav.Work_tasks_schedules ->
                  if
                    Work_store.filtered_tasks m.work <> []
                    && Work_store.filtered_schedules m.work <> []
                  then 2
                  else 1
              | Nav.Work_inbox ->
                  if
                    Attention.filtered_items ~query:m.work.filter_query
                      m.attention
                    = []
                  then 1
                  else 2
              | Nav.Work_candle_scorecard -> 1)
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
              | Nav.Runtime_quotas_credits
              | Nav.Runtime_failover_lanes
              | Nav.Runtime_tools_connectors ->
                  2)
          | Nav.Infra -> (
              match m.infra.active_tab with
              | Nav.Infra_sandboxes ->
                  if inner_body_width m >= 100 then 2 else 1
              | Nav.Infra_activity_logs -> 2
              | Nav.Infra_repos_changes ->
                  if Infra_store.repo_changes m.infra <> [] then 3 else 2))

let active_focus_scope m =
  if is_too_small_viewport m.viewport then
    Nav.Overlay_focused (Nav.System_gate Nav.Micro_viewport)
  else
    match m.nav.overlay with
    | Some ov -> Nav.Overlay_focused ov
    | None -> (
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
  let approval_strip_active =
    if
      (not (is_too_small_viewport m.viewport))
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
  | Some (Nav.System_gate _) ->
      Say.make ~ko:"시스템 게이트" ~en:"SYSTEM GATE"
  | None -> (
      if m.nav.filter_focused then Say.make ~ko:"필터 입력" ~en:"FILTER"
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
        | Some (Nav.Dive_keeper { name; _ }) ->
            Say.make ~ko:("상세 · " ^ name) ~en:("DIVE · " ^ name)
        | Some (Nav.Dive_work _) ->
            Say.make ~ko:"작업 상세" ~en:"WORK DIVE"
        | Some (Nav.Dive_knowledge _) ->
            Say.make ~ko:"지식 상세" ~en:"KNOWLEDGE DIVE"
        | Some (Nav.Dive_infra (Nav.Lane_dive id)) ->
            Say.make ~ko:("레인 · " ^ id) ~en:("LANE · " ^ id)
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
                | Nav.Work_tasks_schedules ->
                    if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"예약 일정" ~en:"Schedules"
                    else pane_prefix ~ko:"작업 목록" ~en:"Tasks"
                | Nav.Work_inbox ->
                    if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"인스펙터" ~en:"Inspector"
                    else pane_prefix ~ko:"수신함" ~en:"Inbox"
                | Nav.Work_candle_scorecard ->
                    Say.make ~ko:"캔들 · 원장" ~en:"Candle")
            | Nav.Knowledge -> (
                match m.knowledge.active_tab with
                | Nav.Knowledge_board ->
                    if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"타래 보기" ~en:"Thread"
                    else pane_prefix ~ko:"보드" ~en:"Board"
                | Nav.Knowledge_wiki ->
                    if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"위키 보기" ~en:"Wiki View"
                    else pane_prefix ~ko:"위키 트리" ~en:"Wiki Tree"
                | Nav.Knowledge_artifacts ->
                    if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"산출물 상세" ~en:"Artifact"
                    else pane_prefix ~ko:"산출물 목록" ~en:"Artifacts"
                | Nav.Knowledge_memory ->
                    if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"기억 탐색" ~en:"Explorer"
                    else pane_prefix ~ko:"기억 범위" ~en:"Memory Scope")
            | Nav.Keepers ->
                if m.nav.pane_index = 1 then
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
                | Nav.Runtime_tools_connectors ->
                    if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"커넥터·MCP" ~en:"Connectors"
                    else pane_prefix ~ko:"도구 목록" ~en:"Tools")
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
                | Nav.Infra_activity_logs ->
                    if m.nav.pane_index = 1 then
                      pane_prefix ~ko:"로그 상세" ~en:"Detail"
                    else pane_prefix ~ko:"활동·로그" ~en:"Logs")))

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
              | Nav.Keeper_memory
              | Nav.Keeper_work_candle
              | Nav.Keeper_sandbox );
            _;
          }
      | Nav.Dive_work _
      | Nav.Dive_knowledge _
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
            label = Say.make ~ko:"커넥터 종류" ~en:"Connector kind";
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
  in
  { kind; fields; active_field = 0; submitting = false; error = None }

let modal_field_value ~key modal =
  match
    List.find_opt (fun (f : modal_form_field) -> String.equal f.key key) modal.fields
  with
  | Some f -> String.trim f.value
  | None -> ""

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

let with_toast ~now ?(duration_s = 4.0) ~level message m =
  let expires_at = Clock.Mono.after_s now duration_s in
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
    match Fleet_store.total_turns_24h m.fleet with
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
