(** Wrapped rows for the one Board document being read. Scrolling changes the
    viewport, not this source. Retaining one document avoids re-running Markdown
    and thread ordering on each wheel event without keeping a history of posts. *)
type source = {
  post : Masc_tui_types.board_post;
  detail :
    (Masc_tui_types.board_post * Masc_tui_types.board_comment list)
      Masc_tui_board_detail.view;
  related_posts : Masc_tui_types.board_post list;
  keeper_names : string list;
  columns : int;
  styles : string list;
  table_frame : bool;
}

type rows
type t
val create : unit -> t
val get : t -> source:source -> render:(unit -> string list * string list) -> rows
(** Exact immutable source equality; refreshed equal data can reuse rows, while
    edits, role changes, width or styling changes replace them. Failed rendering
    never publishes a partial result. *)
val body_count : rows -> int
val comment_count : rows -> int
val body_line : rows -> int -> string
val comment_line : rows -> int -> string
(** Indexed access to the selected viewport, independent of scroll depth. *)
