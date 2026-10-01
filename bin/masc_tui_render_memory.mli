(** Memory surface and fact explorer renderer for the MASC TUI.

    Decomposed from masc_tui_render.ml.
    Renders fleet keeper memory health, ordinary/source/invalidated fact rows,
    category filters, sorting, KPI banners, and structured fact inspector cards.

    Pure by construction: no terminal I/O, no mutation, no unhandled exceptions. *)

open Masc_tui_types

type memory_state = Masc_tui_types.memory_state =
  | Memory_ordinary
  | Memory_warning
  | Memory_degraded
  | Memory_no_current
  | Memory_source_only
  | Memory_starving
  | Memory_read_error

(** #39831: the kind of each row in the block under the selected keeper on the
    Memory table, and which of them the default view draws. The rest wait
    behind the [d] detail toggle, which draws every row. A lag that could not
    be read ([Row_lag None]) is shown, never folded into zero. *)
type memory_row_kind =
  | Row_state
  | Row_last_saved
  | Row_ledger
  | Row_lag of int option
  | Row_librarian_failures of int
  | Row_vision_errors of int
  | Row_stalled
  | Row_cause
  | Row_read_error
  | Row_alert

type memory_row_visibility =
  | Shown_by_default
  | Detail_only

val memory_row_visibility : memory_row_kind -> memory_row_visibility

val facts_keeper_label : string option -> string
(** How the facts title names the keeper it is reading. The fleet view is asked
    for as "*" and read as a phrase. *)

type facts_reading =
  | Facts_unread of { reading : string }
  | Facts_loaded of
      { total : int
      ; filter_label : string
      ; query_label : string
      }

val facts_title :
  cols:int ->
  screen:string ->
  keeper:string ->
  reading:facts_reading ->
  timestamp:string ->
  badge:string ->
  string
(** The facts title row of a frame [cols] wide. It carries the total and the
    filters; the breakdown and the sort belong to the row under it, which this
    module also draws. The title is the narrow line and the clock and the
    connection badge sit at its end, so a fact spelled here and there goes off
    the right edge. The clock and the badge are never shortened; the keeper's
    name folds to its floor and the counts and filters are cut before the name
    goes further ({!Masc_tui_ansi.detail_heading}). *)

val memory_fact_age_label : float -> string
val memory_fact_row_line : ?is_fleet:bool -> cols:int -> memory_fact_row -> string
val memory_fact_detail_lines : cols:int -> memory_fact_row -> string list
(** Full claim and provenance rows, wrapped to the frame of a [cols]-column
    terminal. Each returned row occupies one scrollable display row. *)

val memory_fleet_header_rows : cols:int -> state -> string list
(** The Total, Ordinary and Librarian rows above the sort row, each wrapped to
    the frame [cols] gives. *)

val memory_overview_scrolled : cols:int -> budget:int -> ?cursor:int -> state -> scrolled
(** The overview's scroll layout at [cols], with summary, rejected Keeper
    rows and selected Keeper detail limited to the same body [budget] used by
    the renderer. *)

val render_memory_body :
  cols:int ->
  budget:int ->
  state ->
  push:(string -> unit) ->
  push_styled:(style:string -> string -> unit) ->
  push_selected:(string -> unit) ->
  push_divider:(unit -> unit) ->
  push_empty:(unit -> unit) ->
  unit

val memory_fact_list_floor_rows : int
(** How many rows the fact list keeps before the detail below it takes any --
    one of which the window reading takes when the list overflows. A fact has
    no length limit, so without this floor one long fact left a browser of a
    few hundred facts showing a single row. *)

val memory_facts_content_height : cols:int -> budget:int -> cursor:int -> state -> int
(** The fact list's height after reserving the selected detail, filters and
    errors. [budget] excludes the surrounding surface chrome. *)

val render_memory_facts_body :
  cols:int ->
  budget:int ->
  state ->
  push:(string -> unit) ->
  push_styled:(style:string -> string -> unit) ->
  push_selected:(string -> unit) ->
  push_divider:(unit -> unit) ->
  push_empty:(unit -> unit) ->
  unit
