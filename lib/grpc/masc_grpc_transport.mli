(** MASC Agent Transport — protocol selection for MASC coordination.

    Agents communicate with the MASC coordination server via one of:
    - [Http] — existing HTTP/SSE transport (default, backward compatible).
    - [Grpc] — gRPC transport using grpc-direct h2c.
    - [Local] — direct filesystem-based Coord calls (in-process).

    Selection order:
    1. Explicit [~transport] parameter on API calls.
    2. [MASC_AGENT_TRANSPORT] env var ("grpc", "http", "local").
    3. Default: [Local] (file-based, same as before). *)

(** Transport kind. *)
type t =
  | Http (** HTTP/SSE to MASC server. *)
  | Grpc (** gRPC (h2c) to MASC gRPC coordination port. *)
  | Ws (** WebSocket to MASC server. *)
  | Webrtc (** WebRTC DataChannel for P2P agent communication. *)
  | Local (** Direct Coord filesystem calls (in-process). *)

(** Resolve transport from env var [MASC_AGENT_TRANSPORT].
    Returns [Local] when unset or unrecognized. *)
val from_env : unit -> t

(** String representation for logging. *)
val to_string : t -> string
