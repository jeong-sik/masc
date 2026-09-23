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
  screen:string ->
  keeper:string ->
  reading:facts_reading ->
  timestamp:string ->
  badge:string ->
  string
(** The facts title row. It carries the total and the filters; the breakdown and
    the sort belong to the row under it, which this module also draws. The title
    is the narrow line and the clock and the connection badge sit at its end, so
    a fact spelled here and there goes off the right edge. *)

val memory_fact_age_label : float -> string
val memory_fact_row_line : ?is_fleet:bool -> cols:int -> memory_fact_row -> string
val memory_fact_detail_lines : cols:int -> memory_fact_row -> string list

val memory_fleet_header_rows : cols:int -> state -> string list
(** The Total, Ordinary and Librarian rows above the sort row, each wrapped to
    the frame [cols] gives. *)

val memory_overview_scrolled : cols:int -> ?cursor:int -> state -> scrolled
(** The overview's scroll layout, its chrome counted from
    [memory_fleet_header_rows] at [cols]. *)

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
