(** Which list the six move keys walk on the surface on screen (RFC
    tui-one-screen-grammar §3.1), decided where a test can reach it.

    The dispatcher used to decide this inside the executable, which no test
    links. Routing the Keeper list's keys back through its Keeper rows brought
    back Home unfolding the first group while every test still passed,
    because the tests called the two walks directly and never the choice
    between them. *)

type row_list = {
  rl_count : int;  (** rows the list holds *)
  rl_cursor : int;  (** the row the cursor is on *)
  rl_place : int -> unit;
      (** put the cursor on a row and move the window to show it *)
}
(** One surface's row cursor. The dispatcher builds it, because moving the
    window to the row needs the frame's geometry, which only the executable
    has. *)

(** The two lists on the Tools surface a reader chooses from. *)
type tools_list =
  | Tools_skills  (** the Skill list on the Available pane *)
  | Tools_async_requests  (** the async request list, while no request is open *)

val tools_list : Masc_tui_types.state -> tools_list option
(** The list the move keys walk on the Tools surface. [None] on the panes
    that are readings -- receipts, usage, all tools, storage, the volume
    report, an open async request -- whose move keys scroll the page, and
    while the source picker is open, which walks its own list. [None] too
    on a list with nothing in it: a page with no Skill or no request still
    scrolls. *)

val moves :
  Masc_tui_types.state ->
  rows:(unit -> row_list option) ->
  follow:(tools_list -> unit) ->
  (Masc_tui_scroll.Cursor_move.t -> unit) option
(** How the move keys move the list on screen; [None] when no list answers
    them.

    An overlay drawn over a surface (the context inspector, the Git changes
    list) moves its [rows]. Otherwise the Keeper list walks its stops
    ({!Masc_tui_types.move_keeper_list_stop}) and Overview its destinations
    ({!Masc_tui_home.home_move}); neither asks for [rows], since a Keeper row
    chosen by position opens its group and Overview has no row cursor. Tools
    walks the selection of its {!tools_list} and then calls [follow] with
    that list, because where the selection is drawn on the page is the
    frame's to say; the key itself never scrolls the page. Every other
    surface moves its [rows], and only an empty list ignores the key. *)
