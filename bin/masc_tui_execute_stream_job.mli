(** The connection loop behind the Terminal tab's Execute output stream.

    [run] reads one Keeper's stream into [reader], opens another connection a
    pause after one ends, and hands the reader's view to [on_view] while it
    changes. It does not return: stop it by cancelling the fiber that runs it.
    The socket is [observe], so a test can stand in for the server.

    - [observe ~on_chunk] opens one connection and calls [on_chunk] with each
      piece of the response until the connection ends. [Error] says why it
      could not be read. An exception [on_chunk] raises ends the connection
      and passes through [observe].
    - [on_view] gets the reader's view when {!Masc_tui_execute_stream.version}
      has moved, at most once every [post_interval_s], and once more just
      before [on_ended], so rows a connection delivered last are shown under
      the notice that it ended.
    - [on_ended reason] is called when a connection ends. [reason] is the
      reader's refusal when it refused a frame, otherwise what [observe]
      reported, or that the server closed the stream. *)

val run :
  clock:_ Eio.Time.clock ->
  reconnect_s:float ->
  post_interval_s:float ->
  reader:Masc_tui_execute_stream.t ->
  observe:(on_chunk:(string -> unit) -> (unit, string) result) ->
  on_view:(Masc_tui_execute_stream.view -> unit) ->
  on_ended:(string -> unit) ->
  unit
