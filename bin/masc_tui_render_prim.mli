(** Rendering primitives shared across every surface.

    The set is computed, not curated, and the rule is now the whole rule: a
    value that two or more screens reach belongs below both of them. It used
    to be ten, which left the helpers shared by a handful of screens in the
    godfile -- and those are exactly the ones that turn into a cycle the next
    time a surface is lifted out. Six of them did, once. The rest are here
    before they can.

    31 values live in the implementation without appearing here. They are
    the pieces the exported ones are built from, and no surface names them. *)

(* The same scope the implementation has, so the signatures read the way
   they are written there. *)
open Masc_tui_types
open Tui_decode

module Ask_projection = Masc_tui_ask_projection
module Keeper_control = Masc_tui_keeper_control
module Browser_lane_layout = Masc_tui_browser_lane_layout
module Chart = Masc_tui_chart
module Context_bars = Masc_tui_context_bars
module Diff = Masc_tui_diff
module Frame_presenter = Masc_tui_frame_presenter
module Keeper_chat = Masc_tui_keeper_chat_projection
module Magnitude = Masc_tui_magnitude
module Markdown = Masc_tui_markdown
module Render_schedule = Masc_tui_render_schedule
module Retained_view = Masc_tui_retained_view
module Span = Masc_tui_span
module Status = Masc.Keeper_status_runtime

type planning_tab =
  Render_schedule.planning_tab =
    Planning_goals
  | Planning_task_review
  | Planning_verdicts

type change_context = {
  ctx_keeper : string option;
  ctx_task_id : string option;
  ctx_task_title : string option;
  ctx_task_description : string option;
  ctx_goal_id : string option;
  ctx_goal_title : string option;
  ctx_turn : int option;
  ctx_comment : string option;
  ctx_pr : Masc_tui_pr_ref.t option;
}

type context_pane_body =
    Plain of string list * int option
  | Split of { common : string list; left : string list; right : string list;
    }

type diff_surface =
  { ds_title : string  (** the screen title *)
  ; ds_address : string  (** what the header names beside "vs HEAD" *)
  ; ds_context_lines : string list
        (** drawn under the header, each followed by a divider *)
  ; ds_diff : Masc.Tui_decode.git_diff option  (** [None] until the tree is read *)
  ; ds_error : string option
  ; ds_scroll : int  (** the stored scroll, clamped here and reported back *)
  ; ds_unchanged : string  (** the empty line when the tree reports no change *)
  ; ds_esc_hint : string  (** what esc does on this surface *)
  ; ds_footer_hints : string
  ; ds_surface_key : string
  ; ds_clamped : int -> clamped_scroll
  }

val acting_pane_reserved_cols : int ref

val acting_pane_row_targets : Masc_tui_acting_pane.row_target array ref

val acting_pane_scroll_max : int ref

val navigation_rows : int

val get_terminal_size : unit -> int * int

val frame_lines : Buffer.t -> string list

val write_two_panes :
  Buffer.t -> left_cols:int -> left:Buffer.t -> right:Buffer.t -> unit

val finish_frame :
  ?clamped:Masc_tui_types.clamped_scroll ->
  ?compact_frame:bool ->
  surface_key:string ->
  cursor:Frame_presenter.cursor ->
  rows:int ->
  cols:int ->
  Buffer.t -> Frame_presenter.frame * Masc_tui_types.clamped_scroll option

val table_frame_enabled : bool ref

val chat_markdown_palette : closing:string -> Markdown.palette

val markdown_with_closing :
  closing:string -> width:int -> string -> string list

val document_markdown : width:int -> string -> string list

val search_marker : Masc_tui_types.state -> string option
(** The "/" query on screen and how many rows it reaches, or [None] when no
    query is on screen. One spelling for the three places that draw it: the
    footer, the Keepers heading, and the context inspector's title.

    The count is taken here, over the rows the surface offers right now, so
    it cannot describe a list the surface has since left. The "n/N" suffix
    appears only where those keys have rows to step, and only while footers
    spell their hints. Plain text -- the footer dims its whole line, so it
    styles its own. *)

