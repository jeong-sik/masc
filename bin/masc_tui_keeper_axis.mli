(** Horizontal visual axis cells for Keeper secondary row (RFC-0511 A2). *)

val segments :
  Masc_tui_types.state ->
  now:float ->
  keeper_name:string ->
  Masc_tui_keeper_axis_cell.t list
