(** gRPC socket ownership and bind acknowledgment. Plaintext loopback h2c,
    matching the existing MASC server factory and grpc-direct bind policy. *)

type failure = {
  kind : Transport_metrics.grpc_listener_failure;
  cause : exn;
}
(** [cause] is private diagnostic evidence for the caller's log, never a
    transport JSON field. *)

val with_listener :
  listen:(sw:Eio.Switch.t -> 'socket) ->
  serve:(sw:Eio.Switch.t -> 'socket -> unit) ->
  (unit, failure) result
(** Own a listener scope. [Binding] lasts until [listen] returns; [Listening]
    is published only after that acknowledgment. All children and the socket
    are released before return. Cancellation propagates and records [Stopped];
    failures record a typed cause and remain failed after resource release. *)

val serve_socket :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  socket:[> [> `Generic | `Unix ] Eio.Net.listening_socket_ty ] Eio.Resource.t ->
  Grpc_eio.Server.t ->
  unit
(** Serve an already bound socket. Connection/stream failures stay within
    their own scope; listener failures propagate to the socket owner. *)

val serve :
  env:Eio_unix.Stdenv.base ->
  port:int ->
  Grpc_eio.Server.t ->
  (unit, failure) result
(** Bind loopback and serve with MASC's stream-scoped H2 connection machinery.
    Does not mutate the HTTP listener's lifecycle or accept metrics. *)
