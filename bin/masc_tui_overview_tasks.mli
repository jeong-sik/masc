(** The Overview's Tasks section: which tasks get a row, in what order, and
    what stands in for the ones that do not.

    The section answers "what is moving right now". Work someone holds gets a
    row each -- [InProgress], then [AwaitingVerification], then [Claimed] --
    and the [Todo] backlog is one line with its size and its oldest age.
    Pure over its arguments so a test can read it without the renderer. *)

val rows : Masc.Tui_decode.task list -> Masc.Tui_decode.task list
(** The tasks that get a row, in drawing order. Within one status the task
    held longest comes first; a task whose timestamp does not parse comes
    after the ones that do. [Todo], [Done] and [Cancelled] never appear.
    The Overview selection is a task id, looked up in this list at every
    use: a poll that drops a finished task shifts every index below it. *)

val held_since : Masc.Tui_decode.task -> float option
(** When the row's current hold began: [started_at] for [InProgress],
    [submitted_at] for [AwaitingVerification], [claimed_at] for [Claimed].
    [None] for the other statuses and for a timestamp that does not parse. *)

type backlog = {
  todo_count : int;
  oldest_created_at : float option;
      (** The earliest parseable [created_at] among the [Todo] tasks. [None]
          when there are none, or when none of them parses. *)
}

val backlog : Masc_domain.task list -> backlog
(** Reads the full domain rows, because the Overview's own rows carry no
    creation time. *)

type line =
  | Task_row of { index : int; task : Masc.Tui_decode.task }
      (** [index] is the row's position in {!rows}. *)
  | More_active of int  (** Rows of {!rows} the height left out. *)
  | Nothing_active  (** No task is held. Said rather than left blank. *)
  | Todo_backlog of backlog

val line_count : Masc.Tui_decode.task list -> backlog -> int
(** The lines {!lines} draws when nothing is cut. [0] for an empty list:
    the renderer draws no rows then, and the row budget decides on its own
    whether an empty or unread note gets one. *)

val lines :
  height:int ->
  selected:int option ->
  Masc.Tui_decode.task list ->
  backlog ->
  line list
(** At most [height] lines. With nothing held, [Nothing_active] and the
    backlog line, [Nothing_active] given up first. When every row fits, all
    of {!rows} and then the backlog line; when the rows fit but the backlog
    line does not, the backlog line is given up. When the rows do not fit, a
    window of them that keeps the [selected] row on screen (the top rows
    when nothing is selected), then [More_active] with the
    count left out, then the backlog line -- each of the two only while a
    task row is still drawn beside it. *)

val row_of : Masc.Tui_decode.task list -> task_id:string -> int option
(** The open task's position in {!rows}. [None] for a task that has no row
    -- a [Todo], [Done] or [Cancelled] one opened from the palette, a link or
    the agenda -- and then no row is highlighted beside its detail. *)

val selected_index :
  Masc.Tui_decode.task list -> selected:string option -> int option
(** The selected task's current row. [None] when nothing is selected or the
    selected task has left {!rows}: a finished task selects nothing rather
    than the row that moved into its place. *)

val selected_task :
  Masc.Tui_decode.task list ->
  selected:string option ->
  Masc.Tui_decode.task option
(** The task behind {!selected_index}; what Enter opens and Ctrl-] names. *)

val id_at : Masc.Tui_decode.task list -> int -> string option
(** The id on a row of {!rows}, for keys that name a row by position. *)

type step = Next | Previous

val step :
  Masc.Tui_decode.task list -> selected:string option -> step -> string option
(** j/k. From no selection (or one that left the rows), the first row; from
    a selected row, its neighbour, stopping at either end. [None] only when
    there are no rows. *)

(** Whether the task list owns j/k, and which row it has chosen. One value
    rather than a focus flag beside an id: a selection only exists while the
    list is focused, so what Enter opens, what Ctrl-] follows and the row
    drawn highlighted cannot disagree. *)
type focus =
  | No_task_focus  (** j/k belong to the rest of the Overview. *)
  | Task_focus of { selected : string option }
      (** [None] when the list has no row, or when the chosen task left
          {!rows}. *)

val selection : focus -> string option
(** The chosen id; [None] without task focus. *)

val is_focused : focus -> bool

val focus_list : Masc.Tui_decode.task list -> focus
(** Task focus on the first row, or on nothing when no task is held. *)

val toggle : Masc.Tui_decode.task list -> focus -> focus
(** The [t] key: {!focus_list} from no focus, no focus from task focus. *)

val land_on : Masc.Tui_decode.task list -> task_id:string -> focus
(** A landing from the palette, the agenda or a followed link. Task focus
    on the task when it has a row; no focus when it does not -- a [Todo],
    [Done] or [Cancelled] task could never be highlighted. *)

val move : Masc.Tui_decode.task list -> focus -> step -> focus
(** j/k under task focus ({!step}); no focus stays no focus. *)

val reconcile : Masc.Tui_decode.task list -> focus -> focus * string option
(** After a poll. A chosen task that left {!rows} is dropped from the focus
    and its id returned, once, so the caller can say so; the focus stays on
    the list. [None] when nothing changed. *)

(** What the last backlog read said about the rows. A failed read is not
    an empty list: the rows it would have held are unknown, not gone. *)
type rows_reading =
  | Rows_unread  (** No read yet, or the workspace changed under the TUI. *)
  | Rows_read of Masc.Tui_decode.task list
      (** The active rows. A read recovered from a backup, or one whose goal
          links could not be read, still read its rows. *)
  | Rows_unavailable of string  (** The backlog could not be read. *)

val after_read : rows_reading -> focus -> focus * string option
(** {!reconcile} against rows that were read. An unread or unavailable
    reading keeps the focus and its choice as they are and says nothing: the
    chosen task did not leave, the read did not look. *)

type opening =
  | Open of Masc.Tui_decode.task
  | No_held_task  (** The list has no row. *)
  | No_selection  (** Rows exist and none is chosen. *)

val opening : Masc.Tui_decode.task list -> focus -> opening option
(** What Enter does under task focus. [None] without task focus: the key is
    not the list's then. *)

val age_text : age_text:(int -> string) -> now:float -> float option -> string
(** [age_text] applied to the seconds from the given instant to [now]; ["?"]
    when there is no instant to measure from. *)

val summary_text :
  age_text:(int -> string) -> now:float -> line -> string option
(** The plain text of a line that is not a task row. [None] for
    [Task_row]. *)
