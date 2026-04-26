(** MASC gRPC Client.

    Client-side wrapper for the MascCoordination gRPC service.
    Mirrors the server RPCs defined in [Masc_grpc_service].

    Each function maps to one gRPC RPC:
    - [join], [leave], [get_status], [tool_call], [broadcast] are unary.
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
val create : sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> string -> t

(** Create a client from environment variables.

    Reads [MASC_GRPC_TARGET] or falls back to
    [http://127.0.0.1:{MASC_GRPC_PORT|8936}]. *)
val create_from_env : sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> t

(** Close the underlying gRPC connection. *)
val close : t -> unit

(** {1 Unary RPCs} *)

(** Join the coordination room. *)
val join
  :  t
  -> sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> agent_name:string
  -> capabilities:string list
  -> metadata:(string * string) list
  -> (Masc_grpc_types.JoinResponse.t, string) result

(** Leave the coordination room. *)
val leave
  :  t
  -> sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> agent_name:string
  -> session_id:string
  -> (Masc_grpc_types.LeaveResponse.t, string) result

(** Get current room status. *)
val get_status
  :  t
  -> sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> (Masc_grpc_types.StatusResponse.t, string) result

(** Call an MCP tool via gRPC. *)
val tool_call
  :  t
  -> sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> agent_name:string
  -> session_id:string
  -> tool_name:string
  -> arguments_json:string
  -> (Masc_grpc_types.ToolCallResponse.t, string) result

(** Broadcast a message to all agents. *)
val broadcast
  :  t
  -> sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> agent_name:string
  -> message:string
  -> mentions:string list
  -> (Masc_grpc_types.BroadcastResponse.t, string) result

(** {1 Streaming RPCs} *)

(** Subscribe to room events (server-streaming).

    Returns a stream of events. The stream closes when the server
    finishes sending backlog events or the connection drops. *)
val subscribe
  :  t
  -> sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> agent_name:string
  -> session_id:string
  -> event_types:string list
  -> since_seq:int64
  -> (Masc_grpc_types.Event.t, string) result Grpc_eio.Stream.t

(** Open a bidirectional heartbeat stream.

    Returns [(request_stream, response_stream)]. The caller sends
    [HeartbeatPing] messages on [request_stream] and reads
    [HeartbeatAck] messages from [response_stream]. Close
    [request_stream] to end the stream. *)
val heartbeat_stream
  :  t
  -> sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> (Masc_grpc_types.HeartbeatPing.t -> unit)
     * (unit -> (Masc_grpc_types.HeartbeatAck.t, string) result)
     * (unit -> unit)
