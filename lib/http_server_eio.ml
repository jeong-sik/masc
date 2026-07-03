(** Http_server_eio - Eio-native HTTP server using httpun-eio

    The WebSocket upgrade on top of this server is driven by the masc-owned
    ws-direct stack (RFC-0287), not httpun-ws.
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

  let compress_zstd_result ~original result =
    Compression_codec.legacy_standard_result ~original result

  (** Legacy: Standard zstd without dictionary.

      The [bool] returned here tracks whether the caller should emit a
      [Content-Encoding: zstd] header. It may be [false] either because the
      payload was unchanged, because compression failed and returned
      [Unchanged], or because a dictionary-compressed result cannot be served
      through this legacy standard-zstd path. *)
  let compress_zstd ?(level = 3) (data : string) : string * bool =
    if String.length data < Compression_codec.legacy_min_size
    then data, false
    else
      Compression_codec.compress ~level data
      |> Compression_codec.legacy_standard_result ~original:data
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

  let text_plain_content_type = "text/plain; charset=utf-8"
  let html_content_type = "text/html; charset=utf-8"
  let json_content_type = "application/json; charset=utf-8"

  let rev_prepend_headers headers acc =
    List.fold_left (fun acc header -> header :: acc) acc headers

  let content_headers ?(before_headers = []) ?(after_headers = [])
      ?(tail_headers = []) ~content_type body =
    let content_length = string_of_int (String.length body) in
    let headers_rev =
      let base = rev_prepend_headers before_headers [] in
      let base =
        ("content-length", content_length) :: ("content-type", content_type) :: base
      in
      let base = rev_prepend_headers after_headers base in
      rev_prepend_headers tail_headers base
    in
    Httpun.Headers.of_rev_list headers_rev

  let response ?before_headers ?after_headers ?tail_headers ~content_type status body =
    Httpun.Response.create
      ~headers:(content_headers ?before_headers ?after_headers ?tail_headers ~content_type body)
      status

  let static_response ~content_type status body =
    response ~content_type status body, body

  let not_found_response =
    static_response ~content_type:text_plain_content_type `Not_found "404 Not Found"

  let method_not_allowed_response =
    static_response ~content_type:text_plain_content_type `Method_not_allowed
      "405 Method Not Allowed"

  let text ?(status = `OK) body reqd =
    safe_respond_with_string reqd
      (response ~content_type:text_plain_content_type status body)
      body

  let html ?(status = `OK) ?(headers = []) body reqd =
    safe_respond_with_string reqd
      (response ~after_headers:headers ~content_type:html_content_type status body)
      body

  let bytes ?(status = `OK) ?(headers = []) ~content_type body reqd =
    safe_respond_with_string reqd
      (response ~after_headers:headers ~content_type status body)
      body

  let empty ?(status = `No_content) reqd =
    let response = Httpun.Response.create ~headers:(Httpun.Headers.of_list []) status in
    safe_respond_with_string reqd response ""

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
    safe_respond_with_string reqd
      (response ~before_headers:extra_headers ~tail_headers:compression_headers
         ~content_type:json_content_type status final_body)
      final_body

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
    safe_respond_with_string reqd
      (response ~content_type:json_content_type status body)
      body

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
        let headers =
          Httpun.Headers.of_rev_list [
            ("cache-control", html_cache_control);
            ("etag", etag_value);
          ]
        in
        let response = Httpun.Response.create ~headers `Not_modified in
        safe_respond_with_string reqd response ""
    | _ ->
        (* Serve full response, with compression if possible *)
        let final_body, compression_headers =
          Http_response_payload.compress_body
            ~accept_encoding:(Httpun.Headers.get request.Httpun.Request.headers "accept-encoding")
            body
        in
        let extra_headers = [
          ("etag", etag_value);
          ("cache-control", html_cache_control);
        ] in
        safe_respond_with_string reqd
          (response ~after_headers:extra_headers ~tail_headers:compression_headers
             ~content_type:html_content_type status final_body)
          final_body

  let not_found reqd =
    let response, body = not_found_response in
    safe_respond_with_string reqd response body

  let method_not_allowed reqd =
    let response, body = method_not_allowed_response in
    safe_respond_with_string reqd response body

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
    match from_env "MASC_MAX_BODY_BYTES" with
    | Some v -> v
    | None ->
        (match from_env "MCP_MAX_BODY_BYTES" with
         | Some v -> v
         | None -> default_max_body_bytes)

  let respond_error reqd status body =
    let headers =
      Response.content_headers ~tail_headers:[("connection", "close")]
        ~content_type:Response.text_plain_content_type body
    in
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
         let buf = Http_body_buffer.create initial_capacity in
         let rec read_loop () =
           Httpun.Body.Reader.schedule_read body
             ~on_eof:(fun () ->
               let body_str = Http_body_buffer.contents buf in
               try on_body body_str with
                 | Eio.Cancel.Cancelled _ as e -> raise e
                 | exn ->
                 on_error (`Internal exn))
             ~on_read:(fun buffer ~off ~len ->
               if !stopped then ()
               else
                 let next_bytes = Http_body_buffer.length buf + len in
                 if next_bytes > max_body_bytes then begin
                   stop ();
                   on_error (`Too_large max_body_bytes)
                 end else begin
                   Http_body_buffer.add_bigstring buf buffer ~off ~len;
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
    match String.index_opt request.target '?' with
    | Some idx -> String.sub request.target 0 idx
    | None -> request.target

  (** Get HTTP method *)
  let method_ (request : Httpun.Request.t) =
    request.meth

  (** Get header value *)
  let header (request : Httpun.Request.t) name =
    Httpun.Headers.get request.headers name
end

(** Router for simple path-based routing *)
module Router = struct
  type route_kind = Exact | Prefix

  (* The Gluten protocol-upgrade capability.  It is only available at
     the httpun-eio connection-handler boundary, where the request
     arrives as [Httpun.Reqd.t Gluten.reqd = { reqd; upgrade }].  Plain
     HTTP routes never need it; WebSocket-upgrade routes ([ws_get])
     require it to hand the post-101 socket to a
     [Httpun_ws.Server_connection.t] runtime.  Threaded through
     [dispatch] as a typed per-request value rather than captured
     ambiently.  See RFC-0281. *)
  type upgrade = Gluten.impl -> unit

  type ws_handler =
    upgrade:upgrade -> Httpun.Request.t -> Httpun.Reqd.t -> unit

  (* A route either handles the request in-band ([Plain], the common
     case) or upgrades the connection to WebSocket ([Ws]).  Encoding
     this as a typed variant keeps the route table the single source of
     truth for which paths upgrade, instead of a path-string match in
     the connection handler.  RFC-0281 S3.3. *)
  type route_target =
    | Plain of request_handler
    | Ws of ws_handler

  type route = {
    kind: route_kind;
    path: string;
    methods: Httpun.Method.t list;
    handler: route_target;
  }

  type resolution =
    [ `Matched of route
    | `Method_not_allowed
    | `Not_found ]

  type prefix_node = {
    children: (char, prefix_node) Hashtbl.t;
    mutable routes: route list;
  }

  type method_routes = {
    exact_by_path: (string, route) Hashtbl.t;
    mutable prefix_routes: route list;
    prefix_root: prefix_node;
  }

  type t = {
    get: method_routes;
    post: method_routes;
    put: method_routes;
    delete: method_routes;
    options: method_routes;
    exact_paths: (string, unit) Hashtbl.t;
    mutable routes: route list;
    mutable route_count: int;
  }

  let create_prefix_node () =
    { children = Hashtbl.create 4; routes = [] }

  let create_method_routes () =
    {
      exact_by_path = Hashtbl.create 128;
      prefix_routes = [];
      prefix_root = create_prefix_node ();
    }

  let create () =
    {
      get = create_method_routes ();
      post = create_method_routes ();
      put = create_method_routes ();
      delete = create_method_routes ();
      options = create_method_routes ();
      exact_paths = Hashtbl.create 128;
      routes = [];
      route_count = 0;
    }

  let route_count router = router.route_count

  let routes router = List.rev router.routes

  let insert_prefix_route route routes =
    let route_len = String.length route.path in
    let rec loop acc = function
      | [] -> List.rev (route :: acc)
      | candidate :: rest
        when route_len >= String.length candidate.path ->
          List.rev_append acc (route :: candidate :: rest)
      | candidate :: rest -> loop (candidate :: acc) rest
    in
    loop [] routes

  let insert_prefix_trie (route : route) (root : prefix_node) =
    let path = route.path in
    let path_len = String.length path in
    let rec loop (node : prefix_node) idx =
      if idx = path_len then
        node.routes <- insert_prefix_route route node.routes
      else
        let ch = path.[idx] in
        let child =
          match Hashtbl.find_opt node.children ch with
          | Some child -> child
          | None ->
              let child = create_prefix_node () in
              Hashtbl.add node.children ch child;
              child
        in
        loop child (idx + 1)
    in
    loop root 0

  let method_routes router = function
    | `GET -> Some router.get
    | `POST -> Some router.post
    | `PUT -> Some router.put
    | `DELETE -> Some router.delete
    | `OPTIONS -> Some router.options
    | _ -> None

  let add_to_method_routes kind route method_routes =
    match kind with
    | Exact -> Hashtbl.replace method_routes.exact_by_path route.path route
    | Prefix ->
        method_routes.prefix_routes <-
          insert_prefix_route route method_routes.prefix_routes;
        insert_prefix_trie route method_routes.prefix_root

  let add_kind kind ~path ~methods ~handler router =
    let route = { kind; path; methods; handler } in
    (match kind with
     | Exact ->
         Hashtbl.replace router.exact_paths path ();
         List.iter
           (fun method_ ->
              match method_routes router method_ with
              | Some routes -> add_to_method_routes Exact route routes
              | None -> ())
           methods
     | Prefix ->
         List.iter
           (fun method_ ->
              match method_routes router method_ with
              | Some routes -> add_to_method_routes Prefix route routes
              | None -> ())
           methods);
    router.routes <- route :: router.routes;
    router.route_count <- router.route_count + 1;
    router

  let add ~path ~methods ~handler router =
    add_kind Exact ~path ~methods ~handler:(Plain handler) router

  let get path handler routes =
    add ~path ~methods:[`GET] ~handler routes

  let post path handler routes =
    add ~path ~methods:[`POST] ~handler routes

  let any path handler routes =
    add ~path ~methods:[`GET; `POST; `PUT; `DELETE; `OPTIONS] ~handler routes

  (** Register a WebSocket-upgrade route.  The handler additionally
      receives the Gluten [upgrade] capability so it can drive the
      post-101 connection.  RFC-0281. *)
  let ws_get path handler router =
    add_kind Exact ~path ~methods:[`GET] ~handler:(Ws handler) router

  (** Match by prefix: path field is treated as a prefix, not exact match.
      The suffix (path after the prefix) is available via [Request.path]. *)
  let prefix_get prefix handler routes =
    add_kind Prefix ~path:prefix ~methods:[`GET] ~handler:(Plain handler) routes

  let prefix_post prefix handler routes =
    add_kind Prefix ~path:prefix ~methods:[`POST] ~handler:(Plain handler) routes

  let prefix_delete prefix handler routes =
    add_kind Prefix ~path:prefix ~methods:[`DELETE] ~handler:(Plain handler) routes

  let prefix_put prefix handler routes =
    add_kind Prefix ~path:prefix ~methods:[`PUT] ~handler:(Plain handler) routes

  let resolve_prefix routes req_path =
    let path_len = String.length req_path in
    let rec loop (node : prefix_node) idx best =
      let best =
        match node.routes with
        | route :: _ -> Some route
        | [] -> best
      in
      if idx = path_len then
        best
      else
        match Hashtbl.find_opt node.children req_path.[idx] with
        | Some child -> loop child (idx + 1) best
        | None -> best
    in
    loop routes.prefix_root 0 None

  let resolve router request =
    let req_path = Request.path request in
    let req_method = Request.method_ request in
    match method_routes router req_method with
    | Some routes -> (
        match Hashtbl.find_opt routes.exact_by_path req_path with
        | Some route -> `Matched route
        | None -> (
            match resolve_prefix routes req_path with
            | Some route -> `Matched route
            | None ->
                if Hashtbl.mem router.exact_paths req_path then
                  `Method_not_allowed
                else
                  `Not_found))
    | None ->
        if Hashtbl.mem router.exact_paths req_path then
          `Method_not_allowed
        else
          `Not_found

  let dispatch router ?upgrade request reqd =
    match resolve router request with
    | `Matched route -> (
        match route.handler with
        | Plain handler -> handler request reqd
        | Ws handler -> (
            match upgrade with
            | Some upgrade -> handler ~upgrade request reqd
            | None ->
                (* A WebSocket-upgrade route was matched on a transport
                   that cannot upgrade (e.g. the HTTP/2 dispatch path,
                   which has no Gluten upgrade).  Respond 426 explicitly
                   rather than silently dropping the request.
                   RFC-0281 S3.3. *)
                Response.text ~status:`Upgrade_required
                  "426 Upgrade Required: WebSocket upgrade unavailable on \
                   this transport"
                  reqd))
    | `Not_found -> Response.not_found reqd
    | `Method_not_allowed -> Response.method_not_allowed reqd
end
