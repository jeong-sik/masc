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
    the store's counts. The rows run oldest first by the time each one shows,
    and a held row or one whose delivered wake has not settled names that in
    its status column. A page that is cut, a reading that is being read again
    and a read that failed say so. The window asks for the read while it is
    open. *)

val body_rows : rows:int -> int
(** The lines a window of [rows] rows holds: all but its rule and its title. *)

val feed_lines :
  Masc_tui_types.state -> now:float -> max_lines:int -> keeper_name:string -> string list
(** The past group of the story page told as one feed: the newest turns, the
    newest wakes and the last digest of [keeper_name], oldest first, one line
    each with how long ago it happened. A source that is not read, not
    readable, cut, being read again or whose read failed has no event to put in
    its place, so it gets a line of its own after the events, cautions first,
    whatever the width: turns, schedules and the memory-health reading are the
    three sources. A note of a read that failed ends with the reason the read
    stored. A wake whose time cannot be read leaves the newest wakes unknown.
    At most [max_lines] lines come back, none for a count of zero or less,
    notes included. The notes keep their lines and the oldest events give way;
    a window too short for every note keeps the cautions. *)

val memory_lines :
  Masc_tui_types.state -> now:float -> keeper_name:string -> string list
(** Five separate observations for [keeper_name]: fact age, snapshot save,
    source invalidation, Librarian continuity and the shared-World entry
    path. An age or save time does not establish source validity; retained
    Librarian state does not establish that a model is running now. *)
