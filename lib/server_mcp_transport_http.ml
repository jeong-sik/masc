module Http = Http_server_eio
module Mcp_eio = Mcp_server_eio
module Http_negotiation = Mcp_protocol.Http_negotiation

type deps = {
  get_origin : Httpun.Request.t -> string;
  cors_headers : string -> (string * string) list;
  auth_token_from_request : Httpun.Request.t -> string option;
  get_server_state_opt : unit -> Mcp_server.server_state option;
  get_sw : unit -> Eio.Switch.t option;
  get_clock : unit -> float Eio.Time.clock_ty Eio.Resource.t option;
  verify_mcp_auth : base_path:string -> Httpun.Request.t -> (unit, string) result;
  verify_operator_mcp_auth :
    base_path:string -> Httpun.Request.t -> (unit, string) result;
}

let mcp_protocol_versions = Mcp_server.supported_protocol_versions

let mcp_protocol_version_default = Mcp_server.default_protocol_version

let protocol_version_by_session : (string, string) Hashtbl.t =
  Hashtbl.create 128

let mcp_profile_by_session : (string, Mcp_eio.tool_profile) Hashtbl.t =
  Hashtbl.create 128

let default_base_path () =
  match Sys.getenv_opt "ME_ROOT" with
  | Some path -> path
  | None -> Sys.getcwd ()

let is_valid_protocol_version version =
  List.mem version mcp_protocol_versions

let remember_protocol_version session_id version =
  if is_valid_protocol_version version then
    Hashtbl.replace protocol_version_by_session session_id version

let remember_mcp_profile session_id profile =
  Hashtbl.replace mcp_profile_by_session session_id profile

let forget_mcp_session session_id =
  Hashtbl.remove protocol_version_by_session session_id;
  Hashtbl.remove mcp_profile_by_session session_id

let profile_label = function
  | Mcp_eio.Full -> "/mcp"
  | Mcp_eio.Managed_agent -> "/mcp/managed"
  | Mcp_eio.Operator_remote -> "/mcp/operator"
  | Mcp_eio.Role_filtered mode -> Printf.sprintf "/mcp/role/%s" (Mode.mode_to_string mode)

let validate_mcp_session_profile ~profile session_id =
  match Hashtbl.find_opt mcp_profile_by_session session_id with
  | None -> Ok ()
  | Some existing when existing = profile -> Ok ()
  | Some existing ->
      Error
        (Printf.sprintf "Session %s belongs to %s, not %s." session_id
           (profile_label existing) (profile_label profile))

let validate_mcp_session_delete_profile ~profile session_id =
  match profile with
  | Mcp_eio.Operator_remote -> (
      match Hashtbl.find_opt mcp_profile_by_session session_id with
      | Some Mcp_eio.Operator_remote -> Ok ()
      | Some existing ->
          Error
            (Printf.sprintf "Session %s belongs to %s, not %s." session_id
               (profile_label existing) (profile_label profile))
      | None ->
          Error
            (Printf.sprintf "Session %s is not registered on %s." session_id
               (profile_label profile)))
  | Mcp_eio.Full | Mcp_eio.Managed_agent | Mcp_eio.Role_filtered _ ->
      validate_mcp_session_profile ~profile session_id

let protocol_version_from_body body_str =
  try
    let json = Yojson.Safe.from_string body_str in
    match Mcp_server.jsonrpc_request_of_yojson json with
    | Ok req when String.equal req.method_ "initialize" ->
        let version =
          Mcp_server.protocol_version_from_params req.params
          |> Mcp_server.normalize_protocol_version
        in
        Some version
    | _ -> None
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None

let get_session_id_query target =
  match String.split_on_char '?' target with
  | [ _; query ] ->
      query
      |> String.split_on_char '&'
      |> List.find_map (fun param ->
             match String.split_on_char '=' param with
             | [ "session_id"; v ] | [ "sessionId"; v ] -> Some v
             | _ -> None)
  | _ -> None

let capitalize_ascii (s : string) =
  if s = "" then
    s
  else
    let first = Char.uppercase_ascii s.[0] |> String.make 1 in
    let rest =
      if String.length s > 1 then
        String.sub s 1 (String.length s - 1) |> String.lowercase_ascii
      else
        ""
    in
    first ^ rest

let title_case_header_name (header_name : string) =
  header_name |> String.split_on_char '-' |> List.map capitalize_ascii
  |> String.concat "-"

let get_header_any_case (headers : Httpun.Headers.t) (name : string) =
  match Httpun.Headers.get headers name with
  | Some _ as value -> value
  | None ->
      let title_case = title_case_header_name name in
      (match Httpun.Headers.get headers title_case with
      | Some _ as value -> value
      | None -> Httpun.Headers.get headers (String.uppercase_ascii name))

