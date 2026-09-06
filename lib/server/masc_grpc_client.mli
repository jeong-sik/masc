(** MASC gRPC Client.

    Client-side wrapper for the MascWorkspace gRPC service.
    Mirrors the server RPCs defined in [Masc_grpc_service].

    Each function maps to one gRPC RPC:
    - [get_status], [tool_call], [broadcast] are unary.
    - [subscribe] is server-streaming (returns an event stream).
    - [heartbeat_stream] is bidirectional streaming.

    Connection is established lazily on first call. Set
    [MASC_GRPC_TARGET] to override the default target
    (http://127.0.0.1:MASC_GRPC_PORT). *)

(** {1 Connection} *)

(** Opaque client handle. *)
type t

(** Create a client targeting the given gRPC endpoint.

    @param sw Eio switch for connection lifetime.
    @param env Eio environment.
    @param target gRPC target URI (e.g. "http://127.0.0.1:8936"). *)
val create :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  string ->
  t

(** Create a client from environment variables.

    Reads [MASC_GRPC_TARGET] or falls back to
    [http://127.0.0.1:{MASC_GRPC_PORT|8936}]. *)
val create_from_env :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  t

(** {1 Unary RPCs} *)

(** {1 Streaming RPCs} *)

(** Open a bidirectional heartbeat stream.

    Returns [(request_stream, response_stream)]. The caller sends
    [HeartbeatPing] messages on [request_stream] and reads
    [HeartbeatAck] messages from [response_stream]. Close
    [request_stream] to end the stream. *)
val heartbeat_stream :
  t ->
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  (Masc_grpc_types.HeartbeatPing.t -> unit)
  * (unit -> (Masc_grpc_types.HeartbeatAck.t, string) result)
  * (unit -> unit)
