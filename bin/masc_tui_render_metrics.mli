(** Visual telemetry and metrics dashboard renderer for the MASC TUI.

    Provides high-resolution ASCII & UTF-8 visualizations:
    - 24-hour fleet activity heatmaps
    - Keeper context window & fact memory gauges
    - Turn token velocity sparklines
    - Gate queue tool distribution bars
    - Braille 2x4 dot matrix trend curves
    - Compact overview pulse indicator

    Pure by construction: no terminal I/O, no mutation, no unhandled exceptions. *)

open Masc_tui_types

type metrics_kpis = {
  total_keepers : int;
  active_keepers : int;
  total_tasks : int;
  done_tasks : int;
  active_tasks : int;
  awaiting_tasks : int;
  total_facts : int;
  ordinary_facts : int;
  source_facts : int;
  snapshot_bytes : int;
  gate_pending_count : int;
  held_approvals_count : int;
}

val calculate_kpis : state -> metrics_kpis
val overview_pulse_line : cols:int -> state -> string
val section_pills_line : cols:int -> active:metrics_section -> string

val render_section_fleet : cols:int -> state -> string list
val render_section_resources : cols:int -> state -> string list
val render_section_tools : cols:int -> state -> string list

val render_metrics_body :
  cols:int ->
  budget:int ->
  state ->
  push:(string -> unit) ->
  push_styled:(style:string -> string -> unit) ->
  push_selected:(string -> unit) ->
  push_divider:(unit -> unit) ->
  push_empty:(unit -> unit) ->
  unit
