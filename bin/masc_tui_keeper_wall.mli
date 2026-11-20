(** The 24h wall uses the same half-hour readings as the axis views. *)
type group = Failing | Other | Sound
val group : now:float -> Masc.Tui_decode.keeper_runtime option -> group
val rank : group -> int
val header : ko:bool -> cols:int -> now:float -> string
val fleet_rows :
  ko:bool -> cols:int -> now:float -> Masc.Tui_decode.keeper_runtime option list -> string list
(** Always returns 7 rows (6-row btop mirrored Braille fleet wave at 12-dot
    precision + legend row, paired on [cols >= 100] with a rounded dot-meter
    summary card), even when nothing in the window was read yet, so incoming
    24h pulse updates never shift keeper rows vertically. *)

val selected_cockpit_rows :
  ko:bool -> cols:int -> now:float -> name:string -> status:string ->
  Masc.Tui_decode.keeper_runtime option -> string list
(** Constant 5-row docked selected-keeper cockpit combining an agy-style header
    row with a magnified 4-row mirrored 24h waveform and dot-meter telemetry for
    the highlighted Keeper in [Wall_columns] view ([[]] below 44 columns).
    [status] is plain text: the header sanitises it, so a styled string would
    show its escape bytes. *)
val row :
  ?selected:bool -> ko:bool -> cols:int -> now:float -> name:string ->
  Masc.Tui_decode.keeper_runtime option -> string
(** Same band rule as {!fleet_rows}. *)
