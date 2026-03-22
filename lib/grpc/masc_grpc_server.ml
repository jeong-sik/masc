(** MASC gRPC Server.

    Runs the gRPC coordination service on a separate port (default 8936).
    Configurable via MASC_GRPC_PORT environment variable.

    The server runs in a forked Eio fiber alongside the HTTP/SSE server.
    It uses grpc-direct's Eio-native implementation for h2c (HTTP/2 cleartext). *)

let default_port = 8936

(** Read the configured gRPC port from environment or use default. *)
let configured_port () =
  match Sys.getenv_opt "MASC_GRPC_PORT" with
  | Some s -> (
    match int_of_string_opt s with
    | Some p when p > 0 && p < 65536 -> p
    | _ ->
      Log.Server.warn "MASC_GRPC_PORT=%s is not a valid port, using %d" s default_port;
      default_port)
  | None -> default_port

(** Check whether gRPC is enabled (default: disabled, opt-in via env). *)
let is_enabled () =
  match Sys.getenv_opt "MASC_GRPC_ENABLED" with
  | Some "1" | Some "true" -> true
  | _ -> false

(** Start the gRPC coordination server.

    Runs in a forked fiber. Does not block the caller.

    @param sw Eio switch for structured concurrency.
    @param env Eio environment (for network access).
    @param room_config The MASC room configuration.
    @param tool_dispatcher Function that dispatches tool calls. *)
let start
    ~(sw : Eio.Switch.t)
    ~(env : Eio_unix.Stdenv.base)
    ~(room_config : Room_utils_backend_setup.config)
    ~(tool_dispatcher : string -> string -> (string, string) result)
  : unit =
  if not (is_enabled ()) then begin
    Log.Server.info "gRPC transport disabled (set MASC_GRPC_ENABLED=1 to enable)";
  end
  else begin
    let port = configured_port () in
    let service =
      Masc_grpc_service.create_service ~room_config ~tool_dispatcher
    in
    let server =
      Grpc_eio.Server.create
        ~config:{ Grpc_eio.Server.default_config with port; host = "127.0.0.1" }
        ()
      |> Grpc_eio.Server.add_service service
      |> Grpc_eio.Server.with_interceptor (Grpc_eio.Interceptor.logging ())
    in
    Eio.Fiber.fork ~sw (fun () ->
      Log.Server.info "gRPC coordination server starting on port %d" port;
      Log.Server.info "  service: %s" Masc_grpc_service.service_name;
      Log.Server.info "  methods: Join, Leave, Broadcast, GetStatus, ToolCall, Subscribe, Heartbeat";
      (try
        Grpc_eio.Server.serve ~sw ~env server
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Server.error "gRPC server failed: %s" (Printexc.to_string exn)))
  end
