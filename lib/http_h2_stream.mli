(** Habits of one HTTP/2 response stream that the h2 library does not
    provide itself. {!Http_reqd} writes its HTTP/2 responses through
    {!Response_body}, the stream registry ends stream scopes with {!reset}
    and {!Stream_end}, and the connection-level error handler uses
    {!close_after_flush}. *)

(** Why a stream's scope ended before its response did (RFC-0518 D1). *)
type reset_cause =
  | Reset_by_peer  (** The peer sent RST_STREAM. *)
  | Reset_by_us  (** h2 wrote RST_STREAM for this stream. *)
  | Stalled
      (** Response bytes waited for the peer past the stall bound
          ({!Stream_end}). *)
  | Out_of_capacity of Http_h2_response_ledger.refusal
      (** The response ledger refused the next payload. *)
  | Raised of exn
      (** The stream's own work raised: the request handler, a deferred body
          callback, a fiber forked on the stream switch, or the answer to a
          flush. *)

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

(** The end of one stream's scope and the bound on its flushes (RFC-0518
    D2). The stream registry makes one for each stream it runs and binds it
    to that stream's fibers.

    h2 answers a flush once its bytes were written to the socket. So the
    bound ends the scope of a stream whose peer keeps the flow-control
    window shut, and of one whose peer stopped reading the socket. Only the
    first peer is told: behind a socket that does not drain, the RST_STREAM
    waits in the connection's writer with the bytes already queued there,
    until the socket moves or the connection ends (RFC-0518 D4).

    Every function here is called from the connection's domain, as h2's
    body writer has to be. Nothing takes a lock. *)
