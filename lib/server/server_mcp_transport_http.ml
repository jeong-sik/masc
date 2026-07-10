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
    ?otel_mcp_protocol_version:string ->
    ?otel_transport_context:Otel_dispatch_hook.transport_context ->
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

(* RFC-0100 PR-2: chunked first-flush variant of safe_respond_with_string.
   Writes [body] via [Httpun.Reqd.respond_with_streaming] so the response
   uses [Transfer-Encoding: chunked] framing instead of
   [Content-Length: N]. Body bytes and headers (other than transfer-encoding /
   content-length) are byte-identical to the non-chunked form, so well-behaved
   JSON clients are unaffected.

   The 50 ms first-flush budget is implicit at PR-2 — current sync code
   paths compute the body in well under 50 ms, so the first (and only)
   chunk flushes immediately. The placeholder-stub flow for slow paths
   is RFC-0100 PR-3's auto-upgrade work, not this PR.

   Same race-safe wrapping as {!safe_respond_with_string} — the
   2026-05-05 OAS cancel-race exception class is caught and downgraded
   to a WARN. *)
let safe_respond_chunked reqd response body =
  try
    let writer = Httpun.Reqd.respond_with_streaming reqd response in
    Httpun.Body.Writer.write_string writer body ;
    Httpun.Body.Writer.close writer
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Failure msg ->
      Log.Server.warn
        "[mcp-http-post] respond_chunked skipped (reqd invalid state; \
         2026-05-05 OAS cancel race): %s"
        msg
  | exn ->
      Log.Server.warn
        "[mcp-http-post] respond_chunked unexpected exception: %s"
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

(* RFC-0100 PR-3: extract [params.name] from a [tools/call] body for
   streaming-registry lookup. Returns [None] when the body is malformed,
   not a [tools/call], or missing [params.name]. *)
