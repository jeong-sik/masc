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
    {!tools_list} and {!choose_skill_again} read: a list walked, the chosen
    Skill's page read, or a page with no list. *)

val show_tools_pane : Masc_tui_types.state -> Masc_tui_types.tools_pane -> unit
(** Change the Tools pane. A page read on Available belongs to that visit,
    so every arrival starts with the move keys on the list. *)

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
