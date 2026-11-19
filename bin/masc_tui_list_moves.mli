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

type on_screen = {
  os_height : int;
      (** the rows the list is drawn in, measured by the projection the frame
          draws it with: a page is these less the one row it keeps *)
  os_rows : row_list option;
      (** its row cursor; [None] on Overview, whose move keys select a
          destination rather than move a cursor *)
}
(** The list a surface draws, as the move keys need it. The height belongs to
    the list rather than to the key, so a list cannot be paged by a height it
    was not drawn in. *)

val cursor_move : height:int -> Masc_tui_scroll.key_move -> Masc_tui_scroll.Cursor_move.t
(** The cursor move a key makes in a list drawn [height] rows tall. A page is
    {!Masc_tui_scroll.page_step} of the height, so after PgDn the row that was
    last on screen is still on it, and after PgUp the row that was first. *)

val moves :
  Masc_tui_types.state ->
  on_screen:(unit -> on_screen option) ->
  (Masc_tui_scroll.key_move -> unit) option
(** How the move keys move the list on screen; [None] when no list answers
    them.

    An overlay drawn over a surface (the context inspector, the Git changes
    list) moves its rows. Otherwise the Keeper list walks its stops
    ({!Masc_tui_types.move_keeper_list_stop}) and Overview its destinations
    ({!Masc_tui_home.home_move}); neither moves its rows, since a Keeper row
    chosen by position opens its group and Overview has no row cursor. Every
    other surface moves its rows, and only an empty list ignores the key.
    Every page is {!cursor_move} of the list's [os_height]. *)
