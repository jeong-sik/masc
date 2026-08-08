(** MASC agent transport selection. *)

(** Transport kind. *)
type t =
  | Http    (** HTTP/SSE to MASC server. *)
  | Grpc    (** gRPC (h2c) to MASC gRPC workspace port. *)
  | Ws      (** WebSocket to MASC server. *)
  | Webrtc  (** WebRTC DataChannel for P2P agent communication. *)
  | Local   (** Direct Workspace filesystem calls (in-process). *)

(** Resolve [MASC_AGENT_TRANSPORT]. An absent variable selects [Local]; every
    present value must exactly match [http], [grpc], [ws], [webrtc], or [local]. *)
val from_env : unit -> t

(** Resolve [MASC_AGENT_TRANSPORT] and retain that typed value for subsequent
    {!from_env} calls in this process. Server startup calls this once. *)
val configure_from_env : unit -> t

(** String representation for logging. *)
val to_string : t -> string
