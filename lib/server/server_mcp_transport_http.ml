(** Server_mcp_transport_http — SSE/POST MCP transport handler. *)

type tool_profile = Server_mcp_transport_http_types.tool_profile =
  | Full
  | Managed_agent
  | Operator_remote

type runtime = Server_mcp_transport_http_types.runtime = {
  base_path : string;
  sw : Eio.Switch.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  handle_request :
    ?profile:tool_profile ->
    ?mcp_session_id:string ->
    ?auth_token:string ->
    ?internal_keeper_runtime:bool ->
    string ->
    Yojson.Safe.t;
  clear_resource_subscriptions_for_session : string -> unit;
}

include Server_mcp_transport_http_protocol
include Server_mcp_transport_http_conn
include Server_mcp_transport_http_respond
include Server_mcp_transport_http_agui

(** [safe_respond_with_string] is a local guard against the
    [Failure "invalid state, currently handling error"] race that
    httpun raises when a client disconnects during a long OAS turn
    (2026-05-05 cycle9 FATAL incident).  All direct
    [Httpun.Reqd.respond_with_string] calls in this file use this
    wrapper instead of the raw httpun call. *)
let safe_respond_with_string reqd response body =
  try Httpun.Reqd.respond_with_string reqd response body
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Failure msg ->
      Log.Server.warn
        "[mcp-http-post] respond_with_string skipped (reqd invalid state; \
         2026-05-05 OAS cancel race): %s"
        msg
  | exn ->
      Log.Server.warn
        "[mcp-http-post] respond_with_string unexpected exception: %s"
        (Printexc.to_string exn)

let body_jsonrpc_method = Server_mcp_transport_http_headers.body_jsonrpc_method

let sse_prime_event = Server_mcp_transport_http_headers.sse_prime_event

let sse_ping_interval_s = Server_mcp_transport_http_headers.sse_ping_interval_s

let post_sse_keepalive_interval_s = Float.max 0.1 sse_ping_interval_s

let get_last_event_id = Server_mcp_transport_http_headers.get_last_event_id

let body_jsonrpc_id body_str =
  try
    match Yojson.Safe.from_string body_str with
    | `Assoc fields -> List.assoc_opt "id" fields
    | _ -> None
  with Yojson.Json_error _ -> None

let session_cookie_header = Server_mcp_transport_http_headers.session_cookie_header

let sse_headers = Server_mcp_transport_http_headers.sse_headers

let sse_stream_headers = Server_mcp_transport_http_headers.sse_stream_headers

let stream_post_sse_headers ~deps ~origin ~session_id ~protocol_version
    ~accept_warn_headers =
  Httpun.Headers.of_list
    (accept_warn_headers
    @ [
        ("content-type", Http_negotiation.sse_content_type);
        ("cache-control", "no-cache");
        ("connection", "close");
        ("x-accel-buffering", "no");
        session_cookie_header session_id;
      ]
      @ mcp_headers session_id protocol_version
      @ deps.cors_headers origin)

let stream_post_sse_start ~deps ~origin ~session_id ~protocol_version
    ~accept_warn_headers reqd =
  let headers =
    stream_post_sse_headers ~deps ~origin ~session_id ~protocol_version
      ~accept_warn_headers
  in
  let response = Httpun.Response.create ~headers `OK in
  let writer = Httpun.Reqd.respond_with_streaming reqd response in
  let info = make_inline_sse_conn ~session_id writer in
  if not (send_raw info (sse_prime_event ())) then
    Log.Server.debug "SSE prime send failed for session %s" info.session_id;
  info

let spawn_post_sse_keepalive ~sw ~clock info =
  Eio.Fiber.fork ~sw (fun () ->
      let rec loop () =
        if not !(info.stop) then (
          (try
             Eio.Time.sleep clock post_sse_keepalive_interval_s
           with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn -> Log.Server.warn "SSE keepalive sleep failed for session %s: %s"
                    info.session_id (Printexc.to_string exn));
          if info.closed then
            close_sse_conn info
          else if not !(info.stop) then
            if not (send_raw info ": keepalive\n\n") then
              Log.Server.debug "SSE keepalive send failed for session %s"
                info.session_id;
          loop ())
      in
      try loop ()
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | _ -> close_sse_conn info)

