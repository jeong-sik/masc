(** Http_server_eio - Eio-native HTTP server using httpun-eio

    Conflict-free with httpun-ws-eio (no cohttp 6.x dependency).
    Phase 2 of Eio migration.

    @see <https://github.com/anmonteiro/httpun> httpun documentation
*)

(** Server configuration *)
type config = {
  port: int;
  host: string;
  max_connections: int;
}

let default_config = {
  port = Env_config_core.masc_http_port_int ();
  host =
    Env_config_core.get_string
      ~default:Masc_network_defaults.masc_http_default_host
      "MASC_HTTP_HOST";
  max_connections = Env_config_core.get_int ~default:128 "MASC_HTTP_MAX_CONNECTIONS";
}

(** HTTP request handler type *)
type request_handler =
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  unit

(** Compact Protocol v4: HTTP Compression with Dictionary Support

    For small messages (32-2048 bytes), trained dictionary compression
    achieves +70%p better compression than standard zstd.

    Multi-format dictionary trained on:
    - MASC broadcasts, task updates, lock events
    - MCP JSON-RPC (tools/call, results, errors)
    - HTTP API responses (status, data, error)
    - Slack-style messages
*)
module Compression = struct
  (** Check if client accepts zstd encoding *)
  let accepts_zstd (request : Httpun.Request.t) : bool =
    match Httpun.Headers.get request.headers "accept-encoding" with
    | Some accept_encoding ->
        String.lowercase_ascii accept_encoding
        |> fun s -> String.split_on_char ',' s
        |> List.exists (fun enc ->
             String.trim enc |> String.lowercase_ascii |> fun e ->
             e = "zstd" || String.sub e 0 (min 4 (String.length e)) = "zstd")
    | None -> false

  (** Check if client accepts dictionary-enhanced zstd *)
  let accepts_zstd_dict (request : Httpun.Request.t) : bool =
    match Httpun.Headers.get request.headers "accept-encoding" with
    | Some accept_encoding ->
        String.lowercase_ascii accept_encoding
        |> String.split_on_char ','
        |> List.exists (fun enc ->
             let e = String.trim enc in
             e = "zstd-dict" || e = "zstd;dict=masc")
    | None -> false

  (** Compress with dictionary if beneficial
      @return (compressed_data, encoding_name option) *)
  let compress ?(level = 3) (data : string) : string * string option =
    match Compression_codec.compress ~level data with
    | Compression_codec.Unchanged payload -> (payload, None)
    | Compression_codec.Compressed { payload; encoding } ->
        (payload, Some (Compression_codec.content_encoding encoding))

  (** Legacy: Standard zstd without dictionary *)
  let compress_zstd ?(level = 3) (data : string) : (string * bool) =
    if String.length data < 256 then
      (data, false)
    else
      try
        let compressed = Zstd.compress ~level data in
        if String.length compressed < String.length data then
          (compressed, true)
        else
          (data, false)
      with Zstd.Error _ -> (data, false)
end