let get_cookie_value (request : Httpun.Request.t) cookie_name =
  match get_header_any_case request.headers "cookie" with
  | None -> None
  | Some raw ->
      raw
      |> String.split_on_char ';'
      |> List.find_map (fun part ->
             match String.split_on_char '=' (String.trim part) with
             | key :: value_parts
               when String.lowercase_ascii (String.trim key)
                    = String.lowercase_ascii cookie_name ->
                 let value = String.concat "=" value_parts |> String.trim in
                 if value = "" then None else Some value
             | _ -> None)

let get_session_id_any (request : Httpun.Request.t) =
  match get_session_id_query request.target with
  | Some _ as id -> id
  | None -> (
      match get_header_any_case request.headers "mcp-session-id" with
      | Some _ as id -> id
      | None -> get_cookie_value request "mcp-session-id")

let legacy_messages_endpoint_url (request : Httpun.Request.t) session_id =
  match Httpun.Headers.get request.headers "host" with
  | Some host ->
      let proto =
        match Httpun.Headers.get request.headers "x-forwarded-proto" with
        | Some p -> p
        | None ->
            if
              String.length host >= 17
              && String.sub host 0 17 = "masc.crying.pict"
            then "https"
            else "http"
      in
      Printf.sprintf "%s://%s/messages?session_id=%s" proto host session_id
  | None -> Printf.sprintf "/messages?session_id=%s" session_id

let get_protocol_version (request : Httpun.Request.t) =
  match get_header_any_case request.headers "mcp-protocol-version" with
  | Some v -> v
  | None -> mcp_protocol_version_default

let get_protocol_version_header_opt (request : Httpun.Request.t) =
  get_header_any_case request.headers "mcp-protocol-version"

let validate_protocol_version_continuity ~session_id request =
  let validate_supported version =
    if is_valid_protocol_version version then
      Ok ()
    else
      Error (Printf.sprintf "Unsupported MCP-Protocol-Version: %s" version)
  in
  let provided = get_protocol_version_header_opt request in
  match Hashtbl.find_opt protocol_version_by_session session_id with
  | Some expected -> (
      let ( let* ) = Result.bind in
      match provided with
      (* When the session already negotiated a protocol version, tolerate
         omitted follow-up headers and continue with the remembered version.
         Explicit mismatches still fail hard. *)
      | None -> Ok ()
      | Some version ->
          let* () = validate_supported version in
          if String.equal version expected then
            Ok ()
          else
            Error
              (Printf.sprintf
                 "MCP-Protocol-Version mismatch for session %s: expected %s, got %s."
                 session_id expected version))
  | None -> (
      match provided with
      | Some version -> validate_supported version
      | None -> Ok ())

let get_protocol_version_for_session ?session_id request =
  match session_id with
  | Some id -> (
      match Hashtbl.find_opt protocol_version_by_session id with
      | Some v -> v
      | None -> get_protocol_version request)
  | None -> get_protocol_version request

let query_param request key =
  let uri = Uri.of_string request.Httpun.Request.target in
  Uri.get_query_param uri key

let is_http_error_response = function
  | `Assoc fields ->
      let id_is_null =
        match List.assoc_opt "id" fields with
        | Some `Null -> true
        | _ -> false
      in
      let code =
        match List.assoc_opt "error" fields with
        | Some (`Assoc err_fields) -> (
            match List.assoc_opt "code" err_fields with
            | Some (`Int c) -> Some c
            | _ -> None)
        | _ -> None
      in
      id_is_null && (code = Some (-32700) || code = Some (-32600))
  | _ -> false

let request_runtime_result deps =
  match (deps.get_server_state_opt (), deps.get_sw (), deps.get_clock ()) with
  | Some state, Some sw, Some clock -> Ok (state, sw, clock)
  | None, _, _ -> Error "Server state not initialized"
  | _, None, _ -> Error "Eio switch not available"
  | _, _, None -> Error "Eio clock not available"

let env_flag name =
  match Sys.getenv_opt name with
  | Some raw -> (
      match String.lowercase_ascii (String.trim raw) with
      | "1" | "true" | "yes" | "on" -> true
      | _ -> false)
  | None -> false

let header_truthy_value value =
  match String.lowercase_ascii (String.trim value) with
  | "1" | "true" | "yes" | "on" -> true
  | _ -> false

let request_force_json_response (request : Httpun.Request.t) =
  match get_header_any_case request.headers "x-masc-force-json" with
  | Some value -> header_truthy_value value
  | None -> false

let allow_legacy_accept = env_flag "MASC_ALLOW_LEGACY_ACCEPT"

let classify_mcp_accept (request : Httpun.Request.t) =
  Http_negotiation.classify_mcp_accept ~allow_legacy:allow_legacy_accept
    (Httpun.Headers.get request.headers "accept")

let classify_mcp_accept_for_body request body_str =
  Server_mcp_transport_http_headers.classify_mcp_accept_for_body request
    body_str