let stream_post_sse_finish info = close_sse_conn info

let stream_post_sse_json info (json : Yojson.Safe.t) =
  if not (send_raw info
            (Sse.format_event ~event_type:"message" (Yojson.Safe.to_string json)))
  then
    Log.Server.debug "SSE json send failed for session %s" info.session_id

let should_stream_post_tools_call request body_str accept_mode =
  should_use_sse_for_body request body_str accept_mode
  && not force_json_response
  && not (request_force_json_response request)
  &&
  match body_jsonrpc_method body_str with
  | Some ("tools/call", true) -> true
  | _ -> false

(** Inject or replace [_agent_name] in MCP [tools/call] arguments.
    For authenticated dashboard sessions, the HTTP-layer token owner is the
    canonical caller identity, so a stale browser-supplied [_agent_name]
    must be overwritten. The legacy argument-scoped [token] is also removed
    when HTTP auth is present so stale MCP bodies cannot override the
    transport token. Legacy [agent_name] is left untouched because some tools
    use it as a domain argument rather than caller identity. *)
let inject_agent_name_into_body ?(rewrite_existing = false) ?(strip_token = false)
    ~agent_name body_str =
  try
    let json = Yojson.Safe.from_string body_str in
    let open Yojson.Safe.Util in
    let method_name = member "method" json |> to_string_option in
    match method_name with
    | Some "tools/call" ->
        let params = member "params" json in
        let args = member "arguments" params in
        let existing_agent =
          Option.bind
            (member "_agent_name" args |> to_string_option)
            (fun value ->
               let trimmed = String.trim value in
               if String.equal trimmed "" then None else Some trimmed)
        in
        let existing_legacy_agent =
          Option.bind
            (member "agent_name" args |> to_string_option)
            (fun value ->
               let trimmed = String.trim value in
               if String.equal trimmed "" then None else Some trimmed)
        in
        let new_args =
          match args with
          | `Assoc fields ->
              let normalized_fields =
                let fields =
                  if rewrite_existing then
                    List.filter
                      (fun (key, _) -> not (String.equal key "_agent_name"))
                      fields
                  else
                    fields
                in
                if strip_token then
                  List.filter (fun (key, _) -> not (String.equal key "token"))
                    fields
                else
                  fields
              in
              let should_inject =
                rewrite_existing
                || (Option.is_none existing_agent
                    && Option.is_none existing_legacy_agent)
              in
              if should_inject then
                `Assoc (("_agent_name", `String agent_name) :: normalized_fields)
              else
                args
          | _ -> args
        in
        if new_args = args then body_str else
          let new_params = match params with
            | `Assoc fields ->
                `Assoc (List.map (fun (k, v) ->
                  if k = "arguments" then (k, new_args) else (k, v)) fields)
            | _ -> params
          in
          let new_json = match json with
            | `Assoc fields ->
                `Assoc (List.map (fun (k, v) ->
                  if k = "params" then (k, new_params) else (k, v)) fields)
            | _ -> json
          in
          Yojson.Safe.to_string new_json
    | _ -> body_str
  with Eio.Cancel.Cancelled _ as e -> raise e | _ -> body_str

let body_with_canonical_http_actor ~base_path ~auth_token request body_str =
  match Server_auth.dashboard_actor_for_request ~base_path request with
  | None -> body_str
  | Some agent ->
      inject_agent_name_into_body
        ~rewrite_existing:(Option.is_some auth_token)
        ~strip_token:(Option.is_some auth_token)
        ~agent_name:agent body_str

let handle_post_mcp ~deps ?(profile = Full) request reqd =
  (* Readiness gate: reject before session/auth if server state is not ready *)
  if not (deps.is_ready ()) then
    respond_not_ready ~deps request reqd
  else
  let session_id_opt = get_session_id_any request in
  let session_was_provided = Option.is_some session_id_opt in
  let session_id =
    match session_id_opt with
    | Some sid -> sid
    | None -> Mcp_session.generate ()
  in
  let auth_token = deps.auth_token_from_request request in
  let protocol_version = get_protocol_version_for_session ~session_id request in
  let origin = deps.get_origin request in
  let base_path = deps.get_base_path () in
  let auth_result =
    match profile with
    | Full | Managed_agent ->
        deps.verify_mcp_auth ~base_path request
    | Operator_remote ->
        deps.verify_operator_mcp_auth ~base_path request
  in
  let open Result.Syntax in
  ignore (
    let* () =
      match validate_mcp_session_profile ~profile session_id with
      | Ok () -> Ok ()
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
          safe_respond_with_string reqd response body;
          Error ()
    in
    let* () =
      match validate_protocol_version_continuity ~session_id request with
      | Ok () -> Ok ()
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
          safe_respond_with_string reqd response body;
          Error ()
    in
    remember_mcp_profile session_id profile;
    let* () =
      match auth_result with
      | Ok () -> Ok ()
      | Error msg ->
          respond_mcp_auth_error ~deps request reqd ~session_id
            ~protocol_version msg;
          Error ()
    in
    Ok (Http.Request.read_body_async reqd (fun body_str ->
      ignore (
        let* () =
        match
          validate_session_requirement ~session_was_provided body_str
        with
        | Ok () -> Ok ()
        | Error msg ->
            let body =
              Printf.sprintf
                {|{"jsonrpc":"2.0","error":{"code":-32600,"message":%s},"id":null}|}
                (Yojson.Safe.to_string (`String msg))
            in
            let headers =
              Httpun.Headers.of_list
                (("content-length", string_of_int (String.length body))
                :: json_headers ~deps session_id protocol_version
                     origin)
            in
            safe_respond_with_string reqd
              (Httpun.Response.create ~headers `Bad_request)
              body;
            Error ()
      in
      let accept_mode =
        Server_mcp_transport_http_headers.classify_mcp_accept_for_body
          request body_str
      in
      let* accept_mode =
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
            safe_respond_with_string reqd response body;
            Error ()
        | _ -> Ok accept_mode
      in
      let accept_warn_headers =
        legacy_accept_warning_headers accept_mode
      in
      let* runtime =
        match request_runtime_result deps with
        | Ok r -> Ok r
        | Error msg ->
            respond_mcp_internal_error ~deps request reqd
              ~session_id ~protocol_version msg;
            Error ()
      in
      let sw = runtime.sw in
      let clock = runtime.clock in
      Ok (Eio.Fiber.fork ~sw (fun () ->
                            let response_protocol_version =
                              match protocol_version_from_body body_str with
                              | Some v ->
                                  remember_protocol_version session_id v;
                                  v
                              | None ->
                                  get_protocol_version_for_session ~session_id request
                            in
                            let wants_streaming_post =
                              should_stream_post_tools_call request body_str
                                accept_mode
                            in
                            let response_id = body_jsonrpc_id body_str in
                            let inline_sse : sse_conn_info option ref = ref None in
                            try
                              if wants_streaming_post then (
                                let info =
                                  stream_post_sse_start ~deps ~origin ~session_id
                                    ~protocol_version:response_protocol_version
                                    ~accept_warn_headers reqd
                                in
                                inline_sse := Some info;
                                spawn_post_sse_keepalive ~sw ~clock info);
                              let body_with_agent =
                                body_with_canonical_http_actor ~base_path
                                  ~auth_token request body_str
                              in
                              let internal_keeper_runtime =
                                Server_auth.is_verified_internal_keeper_request
                                  ~base_path request
                              in
                              let response_json =
                                runtime.handle_request ?auth_token ~profile
                                  ~mcp_session_id:session_id
                                  ~internal_keeper_runtime body_with_agent
                              in
                              let protocol_version =
                                get_protocol_version_for_session ~session_id request
                              in
                              let wants_sse =
                                should_use_sse_for_body request body_str accept_mode
                                && not force_json_response
                                && not (request_force_json_response request)
                              in
                              if wants_streaming_post then
                                match !inline_sse with
                                | Some info ->
                                    if response_json <> `Null then
                                      stream_post_sse_json info response_json;
                                    stream_post_sse_finish info
                                | None -> ()
                              else if wants_sse then
                                match response_json with
                                | `Null ->
                                    let headers =
                                      Httpun.Headers.of_list
                                        (("content-length", "0")
                                        :: accept_warn_headers
                                        @ mcp_headers session_id protocol_version)
                                    in
                                    let response =
                                      Httpun.Response.create ~headers `Accepted
                                    in
                                    safe_respond_with_string reqd response ""
                                | json when is_http_error_response json ->
                                    let body = Yojson.Safe.to_string json in
                                    let headers =
                                      Httpun.Headers.of_list
                                        (("content-length",
                                          string_of_int (String.length body))
                                        :: accept_warn_headers
                                        @ json_headers ~deps session_id
                                            protocol_version origin)
                                    in
                                    let response =
                                      Httpun.Response.create ~headers `Bad_request
                                    in
                                    safe_respond_with_string reqd response
                                      body
                                | json ->
                                    let event =
                                      Sse.format_event ~event_type:"message"
                                        (Yojson.Safe.to_string json)
                                    in
                                    let body = sse_prime_event () ^ event in
                                    let headers =
                                      Httpun.Headers.of_list
                                        (("content-length",
                                          string_of_int (String.length body))
                                        :: accept_warn_headers
                                        @ sse_headers ~deps session_id
                                            protocol_version origin)
                                    in
                                    let response =
                                      Httpun.Response.create ~headers `OK
                                    in
                                    safe_respond_with_string reqd response
                                      body
                              else
                                match response_json with
                                | `Null ->
                                    let headers =
                                      Httpun.Headers.of_list
                                        (("content-length", "0")
                                        :: accept_warn_headers
                                        @ mcp_headers session_id protocol_version)
                                    in
                                    let response =
                                      Httpun.Response.create ~headers `Accepted
                                    in
                                    safe_respond_with_string reqd response ""
                                | json when is_http_error_response json ->
                                    let body = Yojson.Safe.to_string json in
                                    let headers =
                                      Httpun.Headers.of_list
                                        (("content-length",
                                          string_of_int (String.length body))
                                        :: accept_warn_headers
                                        @ json_headers ~deps session_id
                                            protocol_version origin)
                                    in
                                    let response =
                                      Httpun.Response.create ~headers `Bad_request
                                    in
                                    safe_respond_with_string reqd response
                                      body
                                | json ->
                                    let body = Yojson.Safe.to_string json in
                                    let headers =
                                      Httpun.Headers.of_list
                                        (("content-length",
                                          string_of_int (String.length body))
                                        :: accept_warn_headers
                                        @ json_headers ~deps session_id
                                            protocol_version origin)
                                    in
                                    let response =
                                      Httpun.Response.create ~headers `OK
                                    in
                                    safe_respond_with_string reqd response
                                      body
                            with
                            | Eio.Cancel.Cancelled _ as e -> raise e
                            | exn ->
                                (match !inline_sse with
                                | Some info ->
                                    stream_post_sse_json info
                                      (mcp_internal_error_json ?id:response_id
                                         ("Internal error: "
                                        ^ Printexc.to_string exn));
                                    stream_post_sse_finish info
                                | None ->
                                    let protocol_version =
                                      get_protocol_version_for_session ~session_id
                                        request
                                    in
                                    respond_mcp_internal_error ~deps request reqd
                                      ~session_id ~protocol_version
                                      ("Internal error: "
                                     ^ Printexc.to_string exn))))))))

