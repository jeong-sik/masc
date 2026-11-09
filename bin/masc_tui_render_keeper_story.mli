(** The Story window drawn below the Keepers list (RFC-0515 section 2.5).

    The window takes rows from the list, draws a rule, a title row and one
    page, and leaves the footer where it was. The story page is built by the
    Keepers list renderer because it reuses that renderer's cells and
    sentences; the schedule and memory pages read the state alone and are
    built here. *)

val rows : budget:int -> int
(** How many of the [budget] rows below the list's header the open window takes:
    the rule, the title and the page. The list keeps four rows and the window
    keeps four, which takes eight; on a shorter screen the window takes every
    row and covers the list. [0] when [budget] is not positive. *)

val draw :
  Buffer.t ->
  cols:int ->
  rows:int ->
  lead:string ->
  current:Masc_tui_keeper_story.page ->
  string list ->
  unit
(** [draw buf ~cols ~rows ~lead ~current lines] writes exactly [rows] rows: the
    rule, the title and then [lines], cut to what is left. [lead] is the styled
    text at the left of the title and [current] is the page whose tab is drawn
    reversed. A page longer than its rows ends in a row that counts the lines it
    leaves out. *)

val next_run_cell :
  Masc_tui_types.state ->
  now:float ->
  keeper_name:string ->
  Masc_tui_keeper_axis_cell.t option
(** The schedule cell the list draws for [keeper_name], read through the same
    agenda. The story page and the schedule page both lead with it, so neither
    contradicts the list row. *)

val memory_reading :
  Masc_tui_types.state -> keeper_name:string -> Masc_tui_keeper_memory_reading.t
(** The memory-health reading of [keeper_name]. *)

val schedule_lines :
  Masc_tui_types.state -> now:float -> keeper_name:string -> string list
(** The schedule page of [keeper_name]: the first page of the Keeper's own
    read, the one the Automation tab draws first, led by the list's [◷] cell and
    the store's counts. A page that is cut, a reading that is being read again
    and a read that failed say so. The window asks for the read while it is
    open. *)

val last_wake_entry :
  Masc_tui_types.state -> now:float -> keeper_name:string -> string option
(** The line of the story page's past group that tells the Keeper's last wake,
    from the same page of schedules. [None] when the page is whole and read and
    no schedule on it has woken the Keeper. A page that is not read, not
    readable or cut says so instead of saying nothing, and so does a reading
    that is read again or whose re-read failed. A wake on a cut page is called
    the latest on the first page, since a later page may hold a newer one, and a
    wake whose time cannot be read leaves the last wake unknown. *)

val turns_entry :
  Masc_tui_types.state ->
  now:float ->
  cells:int ->
  keeper_name:string ->
  string option
(** The line of the story page's past group that tells the Keeper's newest
    turns, newest first, each with the stop reason the receipt recorded and how
    long ago the turn ended. A turn whose record holds no stop reason says so.
    Turns that do not fit in [cells] are left out whole from the oldest. [None]
    when the Keeper has no turn on record. A read that has not answered, or that
    failed with nothing to show, says so instead of saying nothing. The window
    asks for the read while the story page is open. *)

val memory_lines :
  Masc_tui_types.state -> now:float -> keeper_name:string -> string list
(** The memory-health row of [keeper_name] with its fact age ladder. *)