let body_tools_call_name body_str =
  try
    match Yojson.Safe.from_string body_str with
    | `Assoc fields -> (
        match List.assoc_opt "params" fields with
        | Some (`Assoc params) -> (
            match List.assoc_opt "name" params with
            | Some (`String name) -> Some name
            | _ -> None)
        | _ -> None)
    | _ -> None
  with Yojson.Json_error _ -> None

let session_cookie_header = Server_mcp_transport_http_headers.session_cookie_header

let session_cookie_headers = Server_mcp_transport_http_headers.session_cookie_headers

let sse_headers = Server_mcp_transport_http_headers.sse_headers

let sse_stream_headers = Server_mcp_transport_http_headers.sse_stream_headers

let stream_post_sse_headers ~deps ~origin ~session_id ~protocol_version =
  Httpun.Headers.of_list
    ([
        ("content-type", Http_negotiation.sse_content_type);
        ("cache-control", "no-cache");
        ("connection", "close");
        ("x-accel-buffering", "no");
      ]
      @ session_cookie_headers protocol_version session_id
      @ mcp_headers session_id protocol_version
      @ deps.cors_headers origin)

let stream_post_sse_start ~deps ~origin ~session_id ~protocol_version
    reqd =
  let headers =
    stream_post_sse_headers ~deps ~origin ~session_id ~protocol_version
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
        if not (Atomic.get info.stop) then (
          (try
             Eio.Time.sleep clock post_sse_keepalive_interval_s
           with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn -> Log.Server.warn "SSE keepalive sleep failed for session %s: %s"
                    info.session_id (Printexc.to_string exn));
          if Atomic.get info.closed then
            close_sse_conn info
          else if not (Atomic.get info.stop) then
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
  | Some ("tools/call", true) -> (
      (* RFC-0100 PR-3: the [tools/call] request only upgrades to SSE
         framing when the named tool is on the streaming registry
         ([Server_mcp_streaming_tools]). Tools outside the registry stay on
         the RFC-0100 PR-2 chunked-JSON default. Returns [false] when
         [params.name] is missing — a malformed body never triggers the
         streaming branch. *)
      match body_tools_call_name body_str with
      | Some name -> Server_mcp_streaming_tools.is_streaming_capable name
      | None -> false)
  | _ -> false

let inject_agent_name_into_body ?(rewrite_existing = false) ?(strip_token = false)
    ~agent_name body_str =
  Server_mcp_actor_injection.inject_agent_name_into_body ~rewrite_existing
    ~strip_token ~agent_name body_str

let body_with_canonical_http_actor ~base_path ~auth_token request body_str =
  let actor = Server_auth.dashboard_actor_for_request ~base_path request in
  Server_mcp_actor_injection.reduce ~actor ~auth_token body_str

let authorize_mcp_profile_admission ~base_path ~profile request =
  let permission =
    match profile with
    | Full | Managed_agent -> Masc_domain.CanReadState
    | Operator_remote -> Masc_domain.CanAdmin
  in
  Server_auth.authorize_token_bound_admission_request
    ~base_path ~permission request

module Mcp_sse_owner = Server_mcp_transport_http_sse_owner

type mcp_sse_owner_lease = Mcp_sse_owner.lease

let validate_mcp_session_owner_for_request =
  Mcp_sse_owner.validate_mcp_session_owner_for_request

let bind_mcp_session_owner_if_initialize_succeeded =
  Mcp_sse_owner.bind_mcp_session_owner_if_initialize_succeeded

let validate_mcp_sse_session_owner_for_request =
  Mcp_sse_owner.validate_mcp_sse_session_owner_for_request

let claim_mcp_sse_session_owner_for_request =
  Mcp_sse_owner.claim_mcp_sse_session_owner_for_request

let activate_mcp_sse_owner_lease = Mcp_sse_owner.activate
let discard_previous_mcp_sse_owner_lease = Mcp_sse_owner.discard_previous
let release_mcp_sse_owner_lease = Mcp_sse_owner.release
let ensure_sse_backing_session_for_owner =
  Mcp_sse_owner.ensure_backing_session_for_owner
let forget_mcp_session = Mcp_sse_owner.forget_mcp_session
let respond_mcp_session_owner_forbidden ~deps request reqd ~session_id
      ~protocol_version msg =
  let body =
    error_body ~id:`Null ~code:Mcp_error_code.Auth_error msg
    |> Yojson.Safe.to_string
  in
  let headers =
    Httpun.Headers.of_list
      (("content-length", string_of_int (String.length body))
       :: json_headers ~deps session_id protocol_version (deps.get_origin request))
  in
  safe_respond_with_string reqd
    (Httpun.Response.create ~headers `Forbidden)
    body

let handle_post_mcp ~deps ?(profile = Full) request reqd =
  (* Readiness gate: reject before session/auth if server state is not ready *)
  if not (deps.is_ready ()) then
    respond_not_ready ~deps request reqd
  else
  let session_id_opt = get_session_id_any request in
  let session_id =
    match session_id_opt with
    | Some sid -> sid
    | None -> Mcp_session.generate ()
  in
  let context =
    Server_mcp_request_context.make ~session_id_opt
      ~generated_session_id:session_id
      ~auth_token:(deps.auth_token_from_request request)
      ~protocol_version:(get_protocol_version_for_session ~session_id request)
      ~origin:(deps.get_origin request) ~base_path:(deps.get_base_path ())
  in
  let session_id = context.session_id in
  let auth_token = context.auth_token in
  let protocol_version = context.protocol_version in
  let origin = context.origin in
  let base_path = context.base_path in
  let auth_result = authorize_mcp_profile_admission ~base_path ~profile request in
  let open Result.Syntax in
  ignore (
    let* admission =
      match auth_result with
      | Ok admission -> Ok admission
      | Error err ->
          respond_mcp_error ~code:Mcp_error_code.Auth_error ~deps request reqd
            ~session_id ~protocol_version
            (Masc_domain.masc_error_to_string err);
          Error ()
    in
    let* () =
      match
        validate_mcp_session_owner_for_request ~session_id
          ~requester:admission.identity
      with
      | Ok () -> Ok ()
      | Error msg ->
          respond_mcp_session_owner_forbidden ~deps request reqd ~session_id
            ~protocol_version msg;
          Error ()
    in
    let* () =
      match validate_mcp_session_profile ~profile session_id with
      | Ok () -> Ok ()
      | Error msg ->
          let body =
            Mcp_error_code.jsonrpc_error_body Invalid_request ~message:msg
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
            Mcp_error_code.jsonrpc_error_body Invalid_request ~message:msg
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
    let otel_transport_context =
      Otel_dispatch_hook.http_transport_context ~protocol_version:"1.1"
    in
    remember_mcp_profile ~otel_transport_context session_id profile;
    Ok (Http.Request.read_body_async reqd (fun body_str ->
      ignore (
      let* post_context =
        match
          Server_mcp_request_context.decide_post_body ~request ~context
            ~session_is_known:(is_known_session session_id)
            body_str
        with
        | Ok decision -> Ok decision
        | Error (Server_mcp_request_context.Session_required msg) ->
            let body =
              Mcp_error_code.jsonrpc_error_body Invalid_request ~message:msg
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
        | Error (Server_mcp_request_context.Unknown_session msg) ->
            let new_session_id = Mcp_session.generate () in
            let body =
              Mcp_error_code.jsonrpc_error_body Invalid_request ~message:msg
            in
            let headers =
              Httpun.Headers.of_list
                (("content-length", string_of_int (String.length body))
                :: json_headers ~deps new_session_id protocol_version
                     origin)
            in
            safe_respond_with_string reqd
              (Httpun.Response.create ~headers `Not_found)
              body;
            Error ()
        | Error (Server_mcp_request_context.Invalid_accept msg) ->
            let body =
              Yojson.Safe.to_string
                (`Assoc
                  [
                    ("jsonrpc", `String "2.0");
                    ( "error",
                      `Assoc
                        [
                          ("code", `Int (Mcp_error_code.to_wire_code Invalid_request));
                          ("message", `String msg);
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
        | Error (Server_mcp_request_context.Header_mismatch msg) ->
            let body =
              Yojson.Safe.to_string
                (`Assoc
                  [
                    ("jsonrpc", `String "2.0");
                    ( "error",
                      `Assoc
                        [
                          ("code", `Int (-32001));
                          ("message", `String msg);
                        ] );
                    ("id", `Null);
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
      in
      let accept_mode = post_context.accept_mode in
      let* runtime =
        match request_runtime_result deps with
        | Ok r -> Ok r
        | Error msg ->
            respond_mcp_error ~code:Mcp_error_code.Internal_error ~deps request reqd
              ~session_id ~protocol_version msg;
            Error ()
      in
      let sw = runtime.sw in
      let clock = runtime.clock in
      Ok (Eio.Fiber.fork ~sw (fun () ->
                            let otel_transport_context =
                              Otel_dispatch_hook.http_transport_context
                                ~protocol_version:"1.1"
                            in
                            let response_protocol_version =
                              match protocol_version_from_body body_str with
                              | Some v -> v
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
                                    reqd
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
                                  ~otel_mcp_protocol_version:protocol_version
                                  ~otel_transport_context
                                  ~internal_keeper_runtime body_with_agent
                              in
                              let response_json =
                                match
                                  bind_mcp_session_owner_if_initialize_succeeded
                                    session_id
                                    ~requester:admission.identity
                                    ~request_body:body_str
                                    ~response_json
                                with
                                | Ok () -> response_json
                                | Error msg ->
                                    Log.Auth.warn
                                      "MCP initialize owner bind rejected for session %s: %s"
                                      session_id msg;
                                    Mcp_transport_protocol.make_error
                                      ~id:(Option.value ~default:`Null response_id)
                                      (Mcp_error_code.to_wire_code
                                         Mcp_error_code.Auth_error)
                                      msg
                              in
                              remember_protocol_version_if_initialize_succeeded
                                ~otel_transport_context
                                session_id
                                ~request_body:body_str
                                ~response_json;
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
                                        :: mcp_headers session_id protocol_version)
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
                                        :: json_headers ~deps session_id
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
                                        :: sse_headers ~deps session_id
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
                                        :: mcp_headers session_id protocol_version)
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
                                        :: json_headers ~deps session_id
                                            protocol_version origin)
                                    in
                                    let response =
                                      Httpun.Response.create ~headers `Bad_request
                                    in
                                    safe_respond_with_string reqd response
                                      body
                                | json ->
                                    (* RFC-0100 PR-2: chunked first-flush.
                                       Body bytes + Content-Type identical
                                       to pre-PR behaviour; only the
                                       framing changes (content-length →
                                       transfer-encoding: chunked).
                                       Well-behaved JSON clients are
                                       unaffected; this opt-out can be
                                       re-introduced via env knob if a
                                       legacy client surface needs it. *)
                                    let body = Yojson.Safe.to_string json in
                                    let headers =
                                      Httpun.Headers.of_list
                                        (("transfer-encoding", "chunked")
                                        :: json_headers ~deps session_id
                                            protocol_version origin)
                                    in
                                    let response =
                                      Httpun.Response.create ~headers `OK
                                    in
                                    safe_respond_chunked reqd response body
                            with
                            | Eio.Cancel.Cancelled _ as e -> raise e
                            | exn ->
                                (match !inline_sse with
                                | Some info ->
                                    stream_post_sse_json info
                                      (error_body ~code:Mcp_error_code.Internal_error ?id:response_id
                                         ("Internal error: "
                                        ^ Printexc.to_string exn));
                                    stream_post_sse_finish info
                                | None ->
                                    let protocol_version =
                                      get_protocol_version_for_session ~session_id
                                        request
                                    in
                                    respond_mcp_error ~code:Mcp_error_code.Internal_error ~deps request reqd
                                      ~session_id ~protocol_version
                                      ("Internal error: "
                                     ^ Printexc.to_string exn))))))))