let handle_get_mcp ~deps ?legacy_messages_endpoint ?(profile = Full)
    ?(sse_kind = Sse.Coordinator) request reqd =
  if not (deps.is_ready ()) then
    respond_not_ready ~deps request reqd
  else
  let origin = deps.get_origin request in
  let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
  let protocol_version = get_protocol_version_for_session ~session_id request in
  let base_path = deps.get_base_path () in
  let auth_result =
    match profile with
    | Full | Managed_agent ->
        (match sse_kind with
         | Sse.Observer | Sse.Presence ->
             deps.verify_mcp_observer_stream_auth ~base_path request
         | Sse.Coordinator ->
             deps.verify_mcp_auth ~base_path request)
    | Operator_remote ->
        deps.verify_operator_mcp_auth ~base_path request
  in
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
      safe_respond_with_string reqd response msg
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
          safe_respond_with_string reqd response body
      | Ok () ->
      (match auth_result with
      | Error msg ->
          respond_mcp_auth_error ~deps request reqd ~session_id
            ~protocol_version ~extra_headers:legacy_headers msg
      | Ok () ->
      remember_mcp_profile session_id profile;
      (match check_sse_connect_guard session_id with
      | Error (reason, retry_after_s) ->
          respond_sse_rate_limited ~deps ~origin ~session_id ~protocol_version
            ~reason ~retry_after_s reqd
      | Ok () ->
          stop_sse_session session_id;
          if Option.is_some last_event_id then
            Transport_metrics.inc_sse_reconnect ();
          let headers =
            Httpun.Headers.of_list
              (legacy_headers
              @ sse_stream_headers ~deps session_id protocol_version origin)
          in
          let response = Httpun.Response.create ~headers `OK in
          let writer = Httpun.Reqd.respond_with_streaming reqd response in
          let mutex = Eio.Mutex.create () in
          let info_ref : sse_conn_info option ref = ref None in
          let client_id, event_stream, evicted =
            Sse.register ~kind:sse_kind session_id
              ~last_event_id:(Option.value ~default:0 last_event_id)
              ~on_disconnect:(fun () -> stop_sse_session session_id)
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
          register_sse_conn ~session_id ~info;
          if not (send_raw info (sse_prime_event ())) then
            Log.Server.debug "SSE prime send failed for session %s" info.session_id;
          (match legacy_messages_endpoint with
          | None -> ()
          | Some f ->
              let endpoint_url = f session_id in
              if not (send_raw info
                        (Sse.format_event ~event_type:"endpoint" endpoint_url))
              then
                Log.Server.debug "SSE endpoint send failed for session %s"
                  info.session_id);
          (match last_event_id with
          | Some last_id ->
              let missed = Sse.get_events_after_for_kind sse_kind last_id in
              List.iter (fun ev ->
                if not (send_raw info ev) then
                  Log.Server.debug "SSE replay send failed for session %s"
                    info.session_id
              ) missed
          | None -> ());
          (match deps.get_runtime_result () with
          | Ok runtime ->
              let sw = runtime.sw in
              let clock = runtime.clock in
              Eio.Fiber.fork ~sw (fun () ->
                  let rec drain () =
                    let event = Eio.Stream.take event_stream in
                    (try
                      if not (info.closed || !(info.stop)) then
                        if not (send_raw info event) then
                          Log.Server.debug "SSE drain send failed for session %s"
                            info.session_id
                    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                      Log.Server.error "drain write error: %s"
                        (Printexc.to_string exn);
                      stop_sse_session info.session_id);
                    if not !(info.stop) then drain ()
                  in
                  try drain ()
                  with Eio.Cancel.Cancelled _ as e -> raise e
                     | exn ->
                       Log.Server.error "drain loop error: %s"
                         (Printexc.to_string exn));
              Eio.Fiber.fork ~sw (fun () ->
                  let is_cancelled exn =
                    match exn with
                    | Eio.Cancel.Cancelled _ -> true
                    | _ -> false
                  in
                  let rec loop () =
                    if not !(info.stop) then (
                      (try Eio.Time.sleep clock sse_ping_interval_s
                       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                         if is_cancelled exn then raise exn;
                         Log.Server.error "ping sleep error: %s"
                           (Printexc.to_string exn));
                      (try
                         if info.closed then
                           stop_sse_session info.session_id
                         else if not !(info.stop) then
                           if not (send_raw info ": ping\n\n") then
                             Log.Server.debug "SSE ping send failed for session %s"
                               info.session_id
                       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                         if is_cancelled exn then raise exn;
                         Log.Server.error "ping send error: %s"
                           (Printexc.to_string exn);
                         stop_sse_session info.session_id);
                      loop ())
                  in
                   try loop () with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                     if is_cancelled exn then ()
                     else
                       Log.Server.error "ping loop error: %s"
                         (Printexc.to_string exn))
          | Error msg ->
              Log.Server.debug "SSE runtime unavailable for session %s: %s"
                session_id msg);
          let client_count = Sse.client_count () in
          if client_count > Sse.max_clients / 2 then
            Log.Server.info "SSE connected: %s (active: %d/%d)"
              session_id client_count Sse.max_clients)))


let handle_get_operator_mcp ~deps request reqd =
  let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
  let protocol_version = get_protocol_version_for_session ~session_id request in
  let base_path = deps.get_base_path () in
  match deps.verify_operator_mcp_auth ~base_path request with
  | Error msg ->
      respond_mcp_auth_error ~deps request reqd ~session_id ~protocol_version
        msg
  | Ok () ->
      handle_get_mcp ~deps ~profile:Operator_remote request reqd

let handle_post_messages ~deps request reqd =
  if not (deps.is_ready ()) then
    respond_not_ready ~deps request reqd
  else
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
      safe_respond_with_string reqd response body
  | Some session_id when not (Mcp_session.is_valid session_id) ->
      let body = "invalid session_id" in
      let headers =
        Httpun.Headers.of_list
          (("content-length", string_of_int (String.length body))
          :: (legacy_headers @ deps.cors_headers origin))
      in
      let response = Httpun.Response.create ~headers `Bad_request in
      safe_respond_with_string reqd response body
  | Some session_id ->
      let protocol_version = get_protocol_version_for_session ~session_id request in
      let auth_token = deps.auth_token_from_request request in
      let base_path = deps.get_base_path () in
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
              | Ok runtime ->
                  let sw = runtime.sw in
                  Eio.Fiber.fork ~sw (fun () ->
                  let body_with_agent =
                    body_with_canonical_http_actor ~base_path ~auth_token
                      request body_str
                  in
                  let internal_keeper_runtime =
                    Server_auth.is_verified_internal_keeper_request
                      ~base_path request
                  in
                  let response_json =
                    runtime.handle_request ~mcp_session_id:session_id
                      ?auth_token ~internal_keeper_runtime body_with_agent
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
                  safe_respond_with_string reqd response "")))

