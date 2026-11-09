(** Habits of one HTTP/2 response stream that the h2 library does not
    provide itself. {!Http_reqd} uses them for its HTTP/2 arm, the stream
    registry ends stream scopes with them, and the connection-level error
    handler uses {!close_after_flush}. *)

(** Why a stream's scope ended before its response did (RFC-0518 D1). *)
type reset_cause =
  | Reset_by_peer  (** The peer sent RST_STREAM. *)
  | Reset_by_us  (** h2 wrote RST_STREAM for this stream. *)
  | Stalled  (** The peer took no response bytes within the stall bound. *)
  | Out_of_capacity of Http_h2_response_ledger.refusal
      (** The response ledger refused the next payload. *)
  | Raised of exn
      (** The stream's own work raised: the request handler, a deferred body
          callback, or a fiber forked on the stream switch. *)

exception Stream_reset of reset_cause
(** The error a stream switch fails with. Every fiber of the stream sees it
    as [Eio.Cancel.Cancelled (Stream_reset cause)]. *)

val report : H2.Reqd.t -> exn -> unit
(** [report reqd exn] reports [exn] to the stream once. Before a response
    started, h2 answers it through the connection's error handler (500);
    after, it closes the body and sends RST_STREAM (INTERNAL_ERROR), which
    flow control does not hold back. A stream that already carries an error
    gets nothing more. An exception raised by the report itself is logged at
    warn and not raised, except [Eio.Cancel.Cancelled]. Use {!reset} when the
    stream has a switch; this is for a request that never got one. *)

val report_failure : H2.Reqd.t -> exn -> unit
(** [report_failure reqd exn] is {!report} for an exception the stream's own
    work raised. It also logs [exn] at error, unless the report reached the
    connection's error handler, which logs it itself. h2 calls that handler
    only while the stream has no response and no error. A response h2 is
    still sending is reset without it, a fixed body included. A stream that
    is closed or already carries an error takes nothing, and neither does a
    response h2 has marked complete. *)

val reset : stream_sw:Eio.Switch.t -> H2.Reqd.t -> reset_cause -> unit
(** [reset ~stream_sw reqd cause] ends the stream. It {!report}s [Stalled],
    [Out_of_capacity] and [Raised] to h2 (a peer or h2 reset is already on
    the wire), then fails [stream_sw] with [Stream_reset cause], which
    cancels the stream's work and every fiber forked on it.

    One case keeps the switch: when no response had started, h2 answers the
    report with the error handler's response, and that response owns the
    stream until its END_STREAM and the RST_STREAM h2 writes after it, which
    end the scope through the stream registry. [Stalled] fails the switch
    even then. A response that had already started keeps nothing, whatever
    h2 does with the report, and the switch fails. [Raised] is reported with
    {!report_failure}, so its exception is logged.

    The first end of a switch wins: a switch that already has an error, or
    has finished, is left as it is. [stream_sw] fails when the report is
    cancelled. *)

val end_scope : Eio.Switch.t -> reset_cause -> unit
(** [end_scope stream_sw cause] is the second half of {!reset}: it fails
    [stream_sw] with [Stream_reset cause] unless the switch already has an
    error or has finished. It sends nothing to the peer. *)

val dispatch : sw:Eio.Switch.t -> H2.Reqd.t -> (unit -> unit) -> unit
(** [dispatch ~sw reqd work] runs [work] in a daemon fiber of [sw], the
    stream's switch, after yielding once, so the h2 parser gets its turn
    before any request computation, pool wait or response mutation starts
    (RFC-0350). The response ledger scope of the calling fiber is carried
    into [work]. An exception from [work] {!reset}s the stream with
    [Raised]; cancellation propagates.

    [sw] must be the stream's own switch. The reset fails it, and with it
    every fiber forked on it; a switch shared with other streams or with the
    connection would end them too. *)

val close_after_flush : H2.Body.Writer.t -> unit
(** [close_after_flush writer] closes [writer] once every byte written to it
    so far has been handed to the connection, not right away. Close an H2
    response body with this, never with [H2.Body.Writer.close]: h2 0.13.0
    cuts a closed body at the client's flow-control window
    (anmonteiro/ocaml-h2#278).

    Write the whole body first. Bytes written after this call are cut the
    same way, because the flush only covers the bytes already written. *)
