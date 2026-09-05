(** Memory surface and fact explorer renderer for the MASC TUI.

    Decomposed from masc_tui_render.ml.
    Renders fleet keeper memory health, ordinary/source/invalidated fact rows,
    category filters, sorting, KPI banners, and structured fact inspector cards.

    Pure by construction: no terminal I/O, no mutation, no unhandled exceptions. *)

open Masc_tui_types

val memory_fact_age_label : float -> string
val memory_fact_row_line : cols:int -> memory_fact_row -> string
val memory_fact_detail_lines : cols:int -> memory_fact_row -> string list

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