let should_use_sse_for_body request body_str accept_mode =
  Server_mcp_transport_http_headers.should_use_sse_for_body request body_str
    accept_mode

let legacy_accept_warning_headers = function
  | Http_negotiation.Legacy_accepted ->
      [
        ( "warning",
          "299 - \"Legacy Accept is deprecated; use 'application/json, text/event-stream'\"" );
        ("x-masc-legacy-accept", "1");
      ]
  | Http_negotiation.Streamable | Http_negotiation.Rejected -> []

let legacy_transport_deprecation_headers =
  [
    ("deprecation", "true");
    ( "warning",
      "299 - \"Legacy SSE endpoints (/sse,/messages) are deprecated; use /mcp\"" );
    ("link", "</mcp>; rel=\"successor-version\"");
  ]

let force_json_response =
  env_flag "MASC_FORCE_JSON_RESPONSE" || env_flag "MCP_FORCE_JSON_RESPONSE"

let sse_retry_ms = 3000

let sse_prime_event () =
  let id = Sse.next_id () in
  Printf.sprintf "retry: %d\nid: %d\n\n" sse_retry_ms id

let sse_ping_interval_s = 30.0

let env_float_or ~name ~default =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw -> (
      try float_of_string raw with _ -> default)

let env_int_or ~name ~default =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw -> (
      try int_of_string raw with _ -> default)

let sse_reconnect_min_interval_s =
  env_float_or ~name:"MASC_SSE_RECONNECT_MIN_INTERVAL_S" ~default:0.0
  |> Float.max 0.0

let sse_connect_window_s =
  env_float_or ~name:"MASC_SSE_CONNECT_WINDOW_S" ~default:0.0 |> Float.max 0.0

let sse_connect_max_in_window =
  env_int_or ~name:"MASC_SSE_CONNECT_MAX_IN_WINDOW" ~default:0 |> max 0

let get_last_event_id (request : Httpun.Request.t) =
  match Httpun.Headers.get request.headers "last-event-id" with
  | Some id -> (
      try Some (int_of_string id) with Failure _ -> None)
  | None -> None

let mcp_headers session_id protocol_version =
  [ ("mcp-session-id", session_id); ("mcp-protocol-version", protocol_version) ]

let session_cookie_header session_id =
  ( "set-cookie",
    Printf.sprintf
      "mcp-session-id=%s; Path=/; Max-Age=86400; SameSite=Lax"
      session_id )

let sse_headers ~deps session_id protocol_version origin =
  [
    ("content-type", Http_negotiation.sse_content_type);
    session_cookie_header session_id;
  ]
  @ mcp_headers session_id protocol_version
  @ deps.cors_headers origin

let sse_stream_headers ~deps session_id protocol_version origin =
  [
    ("content-type", Http_negotiation.sse_content_type);
    ("cache-control", "no-cache");
    ("connection", "keep-alive");
    session_cookie_header session_id;
  ]
  @ mcp_headers session_id protocol_version
  @ deps.cors_headers origin

let json_headers ~deps session_id protocol_version origin =
  [ ("content-type", "application/json") ]
  @ mcp_headers session_id protocol_version
  @ deps.cors_headers origin

let respond_mcp_auth_error ?(extra_headers = []) ~deps request reqd ~session_id
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
  Httpun.Reqd.respond_with_string reqd response body

let respond_mcp_internal_error ?(extra_headers = []) ~deps request reqd
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
  Httpun.Reqd.respond_with_string reqd response body

type sse_conn_info = {
  session_id : string;
  client_id : int;
  writer : Httpun.Body.Writer.t;
  mutex : Eio.Mutex.t;
  stop : bool ref;
  mutable closed : bool;
}

let sse_conn_by_session : (string, sse_conn_info) Hashtbl.t = Hashtbl.create 128

type sse_connect_guard_state = {
  mutable last_connect_at : float;
  mutable connect_times : float list;
}

let sse_connect_guard_by_session :
    (string, sse_connect_guard_state) Hashtbl.t =
  Hashtbl.create 256

let prune_connect_times ~now times =
  if sse_connect_window_s <= 0.0 then times
  else List.filter (fun ts -> now -. ts <= sse_connect_window_s) times

