(** The 24h wall uses the same half-hour readings as the axis views. *)
type group = Failing | Other | Sound
val group : now:float -> Masc.Tui_decode.keeper_runtime option -> group
val rank : group -> int
val header : ko:bool -> cols:int -> now:float -> string
val fleet_rows :
  ko:bool -> cols:int -> now:float -> Masc.Tui_decode.keeper_runtime option list -> string list
(** Four-row btop-style mirrored Braille fleet wave (2 upward ok-turn rows over
    2 downward failure/rested rows) plus an inline legend row, or a single
    unread summary plus legend row when nothing in the window was read.
    A band nothing was read for says so once ({!Masc_tui_keeper_strip.history_unknown_label});
    a partly read band keeps one mark per half hour. *)
val row :
  ?selected:bool -> ko:bool -> cols:int -> now:float -> name:string ->
  Masc.Tui_decode.keeper_runtime option -> string
(** Same band rule as {!fleet_rows}. *)