val search_marker_styled : Masc_tui_types.state -> string
(** {!search_marker} in the colour the two headings share -- accented while
    the query is being typed, dim once settled -- or [""] when there is no
    query. *)

val footer_line :
  ?status:Masc_tui_footer.status_item list ->
  Masc_tui_types.state -> max_cells:int -> hints:string -> string

val keeper_split_threshold_cols : int

val keeper_roster_pane_cols : int

val finish_frame_with_strip :
  Masc_tui_types.state ->
  ?clamped:Masc_tui_types.clamped_scroll ->
  surface_key:string ->
  cursor:Frame_presenter.cursor ->
  rows:int ->
  cols:int ->
  Buffer.t -> Frame_presenter.frame * Masc_tui_types.clamped_scroll option

val change_row_address : Masc.Tui_decode.file_change -> string

val file_change_evidence_label :
  Masc.Keeper_file_change_evidence.t option -> string option

val acting_pane_changes :
  Masc_tui_types.state -> Masc_tui_acting_pane.changes

val recent_chunk_projection :
  Masc_tui_types.state -> Masc_tui_acting.chunk_projection

val finish_surface :
  Masc_tui_types.state ->
  ?clamped:Masc_tui_types.clamped_scroll ->
  surface_key:string ->
  rows:int ->
  cols:int ->
  Buffer.t -> Frame_presenter.frame * Masc_tui_types.clamped_scroll option

type chrome_body = {
  push : string -> unit;
  push_styled : style:string -> string -> unit;
  push_selected : string -> unit;
  push_divider : unit -> unit;
  push_empty : unit -> unit;
}

