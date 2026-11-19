(** Which list the six move keys walk on the surface on screen, and how far a
    page key moves it (RFC tui-one-screen-grammar §3.1), decided where a test
    can reach it.

    The dispatcher used to decide this inside the executable, which no test
    links. Routing the Keeper list's keys back through its Keeper rows brought
    back Home unfolding the first group while every test still passed,
    because the tests called the two walks directly and never the choice
    between them.

    The page was decided there too, one branch per surface, and a surface
    with no branch paged by the whole body. The Memory list shares its body
    with the selected Keeper's detail, so at 80x24 it drew three rows and
    PgDn jumped thirteen: nine Keepers were never on screen. *)

type row_list = {
  rl_count : int;  (** rows the list holds *)
  rl_cursor : int;  (** the row the cursor is on *)
  rl_place : int -> unit;
      (** put the cursor on a row and move the window to show it *)
}
(** One surface's row cursor. The dispatcher builds it, because moving the
    window to the row needs the frame's geometry, which only the executable
    has. *)

type page_height =
  | Drawn of Masc_tui_types.paged_list
      (** the rows the last built frame drew the list in, as its renderer
          reported them ({!Masc_tui_types.lists_drawn}) *)
  | Projected of int
      (** rows the list's renderer works out from the projection it draws
          with, read before the frame. Only the lists whose renderers do not
          report them yet use it: the Task and Goal lists
          ([Masc_tui_render_work]) and the Tools Skill and request lists
          ([Masc_tui_render_tools]). *)
(** Where the height a page key moves by comes from. *)

type on_screen = {
  os_page : page_height;
  os_rows : row_list option;
      (** its row cursor; [None] on Overview, whose move keys select a
          destination rather than move a cursor *)
}
(** The list a surface draws, as the move keys need it. The height belongs to
    the list rather than to the key, so a list cannot be paged by a height it
    was not drawn in. *)

val page_height : Masc_tui_types.state -> page_height -> int option
(** The rows the list was drawn in; [None] when the last frame did not draw
    it. *)

val cursor_move : height:int option -> Masc_tui_scroll.key_move -> Masc_tui_scroll.Cursor_move.t
(** The cursor move a key makes in a list drawn [height] rows tall. A page is
    {!Masc_tui_scroll.page_step} of the height, so after PgDn the row that was
    last on screen is still on it, and after PgUp the row that was first.
    With no height a page key moves one row. *)

(** The two lists on the Tools surface a reader chooses from. *)
type tools_list =
  | Tools_skills  (** the Skill list on the Available pane *)
  | Tools_async_requests  (** the async request list, while no request is open *)

val tools_list : Masc_tui_types.state -> tools_list option
(** The list the move keys walk on the Tools surface. [None] on the panes
    that are readings -- receipts, usage, all tools, storage, the volume
    report, an open async request -- whose move keys scroll the page, and
    while the source picker is open, which walks its own list. [None] too
    on Available while its page is read ({!read_skill_page}), and on a list
    with nothing in it: a page with no Skill or no request still scrolls. *)

val read_skill_page : Masc_tui_types.state -> unit
(** Enter or f on Available, after the selected Skill's evidence is asked
    for: the move keys read the whole page -- the Skill's flow, its
    evidence, the tool table -- instead of walking the list. With no Skill
    selected there is nothing to read, and the keys stay where they were.
    Other panes keep their own Enter. *)

val choose_skill_again : Masc_tui_types.state -> bool
(** Esc on Available while its page is read: the move keys walk the Skill
    list again. [true] when Esc was spent this way, so the caller brings the
    selected Skill back on screen and Esc goes no further out. *)

val tools_keys : Masc_tui_types.state -> Masc_tui_keys.tools_keys
(** What the Tools footer says j/k and Esc do, from the same state
    {!tools_list} and {!choose_skill_again} read, and the original Task and
    open request Esc's arm reads: a list walked, the chosen Skill's page read,
    an open request or its original Task read, or a page with no list. *)

val show_tools_pane : Masc_tui_types.state -> Masc_tui_types.tools_pane -> unit
(** Change the Tools pane. A page read on Available belongs to that visit,
    so every arrival starts with the move keys on the list. *)

val moves :
  Masc_tui_types.state ->
  on_screen:(unit -> on_screen option) ->
  follow:(tools_list -> unit) ->
  (Masc_tui_scroll.key_move -> unit) option
(** How the move keys move the list on screen; [None] when no list answers
    them.

    An overlay drawn over a surface (the context inspector, the Git changes
    list) moves its rows. Otherwise the Keeper list walks its stops
    ({!Masc_tui_types.move_keeper_list_stop}) and Overview its destinations
    ({!Masc_tui_home.home_move}); neither moves its rows, since a Keeper row
    chosen by position opens its group and Overview has no row cursor. Tools
    walks the selection of its {!tools_list} and then calls [follow] with
    that list, because where the selection is drawn on the page is the
    frame's to say; the key itself never scrolls the page. Every other
    surface moves its rows, and only an empty list ignores the key.
    Every page is {!cursor_move} of the list's {!page_height}. *)
