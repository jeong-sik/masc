(** Shared owed-read backoff and surface error logging helpers. *)

val max_reconnect_s : float

val failed_read : Masc_tui_owed_read.t -> Masc_tui_owed_read.t

val note_read
  :  Masc_tui_types.state
  -> Masc_tui_read_failure.read
  -> ('a, Masc_tui_types.request_failure) result
  -> unit

val remember_surface_error
  :  Masc_tui_types.state
  -> surface:string
  -> current_error:string option
  -> set_error:(string option -> unit)
  -> string
  -> unit

val owe_pushed_read
  :  Masc_tui_types.state
  -> Masc_tui_types.Surface_read_source.t
  -> unit

val settle_pushed_dataset
  :  Masc_tui_types.state
  -> Masc_tui_types.Surface_read_order.dataset
  -> received:bool
  -> unit
