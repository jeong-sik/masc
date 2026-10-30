(** gRPC heartbeat adapter between the keeper domain and the server
    transport. Runs the gRPC bidi stream, dispatches incoming
    [HeartbeatAck] directives into the keeper FSM, and exposes a
    setter so the server bootstrap can install the gRPC client once
    the transport is up. *)

val set_grpc_client
  : ?env:Eio_unix.Stdenv.base
  -> Masc_grpc_client.t
  -> unit
(** Install the gRPC client and its Eio environment used by the
    heartbeat fiber. Called once from [server_runtime_bootstrap] after
    the gRPC transport is bound. *)
