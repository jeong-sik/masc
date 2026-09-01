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
