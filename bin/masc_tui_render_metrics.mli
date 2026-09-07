(** Metrics built from observed runtime and durable task snapshots.
    Current work and outcomes are distinct from the Recent event feed.
    Missing telemetry stays unavailable; rendering does not scan task history. *)

open Masc_tui_types

type turn_counts = { running : int; idle : int; unavailable : int }
type metrics_kpis = {
  total_keepers : int;
  unpaused_keepers : int;
  turns : turn_counts option;
  tasks : Masc_tui_task_flow.counts option;
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
