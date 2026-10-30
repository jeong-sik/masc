(** Request scopes of one HTTP/2 connection, keyed by stream identifier.

    Each dispatched stream owns a switch. An entry moves from [Admitted]
    (registered by the connection reader) to [Running] (its fiber has opened
    the stream switch) and leaves the table either when the peer resets the
    stream or when its fiber finishes after the response ended.

    A peer RST_STREAM removes the entry at once and cancels that stream's
    work and every child forked on its switch. Siblings and the connection
    keep running. *)

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
    yields before the work starts. Handler exceptions are reported to [reqd];
    Eio cancellation propagates. *)

val peer_reset : t -> stream_id:int -> unit
(** The peer reset [stream_id]: release its entry and cancel its scope. *)

val response_ended : t -> stream_id:int -> unit
(** The server finished or reset the response on [stream_id]. The stream's
    fiber releases its entry once the work and its children return. *)