let handle_get_mcp ~deps ?(profile = Full) ?(sse_kind = Sse.Agent_stream)
    request reqd =
  if not (deps.is_ready ()) then
    respond_not_ready ~deps request reqd
  else
    let origin = deps.get_origin request in
    let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
    let protocol_version =
      get_protocol_version_for_session ~session_id request
    in
    let base_path = deps.get_base_path () in
    let auth_result =
      authorize_mcp_profile_admission ~base_path ~profile request
    in
    let last_event_id = get_last_event_id request in
    let open Result.Syntax in
    ignore
      (let* admission =
         match auth_result with
         | Ok admission -> Ok admission
         | Error err ->
             respond_mcp_error ~code:Mcp_error_code.Auth_error ~deps request
               reqd ~session_id ~protocol_version
               (Masc_domain.masc_error_to_string err);
             Error ()
       in
       let* () =
         match
           validate_mcp_sse_session_owner_for_request ~session_id ~sse_kind
             ~requester:admission.identity
         with
         | Ok () -> Ok ()
         | Error msg ->
             respond_mcp_session_owner_forbidden ~deps request reqd
               ~session_id ~protocol_version msg;
             Error ()
       in
       let* () =
         match validate_mcp_session_profile ~profile session_id with
         | Ok () -> Ok ()
         | Error msg ->
             let headers =
               Httpun.Headers.of_list
                 (("content-length", string_of_int (String.length msg))
                 :: json_headers ~deps session_id protocol_version origin)
             in
             let response = Httpun.Response.create ~headers `Conflict in
             safe_respond_with_string reqd response msg;
             Error ()
       in
       let* () =
         match validate_protocol_version_continuity ~session_id request with
         | Ok () -> Ok ()
         | Error msg ->
             let body =
               Mcp_error_code.jsonrpc_error_body Invalid_request ~message:msg
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
       let otel_transport_context =
         Otel_dispatch_hook.http_transport_context ~protocol_version:"1.1"
       in
       if is_known_session session_id then
         remember_mcp_profile ~otel_transport_context session_id profile;
       let* () =
         match check_sse_connect_guard session_id with
         | Ok () -> Ok ()
         | Error (reason, retry_after_s) ->
             respond_sse_rate_limited ~deps ~origin ~session_id
               ~protocol_version ~reason ~retry_after_s reqd;
             Error ()
       in
       let* owner_lease =
         match
           claim_mcp_sse_session_owner_for_request ~session_id ~sse_kind
             ~requester:admission.identity
         with
         | Ok lease -> Ok lease
         | Error msg ->
             respond_mcp_session_owner_forbidden ~deps request reqd
               ~session_id ~protocol_version msg;
             Error ()
       in
       let release_owner_lease () =
         release_mcp_sse_owner_lease owner_lease
       in
       let registered_client_id = ref None in
       let cleanup_failed_setup () =
         match !registered_client_id with
         | Some client_id ->
             Sse.unregister_if_current session_id client_id
         | None -> release_owner_lease ()
       in
       try
         let* () =
           match
             ensure_sse_backing_session_for_owner ~session_id
               ~requester:admission.identity
           with
           | Ok () -> Ok ()
           | Error msg ->
               release_owner_lease ();
               respond_mcp_session_owner_forbidden ~deps request reqd
                 ~session_id ~protocol_version msg;
               Error ()
         in
         (* Ownership is established before either operation.  Clearing the old
            hook prevents an intentional same-owner reconnect from running the
            prior connection's cleanup against the replacement.  Preserve the
            successful connect guard while closing the old writer so concurrent
            reconnects cannot bypass the guard through [stop_sse_session]. *)
         Sse.clear_disconnect_hook session_id;
         stop_sse_session_preserve_guard session_id;
         discard_previous_mcp_sse_owner_lease owner_lease;
         if Option.is_some last_event_id then
           Transport_metrics.inc_sse_reconnect ();
         let auth =
           { Sse.config = base_path; token = Some admission.auth_token }
         in
         match
           Sse.register ~kind:sse_kind ~auth session_id
             ~last_event_id:(Option.value ~default:0 last_event_id)
             ~on_disconnect:(fun () ->
               release_owner_lease ();
               stop_sse_session_preserve_guard session_id)
         with
         | Error reg_err ->
             release_owner_lease ();
             let msg = Sse.registration_error_to_string reg_err in
             Log.Server.warn "%s" msg;
             respond_sse_register_error ~deps ~origin ~protocol_version reqd msg;
             Error ()
         | Ok (client_id, event_stream, evicted) ->
           registered_client_id := Some client_id;
           let headers =
             Httpun.Headers.of_list
               (sse_stream_headers ~deps session_id protocol_version origin)
           in
           let response = Httpun.Response.create ~headers `OK in
           let writer = Httpun.Reqd.respond_with_streaming reqd response in
           let mutex = Eio.Mutex.create () in
           (match evicted with
           | Some evicted_sid ->
               (* RFC-0099 PR-3: cap-exceeded eviction publishes typed
                  close frame + Evict/Close event pair. *)
               stop_sse_session_evict evicted_sid
                 ~reason:Session_lifecycle_event.Cap_exceeded
           | None -> ());
           let info = make_sse_conn ~session_id ~client_id ~writer ~mutex () in
           register_sse_conn ~session_id ~info;
           let* () =
             match activate_mcp_sse_owner_lease owner_lease with
             | Ok () -> Ok ()
             | Error msg ->
                 cleanup_failed_setup ();
                 Log.Server.warn
                   "SSE owner activation failed after connection publication for %s: %s"
                   session_id msg;
                 Error ()
           in
           if not (send_raw info (sse_prime_event ())) then
             Log.Server.debug "SSE prime send failed for session %s"
               info.session_id;
           (match last_event_id with
           | Some last_id ->
               let missed = Sse.get_events_after_for_kind sse_kind last_id in
               List.iter
                 (fun ev ->
                   if not (send_raw info ev) then
                     Log.Server.debug
                       "SSE replay send failed for session %s"
                       info.session_id)
                 missed
           | None -> ());
           (match deps.get_runtime_result () with
           | Ok runtime ->
               let sw = runtime.sw in
               let clock = runtime.clock in
               run_sse_pumps ~sw ~stop_promise:info.stop_promise
                 ~drain:(fun () ->
                   let rec drain () =
                     let event = Eio.Stream.take event_stream in
                     (try
                        if
                          not
                            (Atomic.get info.closed || Atomic.get info.stop)
                        then if not (send_raw info event) then
                          Log.Server.debug
                            "SSE drain send failed for session %s"
                            info.session_id
                      with
                     | Eio.Cancel.Cancelled _ as e -> raise e
                     | exn ->
                         Log.Server.error "drain write error: %s"
                           (Printexc.to_string exn);
                         stop_sse_session_preserve_guard info.session_id);
                     if not (Atomic.get info.stop) then drain ()
                   in
                   try drain () with
                   | Eio.Cancel.Cancelled _ as e -> raise e
                   | exn ->
                       Log.Server.error "drain loop error: %s"
                         (Printexc.to_string exn))
                 ~ping:(fun () ->
                   let is_cancelled = function
                     | Eio.Cancel.Cancelled _ -> true
                     | _ -> false
                   in
                   let rec loop () =
                     if not (Atomic.get info.stop) then (
                       (try Eio.Time.sleep clock sse_ping_interval_s with
                       | Eio.Cancel.Cancelled _ as e -> raise e
                       | exn ->
                           if is_cancelled exn then raise exn;
                           Log.Server.error "ping sleep error: %s"
                             (Printexc.to_string exn));
                       (try
                          if Atomic.get info.closed then
                            stop_sse_session_preserve_guard info.session_id
                          else if not (Atomic.get info.stop) then
                            if not (send_raw info ": ping\n\n") then
                              Log.Server.debug
                                "SSE ping send failed for session %s"
                                info.session_id
                        with
                       | Eio.Cancel.Cancelled _ as e -> raise e
                       | exn ->
                           if is_cancelled exn then raise exn;
                           Log.Server.error "ping send error: %s"
                             (Printexc.to_string exn);
                           stop_sse_session_preserve_guard info.session_id);
                       loop ())
                   in
                   try loop () with
                   | Eio.Cancel.Cancelled _ as e -> raise e
                   | exn ->
                       if not (is_cancelled exn) then
                         Log.Server.error "ping loop error: %s"
                           (Printexc.to_string exn))
           | Error msg ->
               Log.Server.error
                 "SSE runtime unavailable after registration for session %s: %s"
                 session_id msg;
               stop_sse_session_preserve_guard session_id);
           let client_count = Sse.client_count () in
           if client_count > Sse.max_clients / 2 then
             Log.Server.info "SSE connected: %s (active: %d/%d)" session_id
               client_count Sse.max_clients;
           Ok ()
       with
       | Eio.Cancel.Cancelled _ as e ->
           cleanup_failed_setup ();
           raise e
       | exn ->
           cleanup_failed_setup ();
           raise exn)


