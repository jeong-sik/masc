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
    The Overview task cursor is an index into this list. *)

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
      (** [index] is the row's position in {!rows}, the value the cursor
          holds when this row is selected. *)
  | More_active of int  (** Rows of {!rows} the height left out. *)
  | Nothing_active  (** No task is held. Said rather than left blank. *)
  | Todo_backlog of backlog

val line_count : Masc.Tui_decode.task list -> backlog -> int
(** The lines {!lines} draws when nothing is cut. [0] for an empty list:
    the renderer draws no rows then, and the row budget decides on its own
    whether an empty or unread note gets one. *)

val lines :
  height:int -> cursor:int -> Masc.Tui_decode.task list -> backlog -> line list
(** At most [height] lines. With nothing held, [Nothing_active] and the
    backlog line, [Nothing_active] given up first. When every row fits, all
    of {!rows} and then the backlog line; when the rows fit but the backlog
    line does not, the backlog line is given up. When the rows do not fit, a
    window of them that keeps [cursor] on screen, then [More_active] with the
    count left out, then the backlog line -- each of the two only while a
    task row is still drawn beside it. *)

val age_text : age_text:(int -> string) -> now:float -> float option -> string
(** [age_text] applied to the seconds from the given instant to [now]; ["?"]
    when there is no instant to measure from. *)

val summary_text :
  age_text:(int -> string) -> now:float -> line -> string option
(** The plain text of a line that is not a task row. [None] for
    [Task_row]. *)
