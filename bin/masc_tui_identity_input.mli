(** Identity key and paste transitions on the UI owner fiber. *)

val current_query : Masc_tui_types.state -> string

val app_form_key
  :  Masc_tui_types.state
  -> save:(form:Masc_tui_identity_model.identity_app_form -> unit)
  -> string
  -> unit

val paste_form : Masc_tui_types.state -> string -> unit
val paste_filter : Masc_tui_types.state -> string -> unit
val open_app_form : Masc_tui_types.state -> unit

val toggle
  :  Masc_tui_types.state
  -> switch:(keeper_name:string -> provider_id:string -> enabled:bool -> unit)
  -> report:(string -> string -> unit)
  -> unit

val filter_key
  :  Masc_tui_types.state
  -> move_cursor:(delta:int -> unit)
  -> login:(keeper_name:string -> provider_id:string -> label:string -> unit)
  -> string
  -> unit

val start_numbered
  :  Masc_tui_types.state
  -> login:(keeper_name:string -> provider_id:string -> label:string -> unit)
  -> index:int
  -> unit

val start_cursor
  :  Masc_tui_types.state
  -> login:(keeper_name:string -> provider_id:string -> label:string -> unit)
  -> unit

val refresh_attached
  :  Masc_tui_types.state
  -> refresh:(keeper_name:string -> provider_ids:string list -> unit)
  -> unit
