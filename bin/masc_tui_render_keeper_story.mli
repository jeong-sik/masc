(** The Story window drawn below the Keepers list (RFC-0515 section 2.5).

    The window takes rows from the list, draws a rule, a title row and one
    page, and leaves the footer where it was. The story page is built by the
    Keepers list renderer because it reuses that renderer's cells and
    sentences; the schedule and memory pages read the state alone and are
    built here. *)

val rows : budget:int -> int
(** How many of the [budget] rows below the list's header the open window takes:
    the rule, the title and the page. The list keeps at least four rows when it
    can, and the window keeps at least four when [budget] allows. [0] when
    [budget] is not positive. *)

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
(** The schedules of the fleet agenda that are aimed at [keeper_name]. A cut
    agenda says so. *)

val memory_lines :
  Masc_tui_types.state -> now:float -> keeper_name:string -> string list
(** The memory-health row of [keeper_name] with its fact age ladder. *)
