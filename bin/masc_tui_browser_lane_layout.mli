(** Wrapped rows for the one browser page on screen.

    Object analysis puts up to 200 nodes and 50,000 characters into the view,
    and wrapping them ran on every frame and twice per keystroke -- once in
    the scroll handler asking for the row count, once in the frame. This
    retains one page, the way {!Masc_tui_board_read_layout} retains one Board
    document (#34272). *)

(** The three branches of [browser_lane_page_layout]: a read scene, the page
    text behind it, or neither. *)
type content =
  | Scene of Masc.Browser_scene.node list
  | Page of string
  | Empty

(** Every input that decides a row. [scene_cursor] is one because it moves the
    [>] marker; [columns] because it sets the wrap width. Scroll is absent:
    it selects rows, it does not make them. *)
type source = { content : content; scene_cursor : int; columns : int }

type t
type rows

val create : unit -> t

(** [get cache ~source ~render] returns the retained rows when [source] equals
    the retained one, and otherwise calls [render] and retains its result. One
    page is retained, so moving to another and back re-renders. *)
val get : t -> source:source -> render:(unit -> string list * int option) -> rows

val count : rows -> int
val line : rows -> int -> string
val selected_row : rows -> int option
(** First wrapped row of the selected observed node, or [None] when no node
    is selected. Comes from the projection, never from matching rendered text. *)
