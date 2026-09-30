(** Board request execution. The caller owns mailbox delivery and reporting.
    Existing asynchronous and synchronous fallback behavior is retained. *)

val start_board_post_refresh :
  Masc_tui_types.state -> host:string -> port:int -> post_id:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) ->
  report_error:(string -> unit) -> unit

val start_board_post :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) ->
  report:(string -> string -> unit) -> title:string -> body:string ->
  ?hearth:string -> unit -> unit

val start_board_comment :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) ->
  report:(string -> string -> unit) -> post_id:string -> content:string -> unit

val start_board_vote :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) ->
  report:(string -> string -> unit) -> post_id:string -> up:bool -> unit