(** Late-response failure classifier (#13059).

    [Failure] string-literal patterns are fragile (warning 52) — the
    upstream library is free to change them.  We accept that risk
    because:

    - These exact strings ARE the public API surface for the upstream
      libraries (httpun + the [Faraday]-style writer).  Library
      authors treat the message text as user-facing diagnostics.
    - This module is a defensive log-and-skip path only — if a
      future library version reshapes the message we lose the
      log-downgrade and revert to the fallback 500 attempt, not a
      crash.
    - Substring-match guards (via [String.starts_with] /
      [String.equal]) localise the dependency rather than spreading
      the literal across many call sites. *)
[@@@warning "-52"]
module Late_response = struct
  let classify_write_failure = function
    | Failure msg
      when String.starts_with msg
             ~prefix:"httpun.Reqd.respond_with_string: invalid state" ->
        Some msg
    | Failure msg when String.equal msg "cannot write to closed writer" ->
        Some "cannot write to closed writer"
    | _ -> None
end
[@@@warning "+52"]

(** [safe_respond_with_string reqd response body] wraps
    [Httpun.Reqd.respond_with_string] to silently discard the
    [Failure "...invalid state..."] that httpun raises when the
    request descriptor has already transitioned into its error-
    handling path (e.g. client disconnected during a long OAS
    turn and httpun's own error_handler fired first — the
    2026-05-05 cycle9 FATAL race).

    [Eio.Cancel.Cancelled] is always re-raised so structured
    concurrency cancellation is never swallowed.

    Recognized late-response failures route through the shared
    [Late_response.classify_write_failure] SSOT (#13082 review,
    copilot thread on safe_respond_with_string drift) so the
    classifier and this helper cannot diverge silently — anything
    the classifier owns is logged identically here.  Genuinely
    unexpected exceptions still log at WARN. *)
let safe_respond_with_string reqd response body =
  try Httpun.Reqd.respond_with_string reqd response body
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> (
      match Late_response.classify_write_failure exn with
      | Some msg ->
          Log.Http.warn
            "[http-eio] respond_with_string skipped (reqd already in \
             error-handling state; classifier match — 2026-05-05 OAS \
             cancellation race): %s" msg
      | None ->
          Log.Http.warn
            "[http-eio] respond_with_string unexpected exception: %s"
            (Printexc.to_string exn))

(** Simple response helpers *)
module Response = struct
  let html_cache_control = "no-store, max-age=0, must-revalidate"

  let text ?(status = `OK) body reqd =
    let headers = Httpun.Headers.of_list ([
      ("content-type", "text/plain; charset=utf-8");
      ("content-length", string_of_int (String.length body));
    ]) in
    let response = Httpun.Response.create ~headers status in
    safe_respond_with_string reqd response body

  let html ?(status = `OK) ?(headers = []) body reqd =
    let base_headers = [
      ("content-type", "text/html; charset=utf-8");
      ("content-length", string_of_int (String.length body));
    ] in
    let response = Httpun.Response.create
      ~headers:(Httpun.Headers.of_list (base_headers @ headers))
      status
    in
    safe_respond_with_string reqd response body

  let bytes ?(status = `OK) ?(headers = []) ~content_type body reqd =
    let base_headers = [
      ("content-type", content_type);
      ("content-length", string_of_int (String.length body));
    ] in
    let response = Httpun.Response.create
      ~headers:(Httpun.Headers.of_list (base_headers @ headers))
      status
    in
    safe_respond_with_string reqd response body

  (** JSON response with optional zstd compression (dictionary-enhanced)

      Uses trained multi-format dictionary for small messages (32-2048 bytes)
      achieving ~70% compression vs ~6% with standard zstd.

      @param compress Enable compression if client accepts (default: true)
      @param request Optional request to check Accept-Encoding header *)
  let json ?(status = `OK) ?(compress = true) ?(extra_headers = []) ?request body reqd =
    let should_compress =
      compress &&
      match request with
      | Some req -> Compression.accepts_zstd req
      | None -> false
    in
    let final_body, encoding =
      if should_compress then
        (* Use dictionary-based compression for better small message handling *)
        Compression.compress body
      else
        (body, None)
    in
    let base_headers = [
      ("content-type", "application/json; charset=utf-8");
      ("content-length", string_of_int (String.length final_body));
      ("vary", "Accept-Encoding");
    ] in
    let headers = match encoding with
      | Some enc -> ("content-encoding", enc) :: base_headers
      | None -> base_headers
    in
    let headers = extra_headers @ headers in
    let response = Httpun.Response.create ~headers:(Httpun.Headers.of_list headers) status in
    safe_respond_with_string reqd response final_body

  (** Sunset headers for deprecated endpoints per RFC 8594.
      [date] must be an HTTP-date (RFC 7231 S7.1.1.1), e.g. ["Sat, 01 Jun 2026 00:00:00 GMT"].
      Usage: [Response.json ~extra_headers:(sunset_headers ~date ~successor) ...] *)
  let sunset_headers ~date ?successor () =
    let base = [
      ("Sunset", date);
      ("Deprecation", "true");
    ] in
    match successor with
    | Some url -> ("Link", Printf.sprintf "<%s>; rel=\"successor-version\"" url) :: base
    | None -> base

  (** Legacy JSON response without compression check (backwards compatible) *)
  let json_raw ?(status = `OK) body reqd =
    let headers = Httpun.Headers.of_list ([
      ("content-type", "application/json; charset=utf-8");
      ("content-length", string_of_int (String.length body));
    ]) in
    let response = Httpun.Response.create ~headers status in
    safe_respond_with_string reqd response body

  (** HTML response with ETag and conditional 304 support.
      For static HTML that only changes on rebuild (e.g. dashboard).
      Uses zstd compression when client accepts it.
      @param etag ETag value (typically version hash)
      @param request Request to check If-None-Match and Accept-Encoding *)
  let html_cached ?(status = `OK) ~etag ~request body reqd =
    let etag_value = "\"" ^ etag ^ "\"" in
    (* Check If-None-Match for 304 *)
    let if_none_match = Httpun.Headers.get request.Httpun.Request.headers "if-none-match" in
    match if_none_match with
    | Some inm when String.equal inm etag_value ->
        let headers = Httpun.Headers.of_list [
          ("etag", etag_value);
          ("cache-control", html_cache_control);
        ] in
        let response = Httpun.Response.create ~headers `Not_modified in
        safe_respond_with_string reqd response ""
    | _ ->
        (* Serve full response, with compression if possible *)
        let accepts_zstd = Compression.accepts_zstd request in
        let final_body, encoding =
          if accepts_zstd then
            let (compressed, did_compress) = Compression.compress_zstd ~level:3 body in
            if did_compress then (compressed, Some "zstd") else (body, None)
          else (body, None)
        in
        let base_headers = [
          ("content-type", "text/html; charset=utf-8");
          ("content-length", string_of_int (String.length final_body));
          ("etag", etag_value);
          ("cache-control", html_cache_control);
          ("vary", "Accept-Encoding");
        ] in
        let headers = match encoding with
          | Some enc -> ("content-encoding", enc) :: base_headers
          | None -> base_headers
        in
        let response = Httpun.Response.create ~headers:(Httpun.Headers.of_list headers) status in
        safe_respond_with_string reqd response final_body

  let not_found reqd =
    text ~status:`Not_found "404 Not Found" reqd

  let method_not_allowed reqd =
    text ~status:`Method_not_allowed "405 Method Not Allowed" reqd

  let internal_error msg reqd =
    text ~status:`Internal_server_error ("500 Internal Server Error: " ^ msg) reqd
end

(** Request helpers *)
module Request = struct
  (** Read request body - loops until EOF (httpun requires repeated schedule_read) *)
  let default_max_body_bytes = 20 * 1024 * 1024

  let parse_positive_int value =
    match int_of_string_opt value with
    | Some v when v > 0 -> Some v
    | _ -> None

  let max_body_bytes =
    let from_env name =
      match Sys.getenv_opt name with
      | Some v -> parse_positive_int v
      | None -> None
    in
    match from_env "MASC_MCP_MAX_BODY_BYTES" with
    | Some v -> v
    | None ->
        (match from_env "MCP_MAX_BODY_BYTES" with
         | Some v -> v
         | None -> default_max_body_bytes)

  let respond_error reqd status body =
    let headers = Httpun.Headers.of_list [
      ("content-type", "text/plain; charset=utf-8");
      ("content-length", string_of_int (String.length body));
      ("connection", "close");
    ] in
    let response = Httpun.Response.create ~headers status in
    safe_respond_with_string reqd response body

  let respond_too_large reqd max_bytes =
    let body = Printf.sprintf
      "413 Request Entity Too Large (max %d bytes)" max_bytes
    in
    respond_error reqd `Payload_too_large body

  let respond_internal_error reqd exn =
    let body = Printf.sprintf
      "500 Internal Server Error: %s" (Printexc.to_string exn)
    in
    respond_error reqd `Internal_server_error body

  let read_body_async_with_limit reqd ~on_body ~on_error =
    let request = Httpun.Reqd.request reqd in
    let content_length =
      match Httpun.Headers.get request.headers "content-length" with
      | Some v -> parse_positive_int v
      | None -> None
    in
    let body = Httpun.Reqd.request_body reqd in
    let stopped = ref false in
    let stop () =
      if not !stopped then begin
        stopped := true;
        (try Httpun.Body.Reader.close body with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
          Log.Misc.error "[http] body close failed: %s" (Printexc.to_string exn))
      end
    in
    (match content_length with
     | Some len when len > max_body_bytes ->
         stop ();
         on_error (`Too_large max_body_bytes)
     | _ ->
         let initial_capacity =
           match content_length with
           | Some len when len > 0 && len < max_body_bytes -> len
           | _ -> 1024
         in
         let buf = Buffer.create initial_capacity in
         let seen_bytes = ref 0 in
         let rec read_loop () =
           Httpun.Body.Reader.schedule_read body
             ~on_eof:(fun () ->
               let body_str = Buffer.contents buf in
               try on_body body_str with
                 | Eio.Cancel.Cancelled _ as e -> raise e
                 | exn ->
                 on_error (`Internal exn))
             ~on_read:(fun buffer ~off ~len ->
               if !stopped then ()
               else
                 let next_bytes = !seen_bytes + len in
                 if next_bytes > max_body_bytes then begin
                   stop ();
                   on_error (`Too_large max_body_bytes)
                 end else begin
                   seen_bytes := next_bytes;
                   let chunk = Bigstringaf.substring buffer ~off ~len in
                   Buffer.add_string buf chunk;
                   read_loop ()
                 end)
         in
         read_loop ())

  let read_body_async reqd callback =
    read_body_async_with_limit reqd
      ~on_body:callback
      ~on_error:(function
        | `Too_large max_bytes -> respond_too_large reqd max_bytes
        | `Internal exn -> respond_internal_error reqd exn)

  (** Read request body synchronously - uses Condition for proper synchronization *)
  let read_body_sync reqd =
    let result_promise, resolve_result = Eio.Promise.create () in
    let resolved = Atomic.make false in

    let resolve_once outcome =
      if Atomic.compare_and_set resolved false true then
        Eio.Promise.resolve resolve_result outcome
    in

    read_body_async_with_limit reqd
      ~on_body:(fun body_str ->
        resolve_once (Ok body_str))
      ~on_error:(function
        | `Too_large max_bytes ->
            respond_too_large reqd max_bytes;
            resolve_once
              (Error
                 (Printf.sprintf "Request too large (max %d bytes)" max_bytes))
        | `Internal exn ->
            respond_internal_error reqd exn;
            resolve_once (Error (Printexc.to_string exn)));

    Eio.Promise.await result_promise

  (** Get path from request target *)
  let path (request : Httpun.Request.t) =
    match String.split_on_char '?' request.target with
    | p :: _ -> p
    | [] -> request.target (* split always returns non-empty, but type-safe *)

  (** Get HTTP method *)
  let method_ (request : Httpun.Request.t) =
    request.meth

  (** Get header value *)
  let header (request : Httpun.Request.t) name =
    Httpun.Headers.get request.headers name
end

(** Router for simple path-based routing *)
module Router = struct
  type route = {
    path: string;
    methods: Httpun.Method.t list;
    handler: request_handler;
  }

  type resolution =
    [ `Matched of route
    | `Method_not_allowed
    | `Not_found ]

  type t = route list

  let empty : t = []

  let add ~path ~methods ~handler routes =
    { path; methods; handler } :: routes

  let get path handler routes =
    add ~path ~methods:[`GET] ~handler routes

  let post path handler routes =
    add ~path ~methods:[`POST] ~handler routes

  let any path handler routes =
    add ~path ~methods:[`GET; `POST; `PUT; `DELETE; `OPTIONS] ~handler routes

  (** Match by prefix: path field is treated as a prefix, not exact match.
      The suffix (path after the prefix) is available via [Request.path]. *)
  let prefix_get prefix handler routes =
    add ~path:("PREFIX:" ^ prefix) ~methods:[`GET] ~handler routes

  let prefix_post prefix handler routes =
    add ~path:("PREFIX:" ^ prefix) ~methods:[`POST] ~handler routes

  let resolve routes request =
    let req_path = Request.path request in
    let req_method = Request.method_ request in
    (* Try exact matches first *)
    let path_matches =
      List.filter (fun route ->
        (not (String.length route.path > 7
              && String.sub route.path 0 7 = "PREFIX:"))
        && String.equal route.path req_path
      ) routes
    in
    match List.find_opt (fun route -> List.mem req_method route.methods) path_matches with
    | Some route -> `Matched route
    | None ->
        (* Try prefix matches *)
        let prefix_matches =
          List.filter (fun route ->
            String.length route.path > 7
            && String.sub route.path 0 7 = "PREFIX:"
            && let prefix = String.sub route.path 7 (String.length route.path - 7) in
               String.starts_with req_path ~prefix
            && List.mem req_method route.methods
          ) routes
        in
        let prefix_matches =
          List.sort
            (fun a b ->
              let a_len = String.length a.path - 7 in
              let b_len = String.length b.path - 7 in
              compare b_len a_len)
            prefix_matches
        in
        (match prefix_matches with
         | route :: _ -> `Matched route
         | [] ->
             if path_matches = [] then
               `Not_found
             else
               `Method_not_allowed)

  let dispatch routes request reqd =
    match resolve routes request with
    | `Matched route -> route.handler request reqd
    | `Not_found -> Response.not_found reqd
    | `Method_not_allowed -> Response.method_not_allowed reqd
end

(** Health check endpoint - JSON response *)
let health_handler _request reqd =
  let json = Yojson.Safe.to_string (`Assoc [("status", `String "ok"); ("server", `String "masc-mcp"); ("version", `String Version.version)]) in
  Response.json json reqd

(** Readiness probe - Kubernetes *)
let ready_handler _request reqd =
  let body = Yojson.Safe.to_string (Server_startup_state.to_yojson ()) in
  let status =
    if (!Server_startup_state.state).state_ready then `OK
    else `Service_unavailable
  in
  Response.json ~status body reqd

(** Prometheus metrics endpoint *)
let metrics_handler _request reqd =
  let body = Prometheus.to_prometheus_text () in
  let headers = Httpun.Headers.of_list [
    ("content-type", "text/plain; version=0.0.4; charset=utf-8");
    ("content-length", string_of_int (String.length body));
  ] in
  let response = Httpun.Response.create ~headers `OK in
  safe_respond_with_string reqd response body

let mcp_post_handler
    ?request_handler
    (request : Httpun.Request.t)
    (reqd : Httpun.Reqd.t) =
  (* Read request body using sync wrapper *)
  match Request.read_body_sync reqd with
  | Error msg ->
      Response.text ~status:`Bad_request (Printf.sprintf "Body read error: %s" msg) reqd
  | Ok body ->
      let session_id = Streamable_http.get_session_id request in
      let (response_mode, session_opt) =
        Streamable_http.handle_post
          ?session_id
          ~body
          ?request_handler
          ()
      in
      match response_mode with
      | Streamable_http.Json_response json ->
          let json_str = Yojson.Safe.to_string json in
          let extra_headers = match session_opt with
            | Some s -> Streamable_http.with_session_header s []
            | None -> []
          in
          let headers = Httpun.Headers.of_list ([
            ("content-type", "application/json");
            ("content-length", string_of_int (String.length json_str));
          ] @ extra_headers) in
          let response = Httpun.Response.create ~headers `OK in
          safe_respond_with_string reqd response json_str

      | Streamable_http.Json_batch jsons ->
          let json_str = Yojson.Safe.to_string (`List jsons) in
          let extra_headers = match session_opt with
            | Some s -> Streamable_http.with_session_header s []
            | None -> []
          in
          let headers = Httpun.Headers.of_list ([
            ("content-type", "application/json");
            ("content-length", string_of_int (String.length json_str));
          ] @ extra_headers) in
          let response = Httpun.Response.create ~headers `OK in
          safe_respond_with_string reqd response json_str

      | Streamable_http.Sse_upgrade ->
          Response.text ~status:`Not_implemented
            "SSE upgrade is not supported on this transport" reqd

      | Streamable_http.Error_response (code, message) ->
          let status = match code with
            | 400 -> `Bad_request
            | 404 -> `Not_found
            | 500 -> `Internal_server_error
            | _ -> `Bad_request
          in
          Response.text ~status message reqd

(** MCP Streamable HTTP handler (GET /mcp) - SSE stream *)
let mcp_get_handler request reqd =
  let session_id = Streamable_http.get_session_id request in
  match Streamable_http.handle_get ?session_id () with
  | Ok session ->
      (* Return session info, actual SSE handled elsewhere *)
      let json = Yojson.Safe.to_string (`Assoc [("session_id", `String session.id); ("transport", `String "streamable_http")]) in
      Response.json json reqd
  | Error msg ->
      Response.text ~status:`Bad_request msg reqd

(** Default routes for MCP server *)
let default_routes =
  Router.empty
  |> Router.get "/health" health_handler
  |> Router.get "/ready" ready_handler
  |> Router.get "/metrics" metrics_handler
  |> Router.post "/mcp" mcp_post_handler
  |> Router.get "/mcp" mcp_get_handler
  |> Router.get "/" (fun _req reqd ->
      Response.text "MASC MCP Server" reqd)

let with_streamable_mcp_request_handler ~request_handler routes =
  let replace_post_mcp route =
    if String.equal route.Router.path "/mcp" && List.mem `POST route.Router.methods then
      {
        route with
        Router.handler =
          (mcp_post_handler ~request_handler:request_handler);
      }
    else
      route
  in
  let rewritten = List.map replace_post_mcp routes in
  let has_post_mcp =
    List.exists
      (fun route ->
        String.equal route.Router.path "/mcp" && List.mem `POST route.Router.methods)
      rewritten
  in
  if has_post_mcp then rewritten
  else
    Router.post "/mcp" (mcp_post_handler ~request_handler:request_handler) rewritten

(** Create httpun request handler from router
    Note: httpun-eio wraps reqd in Gluten.Reqd.t, extract with .reqd field

    W3C Trace Context: when MASC_OTEL_ENABLED=true and a valid [traceparent]
    header is present, the request is dispatched inside an ambient scope
    carrying the incoming trace_id. Downstream code (tool calls, broadcasts)
    can read it via [Otel_trace_context.from_ambient()].
    When disabled or absent, dispatch proceeds without overhead. *)
let make_request_handler routes =
  fun _client_addr gluten_reqd ->
    let reqd = gluten_reqd.Gluten.Reqd.reqd in
    let request = Httpun.Reqd.request reqd in
    let dispatch () = Router.dispatch routes request reqd in
    if Otel_config.enabled then
      (* Use Headers.get for O(1) lookup instead of Headers.to_list which
         allocates the full header list on every request. *)
      match Httpun.Headers.get request.headers Otel_trace_context.header_name with
      | Some value ->
        (match Otel_trace_context.parse value with
         | Some ctx ->
           let scope =
             Opentelemetry.Scope.make
               ~trace_id:ctx.trace_id
               ~span_id:ctx.parent_id
               ()
           in
           Opentelemetry.Scope.with_ambient_scope scope dispatch
         | None -> dispatch ())
      | None -> dispatch ()
    else
      dispatch ()

(** Create error handler *)
let error_handler _client_addr ?request:_ error start_response =
  let response_body = start_response Httpun.Headers.empty in
  let msg = match error with
    | `Exn exn -> Printexc.to_string exn
    | `Bad_request -> "Bad Request"
    | `Bad_gateway -> "Bad Gateway"
    | `Internal_server_error -> "Internal Server Error"
  in
  Httpun.Body.Writer.write_string response_body msg;
  Httpun.Body.Writer.close response_body

(** Run the HTTP server with Eio *)
let run ~sw ~net ~clock config routes =
  Discovery_cache.set_env ~sw ~net;
  let request_handler = make_request_handler routes in
  let fallback_host = Masc_network_defaults.masc_http_default_host in
  (* Parse IP address using Ipaddr library then convert to Eio format.
     Issue #8725: log + report the effective bind host on parse failure
     so a typo in [config.host] does not silently degrade to loopback
     while the startup banner still claims the misconfigured value. *)
  let ip, effective_host =
    match Ipaddr.of_string config.host with
    | Ok addr -> Eio.Net.Ipaddr.of_raw (Ipaddr.to_octets addr), config.host
    | Error (`Msg msg) ->
        Log.Http.warn
          "http_server_eio: invalid host %S (%s) → loopback %s fallback (#8725)"
          config.host msg fallback_host;
        Eio.Net.Ipaddr.V4.loopback, fallback_host
  in
  let addr = `Tcp (ip, config.port) in
  let socket = Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:config.max_connections addr in
  if String.equal effective_host config.host then
    Printf.printf "MASC MCP Server listening on http://%s:%d\n"
      effective_host config.port
  else
    Printf.printf
      "MASC MCP Server listening on http://%s:%d (configured=%s, parse failed → loopback)\n"
      effective_host config.port config.host;
  Printf.printf "   Graceful shutdown: SIGTERM/SIGINT supported\n%!";

  let initial_backoff_s = 0.05 in
  let max_backoff_s = 1.0 in
  let backoff_s = ref initial_backoff_s in
  let reset_backoff () = backoff_s := initial_backoff_s in
  let bump_backoff () = backoff_s := min max_backoff_s (!backoff_s *. 2.0) in
  let is_cancelled exn =
    match exn with
    | Eio.Cancel.Cancelled _ -> true
    | _ -> false
  in
  let rec accept_loop () =
    try
      (try
         let flow, client_addr = Eio.Net.accept ~sw socket in
         reset_backoff ();
         Eio.Fiber.fork ~sw (fun () ->
           (* Per-connection switch so the accepted [flow] is released
              when the H1 handler exits, not when the long-lived server
              [sw] closes. Without this each connection's TCP FD lingers
              in [CLOSED] state until shutdown — same class of bug
              addressed for the WS standalone accept loop in #10840 and
              already adopted by [http_server_h2.ml] and three accept
              points in [server_bootstrap_http.ml]. Currently latent
              here because the MCP HTTP port has low connection churn. *)
           Eio.Switch.run (fun conn_sw ->
             Eio.Switch.on_release conn_sw (fun () ->
               try Eio.Flow.close flow with
               | Eio.Cancel.Cancelled _ as e -> raise e
               | exn ->
                 Log.Http.warn "[http-eio] flow close failed: %s"
                   (Printexc.to_string exn));
             try
               Httpun_eio.Server.create_connection_handler
                 ~sw:conn_sw
                 ~request_handler
                 ~error_handler
                 client_addr
                 flow
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn ->
               Log.Http.error "Connection error: %s" (Printexc.to_string exn)))
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         if is_cancelled exn then raise exn;
         let delay = !backoff_s in
         Log.Http.error "Accept error: %s (backoff %.2fs)"
           (Printexc.to_string exn) delay;
         Eio.Time.sleep clock delay;
         bump_backoff ());
      accept_loop ()
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      if is_cancelled exn then ()
      else
        let delay = !backoff_s in
        Log.Http.error "Accept loop error: %s (backoff %.2fs)"
          (Printexc.to_string exn) delay;
        Eio.Time.sleep clock delay;
        bump_backoff ();
        accept_loop ()
  in
  accept_loop ()

(** Graceful shutdown exception *)
exception Shutdown

(** Convenience function to start server *)
let start ?(config = default_config) ?(routes = default_routes) () =
  Eio_main.run @@ fun env ->
  Masc_runtime_events.start_listener ();
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in

  (* Graceful shutdown setup *)
  let switch_ref = Atomic.make None in
  let shutdown_initiated = Atomic.make false in
  let initiate_shutdown signal_name =
    if not (Atomic.get shutdown_initiated) then begin
      Atomic.set shutdown_initiated true;
      Log.Http.info "MASC MCP: Received %s, shutting down gracefully..." signal_name;
      match Atomic.get switch_ref with
      | Some sw -> Eio.Switch.fail sw Shutdown
      | None -> ()
    end
  in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle (fun _ -> initiate_shutdown "SIGTERM"));
  Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ -> initiate_shutdown "SIGINT"));

  (try
    Eio.Switch.run @@ fun sw ->
    Atomic.set switch_ref (Some sw);
    run ~sw ~net ~clock config routes
  with
  | Shutdown ->
      Log.Http.info "MASC MCP: Shutdown complete."
  | Eio.Cancel.Cancelled _ ->
      Log.Http.info "MASC MCP: Shutdown complete.")
