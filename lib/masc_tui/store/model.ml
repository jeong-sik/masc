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
  dive_scroll_offset : int;
  help_scroll_offset : int;
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
        dive_scroll_offset = 0;
        help_scroll_offset = 0;
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
              | Attention.Payload_ask _ | Attention.Payload_quarantine _ -> None)
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

let outer_margin_for = function
  | Wide | Standard -> 1
  | Compact | Micro -> 0

let inner_body_width m =
  let cols = max 0 m.viewport.cols in
  let margin = outer_margin_for m.breakpoint in
  if margin <= 0 || cols <= margin * 2 then cols else cols - (margin * 2)

let has_sub_tab_bar_for_model m =
  match active_dive m with
  | Some _ -> true
  | None -> (
      match m.nav.workspace with
      | Nav.Pulse -> false
      | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Runtime | Nav.Infra -> true)

let inner_body_height m =
  let rows = max 0 m.viewport.rows in
  let top_rail_h = if rows >= 1 then 1 else 0 in
  let footer_h = if rows >= 2 then 1 else 0 in
  if is_too_small_viewport m.viewport || equal_breakpoint m.breakpoint Micro
  then max 0 (rows - top_rail_h - footer_h)
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
    let approval_y = rows - footer_h - footer_sep_h - comp_h - approval_h in
    max 0 (approval_y - top_h)

let work_pipeline_has_linked_card m =
  inner_body_width m >= 96 && inner_body_height m >= 14

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
        | Nav.Knowledge_board | Nav.Knowledge_memory -> true
        | Nav.Knowledge_wiki_artifacts -> (
            match m.knowledge.wiki_artifacts_submode with
            | `Wiki -> true
            | `Artifacts -> false))
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
                  let has_changes_for_repo =
                    match Infra_store.selected_repository m.infra with
                    | Some r -> (
                        r.keepers <> []
                        &&
                        match m.infra.file_changes_keeper with
                        | Some k ->
                            List.exists (String.equal k) r.keepers
                            && Infra_store.filtered_file_changes m.infra <> []
                        | None -> false)
                    | None -> Infra_store.filtered_file_changes m.infra <> []
                  in
                  if has_changes_for_repo then 3 else 2))

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
                          | Attention.Payload_goal_confirmation _
                          | Attention.Payload_quarantine _ );
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

let is_text_capture_active m =
  if m.nav.filter_focused || Drafts.is_focused m.drafts then true
  else
    match m.nav.overlay with
    | Some Nav.Palette | Some (Nav.Inline_action _) -> true
    | Some (Nav.Settings _) -> Config_store.is_editing_field m.config
    | Some (Nav.Incidents | Nav.Queue_context _ | Nav.Help | Nav.System_gate _)
    | None ->
        false

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
    | Nav.Harness_overrule _ ->
        [
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
            label = Say.make ~ko:"반복 주기" ~en:"Recurrence";
            value = "every 1h";
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
            label = Say.make ~ko:"채널" ~en:"Channel";
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
      ~quarantines:(Knowledge_store.quarantines_list m.knowledge)
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
    prs_reviewed_24h = Observed.unreported;
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
    prs_reviewed_24h = base.prs_reviewed_24h;
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
        | Some cs -> Some cs.circulating_milli
        | None -> None)
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
