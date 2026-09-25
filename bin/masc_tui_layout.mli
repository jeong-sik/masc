val nonnegative_width : int -> int
val keeper_context_bar_width : inner_width:int -> int

type board_read_allocation = {
  body_rows : int;
  comment_rows : int;
}

val board_read_box_rows : int

val allocate_board_read :
  terminal_rows:int ->
  body_line_count:int ->
  comment_line_count:int ->
  board_read_allocation

type board_read_scroll = {
  normalized_scroll : int;
  body_offset : int;
  comment_offset : int;
}

val project_board_read_scroll :
  body_line_count:int ->
  body_rows:int ->
  comment_line_count:int ->
  comment_rows:int ->
  int ->
  board_read_scroll

(** {1 Board read: comments beside the post} *)

val board_read_side_minimum_cols : int
(** Minimum width of the two-column layout, derived from its post, gutter,
    and comment widths. *)

val board_read_side_body_minimum_cols : int
(** Minimum width preserved for the post when the side layout is active. *)

val board_read_side_comment_cols : int
(** Fixed width of the comment content, excluding the gutter. *)

val board_read_side_gutter_cols : int
(** Separation included in the width returned for the right pane. *)

val board_read_side_layout : cols:int -> (int * int) option
(** [Some (body_cols, comment_cols)] when the pane can keep the 78-cell post,
    two-cell gutter, and fixed 40-cell comment column. The returned comment
    width includes the gutter because the renderer gives it to the right pane. *)

type board_read_side_allocation = {
  body_rows : int;
  comment_rows : int;
}

val allocate_board_read_side :
  terminal_rows:int ->
  body_line_count:int ->
  comment_line_count:int ->
  board_read_side_allocation
(** Give each side-by-side column the full shared vertical viewport. A comment
    column with content still reserves its first row for the heading and folds
    away when the viewport cannot fit both heading and content. *)
type automation_schedule_row =
  { status : string
  ; requested_clock : string
  ; recurrence : string
  ; summary : string
  }

val automation_schedule_lines :
  inner_width:int ->
  status_cells:int ->
  clock_cells:int ->
  automation_schedule_row list ->
  string list
(** Preserve each schedule's summary in the main Automation row. Rows whose
    recurrence exceeds the space left after a summary reserve put the full
    recurrence on labelled continuation lines. Inputs must already be safe
    single-line terminal text. *)

(** {1 Sharing rows between sections} *)

type section = {
  floor : int;
      (** The rows without which the section says nothing: a heading, the
          first row of what it lists. Clamped to [0 .. want]. *)
  want : int;  (** Every row the section could draw. *)
}

type allocation = {
  rows : int list;
      (** One count per section, in the order the sections were given. *)
  filler : int;  (** The budget no section wanted. *)
}

val allocate : budget:int -> section list -> allocation
(** Share [budget] rows between sections listed in priority order, in two
    passes. The first gives each section its floor, in order, while rows
    last; the second gives what is left, in the same order, up to each
    section's want. A section before another cannot take the rows that
    other one needs to mean anything until every floor is paid.

    The counts sum to at most [budget] and none is negative. Adding a row to
    [budget] never takes a row from any section, and neither does lowering
    one section's floor or want take a row from another. *)
