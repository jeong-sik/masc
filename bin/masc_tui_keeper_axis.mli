(** Horizontal visual axis cells for Keeper secondary row (RFC-0511 A2). *)

val segments :
  Masc_tui_types.state ->
  now:float ->
  keeper_name:string ->
  runtime:Masc.Tui_decode.keeper_runtime option ->
  Masc_tui_keeper_axis_cell.t list
(** The cells of one keeper's second row, in the order they yield to a narrow
    row: the last one is dropped first. [runtime] is the keeper's row from the
    live roster, [None] when the roster did not read it; the failing-for cell
    (RFC-0511 D1) comes from it and the others from [state]. *)