let check_sse_connect_guard session_id =
  let now = Time_compat.now () in
  let state =
    match Hashtbl.find_opt sse_connect_guard_by_session session_id with
    | Some v -> v
    | None -> { last_connect_at = -.1.0; connect_times = [] }
  in
  let recent = prune_connect_times ~now state.connect_times in
  state.connect_times <- recent;
  let session_wait_s =
    if sse_reconnect_min_interval_s <= 0.0 then
      0.0
    else
      sse_reconnect_min_interval_s -. (now -. state.last_connect_at)
  in
  if session_wait_s > 0.0 then
    Error ("session_cooldown", session_wait_s)
  else
    let window_wait_s =
      if sse_connect_window_s <= 0.0 || sse_connect_max_in_window <= 0 then
        0.0
      else if List.length recent >= sse_connect_max_in_window then
        match List.rev recent with
        | oldest :: _ -> sse_connect_window_s -. (now -. oldest)
        | [] -> 0.0
      else
        0.0
    in
    if window_wait_s > 0.0 then
      Error ("window_limit", window_wait_s)
    else (
      state.last_connect_at <- now;
      state.connect_times <- now :: recent;
      Hashtbl.replace sse_connect_guard_by_session session_id state;
      Ok ())

let respond_sse_rate_limited ~deps ~origin ~session_id ~protocol_version
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
  Httpun.Reqd.respond_with_string reqd response body

let close_sse_conn info =
  if not info.closed then (
    info.closed <- true;
    info.stop := true;
    (try Httpun.Body.Writer.close info.writer
     with exn ->
       Log.Misc.debug "close_sse_conn: %s"
         (Printexc.to_string exn));
    Sse.unregister_if_current info.session_id info.client_id)

let stop_sse_session session_id =
  match Hashtbl.find_opt sse_conn_by_session session_id with
  | None -> ()
  | Some info ->
      Hashtbl.remove sse_conn_by_session session_id;
      close_sse_conn info

let close_all_sse_connections () =
  let sessions = Hashtbl.fold (fun k _ acc -> k :: acc) sse_conn_by_session [] in
  List.iter stop_sse_session sessions;
  Log.Server.info "MASC MCP: Closed %d SSE connections"
    (List.length sessions)

let send_raw info data =
  if info.closed || !(info.stop) || Httpun.Body.Writer.is_closed info.writer then (
    close_sse_conn info;
    false)
  else
    try
      Eio.Mutex.use_rw ~protect:true info.mutex (fun () ->
          Httpun.Body.Writer.write_string info.writer data;
          Httpun.Body.Writer.flush info.writer (fun _ -> ()));
      Sse.touch info.session_id;
      true
    with _exn ->
      close_sse_conn info;
      false

