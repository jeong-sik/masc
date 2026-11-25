(** Pure immutable root TEA [Model.t] (~20 top-level fields) plus pure
    selectors for viewport breakpoints, focus scope chains, Compact composer
    auto-fold, and the fast-path Approval Strip.

    Zero mutable fields, zero Eio/IO imports, zero UI rendering dependencies. *)

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
  dive_return_stack : (int * bool * Nav.overlay option) list;
      (** Parallel return frames [(pane_index, zoomed, overlay)] captured on
          {!Update_nav.push_dive} and restored when [Esc] pops {!dive_stack}. *)
  overlay : Nav.overlay option;
  pane_index : int;
  pre_zoom_pane_index : int option;
  zoomed : bool;
  filter_focused : bool;
  sidebar_open : bool option;
      (** [None] = auto-docked when [cols >= 132] on non-[Micro] non-too-small
          viewports ([cols >= 132 && rows >= 24]), hidden narrower;
          [Some true] = explicitly shown (docked or floating drawer);
          [Some false] = explicitly collapsed. *)
  sidebar_focused : bool;
  sidebar_cursor : int;
  sidebar_scroll : int;
  dive_scroll_offset : int;
  json_scroll_offset : int;
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
  submission_id : int;
  error : string option;
}

module Ask_draft_key : sig
  type t = string * string
  val compare : t -> t -> int
end

module Ask_draft_map : Map.S with type key = Ask_draft_key.t

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
  lane_addon_declaration_id : string option;
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
  quit_armed_at : Clock.Mono.t option;
  keeper_stop_armed : (string * Clock.Mono.t) option;
  keeper_resume_op_ids : (string * string * int) list;
  keeper_lifecycle_seq : int;
  modal_submission_seq : int;
}

val quit_arm_window_s : float
(** Seconds during which a second [Ctrl+Q] confirms and exits the TUI. *)

val keeper_stop_arm_window_s : float
(** Seconds during which a second [D] confirms and shuts down the armed Keeper. *)

val keeper_stop_arm_toast_message : name:string -> Say.t
(** Single-SSOT warning toast shown while [D] stop-confirmation is armed. *)

val disarm_keeper_stop : t -> t
(** Clear [keeper_stop_armed] and any matching {!keeper_stop_arm_toast_message}
    warning toast without disturbing unrelated toasts. *)

val next_keeper_lifecycle_seq : t -> int * t
(** Mint a strictly monotonic sequence number for a Keeper lifecycle POST or
    resume operation id. Never reset across epochs. *)

val next_modal_submission_id : t -> int * t
(** Mint a strictly monotonic submission identifier for an inline modal POST.
    Never reset across epochs. *)

val modal_mark_submitting_with_id : inline_modal_state -> t -> int * t
(** Mint a fresh submission id via {!next_modal_submission_id} and mark the
    modal submitting with that exact [submission_id] and cleared error. *)

val resume_op_id_for : keeper:string -> t -> string option
(** Return the currently pinned resume [operator_operation_id] for [keeper],
    if any. *)

val get_or_create_resume_op_id : keeper:string -> t -> string * t
(** Return the pending [operator_operation_id] for [keeper] if one exists
    (for idempotent retry), or mint and record a fresh unique ID tagged with
    its monotonic [minted_seq]. *)

val clear_resume_op_id :
  keeper:string -> operator_operation_id:string -> t -> t
(** Remove [keeper]'s pending [operator_operation_id] when it matches the
    committed/completed [operator_operation_id]. *)

val clear_resume_op_ids_for_keeper :
  keeper:string -> before_seq:int -> t -> t