module Stream_end : sig
  type t

  val create
    :  stream_sw:Eio.Switch.t
    -> clock:_ Eio.Time.clock
    -> stalled_after_s:float
    -> request:H2.Request.t
    -> H2.Reqd.t
    -> t
  (** [create ~stream_sw ~clock ~stalled_after_s ~request reqd] ends with
      [stream_sw]: once the switch is released, {!ended} is true, {!signal}
      is resolved and every flush still waiting is answered with [`Closed],
      each one whatever another's answer raised. It also forks a daemon on
      [stream_sw] that watches the flushes. h2 answers them oldest first.
      When the oldest flush still waiting goes [stalled_after_s] by [clock]
      without an answer, counted from its registration or from the answer
      before it, whichever came later, the daemon logs the method and the
      path of [request] at warn, the path without its query, and {!reset}s
      the stream with [Stalled], which fails [stream_sw].

      [request] is what h2 gave the request handler for [reqd]. Read it
      there, with [H2.Reqd.request], before the fiber yields: h2 has no
      request to give once it closed the stream. *)

  val switch : t -> Eio.Switch.t
  (** The stream's switch. *)

  val request : t -> H2.Request.t
  (** The request {!create} was given. The stream's work reads it here, not
      from h2. *)

  val request_line : t -> string
  (** The method and the path of the request, as log lines name it. The
      query is left out: it can carry a token. *)

  val ended : t -> bool
  (** True once the stream's switch was released. *)

  val signal : t -> unit Eio.Promise.t
  (** Resolved once the stream's switch was released. *)

  val flush : t -> H2.Body.Writer.t -> ([ `Written | `Closed ] -> unit) -> unit
  (** [flush t writer f] calls [f] once: with h2's answer to the flush, or
      with [`Closed] when the stream's switch is released first. h2 answers
      from the connection's write loop, which an exception would end for
      every stream of the connection. So what [f] raises on h2's answer
      {!reset}s this stream with [Raised]; cancellation propagates. *)

  val close_after_flush : t -> H2.Body.Writer.t -> unit
  (** [close_after_flush t writer] is the top-level [close_after_flush]
      through [t]: [writer] closes once the bytes written so far have drained,
      or when the stream ends or stalls first. *)

  val with_current : t -> (unit -> 'a) -> 'a
  (** [with_current t f] runs [f] with [t] bound to the calling fiber and to
      the fibers it forks, those on switches that outlive the stream too.
      Such a fiber finds [t] ended once the stream is over, and the
      top-level [close_after_flush] then closes at once. A fiber started
      inside [f] that later answers other streams would close their error
      answers through [t]. *)
end

(** The body of one HTTP/2 response (RFC-0518 D3). h2 holds one slice of it
    at most. h2 gives the connection whatever the peer's windows allow in one
    piece and answers a flush once the socket took all of it, so a body it
    held whole would have to cross the socket within one stall bound, and
    the other streams of the connection would wait behind it. Here the next
    slice is written when the flush of the one before is answered, and what
    is written meanwhile waits in order. Each slice has the stream's stall
    bound to cross the socket, so a stream keeps going while its peer takes
    a slice within the bound, however long the whole body takes.

    h2 gives the socket one stream's bytes at a time and takes the streams
    in turn (scheduler.ml [flush]). The bodies of a connection therefore
    share its link a slice at a time: with [k] bodies in flight, a slice
    also waits for a slice of each of the others (RFC-0518 §5).

    Like {!Stream_end}, a body is used from the connection's domain only. *)
module Response_body : sig
  type t

  val create : Stream_end.t -> H2.Body.Writer.t -> t
  (** The body behind the writer h2 returned for the stream's response.
      Nothing else writes to that writer or closes it. *)

  val slice_bytes : int
  (** 16 KiB: one DATA frame of the default SETTINGS_MAX_FRAME_SIZE. *)

  val write : t -> sent:(unit -> unit) -> string -> unit
  (** [write t ~sent payload] puts [payload] behind everything written
      before it. The call does not suspend, so payloads written by different
      fibers stay whole and in the order of the calls. [sent] runs once:
      when the socket took the last byte of [payload], or when the body can
      take no more of it, because it was closed, the stream ended, or h2
      closed the body. *)

  val flush : t -> ([ `Written | `Closed ] -> unit) -> unit
  (** [flush t f] calls [f] once: with [`Written] when the socket took every
      byte written before the call, with [`Closed] when the body ended
      before that or was closed already. The answer comes with the slice
      that carries the last of those bytes. That slice is filled up with
      what was written after the call, so the answer can wait for up to one
      slice of later bytes too. What [f] raises ends the stream
      ({!Stream_end.flush}). *)

  val close : t -> unit
  (** Ends the body after the bytes written so far. Later writes are dropped
      and later flushes answered [`Closed]. Closing twice is the same as
      closing once. *)

  val is_closed : t -> bool
  (** True once {!close} was called, the stream ended, or h2 closed the body.
      Bytes written before a {!close} may still be on their way. *)
end

val dispatch : Stream_end.t -> (unit -> unit) -> unit
(** [dispatch stream_end work] runs [work] in a daemon fiber of the stream's
    switch, after yielding once, so the h2 parser gets its turn before any
    request computation, pool wait or response mutation starts (RFC-0350).
    [work] runs with [stream_end] bound ({!Stream_end.with_current}) and in
    the response ledger scope of the calling fiber. An exception from [work]
    {!reset}s the stream with [Raised]; cancellation propagates. *)

val close_after_flush : H2.Body.Writer.t -> unit
(** [close_after_flush writer] closes [writer] once every byte written to it
    so far has been handed to the connection, not right away. Close an H2
    response body with this, never with [H2.Body.Writer.close]: h2 0.13.0
    cuts a closed body at the client's flow-control window
    (anmonteiro/ocaml-h2#278).

    Write the whole body first. Bytes written after this call are cut the
    same way, because the flush only covers the bytes already written. It is
    for a short answer written at once; a response body closes with
    {!Response_body.close}.

    A fiber with a bound {!Stream_end} flushes through it, so the writer
    also closes when the stream ends or stalls. Elsewhere, as for the error
    answers h2 opens on the connection reader, the close waits for h2. *)
