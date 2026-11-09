(** Request scopes of one HTTP/2 connection, keyed by stream identifier.

    Each dispatched stream owns a switch. An entry moves from [Admitted]
    (registered by the connection reader) to [Running] (its fiber has opened
    the stream switch) and leaves the table either when a RST_STREAM ends the
    stream or when its fiber finishes after the response ended.

    A RST_STREAM in either direction removes the entry at once and fails the
    stream switch with {!Http_h2_stream.Stream_reset}, which cancels that
    stream's work and every child forked on its switch. Siblings and the
    connection keep running. *)

type t

val create : unit -> t

val active_streams : t -> int
(** Streams whose scope has not been released yet. *)

val dispatch :
  t ->
  sw:Eio.Switch.t ->
  stream_id:int ->
  H2.Reqd.t ->
  (Eio.Switch.t -> unit) ->
  unit
(** Register [stream_id] and run the work in a daemon on [sw]. The work
    receives the stream switch, which stays open until the response ends, so
    deferred body callbacks and response producers may fork on it. The fiber
    yields before the work starts. A handler exception resets the stream
    ({!Http_h2_stream.reset} with [Raised]); a stream that ends with
    {!Http_h2_stream.Stream_reset} ends quietly; Eio cancellation
    propagates. *)

val peer_reset : t -> stream_id:int -> unit
(** The peer reset [stream_id]: release its entry and end its scope with
    [Reset_by_peer]. *)

val reset_sent : t -> stream_id:int -> unit
(** h2 wrote RST_STREAM for [stream_id], for an error masc reported or one
    h2 found itself: release its entry and end its scope with [Reset_by_us].
    Fibers waiting on a flush h2 will no longer answer are cancelled instead
    of holding the stream switch. *)

val response_ended : t -> stream_id:int -> unit
(** The server sent END_STREAM on [stream_id]. The stream's fiber releases
    its entry once the work and its children return. *)
