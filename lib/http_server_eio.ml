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
  listen_backlog: int;
}

let default_config = {
  port = Env_config_core.masc_http_port_int ();
  host =
    Env_config_core.get_string
      ~default:Masc_network_defaults.masc_http_default_host
      "MASC_HTTP_HOST";
  max_connections = Env_config_core.get_int ~default:512 "MASC_HTTP_MAX_CONNECTIONS";
  listen_backlog = Env_config_core.get_int ~default:128 "MASC_TCP_LISTEN_BACKLOG";
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
    Http_response_payload.accepts_zstd_header
      (Httpun.Headers.get request.headers "accept-encoding")

  (** Check if client accepts dictionary-enhanced zstd *)
  let accepts_zstd_dict (request : Httpun.Request.t) : bool =
    Http_response_payload.accepts_zstd_dict_header
      (Httpun.Headers.get request.headers "accept-encoding")

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
          (* Recognised late-response race (httpun "invalid state" / closed
             writer).  Aligned with [Server_ws_standalone] heartbeat /
             send_pong / handler sites which already log this at debug —
             closes the #13082 review N-of-M leftover: the SSOT classifier
             was unified but this site kept emitting WARN, drowning the
             [None] branch's genuinely-unexpected signal in routine
             disconnect noise.  Comment above ("Genuinely unexpected
             exceptions still log at WARN") only holds once this branch
             stops warning too. *)
          Log.Http.debug
            "[http-eio] respond_with_string skipped (reqd already in \
             error-handling state; classifier match — \
             2026-05-05 OAS cancellation race): %s" msg
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
    let request =
      match request with
      | Some req -> req
      | None -> Httpun.Reqd.request reqd
    in
    let final_body, compression_headers =
      Http_response_payload.compress_body
        ~compress
        ~accept_encoding:(Httpun.Headers.get request.headers "accept-encoding")
        body
    in
    let base_headers = [
      ("content-type", "application/json; charset=utf-8");
      ("content-length", string_of_int (String.length final_body));
    ] in
    let headers = extra_headers @ base_headers @ compression_headers in
    let response = Httpun.Response.create ~headers:(Httpun.Headers.of_list headers) status in
    safe_respond_with_string reqd response final_body

  let json_value ?status ?compress ?extra_headers ?request value reqd =
    json ?status ?compress ?extra_headers ?request (Yojson.Safe.to_string value) reqd

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
        let final_body, compression_headers =
          Http_response_payload.compress_body
            ~accept_encoding:(Httpun.Headers.get request.Httpun.Request.headers "accept-encoding")
            body
        in
        let base_headers = [
          ("content-type", "text/html; charset=utf-8");
          ("content-length", string_of_int (String.length final_body));
          ("etag", etag_value);
          ("cache-control", html_cache_control);
        ] in
        let headers = base_headers @ compression_headers in
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

  let prefix_delete prefix handler routes =
    add ~path:("PREFIX:" ^ prefix) ~methods:[`DELETE] ~handler routes

  let prefix_put prefix handler routes =
    add ~path:("PREFIX:" ^ prefix) ~methods:[`PUT] ~handler routes

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
