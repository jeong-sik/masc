(** GitHub authentication UI transitions. Effects execute at their existing
    transition points on the UI owner fiber. *)

val login_lines : Masc_tui_types.state -> keeper_name:string -> string list -> unit

val login_finished
  :  Masc_tui_types.state
  -> keeper_name:string
  -> report:(string -> string -> unit)
  -> refresh:(string -> unit)
  -> (unit, Masc_tui_types.request_failure) result
  -> unit
(** A login the workspace guard kept back is reported as its kept-back notice
    alone, with the Keeper after it (RFC-tui-one-screen-grammar §2). *)

val token_saved
  :  Masc_tui_types.state
  -> keeper_name:string
  -> report:(string -> string -> unit)
  -> refresh:(string -> unit)
  -> (Yojson.Safe.t, Masc_tui_types.request_failure) result
  -> unit
(** A save the workspace guard kept back is reported and shown as its
    kept-back notice alone, never as a failed save. *)

val token_key : Masc_tui_types.state -> save:(string -> string -> unit) -> string -> unit
val paste_token : Masc_tui_types.state -> string -> unit
val start_login : Masc_tui_types.state -> login:(string -> unit) -> unit
val toggle_scope : Masc_tui_types.state -> index:int -> unit
val open_token : Masc_tui_types.state -> unit