val surface_chrome_rows : int
(** The rows {!surface_chrome} draws around its body: the top border, the
    title and its rule, the bottom border and the footer. A key handler that
    bounds a body's scroll subtracts this, the same number the frame does. *)

type chrome_frame = Chrome_screen | Chrome_overlay
(** [Chrome_screen] draws rules without a box, for a surface that is the whole
    screen. [Chrome_overlay] keeps the box, for an overlay opened over one. *)

val surface_chrome :
  ?clamped:(unit -> Masc_tui_types.clamped_scroll option) ->
  ?frame:chrome_frame ->
  Masc_tui_types.state ->
  terminal_rows:int ->
  cols:int ->
  surface_key:string ->
  title:string ->
  hints:string ->
  body:(budget:int -> chrome_body -> unit) ->
  Frame_presenter.frame * Masc_tui_types.clamped_scroll option
(** [clamped] is read after the body has drawn, which is the only moment a
    surface whose rows the drawing counts can say what it clamped to. *)

val connection_badge : Masc_tui_types.state -> string

val count_frame_lines : Buffer.t -> int

val keeper_roster_pane_shown : Masc_tui_types.state -> cols:int -> bool

val keeper_action_color : Status.keeper_next_action_path option -> string

val keeper_state_glyph :
  paused:bool ->
  health:Masc_tui_types.Tui_decode.keeper_health option -> string

val fit_runtime_id : int -> string -> string

val keeper_roster_pane :
  ?focused:bool ->
  Masc_tui_types.state -> rows:int -> cols:int -> Buffer.t -> unit

val listing_rows_below_the_body : int

val write_list_sidebar :
  Buffer.t ->
  rows:int ->
  cols:int ->
  title:string -> focused:bool -> labels:string list -> selected:int -> unit

val data_unreliable_row : cols:int -> string -> string

val fenced_document_text : language:string -> string -> string

val lexed_span : string * String.t -> string

val keeper_lane_idle_text : int -> string

val boxed_surface_chrome_rows : int

val selected_ask_question :
  Masc_tui_types.state -> Masc.Tui_decode.ask_question option

val ask_section_rows : Buffer.t -> int

val draw_ask_question :
  Buffer.t ->
  int ->
  Masc_tui_types.state ->
  row:Masc.Tui_decode.ask_row ->
  draft:Ask_projection.draft ->
  question:Masc.Tui_decode.ask_question ->
  answering:bool -> selected_question:bool -> unit

val draw_ask_context : Buffer.t -> int -> row:Masc.Tui_decode.ask_row -> unit

val ask_block : (Buffer.t -> 'a) -> string * int

val question_hints : Masc_tui_types.state -> string

val question_asks : Masc_tui_types.state -> Masc.Tui_decode.ask_row list

val ask_question_viewport : Masc_tui_types.state -> string list * int

val board_score_style : int -> string

val magnitude_tone : Magnitude.band -> string

val browser_lane_rows :
  cols:int -> Masc_tui_types.Browser_lane_view.t -> Browser_lane_layout.rows

val semantic_status_color : string -> string

val planning_phase_label : Goal_phase.t -> string

val planning_phase_column : int

val planning_phase_color : Goal_phase.t -> string

val planning_workspace_title :
  Masc_tui_types.state -> tab:planning_tab -> window:string -> string

val planning_proof_mark : Masc_tui_types.Tui_decode.goal_proof -> string

val keeper_action_hints :
  ?offers_chat:bool ->
  ?offers_back:bool ->
  Masc_tui_types.state -> Keeper_control.reading option -> string

val system_log_level_style : Masc.Tui_decode.system_log_level -> string

val system_log_category_text : Masc.Tui_decode.system_log_entry -> string

val fusion_run_status_color :
  Masc_tui_types.Tui_decode.fusion_run_status -> string

val fusion_run_progress_text :
  Masc_tui_types.Tui_decode.fusion_run_stage -> string

val fusion_run_clock : Masc_tui_types.Tui_decode.fusion_run -> string

val fusion_run_duration :
  now:float -> Masc_tui_types.Tui_decode.fusion_run -> string

val fusion_run_age :
  now:float -> Masc_tui_types.Tui_decode.fusion_run -> string

val repository_change_status : Masc.Tui_decode.repository_change -> string

val box_line_span : Buffer.t -> int -> Span.t -> unit

val file_change_matches_path : string -> Masc.Tui_decode.file_change -> bool

val resolve_change_context :
  Masc_tui_types.state -> path_opt:string option -> change_context

val build_change_context_lines : change_context -> string list

val tree_diff_row_span : width:int -> Masc.Tui_decode.git_diff_row -> Span.t

val render_diff_surface :
  Masc_tui_types.state ->
  diff_surface ->
  Frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_repository_changes_diff :
  Masc_tui_types.state ->
  path:String.t ->
  Frame_presenter.frame * Masc_tui_types.clamped_scroll option

val runtime_quota_badge : Masc.Tui_decode.runtime_option -> string option

val runtime_all_rows :
  Masc.Tui_decode.runtime_surface_snapshot ->
  (Masc.Tui_decode.runtime_option * string list) list

val tools_scrolled_for_lines :
  Masc_tui_types.state -> 'a list -> Masc_tui_types.scrolled

val config_pane_strip : Masc_tui_types.state -> string

val config_metadata_summary :
  Masc_tui_types.state -> (Masc_tui_runtime_config_view.tone * string) list

val runtime_config_status_lines :
  Masc_tui_types.state ->
  cols:int -> (Masc_tui_runtime_config_view.tone * string) list

val help_masthead : Masc_tui_types.state -> string list

val help_lines : Masc_tui_types.state -> string list

val context_split_width : int -> int

val context_inspector_content_lines :
  cols:int -> Masc_tui_types.state -> context_pane_body

val context_split_pane_height : content_height:int -> common_len:int -> int

val keeper_deletions_lines : Masc_tui_types.state -> cols:int -> string list

val answering_lines : Masc_tui_types.state -> Masc_tui_answering.line list

val answering_preview_rows : int
