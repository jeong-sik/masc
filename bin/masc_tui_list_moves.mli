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

val moves :
  Masc_tui_types.state ->
  rows:(unit -> row_list option) ->
  (Masc_tui_scroll.Cursor_move.t -> unit) option
(** How the move keys move the list on screen; [None] when no list answers
    them.

    An overlay drawn over a surface (the context inspector, the Git changes
    list) moves its [rows]. Otherwise the Keeper list walks its stops
    ({!Masc_tui_types.move_keeper_list_stop}) and Overview its destinations
    ({!Masc_tui_home.home_move}); neither asks for [rows], since a Keeper row
    chosen by position opens its group and Overview has no row cursor. Every
    other surface moves its [rows], and only an empty list ignores the
    key. *)