let handle_delete_mcp ~deps ?(profile = Full) request reqd =
  if not (deps.is_ready ()) then
    respond_not_ready ~deps request reqd
  else
  let base_path = deps.get_base_path () in
  let auth_result =
    match profile with
    | Full | Managed_agent ->
        deps.verify_mcp_auth ~base_path request
    | Operator_remote ->
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
              safe_respond_with_string reqd response msg
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
                  safe_respond_with_string reqd response body
              | Ok () ->
               let protocol_version = get_protocol_version request in
               let sse_active_before_stop = is_active_sse_session session_id in
               stop_sse_session session_id;
               Sse.unregister session_id;
               let resource_cleanup =
                 match request_runtime_result deps with
                 | Ok runtime ->
                     runtime.clear_resource_subscriptions_for_session session_id;
                     "cleared"
                 | Error msg ->
                     Log.Server.debug
                       "skip resource subscription cleanup for session %s: %s"
                       session_id msg;
                     "skipped_runtime_unavailable"
               in
               forget_mcp_session session_id;
               Log.info ~ctx:"mcp_transport"
                 "Session terminated: %s reason=client_delete profile=%s \
                  protocol_version=%s sse_active_before_stop=%b \
                  resource_cleanup=%s"
                 session_id (profile_label profile) protocol_version
                 sse_active_before_stop resource_cleanup;
              let headers =
                Httpun.Headers.of_list
                  (("content-length", "0") :: mcp_headers session_id protocol_version)
              in
              let response = Httpun.Response.create ~headers `No_content in
              safe_respond_with_string reqd response ""))
      | None ->
          let body = "Mcp-Session-Id required" in
          let headers =
            Httpun.Headers.of_list
              [ ("content-length", string_of_int (String.length body)) ]
          in
          let response = Httpun.Response.create ~headers `Bad_request in
          safe_respond_with_string reqd response body)
