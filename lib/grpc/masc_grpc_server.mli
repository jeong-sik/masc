(** MASC gRPC Server.

    Runs the gRPC coordination service on a configurable port.
    Enabled by default; disable with MASC_GRPC_ENABLED=0. *)

(** Default gRPC port (8936). *)
val default_port : int

(** Standard gRPC health service name. *)
val health_service_name : string

(** Read the configured gRPC port from MASC_GRPC_PORT env or use default. *)
val configured_port : unit -> int

(** Whether gRPC transport is enabled (default-on, opt-out via env). *)
val is_enabled : unit -> bool

(** Build a gRPC server preloaded with reflection, health, and coordination
    services. Exposed for tests and local transport wiring checks. *)
val create_server
  :  port:int
  -> room_config:Coord_utils_backend_setup.config
  -> tool_dispatcher:(string -> string -> (string, string) result)
  -> Grpc_eio.Server.t

(** Start the gRPC coordination server in a forked fiber.

    Does nothing if gRPC is not enabled.

    @param sw Eio switch for structured concurrency.
    @param env Eio environment.
    @param room_config The MASC room configuration.
    @param tool_dispatcher Function that dispatches tool calls. *)
val start
  :  sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> room_config:Coord_utils_backend_setup.config
  -> tool_dispatcher:(string -> string -> (string, string) result)
  -> unit
