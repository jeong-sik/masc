(** Wrapped rows for the one Board document being read. Scrolling changes the
    viewport, not this source. Retaining one document avoids re-running Markdown
    and thread ordering on each wheel event without keeping a history of posts. *)
type source = {
  post : Masc_tui_types.board_post;
  detail :
    (Masc_tui_types.board_post * Masc_tui_types.board_comment list * string option)
      Masc_tui_board_detail.view;
  related_posts : Masc_tui_types.board_post list;
  keeper_names : string list;
  columns : int;
  styles : string list;
  table_frame : bool;
}

(** One wrapped row of the comment column. A comment's rows are drawn after a
    gutter of {!comment_gutter_cells} cells, where the reader marks the
    selected comment; a note is drawn whole and belongs to no comment. *)
type comment_row =
  | Thread_note of string
      (** The loading or failure line, or the count above a partial thread. *)
  | Comment_text of { comment_id : string; text : string }
      (** One row of the comment [comment_id], without its gutter. *)

type rows
type t

val comment_gutter_cells : int
(** Display cells the gutter before a comment row takes. The comment text is
    wrapped to the column less these cells. *)

val close_time : float -> (string, float) result
(** UTC close time inside Ptime's supported calendar, or the original seconds
    when the supplied number is non-finite or outside that calendar. *)

val create : unit -> t
val get : t -> source:source -> render:(unit -> string list * comment_row list * (string * int) option) -> rows
(** Exact immutable source equality; refreshed equal data can reuse rows, while
    edits, role changes, width or styling changes replace them. Failed rendering
    never publishes a partial result. *)
val body_line_count : rows -> int
val comment_line_count : rows -> int
(** How many wrapped rows each half holds. A comment becomes an identity row,
    a timestamp row and one row per wrapped line, so this is never the number
    of comments -- the Board header draws that beside the post, and a reader
    who meets both numbers has to be told which is which. *)

val body_line : rows -> int -> string
val comment_line : rows -> gutter:(string -> string) -> int -> string
(** Indexed access to the selected viewport, independent of scroll depth.
    [gutter comment_id] is drawn before a comment's row and must be
    {!comment_gutter_cells} wide; a note row is returned as it is. The gutter
    is applied here rather than wrapped into the retained rows, so moving the
    selection does not re-render the thread. *)

val comment_span : rows -> comment_id:string -> (int * int) option
(** The first wrapped row of [comment_id] and how many rows it spans, or
    [None] when this document draws no such comment. *)

val initial_comment_offset : rows -> comment_id:string -> int option
(** Wrapped row of the newest numeric page comment, including retained ancestors. *)
