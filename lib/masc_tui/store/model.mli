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
  overlay : Nav.overlay option;
  pane_index : int;
  zoomed : bool;
  filter_focused : bool;
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
(** Exact inset body width matching [Layout.inset_body] / [Chrome.compute_layout]. *)

val inner_body_height : t -> int
(** Exact inset body height matching [Chrome.compute_layout]. *)

val work_pipeline_has_linked_card : t -> bool
(** [true] iff [2 Work > Pipeline] renders the bottom-left Linked Tasks &
    Verifications card ([inner_body_width >= 96 && inner_body_height >= 15],
    matching [left_rect.h = inner_body_height - 1 >= 14]). *)

val can_zoom_current_view : t -> bool
(** [true] iff [z] ([Toggle_zoom]) renders a zoomed view on the active screen
    ([Keepers] with a selected keeper, or [Knowledge] Board/Wiki/Memory). *)

val focusable_pane_count : t -> int
(** Single source of truth for the exact number of interactive focusable panes
    currently rendered for [m]'s active view, sub-tab, breakpoint, zoom, and
    data state. Returns [1] when pane cycling is a no-op (never ghost panes). *)

val classify_viewport : viewport -> breakpoint
val is_too_small_viewport : viewport -> bool

val initial :
  ?cols:int ->
  ?rows:int ->
  ?lang:Say.lang ->
  ?theme_preset:Theme.preset ->
  ?tz_offset_sec:int ->
  ?wall_unix:float ->
  unit ->
  t

val active_dive : t -> Nav.dive option

val target_keeper : t -> string option
(** The keeper the composer and the Ctrl+T drawer address: the composer's
    active keeper, else the selected roster keeper. *)
val is_in_keeper_chat : t -> bool
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
val is_text_capture_active : t -> bool
(** [true] when a free-text input surface (composer, filter bar, palette,
    settings field editor, or inline modal) owns printable characters. *)

val inline_modal_for : Nav.inline_action_kind -> inline_modal_state
val modal_field_value : key:string -> inline_modal_state -> string
val modal_update_active_field :
  (string -> string) -> inline_modal_state -> inline_modal_state
val modal_cycle_field : delta:int -> inline_modal_state -> inline_modal_state

val with_toast :
  now:Clock.Mono.t ->
  ?duration_s:float ->
  level:toast_level ->
  Say.t ->
  t ->
  t

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
