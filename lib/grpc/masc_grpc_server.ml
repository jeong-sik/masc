(** MASC gRPC Server.

    Runs the gRPC coordination service on a separate port (default 8936).
    Configurable via MASC_GRPC_PORT environment variable.

    The server runs in a forked Eio fiber alongside the HTTP/SSE server.
    It uses grpc-direct's Eio-native implementation for h2c (HTTP/2 cleartext). *)

let default_port = 8936
let health_service_name = "grpc.health.v1.Health"

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

(** Check whether gRPC is enabled (default: enabled, opt-out via env). *)
let is_enabled () =
  match Sys.getenv_opt "MASC_GRPC_ENABLED" with
  | Some s -> (
    match String.trim s |> String.lowercase_ascii with
    | "1" | "true" -> true
    | "" | "0" | "false" -> false
    | other ->
      Log.Server.warn
        "MASC_GRPC_ENABLED=%s is not recognised, defaulting to enabled"
        other;
      true)
  | None -> true

module Reflection_bridge = struct
  type request =
    | ListServices
    | FileContainingSymbol of string
    | FileByFilename of string
    | Unknown

  module Wire = struct
    let req_file_by_filename = 3
    let req_file_containing_symbol = 4
    let req_list_services = 7
    let resp_file_descriptor_response = 4
    let resp_list_services_response = 6
    let resp_error_response = 7
    let list_service_service = 1
    let service_name = 1
    let error_code = 1
    let error_message = 2
    let file_descriptor_proto = 1
  end

  let grpc_health_descriptor_b64 =
    "CsoDChtncnBjL2hlYWx0aC92MS9oZWFsdGgucHJvdG8SDmdycGMuaGVhbHRoLnYxIi4KEkhlYWx0aENoZWNrUmVxdWVzdBIYCgdzZXJ2aWNlGAEgASgJUgdzZXJ2aWNlIrEBChNIZWFsdGhDaGVja1Jlc3BvbnNlEkkKBnN0YXR1cxgBIAEoDjIxLmdycGMuaGVhbHRoLnYxLkhlYWx0aENoZWNrUmVzcG9uc2UuU2VydmluZ1N0YXR1c1IGc3RhdHVzIk8KDVNlcnZpbmdTdGF0dXMSCwoHVU5LTk9XThAAEgsKB1NFUlZJTkcQARIPCgtOT1RfU0VSVklORxACEhMKD1NFUlZJQ0VfVU5LTk9XThADMq4BCgZIZWFsdGgSUAoFQ2hlY2sSIi5ncnBjLmhlYWx0aC52MS5IZWFsdGhDaGVja1JlcXVlc3QaIy5ncnBjLmhlYWx0aC52MS5IZWFsdGhDaGVja1Jlc3BvbnNlElIKBVdhdGNoEiIuZ3JwYy5oZWFsdGgudjEuSGVhbHRoQ2hlY2tSZXF1ZXN0GiMuZ3JwYy5oZWFsdGgudjEuSGVhbHRoQ2hlY2tSZXNwb25zZTABYgZwcm90bzM="

  let grpc_health_descriptor =
    Base64.decode_exn grpc_health_descriptor_b64

  let health_proto_filenames =
    [ "grpc/health/v1/health.proto"; "grpc-health.proto"; "health.proto" ]

  let health_symbols =
    [
      "grpc.health.v1.Health";
      "grpc.health.v1.Health.Check";
      "grpc.health.v1.Health.Watch";
      "grpc.health.v1.HealthCheckRequest";
      "grpc.health.v1.HealthCheckResponse";
      "grpc.health.v1.HealthCheckResponse.ServingStatus";
    ]

  let decode_varint (bytes : string) (pos : int ref) : int =
    let result = ref 0 in
    let shift = ref 0 in
    let done_ = ref false in
    while !pos < String.length bytes && not !done_ do
      let byte = Char.code bytes.[!pos] in
      incr pos;
      result := !result lor ((byte land 0x7f) lsl !shift);
      shift := !shift + 7;
      if byte land 0x80 = 0 then done_ := true
    done;
    !result

  let encode_varint (n : int) : string =
    if n = 0 then
      "\x00"
    else
      let buf = Buffer.create 10 in
      let n = ref n in
      while !n > 0 do
        let byte = !n land 0x7f in
        n := !n lsr 7;
        if !n > 0 then
          Buffer.add_char buf (Char.chr (byte lor 0x80))
        else
          Buffer.add_char buf (Char.chr byte)
      done;
      Buffer.contents buf

  let encode_length_delimited (field_num : int) (data : string) : string =
    let tag = (field_num lsl 3) lor 2 in
    encode_varint tag ^ encode_varint (String.length data) ^ data

  let encode_string_field (field_num : int) (s : string) : string =
    encode_length_delimited field_num s

  let parse_request (data : string) : request =
    if String.length data = 0 then
      ListServices
    else
      let pos = ref 0 in
      let result = ref Unknown in
      while !pos < String.length data do
        let tag = decode_varint data pos in
        let field_num = tag lsr 3 in
        let wire_type = tag land 7 in
        match wire_type with
        | 2 ->
            let len = decode_varint data pos in
            let value = String.sub data !pos len in
            pos := !pos + len;
            (match field_num with
            | n when n = Wire.req_file_by_filename -> result := FileByFilename value
            | n when n = Wire.req_file_containing_symbol ->
                result := FileContainingSymbol value
            | n when n = Wire.req_list_services -> result := ListServices
            | _ -> ())
        | 0 ->
            let _ = decode_varint data pos in
            ()
        | _ ->
            pos := String.length data
      done;
      !result

  let encode_list_services_response (services : string list) : string =
    let service_msgs =
      List.map
        (fun name -> encode_string_field Wire.service_name name)
        services
    in
    let list_response =
      String.concat ""
        (List.map
           (fun msg ->
             encode_length_delimited Wire.list_service_service msg)
           service_msgs)
    in
    encode_length_delimited Wire.resp_list_services_response list_response

  let encode_error_response (code : int) (message : string) : string =
    let error_msg =
      encode_varint ((Wire.error_code lsl 3) lor 0)
      ^ encode_varint code
      ^ encode_string_field Wire.error_message message
    in
    encode_length_delimited Wire.resp_error_response error_msg

  let encode_file_descriptor_response (descriptors : string list) : string =
    let payload =
      descriptors
      |> List.map (encode_length_delimited Wire.file_descriptor_proto)
      |> String.concat ""
    in
    encode_length_delimited Wire.resp_file_descriptor_response payload

  let health_descriptor_response () =
    encode_file_descriptor_response [ grpc_health_descriptor ]

  let handles_health_symbol symbol =
    List.mem symbol health_symbols

  let handles_health_filename filename =
    List.mem filename health_proto_filenames

  let to_service (server_ref : Grpc_eio.Server.t ref) : Grpc_eio.Service.t =
    let handle_reflection_bidi ~sw
        (request_stream : string Grpc_eio.Stream.t) :
        string Grpc_eio.Stream.t =
      let response_stream = Grpc_eio.Stream.create 16 in
      let process_loop () =
        let rec loop () =
          try
            let request_bytes = Grpc_eio.Stream.take request_stream in
            let services = Grpc_eio.Server.list_services !server_ref in
            let response =
              match parse_request request_bytes with
              | ListServices ->
                  encode_list_services_response services
              | FileContainingSymbol symbol when handles_health_symbol symbol ->
                  health_descriptor_response ()
              | FileByFilename filename when handles_health_filename filename ->
                  health_descriptor_response ()
              | FileContainingSymbol symbol when List.mem symbol services ->
                  encode_list_services_response [ symbol ]
              | FileContainingSymbol symbol ->
                  encode_error_response 5
                    (Printf.sprintf "Symbol not found: %s" symbol)
              | FileByFilename filename ->
                  encode_error_response 5
                    (Printf.sprintf "FileDescriptor not available for: %s"
                       filename)
              | Unknown ->
                  encode_error_response 3 "Unknown request type"
            in
            Grpc_eio.Stream.add response_stream response;
            loop ()
          with
          | End_of_file ->
              Grpc_eio.Stream.close response_stream
        in
        loop ()
      in
      Eio.Fiber.fork ~sw process_loop;
      response_stream
    in
    Grpc_eio.Service.create "grpc.reflection.v1.ServerReflection"
    |> Grpc_eio.Service.add_bidi_streaming
         "ServerReflectionInfo" handle_reflection_bidi
end

let create_server
    ~(port : int)
    ~(room_config : Room_utils_backend_setup.config)
    ~(tool_dispatcher : string -> string -> (string, string) result)
  : Grpc_eio.Server.t =
  let service =
    Masc_grpc_service.create_service ~room_config ~tool_dispatcher
  in
  let health = Grpc_eio.Health.create ~default_status:Grpc_eio.Health.Serving () in
  Grpc_eio.Health.register_service health
    ~service:Masc_grpc_service.service_name;
  Grpc_eio.Health.set_status health
    ~service:Masc_grpc_service.service_name
    Grpc_eio.Health.Serving;
  Grpc_eio.Health.register_service health ~service:"grpc.health.v1.Health";
  Grpc_eio.Health.set_status health
    ~service:"grpc.health.v1.Health"
    Grpc_eio.Health.Serving;
  let server =
    Grpc_eio.Server.create
      ~config:{ Grpc_eio.Server.default_config with port; host = "127.0.0.1" }
      ()
  in
  let server_ref = ref server in
  let reflection_service = Reflection_bridge.to_service server_ref in
  let server =
    server
    |> Grpc_eio.Server.add_service (Grpc_eio.Health.to_service health)
    |> Grpc_eio.Server.add_service service
    |> Grpc_eio.Server.add_service reflection_service
    |> Grpc_eio.Server.with_interceptor (Grpc_eio.Interceptor.logging ())
  in
  server_ref := server;
  server

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
    Log.Server.info "gRPC transport disabled (set MASC_GRPC_ENABLED=0 to disable)";
  end
  else begin
    let port = configured_port () in
    Eio.Fiber.fork ~sw (fun () ->
      (try
        let server = create_server ~port ~room_config ~tool_dispatcher in
        Log.Server.info
          "gRPC coordination server starting on port %d (reflection + health enabled)"
          "gRPC coordination server starting on port %d (health + reflection enabled)"
          port;
        Log.Server.info "  service: %s" Masc_grpc_service.service_name;
        Log.Server.info "  health: %s/Check" health_service_name;
        Log.Server.info
          "  methods: Join, Leave, Broadcast, GetStatus, ToolCall, Subscribe, Heartbeat";
        Grpc_eio.Server.serve ~sw ~env server
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | Unix.Unix_error (Unix.EADDRINUSE, _, _) ->
        Log.Server.error
          "gRPC coordination transport unavailable on 127.0.0.1:%d: port already in use"
          port
      | exn ->
        Log.Server.error "gRPC server failed: %s" (Printexc.to_string exn)))
  end
