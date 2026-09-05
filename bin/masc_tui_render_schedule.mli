type decision =
  | Idle
  | Wait_until of int64
  | Render

type request =
  | Input
  | Background
  | Force

type t

val create : min_interval_ns:int64 -> unit -> t
val request : t -> request -> unit
val take : t -> now_ns:int64 -> decision
val input_timeout_seconds : t -> now_ns:int64 -> maximum:float -> float
val nonnegative_width : int -> int
val keeper_context_bar_width : inner_width:int -> int
val normalize_keeper_detail_scroll :
  line_count:int -> content_height:int -> int -> int

val collapse_consecutive : key:('a -> string) -> 'a list -> ('a * int) list
(** Fold consecutive runs with the same key into (newest element, run length),
    preserving order. The Overview event log draws a burst of identical lines
    (six manual refreshes, a broadcast fan-out) as one row with a [×N] tail
    instead of spending its whole panel repeating itself. *)

type overview_event_window = {
  oew_offset : int;
  oew_first_position : int;
  oew_last_position : int;
}

val project_overview_event_window :
  event_count:int -> visible_rows:int -> int -> overview_event_window
val scroll_overview_events_older :
  event_count:int -> visible_rows:int -> int -> int
val scroll_overview_events_newer :
  event_count:int -> visible_rows:int -> int -> int
val overview_event_offset_after_prepend : retained_count:int -> int -> int

module Input_wait : sig
  type 'a poll_result =
    | Ready of 'a
    | Timed_out
    | Interrupted

  val await :
    now_ns:(unit -> int64) ->
    timeout_ns:int64 ->
    poll:(float -> 'a poll_result) ->
    'a option
end

module Input_shortcut : sig
  val is_quit : message_mode:bool -> string -> bool
end

module Viewport : sig
  val minimum_fixed_chrome_rows : int
  val requires_compact_frame : rows:int -> bool
end

type overview_allocation = {
  attention_rows : int;
  task_error_rows : int;
  task_rows : int;
  filler_rows : int;
      (** Blank rows the renderer draws between the task block and the bottom
          border. Without them a surface whose content is shorter than the
          terminal ends partway down the screen and leaves its own footer in
          the middle of it. *)
}

val allocate_overview :
  terminal_rows:int ->
  has_cluster:bool ->
  attention_count:int ->
  event_count:int ->
  task_count:int ->
  has_task_error:bool ->
  overview_allocation

type board_read_allocation = {
  body_rows : int;
  comment_rows : int;
}

val allocate_board_read :
  terminal_rows:int ->
  body_line_count:int ->
  comment_count:int ->
  board_read_allocation

type board_read_scroll = {
  normalized_scroll : int;
  body_offset : int;
  comment_offset : int;
}

val project_board_read_scroll :
  body_line_count:int ->
  body_rows:int ->
  comment_count:int ->
  comment_rows:int ->
  int ->
  board_read_scroll

(** {1 Keeper roster columns} *)

val keeper_marker_width : int
val keeper_status_width : int
val keeper_flags_width : int
val keeper_last_turn_width : int

type keeper_columns = {
  kcol_show_flags : bool;
  kcol_show_runtime : bool;
  kcol_name : int;
  kcol_runtime : int;
  kcol_task : int;
}
(** Plain-text cell budgets for one roster row, in cells. *)

val allocate_keeper_columns : inner_width:int -> keeper_columns
(** Divide the box's inner width across the roster columns. Columns drop from
    the right as the terminal narrows; the keeper's name and its status never
    drop. Above the minimum, slack goes to name and runtime before task. *)

val keeper_columns_used_width : keeper_columns -> int
(** Total cells the allocation occupies, separators included. Never exceeds the
    [inner_width] it was allocated for, and equals it once that width admits
    the minimum row. *)

(** {1 Memory fleet columns} *)

type memory_columns = {
  mcol_show_revision : bool;
  mcol_show_source : bool;
  mcol_name : int;
}
(** Plain-text cell budgets for one Memory row, in cells. *)

type memory_row_values = {
  mrow_state : string;
  mrow_name : string;
  mrow_revision : string;
  mrow_facts : string;
  mrow_size : string;
  mrow_source : string;
  mrow_delta : string;
}
(** One row's readings, already rendered as text. Each field is its own cell:
    the revision, the fact count and the byte size are three units and do not
    share one. *)

val allocate_memory_columns : inner_width:int -> memory_columns
(** Divide the box's inner width across the Memory columns. The source-bound
    cell drops first and the revision second; the keeper's name and its state
    never drop. Slack above the minimum goes to the name, up to the widest
    name worth reading whole. *)

val memory_columns_used_width : memory_columns -> int
(** Total cells the allocation occupies, gaps included. Never exceeds the
    [inner_width] it was allocated for. Unlike the roster it can fall short of
    it: every Memory cell has a widest known reading, so surplus width stays
    margin instead of padding one cell out to the frame. *)

val memory_header_row : memory_columns -> string
(** The column names, laid out on the allocation. *)

val memory_row :
  ?state_style:string ->
  ?size_style:string ->
  ?delta_style:string ->
  ?close:string ->
  memory_columns ->
  memory_row_values ->
  string
(** One row, laid out on the same allocation as {!memory_header_row}. Both are
    built from one description of the columns, so a cell can never sit at a
    different offset from the header that names it -- the defect this pair
    replaces, where a name over eighteen cells or a reading over fourteen
    pushed the rest of its row right of the header.

    The three styles dress the state cell, the size reading and the delta, and
    nothing else. A keeper that deviates says so where it deviates rather than
    turning its whole line one colour: the readings that are fine keep the
    line's own dress. Escapes cost no display cells, so a dressed row is still
    exactly as wide as its header. *)

(** {1 Workspace repository columns} *)

val workspace_minimum_path_width : int

type workspace_row_values = {
  wrow_name : string;
  wrow_branch : string;
  wrow_status : string;
  wrow_sync : string;
  wrow_path : string;
}
(** One repository row's readings, already rendered as text. *)

val workspace_path_width : inner_width:int -> int
(** Cells the path may occupy: what the named columns leave, never below
    {!workspace_minimum_path_width}. Computed from the column widths rather
    than from a constant kept in step with them by hand. *)

val workspace_header_row : path_width:int -> string
val workspace_row : path_width:int -> workspace_row_values -> string
(** The header and one row, laid out on the same columns. This screen used to
    print one format string in two places; a column can no longer exist in the
    header at a width the rows do not use. *)

(** {1 System log columns} *)

val system_log_minimum_message_width : int

type system_log_row_values = {
  slog_time : string;
  slog_level : string;
  slog_module : string;
  slog_keeper : string;
  slog_category : string;
  slog_message : string;
}

type system_log_styles = {
  slog_time_style : string;
  slog_module_style : string;
  slog_keeper_style : string;
  slog_category_style : string;
}
(** The dresses a log row wears whatever it says. The level's is separate
    because it is the one that changes with the reading. *)

val system_log_plain_styles : system_log_styles
(** No dress at all, for a caller drawing an undressed row and for the tests
    that check a dressed row measures the same. *)

val system_log_message_width : inner_width:int -> int
(** Cells the message may occupy: what the named columns leave, never below
    {!system_log_minimum_message_width}. *)

val system_log_header_row : message_width:int -> string

val system_log_row :
  styles:system_log_styles ->
  level_style:string ->
  message_width:int ->
  system_log_row_values ->
  string
(** One entry, laid out on the same columns as {!system_log_header_row}. The
    widths used to live in two format strings, the row's threaded between five
    escape sequences where nothing could compare them with the header's. *)

(** {1 Lane run columns} *)

type lane_run_row_values = {
  lrow_started : string;
  lrow_subject : string;
  lrow_status : string;
  lrow_elapsed : string;
  lrow_slot : string;
  lrow_run_id : string;
}

val lane_run_id_width : inner_width:int -> int
(** Cells the run id may occupy: the remainder, never below
    {!lane_minimum_run_id_width}. *)

val lane_run_header_row : identity_header:string -> run_id_width:int -> string

val lane_run_row :
  identity_header:string ->
  status_style:string ->
  run_id_width:int ->
  lane_run_row_values ->
  string
(** One run, on the same columns as {!lane_run_header_row}. [identity_header]
    names the second column, which reads differently for one keeper's runs and
    for a fleet's. *)

(** {1 File change columns} *)

type change_row_values = {
  crow_turn : string;
  crow_task : string;
  crow_op : string;
  crow_result : string;
  crow_file : string;
  crow_summary : string;
}

val change_summary_width : inner_width:int -> int
val change_header_row : summary_width:int -> string

val change_row :
  op_style:string ->
  result_style:string ->
  summary_width:int ->
  change_row_values ->
  string
(** One change, on the same columns as {!change_header_row}. The file cell is
    fitted now: it was padded and never cut, so a long path pushed the summary
    beside it -- the column that says what the turn actually did -- off the
    frame. *)

(** {1 Fusion run columns} *)

type fusion_row_values = {
  frow_time : string;
  frow_age : string;
  frow_state : string;
  frow_keeper : string;
  frow_preset : string;
  frow_run : string;
}

val fusion_run_width : inner_width:int -> keeper_width:int -> int
val fusion_header_row : keeper_width:int -> run_width:int -> string

val fusion_row :
  state_style:string ->
  keeper_width:int ->
  run_width:int ->
  fusion_row_values ->
  string
(** One run, on the same columns as {!fusion_header_row}. The keeper cell is
    sized by the caller to the names it holds; the run id takes what is left,
    where it used to be unbounded in the header and cut at fourteen in the
    row. *)

val fusion_sidebar_label :
  status:string -> time:string -> keeper:string -> run_id:string -> string

val fusion_pipeline_diagram :
  ?glyph_done:string ->
  ?glyph_active:string ->
  ?glyph_waiting:string ->
  ?glyph_failed:string ->
  ?arrow:string ->
  status:[ `Completed | `Running | `Failed ] ->
  stage:[ `Accepted | `Panel | `Judge | `Evidence | `Failed | `Completed ] ->
  panel_answered:int ->
  panel_expected:int ->
  unit ->
  string

(** {1 Harness verdict columns} *)

type harness_row_values = {
  hrow_time : string;
  hrow_task : string;
  hrow_gate : string;
  hrow_verdict : string;
  hrow_evaluator : string;
  hrow_reason : string;
}

val harness_reason_width : inner_width:int -> int
val harness_header_row : reason_width:int -> string

val harness_row :
  verdict_style:string ->
  reason_width:int ->
  harness_row_values ->
  string
(** One verdict, on the same columns as {!harness_header_row}. The task and
    gate cells are fitted now: they were padded and never cut, so an id or a
    gate name longer than its column pushed the evaluator and the reason
    beside it out of line with every other row. *)

(** Planning goal columns.

    The list named no columns at all, and its title took the terminal minus a
    hand-summed constant minus however wide the age and the due date happened
    to be. Both are optional, so the pair at the end of the row began at a
    different column on every row -- a goal with no due date started them ten
    cells left of the goal above it. Each has a widest form and each has a
    column now. *)

type planning_row_values = {
  prow_phase : string;
      (** The phase carries the brackets it is drawn in, so [phase_width] below
          is the bracketed width rather than the label's own. *)
  prow_proof : string;
  prow_priority : string;
  prow_open : string;
  prow_title : string;
  prow_age : string;
  prow_due : string;
}

val planning_title_width : inner_width:int -> phase_width:int -> int
(** What the title has after the named columns, never below a floor: a title
    folded past that point identifies no goal, and the row is better off
    running to the frame's edge than naming nothing. *)

val planning_header_row : phase_width:int -> title_width:int -> string

val planning_row :
  ?priority_style:string ->
  ?open_style:string ->
  phase_style:string ->
  phase_width:int ->
  title_width:int ->
  planning_row_values ->
  string
(** One goal, on the same columns as {!planning_header_row}. The proof mark's
    column is named with a space: it is a mark like the roster's, and a name
    would be four cells wider than the cell holding it. *)

(** Board post columns.

    The list sized its title as the terminal minus a constant summed by hand
    from ten widths and their gaps, and the header carried a second copy of the
    same arithmetic. They disagreed: at eighty columns the header ran eight
    cells long, which pushed SCORE into the frame and REPLIES off it, leaving
    two columns drawn on every row with nothing saying what they were.

    Board also spaced its columns two cells apart while every other table used
    one, so six cells of the title were spent on being different. They match
    now. *)

type board_row_values = {
  brow_mark : string;
  brow_id : string;
  brow_hearth : string;
  brow_author : string;
  brow_title : string;
  brow_age : string;
  brow_score : string;
  brow_replies : string;
}

type board_row_styles = {
  bstyle_id : string;
  bstyle_hearth : string;
  bstyle_author : string;
  bstyle_age : string;
  bstyle_score : string;
  bstyle_replies : string;
}
(** What dresses each reading. The layout module carries no palette, so the
    colours come from the caller that owns one; the score's varies by row and
    the rest are the screen's constants. *)

val board_no_styles : board_row_styles
(** Every reading undressed. A caller drawing the row plain -- a test, or a
    surface that dresses the whole line -- has nothing to spell out. *)

val board_title_width : inner_width:int -> int
(** What the title has after the named columns, never below a floor. [inner_width]
    is what the row has left of the frame, the four cells of lead ahead of the
    mark already taken off. *)

val board_header_row : title_width:int -> string

val board_row :
  ?close:string ->
  styles:board_row_styles ->
  title_width:int ->
  board_row_values ->
  string
(** One post, on the same columns as {!board_header_row}. The kind mark carries
    its own dress: the glyph and its colour are chosen together. *)

module Terminal_size_cache : sig
  type refresh =
    | Changed of (int * int)
    | Unchanged of (int * int)

  type t

  val create : fallback:int * int -> t
  val invalidate : t -> unit
  val get : t -> probe:(unit -> (int * int) option) -> int * int
  val refresh : t -> probe:(unit -> (int * int) option) -> refresh
end

(** {1 Planning strip and Keeper schedule page} *)

type planning_tab =
  | Planning_goals
  | Planning_task_review
  | Planning_verdicts

val planning_strip_plain :
  tab:planning_tab -> review_count:int option -> window:string -> string list
(** The Planning strip's stop labels, in order, without styling. Exactly three:
    Schedules and Fusion are tabs of the selected Keeper, not stops here.
    [window] is the page-versus-ledger reading, already formatted (e.g.
    [" (8 of 4223)"]); it is appended to [tab]'s label and to no other, because
    a count placed after the whole strip reads as belonging to its last name. *)

type keeper_schedule_absence =
  | Store_has_none
  | Page_capped of { shown : int; total : int option }

val classify_keeper_schedule_absence :
  truncated:bool -> shown:int -> total:int option -> keeper_schedule_absence
(** Why a Keeper's schedule filter matched nothing. A capped page cannot say
    the store is empty; it can only say it did not look at all of it. *)

(** {1 Schedule wake reading} *)

type wake_reading =
  | Wake_history of { count : int; retention : int }
  | Wake_never
  | Wake_last_only
  | Wake_history_failed of string

val classify_wake_reading :
  history_error:string option -> history:(int * int) option -> wake_reading
(** What the schedule detail can say about a schedule's wakes. [history] is
    (retained count, per-schedule ceiling) once the exact lookup answers.
    [Wake_last_only] is the row's single newest attempt while the list is in
    flight; it is not an empty history, and neither is a failed load. *)
