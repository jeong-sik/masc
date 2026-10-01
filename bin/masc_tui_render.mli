(** Screen dispatch and shared rendering projections.
    Board, Code, MCP resource and Approval screens are owned by
    {!Masc_tui_render_board}, {!Masc_tui_render_code},
    {!Masc_tui_render_resources} and {!Masc_tui_render_approvals}. *)

module Frame_presenter = Masc_tui_frame_presenter
module Ask_projection = Masc_tui_ask_projection
module Ask_layout = Masc_tui_ask_layout
module Board_detail = Masc_tui_board_detail
module Magnitude = Masc_tui_magnitude
module Message_layout = Masc_tui_message_layout
module Tool_detail = Masc_tui_tool_detail
module Retained_view = Masc_tui_retained_view
module Metrics_tail = Masc_tui_metrics_tail
module Observation_layout = Masc_tui_observation_layout
module Context_state = Masc_tui_context_state
module Keeper_activity = Masc_tui_keeper_activity
module Keeper_chat = Masc_tui_keeper_chat_projection
module Keeper_chat_diff = Masc_tui_keeper_chat_diff
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript
module Render_schedule = Masc_tui_render_schedule
module Agenda = Masc_tui_agenda
module Markdown = Masc_tui_markdown
module Markdown_cache = Masc_tui_markdown_render_cache
module Composer = Masc_tui_composer
module Composer_projection = Masc_tui_composer_projection
module Keeper_control = Masc_tui_keeper_control
module Task_selection = Masc_tui_task_selection
module Tool_tree = Masc_tui_tool_tree
module Theme_choice = Masc_tui_theme_choice
module Planning_detail = Masc_tui_planning_detail
module Link = Masc_tui_link
module Status = Masc.Keeper_status_runtime
module Render_tools = Masc_tui_render_tools
val json_assoc_member_opt : string -> Yojson.Safe.t -> Yojson.Safe.t option

val set_table_frame : bool -> unit

(** The Activity pane as the last frame drew it, for the input layer: how
    many columns it held on the right (zero when none was drawn), what a
    press on one of its rows acts on, and how far its list can scroll. A
    press or a wheel notch between frames is answered from what was on
    screen, which is this, not from what the next frame would draw. *)
val acting_pane_drawn_cols : unit -> int

val acting_pane_columns : Masc_tui_types.state -> terminal_cols:int -> int
(** The current Activity pane reservation at this terminal width, usable
    before a frame is built when reconciling interaction bounds. *)

val acting_pane_suppressed : Masc_tui_types.state -> bool
(** Whether this frame draws no Activity pane whatever the reader chose: a
    modal covers the whole terminal, and the Activity screen and the Browser
    Lane already fill their own. The pane's key reads this too, so a press
    cannot move a choice the reader has no way to see. *)

val acting_pane_target_at : line:int -> Masc_tui_acting_pane.row_target

val acting_pane_row_count : unit -> int
(** How many rows the last frame drew in the Activity pane: the range
    [acting_pane_target_at] answers for. Zero when the pane was not drawn. *)

val acting_pane_scroll_limit : unit -> int

(** What a press on this terminal row opens in the chat history the last frame
    drew, and {!Masc_tui_message_layout.Action_none} for any row outside it.

    Absolute terminal rows: the two-pane split places the chat beside the
    roster rather than below it, so a line keeps the vertical position its
    buffer gave it. Answers {!Action_none} until a frame has drawn a history,
    so a press cannot be served by a row that is no longer on screen. *)
val keeper_roster_marquee_target :
  Masc_tui_types.state -> cols:int -> string option

type lane_run_tool_counts = {
  completed : int;
  deferred : int;
  failed : int;
  other : int;
}

type memory_state =
    Memory_ordinary
  | Memory_warning
  | Memory_degraded
  | Memory_no_current
  | Memory_source_only
  | Memory_starving
  | Memory_read_error