let handle_post_mcp ~deps ?(profile = Mcp_eio.Full) request reqd =
  let session_id =
    match get_session_id_any request with
    | Some sid -> sid
    | None -> Mcp_session.generate ()
  in
  let auth_token = deps.auth_token_from_request request in
  let protocol_version = get_protocol_version_for_session ~session_id request in
  let origin = deps.get_origin request in
  let base_path =
    match deps.get_server_state_opt () with
    | Some s -> s.Mcp_server.room_config.base_path
    | None -> default_base_path ()
  in
  let auth_result =
    match profile with
    | Mcp_eio.Full | Mcp_eio.Managed_agent | Mcp_eio.Role_filtered _ ->
        deps.verify_mcp_auth ~base_path request
    | Mcp_eio.Operator_remote ->
        deps.verify_operator_mcp_auth ~base_path request
  in
  match validate_mcp_session_profile ~profile session_id with
  | Error msg ->
      let body =
        Printf.sprintf
          {|{"jsonrpc":"2.0","error":{"code":-32600,"message":%s},"id":null}|}
          (Yojson.Safe.to_string (`String msg))
      in
      let headers =
        Httpun.Headers.of_list
          (("content-length", string_of_int (String.length body))
          :: json_headers ~deps session_id protocol_version origin)
      in
      let response = Httpun.Response.create ~headers `Conflict in
      Httpun.Reqd.respond_with_string reqd response body
  | Ok () ->
      match validate_protocol_version_continuity ~session_id request with
      | Error msg ->
          let body =
            Printf.sprintf
              {|{"jsonrpc":"2.0","error":{"code":-32600,"message":%s},"id":null}|}
              (Yojson.Safe.to_string (`String msg))
          in
          let headers =
            Httpun.Headers.of_list
              (("content-length", string_of_int (String.length body))
              :: json_headers ~deps session_id protocol_version origin)
          in
          let response = Httpun.Response.create ~headers `Bad_request in
          Httpun.Reqd.respond_with_string reqd response body
      | Ok () ->
          remember_mcp_profile session_id profile;
          match auth_result with
      | Error msg ->
          let body =
            Printf.sprintf
              {|{"jsonrpc":"2.0","error":{"code":-32600,"message":%s},"id":null}|}
              (Yojson.Safe.to_string (`String msg))
          in
          let headers =
            Httpun.Headers.of_list
              (("content-length", string_of_int (String.length body))
              :: json_headers ~deps session_id protocol_version origin)
          in
          let response = Httpun.Response.create ~headers `Bad_request in
          Httpun.Reqd.respond_with_string reqd response body
      | Ok () ->
          remember_mcp_profile session_id profile;
          match auth_result with
          | Error msg ->
              respond_mcp_auth_error ~deps request reqd ~session_id
                ~protocol_version msg
          | Ok () ->
              Http.Request.read_body_async reqd (fun body_str ->
                  let accept_mode =
                    Server_mcp_transport_http_headers.classify_mcp_accept_for_body
                      request body_str
                  in
                  match accept_mode with
                  | Http_negotiation.Rejected ->
                      let body =
                        Yojson.Safe.to_string
                          (`Assoc
                            [
                              ("jsonrpc", `String "2.0");
                              ( "error",
                                `Assoc
                                  [
                                    ("code", `Int (-32600));
                                    ( "message",
                                      `String
                                        "Invalid Accept header: must include application/json and text/event-stream. Set MASC_ALLOW_LEGACY_ACCEPT=1 for temporary compatibility." );
                                  ] );
                            ])
                      in
                      let headers =
                        Httpun.Headers.of_list
                          (("content-length", string_of_int (String.length body))
                          :: json_headers ~deps session_id protocol_version origin)
                      in
                      let response = Httpun.Response.create ~headers `Bad_request in
                      Httpun.Reqd.respond_with_string reqd response body
                  | accept_mode ->
                      let accept_warn_headers =
                        legacy_accept_warning_headers accept_mode
                      in
                      try
                        match request_runtime_result deps with
                        | Error msg ->
                            respond_mcp_internal_error ~deps request reqd
                              ~session_id ~protocol_version msg
                        | Ok (state, sw, clock) ->
                            let response_json =
                              Mcp_eio.handle_request ~clock ~sw ~profile
                                ~mcp_session_id:session_id ?auth_token state body_str
                            in
                            (match protocol_version_from_body body_str with
                            | Some v -> remember_protocol_version session_id v
                            | None -> ());
                            let protocol_version =
                              get_protocol_version_for_session ~session_id request
                            in
                            let wants_sse =
                              should_use_sse_for_body request body_str accept_mode
                              && not force_json_response
                              && not (request_force_json_response request)
                            in
                            if wants_sse then
                              match response_json with
                              | `Null ->
                                  let headers =
                                    Httpun.Headers.of_list
                                      ( ("content-length", "0")
                                      :: accept_warn_headers
                                      @ mcp_headers session_id protocol_version )
                                  in
                                  let response =
                                    Httpun.Response.create ~headers `Accepted
                                  in
                                  Httpun.Reqd.respond_with_string reqd response ""
                              | json when is_http_error_response json ->
                                  let body = Yojson.Safe.to_string json in
                                  let headers =
                                    Httpun.Headers.of_list
                                      ( ("content-length", string_of_int (String.length body))
                                      :: accept_warn_headers
                                      @ json_headers ~deps session_id protocol_version
                                          origin )
                                  in
                                  let response =
                                    Httpun.Response.create ~headers `Bad_request
                                  in
                                  Httpun.Reqd.respond_with_string reqd response body
                              | json ->
                                  let event =
                                    Sse.format_event ~event_type:"message"
                                      (Yojson.Safe.to_string json)
                                  in
                                  let body = sse_prime_event () ^ event in
                                  let headers =
                                    Httpun.Headers.of_list
                                      ( ("content-length", string_of_int (String.length body))
                                      :: accept_warn_headers
                                      @ sse_headers ~deps session_id protocol_version
                                          origin )
                                  in
                                  let response = Httpun.Response.create ~headers `OK in
                                  Httpun.Reqd.respond_with_string reqd response body
                            else
                              match response_json with
                              | `Null ->
                                  let headers =
                                    Httpun.Headers.of_list
                                      ( ("content-length", "0")
                                      :: accept_warn_headers
                                      @ mcp_headers session_id protocol_version )
                                  in
                                  let response =
                                    Httpun.Response.create ~headers `Accepted
                                  in
                                  Httpun.Reqd.respond_with_string reqd response ""
                              | json when is_http_error_response json ->
                                  let body = Yojson.Safe.to_string json in
                                  let headers =
                                    Httpun.Headers.of_list
                                      ( ("content-length", string_of_int (String.length body))
                                      :: accept_warn_headers
                                      @ json_headers ~deps session_id protocol_version
                                          origin )
                                  in
                                  let response =
                                    Httpun.Response.create ~headers `Bad_request
                                  in
                                  Httpun.Reqd.respond_with_string reqd response body
                              | json ->
                                  let body = Yojson.Safe.to_string json in
                                  let headers =
                                    Httpun.Headers.of_list
                                      ( ("content-length", string_of_int (String.length body))
                                      :: accept_warn_headers
                                      @ json_headers ~deps session_id protocol_version
                                          origin )
                                  in
                                  let response = Httpun.Response.create ~headers `OK in
                                  Httpun.Reqd.respond_with_string reqd response body
                      with exn ->
                        let protocol_version =
                          get_protocol_version_for_session ~session_id request
                        in
                        respond_mcp_internal_error ~deps request reqd ~session_id
                          ~protocol_version
                          ("Internal error: " ^ Printexc.to_string exn))

let handle_get_mcp ~deps ?legacy_messages_endpoint ?(profile = Mcp_eio.Full)
    request reqd =
  let origin = deps.get_origin request in
  let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
  let protocol_version = get_protocol_version_for_session ~session_id request in
  let legacy_headers =
    match legacy_messages_endpoint with
    | Some _ -> legacy_transport_deprecation_headers
    | None -> []
  in
  let last_event_id = get_last_event_id request in
  match validate_mcp_session_profile ~profile session_id with
  | Error msg ->
      let headers =
        Httpun.Headers.of_list
          (("content-length", string_of_int (String.length msg))
          :: json_headers ~deps session_id protocol_version origin)
      in
      let response = Httpun.Response.create ~headers `Conflict in
      Httpun.Reqd.respond_with_string reqd response msg
  | Ok () -> (
      match validate_protocol_version_continuity ~session_id request with
      | Error msg ->
          let body =
            Printf.sprintf
              {|{"jsonrpc":"2.0","error":{"code":-32600,"message":%s},"id":null}|}
              (Yojson.Safe.to_string (`String msg))
          in
          let headers =
            Httpun.Headers.of_list
              (("content-length", string_of_int (String.length body))
              :: json_headers ~deps session_id protocol_version origin)
          in
          let response = Httpun.Response.create ~headers `Bad_request in
          Httpun.Reqd.respond_with_string reqd response body
      | Ok () ->
      remember_mcp_profile session_id profile;
      (match check_sse_connect_guard session_id with
      | Error (reason, retry_after_s) ->
          respond_sse_rate_limited ~deps ~origin ~session_id ~protocol_version
            ~reason ~retry_after_s reqd
      | Ok () ->
          stop_sse_session session_id;
          let headers =
            Httpun.Headers.of_list
              (legacy_headers
              @ sse_stream_headers ~deps session_id protocol_version origin)
          in
          let response = Httpun.Response.create ~headers `OK in
          let writer = Httpun.Reqd.respond_with_streaming reqd response in
          let mutex = Eio.Mutex.create () in
          let info_ref : sse_conn_info option ref = ref None in
          let push event =
            match !info_ref with
            | None -> ()
            | Some info -> ignore (send_raw info event)
          in
          let client_id, evicted =
            Sse.register session_id ~push
              ~last_event_id:(Option.value ~default:0 last_event_id)
          in
          (match evicted with
          | Some evicted_sid -> stop_sse_session evicted_sid
          | None -> ());
          let info =
            {
              session_id;
              client_id;
              writer;
              mutex;
              stop = ref false;
              closed = false;
            }
          in
          info_ref := Some info;
          Hashtbl.replace sse_conn_by_session session_id info;
          ignore (send_raw info (sse_prime_event ()));
          (match legacy_messages_endpoint with
          | None -> ()
          | Some f ->
              let endpoint_url = f session_id in
              ignore
                (send_raw info
                   (Sse.format_event ~event_type:"endpoint" endpoint_url)));
          (match last_event_id with
          | Some last_id ->
              let missed = Sse.get_events_after last_id in
              List.iter (fun ev -> ignore (send_raw info ev)) missed
          | None -> ());
          (match
             (deps.get_sw (), deps.get_clock ())
           with
          | Some sw, Some clock ->
              Eio.Fiber.fork ~sw (fun () ->
                  let is_cancelled exn =
                    match exn with
                    | Eio.Cancel.Cancelled _ -> true
                    | _ -> false
                  in
                  let rec loop () =
                    if not !(info.stop) then (
                      (try Eio.Time.sleep clock sse_ping_interval_s
                       with exn ->
                         if is_cancelled exn then raise exn;
                         Log.Server.error "ping sleep error: %s"
                           (Printexc.to_string exn));
                      (try
                         if info.closed then
                           stop_sse_session info.session_id
                         else if not !(info.stop) then
                           ignore (send_raw info ": ping\n\n")
                       with exn ->
                         if is_cancelled exn then raise exn;
                         Log.Server.error "ping send error: %s"
                           (Printexc.to_string exn);
                         stop_sse_session info.session_id);
                      loop ())
                  in
                  try loop () with exn ->
                    if is_cancelled exn then ()
                    else
                      Log.Server.error "ping loop error: %s"
                        (Printexc.to_string exn))
          | _ -> ());
          let client_count = Sse.client_count () in
          if client_count > Sse.max_clients / 2 then
            Log.Server.info "SSE connected: %s (active: %d/%d)"
              session_id client_count Sse.max_clients))

let sse_simple_handler ~deps request reqd =
  let origin = deps.get_origin request in
  let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
  let protocol_version = get_protocol_version_for_session ~session_id request in
  let event =
    sse_prime_event ()
    ^ Sse.format_event ~event_type:"connected"
        (Printf.sprintf {|{"session_id":"%s"}|} session_id)
  in
  let headers =
    Httpun.Headers.of_list
      (("content-length", string_of_int (String.length event))
      :: legacy_transport_deprecation_headers
      @ sse_headers ~deps session_id protocol_version origin)
  in
  let response = Httpun.Response.create ~headers `OK in
  Httpun.Reqd.respond_with_string reqd response event

let handle_get_operator_mcp ~deps request reqd =
  let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
  let protocol_version = get_protocol_version_for_session ~session_id request in
  let base_path =
    match deps.get_server_state_opt () with
    | Some s -> s.Mcp_server.room_config.base_path
    | None -> default_base_path ()
  in
  match deps.verify_operator_mcp_auth ~base_path request with
  | Error msg ->
      respond_mcp_auth_error ~deps request reqd ~session_id ~protocol_version
        msg
  | Ok () ->
      handle_get_mcp ~deps ~profile:Mcp_eio.Operator_remote request reqd

let handle_post_messages ~deps request reqd =
  let origin = deps.get_origin request in
  let legacy_headers = legacy_transport_deprecation_headers in
  match get_session_id_any request with
  | None ->
      let body = "session_id required" in
      let headers =
        Httpun.Headers.of_list
          (("content-length", string_of_int (String.length body))
          :: (legacy_headers @ deps.cors_headers origin))
      in
      let response = Httpun.Response.create ~headers `Bad_request in
      Httpun.Reqd.respond_with_string reqd response body
  | Some session_id when not (Mcp_session.is_valid session_id) ->
      let body = "invalid session_id" in
      let headers =
        Httpun.Headers.of_list
          (("content-length", string_of_int (String.length body))
          :: (legacy_headers @ deps.cors_headers origin))
      in
      let response = Httpun.Response.create ~headers `Bad_request in
      Httpun.Reqd.respond_with_string reqd response body
  | Some session_id ->
      let protocol_version = get_protocol_version_for_session ~session_id request in
      let auth_token = deps.auth_token_from_request request in
      let base_path =
        match deps.get_server_state_opt () with
        | Some s -> s.Mcp_server.room_config.base_path
        | None -> default_base_path ()
      in
      (match deps.verify_mcp_auth ~base_path request with
      | Error msg ->
          respond_mcp_auth_error ~deps request reqd ~session_id
            ~protocol_version ~extra_headers:legacy_headers msg
      | Ok () ->
          Http.Request.read_body_async reqd (fun body_str ->
              match request_runtime_result deps with
              | Error msg ->
                  respond_mcp_internal_error ~extra_headers:legacy_headers
                    ~deps request reqd ~session_id ~protocol_version msg
              | Ok (state, sw, clock) ->
                  let response_json =
                    Mcp_eio.handle_request ~clock ~sw ~mcp_session_id:session_id
                      ?auth_token state body_str
                  in
                  (match response_json with
                  | `Null -> ()
                  | json -> Sse.send_to session_id json);
                  let headers =
                    Httpun.Headers.of_list
                      (("content-length", "0")
                      :: (legacy_headers @ mcp_headers session_id protocol_version))
                  in
                  let response = Httpun.Response.create ~headers `Accepted in
                  Httpun.Reqd.respond_with_string reqd response ""))

let handle_delete_mcp ~deps ?(profile = Mcp_eio.Full) request reqd =
  let base_path =
    match deps.get_server_state_opt () with
    | Some s -> s.Mcp_server.room_config.base_path
    | None -> default_base_path ()
  in
  let auth_result =
    match profile with
    | Mcp_eio.Full | Mcp_eio.Managed_agent | Mcp_eio.Role_filtered _ -> Ok ()
    | Mcp_eio.Operator_remote ->
        deps.verify_operator_mcp_auth ~base_path request
  in
  match auth_result with
  | Error msg ->
      let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
      let protocol_version = get_protocol_version_for_session ~session_id request in
      respond_mcp_auth_error ~deps request reqd ~session_id ~protocol_version
        msg
  | Ok () -> (
      match get_session_id_any request with
      | Some session_id -> (
          match validate_mcp_session_delete_profile ~profile session_id with
          | Error msg ->
              let headers =
                Httpun.Headers.of_list
                  [ ("content-length", string_of_int (String.length msg)) ]
              in
              let response = Httpun.Response.create ~headers `Conflict in
              Httpun.Reqd.respond_with_string reqd response msg
          | Ok () -> (
              match validate_protocol_version_continuity ~session_id request with
              | Error msg ->
                  let body =
                    Printf.sprintf
                      {|{"jsonrpc":"2.0","error":{"code":-32600,"message":%s},"id":null}|}
                      (Yojson.Safe.to_string (`String msg))
                  in
                  let protocol_version =
                    get_protocol_version_for_session ~session_id request
                  in
                  let headers =
                    Httpun.Headers.of_list
                      (("content-length", string_of_int (String.length body))
                      :: json_headers ~deps session_id protocol_version
                           (deps.get_origin request))
                  in
                  let response =
                    Httpun.Response.create ~headers `Bad_request
                  in
                  Httpun.Reqd.respond_with_string reqd response body
              | Ok () ->
              stop_sse_session session_id;
              Sse.unregister session_id;
              Mcp_eio.clear_resource_subscriptions_for_session session_id;
              forget_mcp_session session_id;
              Printf.printf "🔚 Session terminated: %s\n%!" session_id;
              let headers =
                Httpun.Headers.of_list
                  (("content-length", "0")
                  :: mcp_headers session_id (get_protocol_version request))
              in
              let response = Httpun.Response.create ~headers `No_content in
              Httpun.Reqd.respond_with_string reqd response ""))
      | None ->
          let body = "Mcp-Session-Id required" in
          let headers =
            Httpun.Headers.of_list
              [ ("content-length", string_of_int (String.length body)) ]
          in
          let response = Httpun.Response.create ~headers `Bad_request in
          Httpun.Reqd.respond_with_string reqd response body)

let ag_ui_event_of_masc_event ~room_id event =
  try
    let lines = String.split_on_char '\n' event in
    let data_line =
      List.find_opt
        (fun l -> String.length l > 6 && String.sub l 0 6 = "data: ")
        lines
    in
    match data_line with
    | Some dl ->
        let json_str = String.sub dl 6 (String.length dl - 6) in
        let json = Yojson.Safe.from_string json_str in
        let ag_event = Ag_ui.of_custom ~room_id ~name:"MASC_EVENT" json in
        Ag_ui.event_to_sse ag_event
    | None -> event
  with
  | Yojson.Json_error _ -> event
  | exn ->
      Log.Transport.warn "ag_ui_event_of_masc_event failed: %s" (Printexc.to_string exn);
      event

let handle_ag_ui_events ~deps request reqd =
  let origin = deps.get_origin request in
  let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
  let protocol_version = get_protocol_version_for_session ~session_id request in
  let room_id = Option.value ~default:"default" (query_param request "room") in
  let last_event_id = get_last_event_id request in
  match check_sse_connect_guard session_id with
  | Error (reason, retry_after_s) ->
      respond_sse_rate_limited ~deps ~origin ~session_id ~protocol_version
        ~reason ~retry_after_s reqd
  | Ok () ->
      stop_sse_session session_id;
      let headers =
        Httpun.Headers.of_list
          (sse_stream_headers ~deps session_id protocol_version origin)
      in
      let response = Httpun.Response.create ~headers `OK in
      let writer = Httpun.Reqd.respond_with_streaming reqd response in
      let mutex = Eio.Mutex.create () in
      let info_ref : sse_conn_info option ref = ref None in
      let push event =
        match !info_ref with
        | None -> ()
        | Some info -> ignore (send_raw info (ag_ui_event_of_masc_event ~room_id event))
      in
      let client_id, evicted =
        Sse.register session_id ~push
          ~last_event_id:(Option.value ~default:0 last_event_id)
      in
      (match evicted with
      | Some evicted_sid -> stop_sse_session evicted_sid
      | None -> ());
      let info =
        {
          session_id;
          client_id;
          writer;
          mutex;
          stop = ref false;
          closed = false;
        }
      in
      info_ref := Some info;
      Hashtbl.replace sse_conn_by_session session_id info;
      let prime =
        Ag_ui.(
          make_event ~thread_id:room_id ~run_id:(Some session_id) Run_started
          |> event_to_sse)
      in
      ignore (send_raw info prime);
      (match last_event_id with
      | Some last_id ->
          let missed = Sse.get_events_after last_id in
          List.iter (fun ev -> ignore (send_raw info ev)) missed
      | None -> ());
      (match
         (deps.get_sw (), deps.get_clock ())
       with
      | Some sw, Some clock ->
          Eio.Fiber.fork ~sw (fun () ->
              let rec loop () =
                if not !(info.stop) then (
                  (try Eio.Time.sleep clock sse_ping_interval_s
                   with Eio.Cancel.Cancelled _ as exn -> raise exn | _ -> ());
                  (try
                     if info.closed then
                       stop_sse_session info.session_id
                     else if not !(info.stop) then
                       ignore (send_raw info ": ping\n\n")
                   with Eio.Cancel.Cancelled _ as exn -> raise exn
                      | _ -> stop_sse_session info.session_id);
                  loop ())
              in
              try loop () with Eio.Cancel.Cancelled _ as exn -> raise exn | _ -> ())
      | _ -> ())
