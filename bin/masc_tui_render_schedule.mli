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
val take : input_pending:bool -> t -> now_ns:int64 -> decision
(** Handled input renders when currently available input is drained, including
    after a recent input frame. [input_pending] covers decoded events, buffered
    bytes, probe replay and terminal readiness; it coalesces a continuous burst
    until it drains or the deadline arrives. Background updates keep the
    minimum interval. No timer delays the last input of a burst. *)
val completed : t -> now_ns:int64 -> unit
(** Record completion after synchronous frame construction and presentation.
    Pending requests survive. Continuous input gets its coalescing interval
    after the work returns, even when the frame overran that interval. Drained
    input and [Force] still render immediately. Background pacing and deferred
    frames that did no work keep the start timestamp recorded by [take]. *)
val frame_due_ns : t -> now_ns:int64 -> int64 option
(** When the pending request may render, on the same clock as [now_ns]:
    [now_ns] for [Force], [Input] and a [Background] whose interval has
    passed, the end of that interval otherwise, [None] when nothing is
    pending. The main loop wakes for it (RFC tui-idle-wait §2.2 [Frame_slot]). *)
val normalize_keeper_detail_scroll :
  line_count:int -> content_height:int -> int -> int

val collapse_consecutive : key:('a -> string) -> 'a list -> ('a * int) list
(** Fold consecutive runs with the same key into (newest element, run length),
    preserving order. The TUI session block on Metrics draws a burst of
    identical lines (six manual refreshes, a broadcast fan-out) as one row with
    a [×N] tail instead of spending its rows repeating itself. *)

module Time_redraw : sig
  val due : now:float -> float option -> float option
  (** When to render a frame that only time asks for, given the earliest
      instant at which the last frame's time text reads differently
      ({!Masc_tui_value.Redraw.next_change}): the first whole wall-clock
      second at or after that instant, and always later than [now]. [None]
      when the frame drew no text that changes with time: then nothing is
      scheduled (RFC tui-one-screen-grammar §8). Input and new data keep the
      immediate scheduler above. *)
end

module Input_wait : sig
  type 'a poll_result =
    | Ready of 'a
    | Timed_out
    | Interrupted

  val await :
    now_ns:(unit -> int64) ->
    timeout_ns:int64 option ->
    poll:(float option -> 'a poll_result) ->
    'a option
  (** Poll until [Ready] or [Timed_out]. [Interrupted] polls again with the
      time left; with no [timeout_ns] the wait has no end of its own. *)
end

module Input_shortcut : sig
  val is_quit : message_mode:bool -> string -> bool
end

module Viewport : sig
  val minimum_fixed_chrome_rows : int
  (** The most rows any surface declares for its fixed chrome. A body with
      fewer rows holds no surface (RFC tui-one-screen-grammar §2). *)

  val navigation_rows : int
  (** The surface strip's row above every surface (zone 1). *)

  val below_strip : terminal_rows:int -> int
  (** The rows below the strip of a terminal [terminal_rows] tall, at least
      one. Every surface and the too-small decision measure from this. *)

  val body_rows : terminal_rows:int -> agenda_rows:int -> int
  (** The rows a surface may draw in below the strip: [terminal_rows] less the
      composer's row and the [agenda_rows] the agenda strip took. The
      composer's row is counted at every size, because it is drawn at every
      size. At least one. *)

  type size = { cols : int; rows : int }
  (** A terminal's size as the operator counts it: every column, and every
      row, the strip's included. *)

  type too_small =
    | Rows_short of { have : size; need_rows : int }
        (** The body is under {!minimum_fixed_chrome_rows}. [have] is the size
            the decision was given and [need_rows] the terminal rows the
            decision compares it with: it fits from [need_rows] up and
            [have.rows < need_rows]. Columns never decide, so there is no
            column need. *)
    | Notice_needs_full_frame
        (** The rows fit, but a notice is wider than the footer row and takes
            the whole frame. The size is not why. *)

  val too_small :
    terminal_rows:int ->
    terminal_cols:int ->
    agenda_rows:int ->
    notice_needs_full_frame:(unit -> bool) ->
    too_small option
  (** Whether the terminal holds no surface, and why. [terminal_rows] counts
      the rows below the strip and [terminal_cols] every column. A short body
      is the reason even when a notice is also too wide; the notice is asked
      only when the rows fit. [None] when a surface fits. *)
end

(** {1 Keeper roster columns} *)

val keeper_marker_width : int
val keeper_status_width : int
val keeper_flags_width : int

val keeper_flags_header : string
(** The header words of the flag cell. The activation letter sits under the
    first word and the sandbox letter under the last. *)

val keeper_flags_gap : int
(** Cells between the activation letter and the sandbox letter. *)

val keeper_last_turn_width : int

val keeper_minimum_name_width : int
val keeper_maximum_name_width : int
(** The name column's floor, and the widest name worth reading whole. *)

val keeper_flags_minimum_inner_width : int
(** The inner width from which the roster shows its flag columns. The
    Activity pane opens only where a surface keeps this much inside its
    frame. *)

type keeper_columns = {
  kcol_show_flags : bool;
  kcol_show_runtime : bool;
  kcol_show_detail : bool;
  kcol_name : int;
  kcol_runtime : int;
  kcol_task : int;
}
(** Plain-text cell budgets for one roster row, in cells. *)

val allocate_keeper_columns :
  ?runtime_visible:bool ->
  ?detail_beside_runtime:bool ->
  ?widest_detail:int ->
  prioritize_runtime:bool ->
  inner_width:int ->
  widest_runtime:int ->
  unit ->
  keeper_columns
(** Divide the box's inner width across the roster columns. Columns drop from
    the right as the terminal narrows; the keeper's name and its status never
    drop. Slack above the minimum goes to the name, up to the widest name worth
    reading whole, unless a failure context asks the runtime column to take
    priority. When [widest_detail] is supplied and runtime is hidden, that floor
    is reserved for the detail column from slack before name expands, ensuring
    failure sentences are not clipped on narrow viewports.
    [runtime_visible] defaults to [true]. When it is [false], the runtime cell
    is absent and its width is available to the other columns.
    [detail_beside_runtime] defaults to [true]. When it is [false] and the
    runtime column is drawn, the row has no detail column, [kcol_task] is 0,
    and the slack the detail would have taken is left unused: the Detailed
    layout states the detail once, on its second row. Without the runtime
    column the detail column stays, since it carries the failure sentence. *)

val keeper_columns_used_width : keeper_columns -> int
(** Total cells the allocation occupies, separators included. Never exceeds the
    [inner_width] it was allocated for, and equals it once that width admits
    the minimum row. *)

type waiting_group_layout = {
  compact : bool;
  cells : int;
  segment_count : int;
}
(** A width decision for the Waiting summary. [cells] measures the whole group
    heading, and [segment_count] retains every nonzero reason and async count. *)

val waiting_group_layout :
  available_cells:int ->
  group_count:int ->
  Masc_tui_keeper_list_model.waiting_summary ->
  waiting_group_layout
(** Use dense labels only when the full heading exceeds [available_cells].
    The compact decision never drops a nonzero summary segment. *)

val waiting_group_heading_detail :
  ?ko:bool ->
  available_cells:int ->
  group_count:int ->
  Masc_tui_keeper_list_model.waiting_summary ->
  string
(** Render the suffix selected by [waiting_group_layout]. *)

val keeper_failure_context_for_detail : show_runtime:bool -> string option -> string option
(** Preserve the existing failure reading for DETAIL only when its runtime cell
    is hidden. A visible runtime keeps the sole copy and returns [None]. *)

(** {1 Memory fleet columns} *)

type memory_columns = {
  mcol_show_updated : bool;
  mcol_show_source : bool;
  mcol_name : int;
}
(** Plain-text cell budgets for one Memory row, in cells. *)

type memory_row_values = {
  mrow_state : string;
  mrow_name : string;
  mrow_updated : string;
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

val memory_header_row : ko:bool -> memory_columns -> string
(** The column names, laid out on the allocation. [ko] selects Korean. *)

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

type system_log_column =
  | Log_time
  | Log_level
  | Log_module
  | Log_keeper
  | Log_category
  | Log_message

val system_log_layout : inner_width:int -> system_log_column Masc_tui_table.layout
(** Read message and severity first. Fold time, category, keeper and module
    in that order before shrinking the message. The two retained columns
    share the actual available width, including in a narrow frame. *)

val system_log_header_row :
  ko:bool -> layout:system_log_column Masc_tui_table.layout -> string
val system_log_row :
  styles:system_log_styles -> level_style:string ->
  layout:system_log_column Masc_tui_table.layout -> system_log_row_values -> string
(** Header and styled rows share the measured column allocation. *)

(** {1 Schedules list columns} *)

type schedule_row_values = {
  srow_status : string;
  srow_due : string;
  srow_target : string;
  srow_wake : string;
  srow_delivery : string;
  srow_recurrence : string;
}

val schedule_minimum_recurrence_width : int

val schedule_minimum_target_width : int
val schedule_maximum_target_width : int
(** The bounds of the target column, which the caller measures from the
    names on the page: never under the minimum, and never past the maximum,
    so a long fallback summary cannot take the recurrence's room. *)

val schedule_minimum_delivery_width : int
val schedule_maximum_delivery_width : int

val schedule_delivery_width : string list -> int
(** Cells the delivery column needs for [words]: the widest of them, never
    under {!schedule_minimum_delivery_width} -- what the column drew before it
    was measured -- and never over {!schedule_maximum_delivery_width}, so one
    long word cannot take the recurrence's room. *)

(** The list's columns, named so a narrow list can say which it gives up. *)
type schedule_column =
  | Schedule_status
  | Schedule_due
  | Schedule_target
  | Schedule_wake
  | Schedule_delivery
  | Schedule_recurrence

(** The columns the list draws and the widths it drew them at. Only
    {!schedule_layout} makes one, so the header and every row are drawn from
    the widths the columns were fitted with. *)
type schedule_layout = private {
  sl_columns : schedule_column Masc_tui_table.layout;
  sl_due_width : int;
  sl_target_width : int;
  sl_wake_width : int;
  sl_delivery_width : int;
}

val schedule_layout :
  ko:bool ->
  inner_width:int ->
  target_width:int ->
  wake_width:int ->
  delivery_width:int ->
  schedule_layout
(** The columns the list draws in [inner_width], given the target, wake and
    delivery widths measured from the page. When the row is narrow the
    delivery goes first, then the wake and state. Due time, target and
    recurrence stay; target names are bounded before fitting so one long name
    cannot consume the recurrence. Very narrow tables shrink those primary
    widths and the detail carries their full readings. *)

val schedule_header_row : ko:bool -> layout:schedule_layout -> string

val schedule_row :
  ?status_style:string ->
  ?wake_style:string ->
  ?recurrence_style:string ->
  layout:schedule_layout ->
  schedule_row_values ->
  string
(** One schedule, on the same columns as {!schedule_header_row}. The list used
    to name one of its six columns and name it inside the row -- "wake:" on the
    wake's word, a dot before the delivery's -- and leave the other five for the
    reader to work out. *)

(** {1 Keeper automation tab columns} *)

type kauto_row_values = {
  krow_mark : string;
  krow_status : string;
  krow_triggered : string;
  krow_outcome : string;
  krow_received : string;
  krow_recurrence : string;
  krow_by : string;
  krow_requested : string;
  krow_what : string;
}

(** What a row wears whatever it says: the recurrence and the storage context
    recede. The mark, the state word and the outcome change with the reading
    and are the row's own. *)
type kauto_row_styles = {
  kstyle_mark : string;
  kstyle_status : string;
  kstyle_outcome : string;
  kstyle_recurrence : string;
  kstyle_by : string;
}

(** The tab's columns, named so a narrow pane can say which it gives up: the
    storage context (BY, then REQUESTED), then the outcome word, then the
    recurrence. The mark, the state, the two clocks and the summary never
    go. *)
type kauto_column =
  | Kauto_mark
  | Kauto_status
  | Kauto_triggered
  | Kauto_outcome
  | Kauto_received
  | Kauto_recurrence
  | Kauto_by
  | Kauto_requested
  | Kauto_what

val kauto_minimum_recurrence_width : int
val kauto_maximum_recurrence_width : int

val kauto_recurrence_width : string list -> int
(** Cells the RECURRENCE column needs for the recurrences on the page: the
    widest of them, never under {!kauto_minimum_recurrence_width} and never
    over {!kauto_maximum_recurrence_width}. *)

val kauto_minimum_by_width : int
val kauto_maximum_by_width : int

val kauto_by_width : string list -> int
(** Cells the BY column needs for the actors on the page: the widest of
    them, never under {!kauto_minimum_by_width} and never over
    {!kauto_maximum_by_width}. *)

(** The columns the tab draws and the widths it drew them at. Only
    {!kauto_layout} makes one, so the header and every row are drawn from the
    widths the columns were fitted with. *)
type kauto_layout = private {
  k_columns : kauto_column Masc_tui_table.layout;
  k_status_width : int;
  k_clock_width : int;
  k_outcome_width : int;
  k_recurrence_width : int;
  k_by_width : int;
}

val kauto_layout :
  inner_width:int ->
  status_width:int ->
  clock_width:int ->
  outcome_width:int ->
  recurrence_width:int ->
  by_width:int ->
  kauto_layout
(** The columns the tab draws in [inner_width], given the status width
    (measured from the contract's own word list), the clock width (from the
    stamp format) and the outcome, recurrence and actor widths measured from
    the page. *)

val kauto_plain_styles : kauto_row_styles

val kauto_header_row : ko:bool -> layout:kauto_layout -> string

val kauto_row :
  styles:kauto_row_styles ->
  layout:kauto_layout ->
  kauto_row_values ->
  string
(** One automation, on the same columns as {!kauto_header_row}. *)

val kauto_group_label : title:string -> string list -> string
(** The label on the rule parting the live rows from the closed ones: the
    title alone when there are no parts, the parts after it when there are. *)

(** {1 Lane run columns} *)

type lane_run_headers = {
  lhead_started : string;
  lhead_subject : string;
  lhead_status : string;
  lhead_elapsed : string;
  lhead_slot : string;
}
(** The column names, in the language the screen is drawn in. *)

(** What the subject column carries. The Verifier's runs are about a task or
    a goal; every other lane's are about who asked. *)
type lane_run_subject =
  | Run_actor_name  (** Read from its head, so it folds at the tail. *)
  | Run_subject_id  (** Told apart by both ends, so it folds in the middle. *)

type lane_run_row_values = {
  lrow_started : float;  (** Seconds since the epoch. *)
  lrow_subject : string;
  lrow_status : string;
  lrow_elapsed : float option;
      (** Seconds. [None], or a span no clock reads, draws the no-value mark. *)
  lrow_slot : string;
}
(** One run as the values the wire gave. The table turns the start and the
    elapsed time into text, so every row of every lane writes them one way. *)

type lane_run_table
(** The run list's columns fitted to one frame width. *)

val lane_run_table :
  headers:lane_run_headers ->
  subject:lane_run_subject ->
  subjects:string list ->
  inner_width:int ->
  lane_run_table
(** The columns the run list draws in [inner_width]. When the row is narrow
    the start goes first, then the elapsed time; the subject, the status and
    the slot stay. [subjects] is every subject on the page, not the rows in
    view alone, so scrolling does not move a column: the subject column is as
    wide as the widest of them where the frame has the cells, and the slot
    takes the rest. *)

val lane_run_header_row : lane_run_table -> string

val lane_run_row :
  lane_run_table ->
  now:float ->
  status_style:string ->
  lane_run_row_values ->
  string
(** One run, on the same columns as {!lane_run_header_row}. [now] decides how
    much of the start's date the row still needs; [status_style] dresses the
    status cell alone. *)

(** {1 File change columns} *)

type change_row_values = {
  crow_turn : string;
  crow_task : string;
  crow_op : string;
  crow_result : string;
  crow_file : string;
  crow_summary : string;
}

(** The change list's columns, named so a narrow list can say which it
    spares. *)
type change_column =
  | Change_turn
  | Change_task
  | Change_op
  | Change_result
  | Change_file
  | Change_summary

val change_layout : inner_width:int -> change_column Masc_tui_table.layout
(** The columns the change list draws in [inner_width] and the summary's share
    of it. When the row is narrow the turn goes first, then the task, the
    operation and the result; the file and the summary stay, and the summary
    takes what the others leave, never below its floor. *)

val change_header_row :
  ko:bool -> layout:change_column Masc_tui_table.layout -> string

val change_row :
  op_style:string ->
  result_style:string ->
  layout:change_column Masc_tui_table.layout ->
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

type fusion_columns = {
  fcol_keeper : int;
  fcol_run : int;
  fcol_show_preset : bool;
}

val allocate_fusion_columns : inner_width:int -> keeper_width:int -> fusion_columns
val fusion_header_row : ko:bool -> fusion_columns -> string
(** The column heads in Korean when [ko] is true, in English otherwise. *)

val fusion_row :
  state_style:string ->
  fusion_columns ->
  fusion_row_values ->
  string
(** One run, on the same columns as {!fusion_header_row}. The keeper cell is
    sized by the caller to the names it holds; the run id takes what is left,
    where it used to be unbounded in the header and cut at fourteen in the
    row. *)

val sidebar_row_label : about:string -> apart:string option -> string
(** A list pane's row label: what the row is about, then the value that parts
    it from its neighbours. The parting value goes last because the pane
    folds a label from the middle and keeps its tail.

    Every index that parts its rows asks this one, so a row reads the same
    way whichever pane draws it. [None] is a row with nothing to be parted
    by, and it keeps its subject alone. *)

val fusion_sidebar_label :
  status:string -> time:string -> keeper:string -> run_id:string -> string

val task_history_sidebar_label : task_id:string -> apart:string option -> string
(** A Task Review or Verdicts list row. Both lists hold a task once per
    submission, so the id alone draws the same row many times over. [apart]
    is the value that parts this row from its siblings: it must hold still
    while the reader looks at it, and it must be the row's own value rather
    than a reading of one. A row with nothing to part it keeps the id
    alone. *)

val verdict_sidebar_labels : now:float -> (string * float) list -> string list
(** Task id and the moment of each Verdicts row, in seconds since the epoch,
    drawn as the run list draws a start. Rows whose displayed clock is
    identical receive a snapshot-local ordinal after the minute, so two
    verdicts recorded in the same second do not read as the same row. *)

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

(** Board post columns.

    The list sized its title as the terminal minus a constant summed by hand
    from ten widths and their gaps, and the header carried a second copy of the
    same arithmetic. They disagreed: at eighty columns the header ran eight
    cells long, which pushed SCORE into the frame and REPLIES off it, leaving
    two columns drawn on every row with nothing saying what they were.

    Board also spaced its columns two cells apart while every other table used
    one, so six cells of the title were spent on being different. They match
    now. *)

val board_id_width : int
(** Width of compact post references in reader headings. *)

type board_row_values = {
  brow_mark : string;
  brow_hearth : string;
  brow_author : string;
  brow_title : string;
  brow_age : string;
  brow_score : string;
  brow_replies : string;
}

type board_row_styles = {
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

val board_age_text : now:float -> float option -> string
(** The age cell: the span since the time the caller chose, or ["—"] when the
    post carried no such time. Which time that is follows the sort, which
    {!Masc_tui_types.board_sort_time} answers. *)

(** The list's columns, named so a narrow list can say which it spares. *)
type board_column =
  | Board_mark
  | Board_hearth
  | Board_author
  | Board_title
  | Board_age
  | Board_score
  | Board_replies

(** Which column header carries the active descending sort arrow ([↓]). *)
type board_sort_column =
  | Sort_none
  | Sort_age
  | Sort_score
  | Sort_replies

val board_layout :
  hide_hearth:bool ->
  sort_column:board_sort_column ->
  inner_width:int ->
  board_column Masc_tui_table.layout
(** The columns the list draws inside its frame: fixed metadata
    ([mark], [age], [author], [hearth]) on the left, flexible [title] beside
    them, and right-aligned numeric [score] and [replies] on the right. When
    [hide_hearth] is [true] (the listing is already narrowed to one hearth),
    [Board_hearth] is omitted without counting as dropped so its width goes to
    [Board_title]. A narrow row drops hearth, the inactive numeric counter,
    author, and only last the active [sort_column] so the column governing the
    order stays visible whenever room allows. Exact post references remain
    available through the existing copy action; they do not take a list column. *)

val board_header_row :
  sort_column:board_sort_column ->
  ko:bool ->
  age_header:string ->
  layout:board_column Masc_tui_table.layout ->
  string
(** [age_header] is the word over the age column, which names the time the
    column holds. [sort_column] appends [↓] to the active sort column header. *)

val board_header_row_with_dropped :
  sort_column:board_sort_column ->
  ko:bool ->
  inner_width:int ->
  age_header:string ->
  layout:board_column Masc_tui_table.layout ->
  string
(** Like {!board_header_row}, placing any dropped-columns badge inside the
    flexible title column's trailing slack so right-aligned numeric headers
    and active sort arrows are never overwritten. *)

val board_row :
  ?close:string ->
  ko:bool ->
  styles:board_row_styles ->
  age_header:string ->
  layout:board_column Masc_tui_table.layout ->
  board_row_values ->
  string
(** One post, on the same columns as {!board_header_row}. The kind mark carries
    its own dress: the glyph and its colour are chosen together. *)

module Terminal_size_cache : sig
  type refresh =
    | Changed of (int * int)
    | Unchanged of (int * int)

  type work_geometry = Current | Resize_interrupted | Resize_detected

  type t

  val create : fallback:int * int -> t
  val invalidate : t -> unit
  val get : t -> probe:(unit -> (int * int) option) -> int * int
  val refresh : t -> probe:(unit -> (int * int) option) -> refresh
  val verify_for_work :
    cached:(int * int) -> resize_changed:(unit -> bool) ->
    probe:(unit -> (int * int) option) -> work_geometry
  (** Check before admitting geometry-dependent work. A failed probe keeps the
      cached size, as [get] does. [resize_changed] must detect both a pending
      signal and a resize generation change since the size was captured. *)
end

(** {1 Planning strip and Keeper schedule page} *)

type planning_tab =
  | Planning_goals
  | Planning_task_review
  | Planning_verdicts

val planning_strip_plain :
  tab:planning_tab ->
  review_count:int option ->
  verifying_count:int option ->
  window:string ->
  (planning_tab * string) list
(** The Planning strip's stop labels, in order, without styling. Exactly three:
    Schedules and Fusion are tabs of the selected Keeper, not stops here.

    Unnumbered, and the two task stops share a word. The numbers read as a
    pipeline the surfaces do not form: Goals is the goal lifecycle judged
    against its own ledger, while Task Review and Task Verdicts are the two
    halves of the task protocol, and a goal in [verifying] appears in neither.

    [verifying_count] and [review_count] are what each side is holding, so
    the reading an operator opens this screen for is on the strip rather than
    counted by eye. [window] is the page-versus-ledger reading, already
    formatted (e.g. [" (8 of 4223)"]); it is appended to [tab]'s label and to
    no other, because a count placed after the whole strip reads as belonging
    to its last name. *)

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

(** {1 Schedule hold reading} *)

val schedule_hold_tag : ko:bool -> due:string -> string
(** The short form, for a line that also names the schedule and its status:
    only since when the held occurrence has been due. It leads
    {!schedule_hold_reading}, so the two cannot say different things. *)

val schedule_hold_reading : ko:bool -> due:string -> string
(** What the Schedules screen says about a schedule the runner is holding:
    since when its held occurrence has been due, and that it waits for the
    target Keeper to take the previous wake. [due] is already formatted. *)

val schedule_fence_hold_reading :
  ko:bool -> due:string -> target:string -> fence_owner:string -> string
(** The same reading for a schedule held because its target Keeper is
    shutting down: it names the Keeper and the shutdown operation instead of
    the previous wake. *)

val schedule_hold_as_of_tag : ko:bool -> checked:string -> string
(** The short form of a hold the runner has not read again since [checked]:
    the time the hold was seen, in place of since when it has been due. It
    leads {!schedule_hold_as_of_reading}. *)

val schedule_hold_as_of_reading : ko:bool -> checked:string -> string
(** The same hold in the detail pane: that the keeper had not taken the
    previous wake as of [checked]. Drawn instead of {!schedule_hold_reading}
    when the runner status beside the list is not [ok], because a failed tick
    does not re-read the hold (#38411). [checked] is already formatted. *)

val schedule_fence_hold_as_of_reading :
  ko:bool -> checked:string -> target:string -> fence_owner:string -> string
(** The fence hold ({!schedule_fence_hold_reading}) drawn as of [checked],
    for the same failed-tick reason as {!schedule_hold_as_of_reading}.
    [checked] is already formatted. *)
