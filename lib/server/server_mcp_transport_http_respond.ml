(** Server_mcp_transport_http_respond — HTTP MCP error / not-ready /
    rate-limit response factories. *)

(** [safe_respond_with_string] guards [Httpun.Reqd.respond_with_string]
    against the [Failure "invalid state, currently handling error"] race
    that occurs when a client disconnects while a long OAS turn is in
    progress and httpun's error_handler has already started responding
    (2026-05-05 cycle9 FATAL incident). *)
let safe_respond_with_string reqd response body =
  try Httpun.Reqd.respond_with_string reqd response body
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Failure msg ->
      Log.Server.warn
        "[mcp-http] respond_with_string skipped (reqd invalid state; \
         2026-05-05 OAS cancel race): %s"
        msg
  | exn ->
      Log.Server.warn
        "[mcp-http] respond_with_string unexpected exception: %s"
        (Printexc.to_string exn)

let mcp_headers = Server_mcp_transport_http_headers.mcp_headers

let json_headers = Server_mcp_transport_http_headers.json_headers

let respond_mcp_auth_error ?(extra_headers = []) ~(deps : Server_mcp_transport_http_types.deps) request reqd ~session_id
    ~protocol_version msg =
  let origin = deps.get_origin request in
  let body =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ( "error",
            `Assoc
              [ ("code", `Int (-32001)); ("message", `String msg) ] );
        ])
  in
  let headers =
    Httpun.Headers.of_list
      ((("content-length", string_of_int (String.length body))
       :: ("www-authenticate", "Bearer")
       :: extra_headers)
      @ json_headers ~deps session_id protocol_version origin)
  in
  let response = Httpun.Response.create ~headers `Unauthorized in
  safe_respond_with_string reqd response body

let respond_mcp_internal_error ?(extra_headers = []) ~(deps : Server_mcp_transport_http_types.deps) request reqd
    ~session_id ~protocol_version msg =
  let origin = deps.get_origin request in
  let body =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ( "error",
            `Assoc
              [ ("code", `Int (-32603)); ("message", `String msg) ] );
        ])
  in
  let headers =
    Httpun.Headers.of_list
      ((("content-length", string_of_int (String.length body)) :: extra_headers)
      @ json_headers ~deps session_id protocol_version origin)
  in
  let response = Httpun.Response.create ~headers `Internal_server_error in
  safe_respond_with_string reqd response body

let respond_not_ready ~(deps : Server_mcp_transport_http_types.deps) request reqd =
  let origin = deps.get_origin request in
  let body =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("error",
           `Assoc
             [
               ("code", `Int (-32002));
               ("message", `String "Server is starting up, not ready yet");
             ]);
          ("id", `Null);
        ])
  in
  let headers =
    Httpun.Headers.of_list
      ([
         ("content-type", "application/json");
         ("content-length", string_of_int (String.length body));
         ("retry-after", "2");
       ]
      @ deps.cors_headers origin)
  in
  let response = Httpun.Response.create ~headers `Service_unavailable in
  safe_respond_with_string reqd response body

let respond_sse_rate_limited ~(deps : Server_mcp_transport_http_types.deps) ~origin ~session_id ~protocol_version
    ~reason ~retry_after_s reqd =
  let retry_after_s = Float.max retry_after_s 0.001 in
  let retry_after_header =
    retry_after_s |> Float.ceil |> int_of_float |> max 1 |> string_of_int
  in
  let body =
    `Assoc
      [
        ("error", `String "sse_connection_rate_limited");
        ("reason", `String reason);
        ("retry_after_seconds", `Float retry_after_s);
      ]
    |> Yojson.Safe.to_string
  in
  let headers =
    Httpun.Headers.of_list
      (("content-length", string_of_int (String.length body))
      :: ("retry-after", retry_after_header)
      :: json_headers ~deps session_id protocol_version origin)
  in
  let response = Httpun.Response.create ~headers `Too_many_requests in
  safe_respond_with_string reqd response body

let mcp_internal_error_json ?id msg =
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("id", Option.value ~default:`Null id);
      ("error", `Assoc [ ("code", `Int (-32603)); ("message", `String msg) ]);
    ]
