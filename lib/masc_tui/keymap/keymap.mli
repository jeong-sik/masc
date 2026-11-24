(** Single-SSOT 3-tier terminal-safe keymap driving dispatch, priority-fitted
    footer hints, dynamic [?] help groups, [Ctrl+K] palette commands, and
    deterministic Markdown reference generation.

    Design invariants:
    - Zero collisions within any {!scope}.
    - Bare lowercase [p] remains unbound in [Unfocused_nav] / [Global] (only
      bound in [Screen_context] for Sandbox probe).
    - VT100 control aliases ([Ctrl+I], [Ctrl+M], [Ctrl+H]) are never bound.
    - [Ctrl+K] opens the Universal Palette exclusively and never approves.
    - [Esc] pops overlays/dives/filters/rail/composer focus and never quits.
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
  | Toggle_sidebar
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
  | Cycle_memory_view
  | Toggle_memory_sort
  | Cycle_signal_or_source
  | Cycle_sort_or_speak
  | Cycle_hearth_or_overrule
  | Cycle_time_window
  | Cycle_view_mode
  | Context_primary_action
  | Toggle_artifact_share
  | Step_revision of cycle_dir
  | Step_context_item of cycle_dir
  | Launch_fusion
  | Toggle_unreported
  | Unbind_connector
  | Entity_approve_or_assign
  | Entity_reject_or_cancel
  | Edit_or_export
  | Configure_provider_key
  | Account_login
  | Poll_account_login
  | Copy_hash
  | Dismiss_errors
  | Board_vote of [ `Up | `Down ]
  | Toggle_memory_scope
  | Copy_public_url
  | Probe_sandbox
  | Refresh_browser_tabs
  | Open_memory_recovery
  | Search_prev_match
  | Toggle_memory_chart
  | Open_external_editor
  | Interrupt_turn
  | Quit_app

type scope =
  | Global
  | Unfocused_nav
  | Screen_context
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
val replay_ime_event : Input.key_event -> Input.key_event

val scope_chain_of_focus :
  ?approval_strip_active:bool -> Nav.focus_scope -> scope list

val dispatch : scope_chain:scope list -> Input.key_event -> action option
val collisions : unit -> collision list

val footer_separator : string

val footer_hints :
  scope_chain:scope list -> max_width:int -> lang:Say.lang -> footer_hint list

val format_footer_line : footer_hint list -> string

val help_entries : scope_chain:scope list -> lang:Say.lang -> help_group list
val palette_commands : lang:Say.lang -> palette_command list
val render_markdown_reference : ?lang:Say.lang -> unit -> string
