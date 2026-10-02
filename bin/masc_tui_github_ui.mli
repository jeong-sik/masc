(** GitHub authentication UI transitions. Effects execute at their existing
    transition points on the UI owner fiber. *)

val login_lines : Masc_tui_types.state -> keeper_name:string -> string list -> unit

val login_finished
  :  keeper_name:string
  -> report:(string -> string -> unit)
  -> refresh:(string -> unit)
  -> (unit, string) result
  -> unit

val token_saved
  :  Masc_tui_types.state
  -> keeper_name:string
  -> report:(string -> string -> unit)
  -> refresh:(string -> unit)
  -> (Yojson.Safe.t, string) result
  -> unit

val token_key : Masc_tui_types.state -> save:(string -> string -> unit) -> string -> unit
val paste_token : Masc_tui_types.state -> string -> unit
val start_login : Masc_tui_types.state -> login:(string -> unit) -> unit
val toggle_scope : Masc_tui_types.state -> index:int -> unit
val open_token : Masc_tui_types.state -> unit
