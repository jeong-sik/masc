(** The 24h wall uses the same half-hour readings as the axis views. *)
type group = Failing | Other | Sound
val group : now:float -> Masc.Tui_decode.keeper_runtime option -> group
val rank : group -> int
val header : cols:int -> now:float -> string
val fleet : cols:int -> now:float -> Masc.Tui_decode.keeper_runtime option list -> string
val row : cols:int -> now:float -> name:string -> Masc.Tui_decode.keeper_runtime option -> string
