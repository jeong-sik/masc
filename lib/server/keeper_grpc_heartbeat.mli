(** gRPC heartbeat adapter between the keeper domain and the server
    transport. Runs the credential-bound bidi liveness stream and exposes a
    setter so the server bootstrap can install the gRPC client once the
    transport is up. Control-plane directives intentionally do not travel on
    this telemetry channel. *)

val set_grpc_client
  : ?env:Eio_unix.Stdenv.base
  -> Masc_grpc_client.t
  -> unit
(** Install the gRPC client and its Eio environment used by the
    heartbeat fiber. Called once from [server_runtime_bootstrap] after
    the gRPC transport is bound. *)
