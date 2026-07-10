(** MASC gRPC Server.

    Runs the gRPC workspace service on a configurable port.
    Experimental and disabled by default; enable with MASC_GRPC_ENABLED=1. *)

(** Default gRPC port (8936). *)
val default_port : int

(** Standard gRPC health service name. *)
val health_service_name : string

(** Read the configured gRPC port from MASC_GRPC_PORT env or use default. *)
val configured_port : unit -> int

(** Whether gRPC transport is explicitly enabled (default: false). *)
val is_enabled : unit -> bool

(** Build a gRPC server preloaded with reflection, health, and workspace
    services. Exposed for tests and local transport wiring checks. *)
val create_server :
  port:int ->
  workspace_config:Workspace_utils_backend_setup.config ->
  tool_dispatcher:(identity:Server_transport_admission.identity ->
                   auth_token:string ->
                   tool_name:string ->
                   arguments:Yojson.Safe.t ->
                   (string, string) result) ->
  Grpc_eio.Server.t

(** Start the gRPC workspace server in a forked fiber.

    Does nothing if gRPC is not enabled.

    @param sw Eio switch for structured concurrency.
    @param env Eio environment.
    @param workspace_config The MASC workspace configuration.
    @param tool_dispatcher Function that dispatches tool calls. *)
val start :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  workspace_config:Workspace_utils_backend_setup.config ->
  tool_dispatcher:(identity:Server_transport_admission.identity ->
                   auth_token:string ->
                   tool_name:string ->
                   arguments:Yojson.Safe.t ->
                   (string, string) result) ->
  unit
