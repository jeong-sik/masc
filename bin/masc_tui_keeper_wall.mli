(** The 24h wall uses the same half-hour readings as the axis views. *)
type group = Failing | Other | Sound
val group : now:float -> Masc.Tui_decode.keeper_runtime option -> group
val rank : group -> int
val header : ko:bool -> cols:int -> now:float -> string
val fleet_rows :
  ko:bool -> cols:int -> now:float -> Masc.Tui_decode.keeper_runtime option list -> string list
(** Six-row btop-style mirrored Braille fleet wave (3 upward ok-turn rows over
    3 downward failure/rested rows at 12-dot vertical precision) plus a legend
    row, paired on wide terminals ([cols >= 100]) with a rounded summary
    dot-meter mini-box. Returns a 2-row unread summary + legend when nothing in
    the window was read. *)

val selected_cockpit_rows :
  ko:bool -> cols:int -> now:float -> name:string -> status:string ->
  Masc.Tui_decode.keeper_runtime option -> string list
(** Five-row docked selected-keeper cockpit combining an agy-style header row
    with a magnified 4-row mirrored 24h waveform and dot-meter telemetry for the
    highlighted Keeper in [Wall_columns] view ([[]] below 44 columns). A
    window with nothing read draws two rows: the header and the unread label.
    [status] is plain text: the header sanitises it, so a styled string would
    show its escape bytes. *)
val row :
  ?selected:bool -> ko:bool -> cols:int -> now:float -> name:string ->
  Masc.Tui_decode.keeper_runtime option -> string
(** Same band rule as {!fleet_rows}. *)