module Span = Masc_tui_span
module Diff = Masc_tui_diff
val tools_scrolled : Masc_tui_types.state -> Masc_tui_types.scrolled
val render_tools :
  Masc_tui_types.state ->
  Frame_presenter.frame * Masc_tui_types.clamped_scroll option
val config_content_height : Masc_tui_types.state -> int
val prompts_detail_viewport : Masc_tui_types.state -> int * int
(** Wrapped selected prompt/asset row count and the detail's visible rows.
    Page and edge keys use the same document and geometry as drawing. *)
val context_inspector_viewport : Masc_tui_types.state -> int * int
val context_inspector_detail_viewport : Masc_tui_types.state -> int * int
val keeper_deletions_viewport : Masc_tui_types.state -> int * int
val help_viewport : Masc_tui_types.state -> int * int
val patch_modal_horizontal_limit : Masc_tui_types.state -> int
(** Largest body-cell offset needed to read a patch line while keeping its
    old/new line numbers and change marker fixed. *)

val patch_modal_viewport : Masc_tui_types.state -> int * int
(** The patch review overlay's diff-row count and the rows it shows, so the
    page keys move a window and the end key reaches the end. *)

val link_modal_viewport : Masc_tui_types.state -> int * int
(** The link preview overlay's line count and the rows it shows, so the page
    keys move a window rather than a fixed number of lines. *)

val agenda_lines : Masc_tui_types.state -> Masc_tui_agenda.line list
(** The agenda panel's rows, as the frame draws them. The keypress that walks
    the rows Enter can act on reads the same list, so the cursor cannot name a
    row the frame is not drawing. *)

val agenda_viewport : Masc_tui_types.state -> int * int
val agenda_scroll_position : Masc_tui_types.state -> int
(** The scroll currently drawn, following a selected target only during
    target navigation. Page reading retains its own window. *)
val presets_viewport : Masc_tui_types.state -> int * int
(** Wrapped detail row count and height below the Presets selection list. *)
val answering_viewport : Masc_tui_types.state -> int * int
(** Pure projection for the visible Recent pane, or [None] when it will not
    consume chunks. Dimensions are the raw terminal measurement. The loop
    stores this result inside frame Build timing; rendering never stores it. *)
val acting_pane_chunk_projection :
  Masc_tui_types.state -> terminal_rows:int -> terminal_cols:int ->
  Masc_tui_acting.chunk_projection option

val frame_choice :
  Masc_tui_types.state -> terminal_rows:int ->
  [ `Too_small of int
  | `Play_card of Masc_tui_play_card.t
  | `Account_login of Masc_tui_account_login.t
  | `Lane_addons of Masc_tui_lane_addons.t
  | `About | `Palette | `Context | `Keeper_deletions | `Help
  | `Agenda | `Answering | `Patch | `Link
  | `Client_detail of Masc.Tui_decode.client_row | `Surface ]
(** The visible surface or overlay, also used before preparing Home focus. *)

val render :
  Masc_tui_types.state ->
  Frame_presenter.frame * Masc_tui_types.clamped_scroll option *
  Masc_tui_approvals_model.approval_row option *
  Masc_tui_press.press_target Masc_tui_hit.zones
(** The frame without press marks, and where each marked text landed in it.
    Commit the zones only once the terminal accepts the frame. *)

val browser_lane_scroll_limit :
  Masc_tui_types.state -> terminal_rows:int -> cols:int ->
  Masc_tui_types.Browser_lane_view.t -> int

val browser_lane_selection_scroll :
  Masc_tui_types.state -> terminal_rows:int -> cols:int ->
  Masc_tui_types.Browser_lane_view.t -> int
(** Reveal the selected node's first wrapped row after explicit selection. *)


val runtime_config_status_scroll_limit :
  Masc_tui_types.state -> terminal_rows:int -> cols:int -> int

val browser_history_scroll_limit : Masc_tui_types.state -> terminal_rows:int -> cols:int -> Masc_tui_types.Browser_history.t -> int

val schedule_detail_viewport : Masc_tui_types.state -> int * int
(** Physical-row count and height of the current Schedule evidence reader. *)
