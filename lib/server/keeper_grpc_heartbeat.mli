(** gRPC heartbeat bridge for keeper keepalive.

    The module registers its heartbeat starter at load time; callers only need
    to provide the process-wide client created by the server bootstrap. *)

val set_grpc_client :
     ?env:Eio_unix.Stdenv.base
  -> Masc_grpc_client.t
  -> unit
(** Install the gRPC client used by keeper heartbeat fibers. *)