(** Remove pending [operator_operation_id] entries for [keeper] whose
    [minted_seq < before_seq], so an out-of-order delayed [ok = true] reply
    from an earlier lifecycle POST can never erase a later resume's id. *)

val equal_breakpoint : breakpoint -> breakpoint -> bool
val equal_composer_mode : composer_mode -> composer_mode -> bool
val equal_palette_mode : palette_mode -> palette_mode -> bool
val equal_mismatch_state : mismatch_state -> mismatch_state -> bool
val equal_pulse_pane : pulse_pane -> pulse_pane -> bool

val pulse_panes : t -> pulse_pane list
(** Ordered interactive panes rendered on [1 Pulse] (omitting [Pulse_attention]
    when the human action queue is empty). *)

val active_pulse_pane : t -> pulse_pane
(** Currently focused {!pulse_pane} derived from [m.nav.pane_index] and
    {!pulse_panes}. *)

val inner_body_width : t -> int
(** Exact inset body width matching [Layout.inset_body] / [Chrome.compute_layout],
    accounting for the docked Left Navigation Sidebar when visible. *)

val inner_body_height : t -> int
(** Exact inset body height matching [Chrome.compute_layout]. *)

val keeper_dive_focused : t -> bool
(** The selected Keeper detail occupies the body without the navigation menu. *)

val sidebar_width : int
val sidebar_gap : int
val sidebar_docked_min_cols : int
val sidebar_docked : t -> bool
val sidebar_drawer_open : t -> bool
val sidebar_visible : t -> bool
val sidebar_has_focus : t -> bool
(** [true] iff the Left Navigation Sidebar is currently visible and owns
    keyboard focus (no overlay, filter bar, or composer active). Single source
    of truth so resizing to a narrower viewport can never trap focus in a
    hidden sidebar. *)

type sidebar_row =
  | Sidebar_section of Nav.menu_section
  | Sidebar_item of {
      index : int;
      item : Nav.menu_item;
    }

val sidebar_visual_rows : sidebar_row list
val sidebar_cursor_visual_row : cursor:int -> int
val sidebar_viewport_start : inner_h:int -> scroll:int -> cursor:int -> int
val sidebar_has_below_overflow : inner_h:int -> start:int -> bool
val sidebar_visible_data_rows : inner_h:int -> start:int -> int
val sidebar_hidden_below_sections : inner_h:int -> start:int -> Nav.menu_section list
val active_menu_target : t -> Nav.menu_target
val sync_sidebar_cursor : t -> t
val body_top_y : t -> int
val sidebar_rect : t -> Rect.t option
val body_rect : t -> Rect.t
val pane_rects : t -> Rect.t list
(** Exact screen rectangles of interactive panes in focus index order
    ([0 .. focusable_pane_count m - 1]) for SSOT mouse hit-testing across 2/3/4
    pane and compact vertical stacked layouts. *)
val composer_rect : t -> Rect.t option
(** Exact bottom composer rectangle matching [Chrome.compute_layout], or
    [None] when the composer is auto-folded or gated by Micro/too-small. *)

val work_pipeline_has_linked_card : t -> bool
(** [true] iff [2 Work > Pipeline] renders the bottom-left Linked Tasks &
    Verifications card ([inner_body_width >= 96 && inner_body_height >= 15],
    matching [left_rect.h = inner_body_height - 1 >= 14]). *)
val work_pipeline_verifs_visible : t -> bool
(** [true] iff [2 Work > Pipeline] pane 1 has both the Linked Card rendered and
    sufficient vertical space to display at least one verification row. *)

val can_zoom_current_view : t -> bool
(** [true] iff [z] ([Toggle_zoom]) renders a zoomed view on the active screen
    (Keeper detail, [Keepers] with a selected keeper, or [Knowledge]). *)

val focusable_pane_count : t -> int
(** Single source of truth for the exact number of interactive focusable panes
    currently rendered for [m]'s active view, sub-tab, breakpoint, zoom, and
    data state. Returns [1] when pane cycling is a no-op (never ghost panes). *)

val keeper_preview_has_inner_split : t -> bool
val has_active_memory_reading : t -> bool

val task_dive_has_two_main_panes : t -> string -> bool
(** [true] iff [Task_dive task_id] renders both a non-empty Description section
    and a linked Verification section as separate focusable panes. *)

val dive_work_json_pane_index : t -> int option
(** Active pane index of the opt-in Raw JSON card inside [Dive_work _], or
    [None] when [show_raw_json] is off. Returns [Some 0] when the viewport is
    too narrow ([< 88] cols) and JSON replaces the main card. *)

val classify_viewport : viewport -> breakpoint
val is_too_small_viewport : viewport -> bool

val initial :
  ?cols:int ->
  ?rows:int ->
  ?lang:Say.lang ->
  ?theme_preset:Theme.preset ->
  ?cli_lang_override:bool ->
  ?cli_theme_override:bool ->
  ?tz_offset_sec:int ->
  ?wall_unix:float ->
  ?tui_version:string ->
  ?tui_commit:string option ->
  unit ->
  t

val active_dive : t -> Nav.dive option

val drawer_queue :
  keeper:string -> t -> Fleet_store.chat_queue * Drafts.pending_message list
(** Server waiting rows and local transmissions not represented by those rows. *)

val target_keeper : t -> string option
(** The keeper the composer and the Ctrl+T drawer address: the composer's
    active keeper, else the selected roster keeper. *)

val is_keeper_lifecycle_surface : t -> bool
(** [true] iff no overlay, Micro/too-small viewport gate, text-capture input,
    or sidebar focus is active and the operator is on [4 Keepers] or inside a
    [Dive_keeper] view (where bare [W]/[D] lifecycle hotkeys apply). *)

val target_keeper_for_lifecycle : t -> string option
(** Single-SSOT target keeper for lifecycle actions ([W]/[D], slash commands,
    and [Ctrl+K] palette): active [Dive_keeper] name first, then on [4 Keepers]
    yielding [None] when a collapsed company header is focused on unzoomed
    [pane 0] else the selected roster keeper (including split [pane 1] and
    zoomed preview), else {!target_keeper}. *)
val is_in_keeper_chat : t -> bool
val uses_keeper_split : width:int -> t -> bool
val is_keeper_config_active : t -> bool
(** [true] when [overlay = None] and either [Dive_keeper { tab = Keeper_config }]
    is active, or [4 Keepers] Split [pane 1] / zoomed view has
    [fleet.keeper_dive_tab = Keeper_config]. *)
val fast_approval_strip_item : t -> Attention.entry option
val composer_mode : t -> composer_mode
(** Compact auto-fold selector: on {!Compact} / {!Micro}, folds to
    {!Auto_folded_pill} strictly when composer is unfocused, draft is empty,
    voice is off, there is no active transmission for the target keeper, and
    the operator is not inside [Keepers > Chat]. *)

val active_focus_scope : t -> Nav.focus_scope
val focus_scope_chain : t -> Keymap.scope list
val body_has_focus : t -> bool
(** [true] iff the main workspace/dive body owns keyboard focus (composer is
    unfocused, filter bar is unfocused, and no overlay is open). Body card
    renderers MUST gate [focused] through this SSOT helper so two surfaces never
    appear simultaneously focused. *)
val pane_focused : t -> int -> bool
(** [body_has_focus m && m.nav.pane_index = idx]. *)
val active_focus_label : t -> Say.t
(** Concise human-readable indicator of the currently focused surface/pane for
    the footer focus pill (e.g. ["1/2 Fleet"], ["COMPOSER"], ["FILTER"]). *)
val is_text_capture_active : t -> bool
(** [true] when a free-text input surface (composer, filter bar, palette,
    settings field editor, or inline modal) owns printable characters. *)

val inline_modal_for : Nav.inline_action_kind -> inline_modal_state
val is_viewing_wiki_slug : slug:string -> t -> bool
(** [true] when no overlay is open and the user is currently viewing [slug]
    either in the Knowledge Wiki tab or in a [Wiki_dive slug]. *)
val open_wiki_edit_modal_for_detail :
  Wire_knowledge.wiki_page_detail -> t -> t
(** Open the inline Wiki edit modal seeded with [detail], recording [detail]
    as [knowledge.wiki_edit_base] and clearing any pending wiki edit slug. *)
val modal_field_value : key:string -> inline_modal_state -> string
val modal_active_field_value : inline_modal_state -> string
val modal_field_multiline : modal_form_field -> bool
(** The inline form's body fields accept literal line breaks. *)
val modal_field_help : key:string -> Say.t option
(** Concise contextual help / allowed enum values for the focused inline modal
    field, rendered below the input row so short labels never clip options. *)
val modal_field_raw_value : key:string -> inline_modal_state -> string
(** Untrimmed field value for body editors (skills, prompt overrides). *)
val modal_update_active_field :
  (string -> string) -> inline_modal_state -> inline_modal_state
val modal_cycle_field : delta:int -> inline_modal_state -> inline_modal_state

val tool_approval_markdown : lang:Say.lang -> Wire_work.held_tool_approval -> string
(** The full approval request, including the reason when one was supplied. *)

(** {1 Dedicated Ask Answer Modal State & Pure Transitions} *)

val equal_ask_answer_mode : ask_answer_mode -> ask_answer_mode -> bool
val equal_ask_live_status : ask_live_status -> ask_live_status -> bool
val ask_choice_letters : string
(** Canonical ordered quick-pick choice letters inside the Ask Answer Modal
    (["abcdefhlmnopqrstuvwxyz"], skipping [g]/[i]/[j]/[k] reserved for
    home/free-text/down/up). *)
val ask_choice_hotkey_char : int -> char option
val ask_choice_index_of_char : char -> int option

val empty_ask_question_draft : ask_question_draft
val ask_modal_for :
  ?preselect_choice_1based:int -> Wire_work.ask_row -> ask_modal
val ask_modal_for_lane_addon : Wire_runtime.lane_addon_ask_row -> ask_modal
val ask_modal_current_question : ask_modal -> Wire_work.ask_question option
val ask_modal_rows : Wire_work.ask_question -> ask_modal_row list
val ask_modal_current_row : ask_modal -> ask_modal_row option
val ask_question_draft_for :
  ask_modal -> Wire_work.ask_question -> ask_question_draft
val ask_question_response :
  ask_modal -> Wire_work.ask_question -> Wire_work.ask_response option
val ask_modal_all_answered : ask_modal -> bool
val ask_modal_build_answers :
  ask_modal -> ((string * Wire_work.ask_response) list, int) result
val ask_live_status : t -> string -> ask_live_status
(** Derive whether [ask_id] is still open, in-flight, or already
    answered/withdrawn in live [m.attention]. *)

val ask_modal_move_cursor : delta:int -> ask_modal -> ask_modal
val ask_modal_set_cursor : int -> ask_modal -> ask_modal
val ask_modal_scroll_prompt : ?max_scroll:int -> delta:int -> ask_modal -> ask_modal
val ask_modal_prompt_markdown :
  compact:bool -> Wire_work.ask_row -> Wire_work.ask_question -> string
val ask_modal_select_question : int -> ask_modal -> ask_modal
val ask_modal_step_question : delta:int -> ask_modal -> ask_modal
val ask_modal_set_editing_free_text : bool -> ask_modal -> ask_modal
val ask_modal_enter_free_text : ask_modal -> ask_modal
val ask_modal_toggle_or_select_choice : int -> ask_modal -> ask_modal
val ask_modal_toggle_skip : ask_modal -> ask_modal
val ask_modal_set_skipped : ask_modal -> ask_modal
val ask_modal_insert_free_text : string -> ask_modal -> ask_modal
val ask_modal_backspace_free_text : ask_modal -> ask_modal
val ask_modal_delete_free_text : ask_modal -> ask_modal
val ask_modal_move_free_text_cursor :
  [ `Left | `Right | `Home | `End ] -> ask_modal -> ask_modal
val ask_modal_kill_free_text_start : ask_modal -> ask_modal
val ask_modal_confirm_free_text : ask_modal -> ask_modal * bool

val with_toast :
  now:Clock.Mono.t ->
  ?duration_s:float ->
  level:toast_level ->
  Say.t ->
  t ->
  t

val with_incident :
  source:Health.incident_source ->
  summary:Say.t ->
  detail:string ->
  status:Health.incident_status ->
  t ->
  t
(** Append a Channel 3 historical incident to [m.incidents] using
    [m.freshness.last_wall_unix] without mutating Channel 2 live health. *)

val expire_toast : now:Clock.Mono.t -> t -> t

val rebuild_attention : t -> t
(** Recompute Channel 1 {!Attention.t} from authoritative work/knowledge
    slices without touching Channel 2 live health or Channel 3 incidents. *)

val mark_all_domains_stale : t -> t

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

val effective_scorecard : t -> Wire_fleet.daily_scorecard
(** Merge [fleet.shell.scorecard_24h] with authoritative live readings from
    [work.planning]/[backlog_counts], [work.verifications], [fleet.keepers]
    24h turn pulses, [runtime.models_metrics]/[runtime_metrics]/[keeper_costs],
    and [knowledge.board] so Pulse never falls back to [—] when live data exists. *)

val pulse_hero_metrics : t -> pulse_hero_metrics
(** Single authoritative selector for the Pulse 4-KPI Hero Band & 24h Daily
    Scorecard across both live [8935] and [feat/tui-v2] servers. *)

val sync_effective_scorecard : now:Clock.Mono.t -> t -> t
(** Project {!effective_scorecard} back onto [fleet.shell.scorecard_24h] when
    shell is loaded so legacy and v2.5 Pulse views read consistent metrics. *)

val active_view_ssot_mode : t -> view_ssot_mode
(** Honest per-view SSOT telemetry provenance derived purely from [(m.nav,
    m.freshness)] and the active surface's primary {!Observed.t} timestamp. *)

val tui_build_label : t -> string
(** Concise TUI executable build label derived from [m.tui_version] and the
    first 8 chars of [m.tui_commit] (e.g. ["v0.81.0 (2a58dc57)"], ["v0.81.0"]
    when commit is absent/blank, or [""] when both are absent). Safe on short
    commit strings. *)

val server_build_label : t -> string option
(** Concise connected server build label derived from
    [m.server_identity.observer_version] and [observer_commit] (falling back to
    [server_identity.health] before the observer handshake completes), e.g.
    [Some "v0.81.0 (4a271ac5)"], or [None] when neither version nor commit has
    been observed. *)

val build_commit_mismatch : t -> bool
(** [true] iff both the TUI's embedded commit and the server's reported commit
    are non-empty and disagree. *)

val focused_artifact : t -> Wire_knowledge.artifact_entry option
(** Authoritative artifact for [Nav.Media_viewer] rendering, scrolling, and
    actions: resolves the [Nav.Artifact_dive] target when diving into an
    artifact (never falling back to an unrelated list selection), otherwise
    returns [Knowledge_store.selected_artifact m.knowledge]. *)

type keeper_banner_row = {
  tone : Theme.status_token;
  glyph : Glyph.t;
  text : string;
}

val keeper_diagnostic_banner : name:string -> t -> keeper_banner_row list
(** Pure SSOT diagnostic banner lines for a keeper (active blockers, failures on
    unhealthy keepers, runnable path rest, waiting inventory, actionable
    disposition). Benign server values (["pass"], ["direct_message"]) are
    suppressed so healthy keepers render zero banner rows. *)

val keeper_diagnostic_banner_height : name:string -> avail_h:int -> t -> int
(** Exact number of rows [Keeper_dive.render_tabs_body] deducts for
    {!keeper_diagnostic_banner}, shared by {!Chat_transcript} and
    {!Memory_diagram} so chat scroll and Kitty image placement stay in sync. *)
