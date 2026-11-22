(** Single-SSOT 3-tier terminal-safe keymap driving dispatch, priority-fitted
    footer hints, dynamic [?] help groups, [Ctrl+K] palette commands, and
    deterministic Markdown reference generation.

    Design invariants:
    - Zero collisions within any {!scope}.
    - Bare lowercase [p] and [v] are permanently retired.
    - VT100 control aliases ([Ctrl+I], [Ctrl+M], [Ctrl+H]) are never bound.
    - [Ctrl+K] opens the Universal Palette exclusively and never approves.
    - [Esc] pops overlays/dives/filters/composer focus and never quits.
    - [footer_hints] fits strictly within [max_width] columns with zero
      ["...?"] overflow. *)

module Nav = Masc_tui_core.Nav
module Say = Masc_tui_core.Say
module Input = Masc_tui_term.Input_decoder

type move_dir =
  | Up
  | Down
  | Left
  | Right
  | Page_up
  | Page_down
  | Home
  | End

type cycle_dir =
  | Prev
  | Next

type action =
  | Switch_workspace of Nav.workspace
  | Sub_tab of cycle_dir
  | Cycle_focus_pane of cycle_dir
  | Focus_composer
  | Focus_filter
  | Dive_selected
  | Confirm_selected
  | Pop_back_or_close
  | Open_settings
  | Teleport_blocked
  | Open_incidents
  | Voice_ptt_toggle
  | Fast_approve_top
  | Fast_deny_top
  | Ask_select_choice of int
  | Open_help
  | Open_palette
  | Open_keeper_switcher
  | Open_model_switcher
  | Toggle_tool_details
  | Open_queue_context
  | Toggle_thinking
  | Cycle_origin_mode
  | Composer_kill_word
  | Composer_newline
  | Submit_steer
  | Submit_followup
  | Move of move_dir
  | Toggle_expand
  | Create_new
  | Refresh
  | Copy_selected
  | Open_external
  | Toggle_zoom
  | Quit_app

type scope =
  | Global
  | Unfocused_nav
  | Ask_choice_focused
  | Approval_strip_focused
  | Approval_strip_chords
  | Composer_focused
  | Overlay_focused

type tier =
  | Bare_unfocused
  | Universal_ctrl
  | Modern_accel

type help_category =
  | Cat_navigation
  | Cat_actions
  | Cat_overlays
  | Cat_composer
  | Cat_approval

type binding = {
  chord : Input.key_event;
  scope : scope;
  tier : tier;
  category : help_category;
  action : action;
  key_display : string;
  hint_label : Say.t;
  help_desc : Say.t;
  slash_twin : string option;
  footer_priority : int;
      (** [0] omits from footer; positive integers sort ascending ([1] highest). *)
}

type collision = {
  scope : scope;
  chord : Input.key_event;
  first : action;
  second : action;
}

type footer_hint = {
  key_display : string;
  label : string;
  action : action;
  priority : int;
}

type help_entry = {
  keys : string list;
  desc : string;
  slash_twin : string option;
  action : action;
}

type help_group = {
  category : help_category;
  title : string;
  entries : help_entry list;
}

type palette_command = {
  action : action;
  title : string;
  shortcut : string;
  slash_twin : string option;
  category : help_category;
}

val equal_move_dir : move_dir -> move_dir -> bool
val equal_cycle_dir : cycle_dir -> cycle_dir -> bool
val equal_action : action -> action -> bool
val equal_scope : scope -> scope -> bool
val equal_tier : tier -> tier -> bool
val equal_help_category : help_category -> help_category -> bool

val all_scopes : scope list
val bindings : binding list

val normalize_key_event : Input.key_event -> Input.key_event
(** Normalize Kitty [CSI u] and legacy VT100 variants of the same keystroke
    (e.g., uppercase ASCII with or without [shift = true]) to the canonical
    chord stored in {!bindings}. *)

val scope_chain_of_focus :
  ?approval_strip_active:bool -> Nav.focus_scope -> scope list
(** Derive the ordered lookup chain from a {!Nav.focus_scope}. When
    [approval_strip_active] is [true], fast-approve/deny bindings are enabled
    without letting bare [Y]/[N] hijack typing inside [Composer_focused]. *)

val dispatch : scope_chain:scope list -> Input.key_event -> action option
(** Look up the first matching binding across [scope_chain]. Supports single-key
    Korean 2-bulsik IME replay strictly in unfocused command scopes. *)

val collisions : unit -> collision list
(** Audit the entire {!bindings} table for duplicate normalized chords within
    any single {!scope}. Always empty in a valid keymap. *)

val footer_separator : string
(** [" · "] — 3 terminal cells wide. *)

val footer_hints :
  scope_chain:scope list -> max_width:int -> lang:Say.lang -> footer_hint list
(** Project deduplicated hints for [scope_chain] sorted by priority and fitted
    strictly within [max_width] terminal columns, stopping cleanly before any
    overflow (never emitting ["...?"]). *)

val format_footer_line : footer_hint list -> string
(** Render {!footer_hint} entries joined by {!footer_separator}. *)

val help_entries : scope_chain:scope list -> lang:Say.lang -> help_group list
(** Project grouped [?] Help entries for [scope_chain] directly from {!bindings}. *)

val palette_commands : lang:Say.lang -> palette_command list
(** Project command entries for the [Ctrl+K] Universal Palette from {!bindings}. *)

val render_markdown_reference : ?lang:Say.lang -> unit -> string
(** Generate a complete deterministic Markdown reference table from {!bindings}. *)
