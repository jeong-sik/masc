(** Reduction of fleet schedule agenda into a Keeper's next run status (RFC-0511 A1). *)

type t =
  | No_schedule
  | Scheduled_at of float
  | Late_since of float
  | Held_current of float
  | Held_as_of of float
  | Not_before of float
  | Unknown

type index

val index_of_agenda :
  freshness:Masc_tui_agenda.schedule_freshness ->
  ?runner:Tui_decode.schedule_runner_status ->
  Masc_tui_types.schedule_snapshot option ->
  index

val of_snapshot :
  freshness:Masc_tui_agenda.schedule_freshness ->
  ?runner:Tui_decode.schedule_runner_status ->
  keeper_name:string ->
  Masc_tui_types.schedule_snapshot ->
  t

val find : index -> keeper_name:string -> t

val cell : now:float -> t -> Masc_tui_keeper_axis_cell.t option
