(** Board request execution. The caller owns workspace-authorized launch,
    mailbox delivery and reporting, including synchronous fallback. *)

type 'a launch =
  deliver:(('a, string) result -> Masc_tui_async_protocol.async_msg) ->
  (unit -> ('a, string) result) -> unit

val start_board_post_refresh :
  Masc_tui_types.state -> host:string -> port:int -> post_id:string ->
  launch:(Masc_tui_types.board_post * Masc_tui_types.board_comment list * string option) launch -> unit

val start_board_post :
  Masc_tui_types.state -> host:string -> launch:string launch ->
  report:(string -> string -> unit) -> title:string -> body:string ->
  ?hearth:string -> unit -> unit

val start_board_comment :
  Masc_tui_types.state -> host:string -> launch:string launch ->
  report:(string -> string -> unit) -> post_id:string -> content:string -> unit

val start_board_vote :
  Masc_tui_types.state -> host:string -> launch:string launch ->
  report:(string -> string -> unit) -> post_id:string -> up:bool -> unit
