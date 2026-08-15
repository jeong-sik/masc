(** MASC agent transport selection. *)

(** Transport kind. *)
type t =
  | Http    (** HTTP/SSE to MASC server. *)
  | Grpc    (** gRPC (h2c) to MASC gRPC workspace port. *)
  | Ws      (** WebSocket to MASC server. *)
  | Local   (** Direct Workspace filesystem calls (in-process). *)

(** Resolve [MASC_AGENT_TRANSPORT]. An absent variable selects [Local]; every
    present value must exactly match [http], [grpc], [ws], or [local]. *)
val from_env : unit -> t

(** Resolve [MASC_AGENT_TRANSPORT] and publish the first typed value for all
    subsequent calls in this process. Concurrent or repeated calls return the
    first published value. Server startup calls this before creating fibers or
    listeners. *)
val configure_from_env : unit -> t

(** String representation for logging. *)
val to_string : t -> string

(** Operator snapshot entry projected from the same typed process resolution. *)
val snapshot_entry : Env_config_snapshot_collector.t
