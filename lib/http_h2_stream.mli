(** Two habits of one HTTP/2 response stream that the h2 library does not
    provide itself. {!Http_reqd} uses them for its HTTP/2 arm; the
    connection-level error handler uses {!close_after_flush}. *)

val dispatch : sw:Eio.Switch.t -> H2.Reqd.t -> (unit -> unit) -> unit
(** [dispatch ~sw reqd work] runs [work] in a daemon fiber of [sw], the
    stream's switch, after yielding once, so the h2 parser gets its turn
    before any request computation, pool wait or response mutation starts
    (RFC-0350). The response ledger scope of the calling fiber is carried
    into [work]. An exception from [work] is reported to the stream;
    cancellation propagates. *)

val close_after_flush : H2.Body.Writer.t -> unit
(** [close_after_flush writer] closes [writer] once every byte written to it
    so far has been handed to the connection, not right away. Close an H2
    response body with this, never with [H2.Body.Writer.close]: h2 0.13.0
    cuts a closed body at the client's flow-control window
    (anmonteiro/ocaml-h2#278).

    Write the whole body first. Bytes written after this call are cut the
    same way, because the flush only covers the bytes already written. *)
