(** MASC gRPC Server.

    Runs the gRPC workspace service on a configurable port.
    Enabled by default; disable with MASC_GRPC_ENABLED=0. *)

(** Default gRPC port (8936). *)
val default_port : int

(** Standard gRPC health service name. *)
val health_service_name : string

(** Read the configured gRPC port from MASC_GRPC_PORT env or use default. *)
val configured_port : unit -> int

(** Whether gRPC transport is enabled (default-on, opt-out via env). *)
val is_enabled : unit -> bool

module For_testing : sig
  val parse_lsp_jsonrpc_request :
    string -> ((string * Yojson.Safe.t), string) result
end

(** Build a gRPC server preloaded with reflection, health, and workspace
    services. Exposed for tests and local transport wiring checks. *)
val create_server :
  port:int ->
  workspace_config:Workspace_utils_backend_setup.config ->
  tool_dispatcher:(string -> string -> (string, string) result) ->
  lsp_dispatcher:(language_id:string ->
                   jsonrpc_request_json:string ->
                   workspace_root:string option ->
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
  tool_dispatcher:(string -> string -> (string, string) result) ->
  unit
