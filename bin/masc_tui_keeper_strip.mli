(** Keeper Pulse's two header strips and the selected Keeper summary (RFC-0515 §2.8).
    The caller supplies one frame's clock and the roster before view filtering. *)
val header :
  now:float -> cells:int -> view:Masc_tui_keeper_list_model.view ->
  selected:string option ->
  age:(Masc_tui_keeper_list_model.row -> Masc_tui_keeper_list_model.memory_age) ->
  Masc_tui_keeper_list_model.row list -> string
(** Four fixed known groups; unknown readings keep an explicit [?] count.
    A selected Keeper's individual mark is bold, and labels yield before marks. *)

type fleet_cells = { name : string; pulse : string; strip : string; due : string }

val fleet_cells :
  now:float -> grid:Masc_tui_keeper_grid.t ->
  wakes:(Masc_tui_keeper_list_model.row -> Masc_tui_keeper_next_run.wake_slot list) ->
  Masc_tui_keeper_list_model.row list -> fleet_cells
(** Half-hour failed-Keeper counts, not failed-turn counts; rested counts as
    failure. Missing pulse/wake readings remain [?] when no known count exists.
    Paused Keepers do not contribute wakes. Draw these fields on the shared grid. *)

val selected_summary :
  now:float -> activity_cell:string ->
  next_run:Masc_tui_keeper_next_run.t -> recurrence:Schedule_domain.recurrence option ->
  memory:Masc_tui_keeper_memory_reading.t -> Masc_tui_keeper_list_model.row -> string
(** Activity age/since, next scheduled run with a decoded recurrence, lag and,
    for a failing Keeper, the independently observed next runtime path. *)