let handle_get_operator_mcp ~deps request reqd =
  handle_get_mcp ~deps ~profile:Operator_remote request reqd

let handle_delete_mcp ~deps ?(profile = Full) request reqd =
  if not (deps.is_ready ()) then
    respond_not_ready ~deps request reqd
  else
  let base_path = deps.get_base_path () in
  let auth_result = authorize_mcp_profile_admission ~base_path ~profile request in
  match auth_result with
  | Error err ->
      let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
      let protocol_version = get_protocol_version_for_session ~session_id request in
      respond_mcp_error ~code:Mcp_error_code.Auth_error ~deps request reqd ~session_id ~protocol_version
        (Masc_domain.masc_error_to_string err)
  | Ok admission -> (
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
              let protocol_version =
                get_protocol_version_for_session ~session_id request
              in
              match
                authorize_mcp_session_delete ~session_id
                  ~requester:admission.identity
              with
              | Error msg ->
                  respond_mcp_session_owner_forbidden ~deps request reqd
                    ~session_id ~protocol_version msg
              | Ok () -> (
              match validate_protocol_version_continuity ~session_id request with
              | Error msg ->
                  let body =
                    Mcp_error_code.jsonrpc_error_body Invalid_request ~message:msg
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
               forget_mcp_session session_id;
               stop_sse_session session_id;
               Sse.unregister session_id;
               ignore (Session.McpSessionStore.remove session_id);
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
               Log.Mcp_transport.info "Session terminated: %s reason=client_delete profile=%s \
                  protocol_version=%s sse_active_before_stop=%b \
                  resource_cleanup=%s"
                 session_id (profile_label profile) protocol_version
                 sse_active_before_stop resource_cleanup;
              let headers =
                Httpun.Headers.of_list
                  (("content-length", "0") :: mcp_headers session_id protocol_version)
              in
              let response = Httpun.Response.create ~headers `No_content in
              safe_respond_with_string reqd response "")))
      | None ->
          let body = "Mcp-Session-Id required" in
          let headers =
            Httpun.Headers.of_list
              [ ("content-length", string_of_int (String.length body)) ]
          in
          let response = Httpun.Response.create ~headers `Bad_request in
          safe_respond_with_string reqd response body)
