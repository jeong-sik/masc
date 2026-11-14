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
  max_connections =
    Env_config_core.get_int
      ~default:Masc_network_defaults.masc_http_default_max_connections
      "MASC_HTTP_MAX_CONNECTIONS";
  listen_backlog = Env_setting.Int_knob.get Tcp_listen_backlog;
}

(** HTTP request handler type *)
type request_handler =
  Httpun.Request.t ->
  Http_reqd.t ->
  unit

(** Simple response helpers *)
module Response = struct
  let scoped_headers_key : (string * string) list Eio.Fiber.key = Eio.Fiber.create_key ()

  let with_scoped_headers headers send =
    Eio.Fiber.with_binding scoped_headers_key headers send

  let scoped_headers () =
    (* Offline response preparation has no request fiber or admitted headers. *)
    try match Eio.Fiber.get scoped_headers_key with Some headers -> headers | None -> []
    with Effect.Unhandled _ -> []

  let html_cache_control = "no-store, max-age=0, must-revalidate"

  let text_plain_content_type = "text/plain; charset=utf-8"
  let html_content_type = "text/html; charset=utf-8"
  let json_content_type = "application/json; charset=utf-8"

  (* [#28400] Dashboard cache timeouts travel in-band: a value that is
     structurally a normal payload but semantically an error envelope. Only
     the producing layer (Dashboard_cache, masc.dashboard) can distinguish
     the envelope from real data, and masc.dashboard depends on this module,
     so the recognizer is injected here at library init instead of a direct
     reference (which would be a dependency cycle).

     [register_timeout_envelope_recognizer] installs the recognizer once at
     dashboard library init; [json_value] consults it for every JSON value
     response and reclassifies a detected envelope as 504 Gateway_timeout,
     honoring the error contract the dashboard client already tests
     (504 + {"error":"computation_timeout", ...}).

     A recognizer that was never registered means this build links no
     dashboard producer, and the check is a no-op. *)
  let timeout_envelope_recognizer : (Yojson.Safe.t -> bool) option ref =
    ref None

  let register_timeout_envelope_recognizer (recognizer : Yojson.Safe.t -> bool) =
    timeout_envelope_recognizer := Some recognizer

  let timeout_envelope_status_override ?status json =
    match (status, !timeout_envelope_recognizer) with
    | (None | Some `OK), Some recognizes when recognizes json ->
      `Gateway_timeout
    | (Some status, _) -> status
    | (None, _) -> `OK

  (* [#28400] Same reclassification for string-bodied JSON responses
     (json_lazy / respond_cached_read family). Envelopes are small error
     objects, so bound the parse cost and fall back to the caller status. *)
  let timeout_envelope_status_override_string ?status (body : string) =
    let ok_status () = match status with Some s -> s | None -> `OK in
    match !timeout_envelope_recognizer with
    | None -> ok_status ()
    | Some _ when status <> None && status <> Some `OK -> ok_status ()
    | Some recognizes ->
        if String.length body > 8192 then ok_status ()
        else
          match Yojson.Safe.from_string body with
          | json when recognizes json -> `Gateway_timeout
          | _ -> ok_status ()
          | exception Yojson.Json_error _ -> ok_status ()

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
    Http_reqd.respond_with_string reqd
      (response ~content_type:text_plain_content_type status body)
      body

  let html ?(status = `OK) ?(headers = []) body reqd =
    Http_reqd.respond_with_string reqd
      (response ~after_headers:headers ~content_type:html_content_type status body)
      body

  let bytes ?(status = `OK) ?(headers = []) ~content_type body reqd =
    let headers = scoped_headers () @ headers in
    Http_reqd.respond_with_string reqd
      (response ~after_headers:headers ~content_type status body)
      body

  let shared ?(status = `OK) ?(headers = []) ~content_type body reqd =
    let headers = scoped_headers () @ headers in
    Http_reqd.respond_with_shared reqd
      (response ~after_headers:headers ~content_type status (Shared_body.to_string body))
      body

  let empty ?(status = `No_content) reqd =
    let response =
      Httpun.Response.create
        ~headers:(Httpun.Headers.of_list [ "content-length", "0" ])
        status
    in
    Http_reqd.respond_with_string reqd response ""

  (** JSON response with optional zstd compression (dictionary-enhanced)

      Uses trained multi-format dictionary for small messages (32-2048 bytes)
      achieving ~70% compression vs ~6% with standard zstd.

      @param compress Enable compression if client accepts (default: true)
      @param request Optional request to check Accept-Encoding header *)
  (* One entity tag policy for every response that carries one. Truncated
     because a tag only has to distinguish this body from the previous body of
     the same resource, not resist collision from an attacker. *)
  let etag_hex_chars = 12

  let etag_of_body body =
    let hash = Digest.string body |> Digest.to_hex in
    String.sub hash 0 (min etag_hex_chars (String.length hash))

  (* Weak, because the same JSON goes out gzipped, zstd-compressed, or plain
     depending on Accept-Encoding, and those are three encodings of one
     payload rather than three payloads. If-None-Match compares weakly, which
     is the comparison we want. *)
  let weak_etag_value body = "W/\"" ^ etag_of_body body ^ "\""

  (* Store the response but revalidate before every use. Without this a cache
     is free to invent a freshness lifetime for a 200 that carries a validator
     and serve keeper state that has moved on. *)
  let json_revalidate_cache_control = "no-cache"

  (* What a request gets, decided before any socket work. Kept as a closed
     variant and a pure function so every combination of method, status, and
     If-None-Match is decidable in a test without constructing a [Reqd]. *)
  type json_conditional =
    | Untagged
    (** No validator offered: the response is not a successful safe read, so a
        tag would invite revalidation of something that should not be reused. *)
    | Tagged of string
    (** Full body, carrying this tag for the client to present next time. *)
    | Not_modified of string
    (** The client's tag matches; it already holds this body. *)

  (* The opaque part of an entity tag: [W/"x"] and ["x"] both give ["x"]. *)
  let opaque_tag tag =
    let tag = String.trim tag in
    if String.starts_with ~prefix:"W/" tag
    then String.sub tag 2 (String.length tag - 2)
    else tag

  (* If-None-Match uses the weak comparison (RFC 9110 section 13.1.2): two
     tags match when their opaque parts are equal, whichever of them carries
     [W/]. A proxy that weakens a strong tag still gets its 304. *)
  let client_tag_matches ~etag ~client_tag =
    let client_tag = String.trim client_tag in
    let wanted = opaque_tag etag in
    String.equal client_tag "*"
    || List.exists
         (fun tag -> String.equal (opaque_tag tag) wanted)
         (String.split_on_char ',' client_tag)

  let json_conditional ~status ~(meth : Httpun.Method.t) ~if_none_match ~body =
    let safe_read = match meth with `GET | `HEAD -> true | _ -> false in
    if not (safe_read && status = `OK) then Untagged
    else
      let etag_value = weak_etag_value body in
      match if_none_match with
      | Some client_tag when client_tag_matches ~etag:etag_value ~client_tag ->
        Not_modified etag_value
      | Some _ | None -> Tagged etag_value

  let prepare_json ?(status = `OK) ?(compress = true) ?(extra_headers = []) ~(request : Httpun.Request.t) ?etag body =
    let send ~validator_headers =
      let final_body, compression_headers =
        Http_response_payload.compress_body_on_cpu
          ~compress
          ~accept_encoding:(Httpun.Headers.get request.headers "accept-encoding")
          body
      in
      (response
           ~before_headers:(extra_headers @ validator_headers)
           ~tail_headers:compression_headers
           ~content_type:json_content_type status final_body), final_body
    in
    let outcome =
      match etag with
      | Some etag_value ->
        let safe_read = match request.Httpun.Request.meth with `GET | `HEAD -> true | _ -> false in
        if not (safe_read && status = `OK) then Untagged
        else
          let if_none_match =
            Httpun.Headers.get request.Httpun.Request.headers "if-none-match"
          in
          (match if_none_match with
          | Some client_tag when client_tag_matches ~etag:etag_value ~client_tag ->
            Not_modified etag_value
          | Some _ | None -> Tagged etag_value)
      | None ->
        json_conditional
          ~status
          ~meth:request.Httpun.Request.meth
          ~if_none_match:
            (Httpun.Headers.get request.Httpun.Request.headers "if-none-match")
          ~body
    in
    match outcome with
    | Untagged -> send ~validator_headers:[]
    | Tagged etag_value ->
      send
        ~validator_headers:
          [ ("etag", etag_value); ("cache-control", json_revalidate_cache_control) ]
    | Not_modified etag_value ->
      (* The body is not compressed, written to the socket, or parsed by the
         client. That is the whole saving — the projection behind it already
         came from the dashboard cache. *)
      let headers =
        Httpun.Headers.of_list
          (extra_headers
          @ [ ("etag", etag_value);
              ("cache-control", json_revalidate_cache_control);
            ])
      in
      Httpun.Response.create ~headers `Not_modified, ""

  let json ?status ?compress ?extra_headers ?request ?etag body reqd =
    let extra_headers = scoped_headers () @ Option.value ~default:[] extra_headers in
    let request =
      match request with
      | Some request -> request
      | None -> Http_reqd.request reqd
    in
    let response, final_body =
      prepare_json ?status ?compress ~extra_headers ~request ?etag body
    in
    Http_reqd.respond_with_string reqd response final_body

  let json_lazy ?(status = `OK) ?(compress = true) ?(extra_headers = []) ?request
      ~etag (lazy_body : unit -> string) reqd =
    let request =
      match request with
      | Some req -> req
      | None -> Http_reqd.request reqd
    in
    let safe_read = match request.Httpun.Request.meth with `GET | `HEAD -> true | _ -> false in
    if not (safe_read && status = `OK) then
      let body = lazy_body () in
      let status = timeout_envelope_status_override_string ~status body in
      json ~status ~compress ~extra_headers ~request ~etag body reqd
    else
      let extra_headers = scoped_headers () @ extra_headers in
      let if_none_match =
        Httpun.Headers.get request.Httpun.Request.headers "if-none-match"
      in
      match if_none_match with
      | Some client_tag when client_tag_matches ~etag ~client_tag ->
        let headers =
          Httpun.Headers.of_list
            (extra_headers
            @ [ ("etag", etag);
                ("cache-control", json_revalidate_cache_control);
              ])
        in
        Http_reqd.respond_with_string reqd
          (Httpun.Response.create ~headers `Not_modified)
          ""
      | _ ->
        let body = lazy_body () in
        let status = timeout_envelope_status_override_string ~status body in
        let final_body, compression_headers =
          Http_response_payload.compress_body_on_cpu
            ~compress
            ~accept_encoding:(Httpun.Headers.get request.headers "accept-encoding")
            body
        in
        Http_reqd.respond_with_string reqd
          (response
             ~before_headers:(extra_headers @ [ ("etag", etag); ("cache-control", json_revalidate_cache_control) ])
             ~tail_headers:compression_headers
             ~content_type:json_content_type status final_body)
          final_body

  let json_value ?status ?compress ?extra_headers ?request value reqd =
    let status = timeout_envelope_status_override ?status value in
    json ~status ?compress ?extra_headers ?request (Yojson.Safe.to_string value) reqd

  let json_value_on_cpu ?status ?compress ?extra_headers ?request value reqd =
    let status = timeout_envelope_status_override ?status value in
    let extra_headers = scoped_headers () @ Option.value ~default:[] extra_headers in
    let request = match request with Some request -> request | None -> Http_reqd.request reqd in
    let response, body =
      Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
        prepare_json ~status ?compress ~extra_headers ~request
          (Yojson.Safe.to_string value))
    in
    Http_reqd.respond_with_string reqd response body

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
        Http_reqd.respond_with_string reqd response ""
    | _ ->
        (* Serve full response, with compression if possible *)
        let final_body, compression_headers =
          Http_response_payload.compress_body_on_cpu
            ~accept_encoding:(Httpun.Headers.get request.Httpun.Request.headers "accept-encoding")
            body
        in
        let extra_headers = [
          ("etag", etag_value);
          ("cache-control", html_cache_control);
        ] in
        Http_reqd.respond_with_string reqd
          (response ~after_headers:extra_headers ~tail_headers:compression_headers
             ~content_type:html_content_type status final_body)
          final_body

  let strong_tag_value etag = "\"" ^ etag ^ "\""

  let bytes_validator ~etag ~cache_control =
    [ ("etag", strong_tag_value etag); ("cache-control", cache_control) ]

  let request_holds_tag ~etag (request : Httpun.Request.t) =
    match Httpun.Headers.get request.headers "if-none-match" with
    | Some client_tag -> client_tag_matches ~etag:(strong_tag_value etag) ~client_tag
    | None -> false

  let not_modified ~headers reqd =
    Http_reqd.respond_with_string reqd
      (Httpun.Response.create
         ~headers:(Httpun.Headers.of_list (scoped_headers () @ headers))
         `Not_modified)
      ""

  let bytes_not_modified ~etag ~cache_control reqd =
    Http_reqd.respond_with_string reqd
      (Httpun.Response.create
         ~headers:(Httpun.Headers.of_list (bytes_validator ~etag ~cache_control))
         `Not_modified)
      ""

  let bytes_cached ~etag ~cache_control ~request ~content_type body reqd =
    if request_holds_tag ~etag request
    then bytes_not_modified ~etag ~cache_control reqd
    else
      Http_reqd.respond_with_string reqd
        (response ~after_headers:(bytes_validator ~etag ~cache_control) ~content_type `OK body)
        body

  let not_found reqd =
    let response, body = not_found_response in
    Http_reqd.respond_with_string reqd response body

  let method_not_allowed reqd =
    let response, body = method_not_allowed_response in
    Http_reqd.respond_with_string reqd response body

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
    | None -> default_max_body_bytes

  let respond_error reqd status body =
    let headers =
      Response.content_headers ~tail_headers:[("connection", "close")]
        ~content_type:Response.text_plain_content_type body
    in
    let response = Httpun.Response.create ~headers status in
    Http_reqd.respond_with_string reqd response body

  let too_large_body max_bytes =
    Printf.sprintf "413 Request Entity Too Large (max %d bytes)" max_bytes

  let respond_too_large reqd max_bytes =
    respond_error reqd `Payload_too_large (too_large_body max_bytes)

  (* [exn] is what the route's body callback raised. Its text can name a
     file of the server, so it goes to the log and the body is the fixed
     sentence. *)
  let respond_internal_error reqd exn =
    Log.Http.error "[http] request body handler failed: %s" (Printexc.to_string exn);
    respond_error reqd `Internal_server_error Http_error_body.internal_server_error

  type body_read_error = Http_reqd.body_read_error =
    | Too_large of int
    | Internal of exn

  let read_body_async_with_limit reqd ~max_bytes ~on_body ~on_error =
    Http_reqd.read_body reqd ~max_bytes ~on_body ~on_error

  let read_body_async reqd callback =
    read_body_async_with_limit reqd
      ~max_bytes:max_body_bytes
      ~on_body:callback
      ~on_error:(function
        | Too_large max_bytes -> respond_too_large reqd max_bytes
        | Internal exn -> respond_internal_error reqd exn)

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

  (* The Gluten protocol-upgrade capability.  A handle made at the
     httpun-eio connection boundary ([Http_reqd.of_gluten]) carries it;
     plain HTTP routes never need it; WebSocket-upgrade routes ([ws_get])
     require it to hand the post-101 socket to the ws-direct runtime.
     A discovery GET still runs when the transport carries no capability.
     [dispatch] reads it from the handle. See RFC-0281. *)
  type upgrade = Http_reqd.upgrade

  type ws_handler =
    upgrade:upgrade option -> Httpun.Request.t -> Http_reqd.t -> unit

  (* A route either handles the request in-band ([Owner], the common
     case, and [Serving]) or upgrades the connection to WebSocket ([Ws]).
     Encoding this as a typed variant keeps the route table the single
     source of truth for which paths upgrade and for which domain a handler
     runs on, instead of a path-string match in the connection handler.
     RFC-0281 S3.3, RFC http-transport-runs-on-its-own-domain §3.2. *)
  type route_target =
    | Owner of request_handler
    | Serving of request_handler
    | Ws of ws_handler

  type route = {
    kind: route_kind;
    path: string;
    methods: Httpun.Method.t list;
    handler: route_target;
    access: Route_access.t;
  }

  type resolution =
    [ `Matched of route
    | `Method_not_allowed
    | `Not_found ]

  type method_routes = {
    exact_by_path: (string, route) Hashtbl.t;
    mutable prefix_routes: route list;
  }

  (* Every registration, newest first. It is shared state like the method
     index, so a router that was passed to a registration
     function and is used afterwards describes the same table in [routes] and
     in [resolve]. *)
  type route_log = {
    mutable entries: route list;
    mutable count: int;
  }

  type t = {
    get: method_routes;
    post: method_routes;
    put: method_routes;
    delete: method_routes;
    options: method_routes;
    exact_paths: (string, unit) Hashtbl.t;
    log: route_log;
  }

  let create_method_routes () =
    {
      exact_by_path = Hashtbl.create 128;
      prefix_routes = [];
    }

  let create () =
    {
      get = create_method_routes ();
      post = create_method_routes ();
      put = create_method_routes ();
      delete = create_method_routes ();
      options = create_method_routes ();
      exact_paths = Hashtbl.create 128;
      log = { entries = []; count = 0 };
    }

  let route_count router = router.log.count

  let routes router = List.rev router.log.entries

  let copy_method_routes routes =
    {
      exact_by_path = Hashtbl.copy routes.exact_by_path;
      prefix_routes = routes.prefix_routes;
    }

  (* The route records and the prefix lists are immutable, so the copy shares
     them and owns the tables and the log that a registration changes. *)
  let copy router =
    {
      get = copy_method_routes router.get;
      post = copy_method_routes router.post;
      put = copy_method_routes router.put;
      delete = copy_method_routes router.delete;
      options = copy_method_routes router.options;
      exact_paths = Hashtbl.copy router.exact_paths;
      log = { entries = router.log.entries; count = router.log.count };
    }

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
          insert_prefix_route route method_routes.prefix_routes

  let add_kind kind ~access ~path ~methods ~handler router =
    let route = { kind; path; methods; handler; access } in
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
    router.log.entries <- route :: router.log.entries;
    router.log.count <- router.log.count + 1;
    router

  (* Dispatch gives a method and a path to the route registered last:
     [Hashtbl.replace] for an exact path, and the newest route first among equal
     prefixes. A registration that a later one replaced is still in [routes]. *)
  let effective_routes router =
    let seen = Hashtbl.create 256 in
    let reachable method_ = Option.is_some (method_routes router method_) in
    let replaced route method_ =
      let key = route.kind, route.path, Httpun.Method.to_string method_ in
      if Hashtbl.mem seen key
      then true
      else (
        Hashtbl.add seen key ();
        false)
    in
    List.filter_map
      (fun route ->
         match
           List.filter
             (fun method_ -> reachable method_ && not (replaced route method_))
             route.methods
         with
         | [] -> None
         | methods -> Some { route with methods })
      router.log.entries
    |> List.rev

  (* Typed registration. [Make_typed] is the only way to register a route: it
     applies the wrapper that goes with the kind to the handler and records the
     kind in the same call, so a route cannot say [Permission] and run a handler
     that checks nothing. [add_kind], the function that takes the access and the
     handler as separate arguments, is not exported. *)
  module type Wrappers = sig
    type state

    val with_public_read
      :  (state -> Httpun.Request.t -> Http_reqd.t -> unit)
      -> request_handler

    val with_public_read_open_when_strict
      :  (state -> Httpun.Request.t -> Http_reqd.t -> unit)
      -> request_handler

    val with_read_auth
      :  (state -> Httpun.Request.t -> Http_reqd.t -> unit)
      -> request_handler

    val with_permission_auth
      :  permission:Masc_domain.permission
      -> (state -> Httpun.Request.t -> Http_reqd.t -> unit)
      -> request_handler

    val with_token_permission_auth
      :  permission:Masc_domain.permission
      -> (state -> string -> Httpun.Request.t -> Http_reqd.t -> unit)
      -> request_handler

    val with_private_token_permission_auth
      :  permission:Masc_domain.permission
      -> (state -> string -> Httpun.Request.t -> Http_reqd.t -> unit)
      -> request_handler

    val with_tool_auth
      :  tool_name:string
      -> (state -> Httpun.Request.t -> Http_reqd.t -> unit)
      -> request_handler

    val with_tool_observation_auth
      :  tool_name:string
      -> (state -> Httpun.Request.t -> Http_reqd.t -> unit)
      -> request_handler

    val with_tool_actor_auth
      :  tool_name:string
      -> (state -> string -> Httpun.Request.t -> Http_reqd.t -> unit)
      -> request_handler

    val with_canonical_loopback_host : request_handler -> request_handler
  end

  module type Typed = sig
    type state
    type state_handler = state -> Httpun.Request.t -> Http_reqd.t -> unit
    type token_handler = state -> string -> Httpun.Request.t -> Http_reqd.t -> unit
    type actor_handler = state -> string -> Httpun.Request.t -> Http_reqd.t -> unit

    type _ auth =
      | Always_public : request_handler auth
      | Public_read : state_handler auth
      | Public_read_open_when_strict : state_handler auth
      | Public_read_on_canonical_host :
          { when_strict : Route_access.strict_reading }
          -> state_handler auth
      | Read_auth : state_handler auth
      | Permission : Masc_domain.permission -> state_handler auth
      | Token_permission : Masc_domain.permission -> token_handler auth
      | Private_token_permission : Masc_domain.permission -> token_handler auth
      | Tool : { tool_name : string } -> state_handler auth
      | Tool_observation : { tool_name : string } -> state_handler auth
      | Tool_actor : { tool_name : string } -> actor_handler auth
      | Self_authenticated :
          Route_access.self_authenticated_reason
          -> request_handler auth

    val access : _ auth -> Route_access.t
    val get : 'h auth -> string -> 'h -> t -> t
    val post : 'h auth -> string -> 'h -> t -> t

    val add
      :  'h auth
      -> path:string
      -> methods:Httpun.Method.t list
      -> 'h
      -> t
      -> t

    val prefix_get : 'h auth -> string -> 'h -> t -> t
    val prefix_post : 'h auth -> string -> 'h -> t -> t
    val prefix_put : 'h auth -> string -> 'h -> t -> t
    val prefix_delete : 'h auth -> string -> 'h -> t -> t
    module Serving : sig
      val get : 'h auth -> string -> 'h -> t -> t
    end

    val ws_get : string -> ws_handler -> t -> t
  end

  module Make_typed (W : Wrappers) : Typed with type state = W.state = struct
    type state = W.state
    type state_handler = state -> Httpun.Request.t -> Http_reqd.t -> unit
    type token_handler = state -> string -> Httpun.Request.t -> Http_reqd.t -> unit
    type actor_handler = state -> string -> Httpun.Request.t -> Http_reqd.t -> unit

    type _ auth =
      | Always_public : request_handler auth
      | Public_read : state_handler auth
      | Public_read_open_when_strict : state_handler auth
      | Public_read_on_canonical_host :
          { when_strict : Route_access.strict_reading }
          -> state_handler auth
      | Read_auth : state_handler auth
      | Permission : Masc_domain.permission -> state_handler auth
      | Token_permission : Masc_domain.permission -> token_handler auth
      | Private_token_permission : Masc_domain.permission -> token_handler auth
      | Tool : { tool_name : string } -> state_handler auth
      | Tool_observation : { tool_name : string } -> state_handler auth
      | Tool_actor : { tool_name : string } -> actor_handler auth
      | Self_authenticated :
          Route_access.self_authenticated_reason
          -> request_handler auth

    let access : type h. h auth -> Route_access.t = function
      | Always_public -> Route_access.Always_public
      | Public_read -> Route_access.Public_read Route_access.Credential_when_strict
      | Public_read_open_when_strict -> Route_access.Public_read Route_access.Open_when_strict
      | Public_read_on_canonical_host { when_strict } -> Route_access.Public_read when_strict
      | Read_auth -> Route_access.Read_auth
      | Permission permission -> Route_access.Permission permission
      | Token_permission permission -> Route_access.Token_permission permission
      | Private_token_permission permission ->
        Route_access.Private_token_permission permission
      | Tool { tool_name } -> Route_access.Tool { tool_name }
      | Tool_observation { tool_name } -> Route_access.Tool_observation { tool_name }
      | Tool_actor { tool_name } -> Route_access.Tool_actor { tool_name }
      | Self_authenticated reason -> Route_access.Self_authenticated reason

    (* The handler a route runs: [handler] inside the wrapper the kind names.
       The kinds that wrap nothing hand [handler] over unchanged. *)
    let wrapped : type h. h auth -> h -> request_handler =
      fun auth handler ->
      match auth with
      | Always_public -> handler
      | Self_authenticated _ -> handler
      | Public_read -> W.with_public_read handler
      | Public_read_open_when_strict -> W.with_public_read_open_when_strict handler
      | Public_read_on_canonical_host { when_strict } ->
        let public_read =
          match when_strict with
          | Route_access.Credential_when_strict -> W.with_public_read handler
          | Route_access.Open_when_strict -> W.with_public_read_open_when_strict handler
        in
        W.with_canonical_loopback_host public_read
      | Read_auth -> W.with_read_auth handler
      | Permission permission -> W.with_permission_auth ~permission handler
      | Token_permission permission ->
        W.with_token_permission_auth ~permission handler
      | Private_token_permission permission ->
        W.with_private_token_permission_auth ~permission handler
      | Tool { tool_name } -> W.with_tool_auth ~tool_name handler
      | Tool_observation { tool_name } -> W.with_tool_observation_auth ~tool_name handler
      | Tool_actor { tool_name } -> W.with_tool_actor_auth ~tool_name handler

    let register auth ~kind ~path ~methods handler routes =
      add_kind kind ~access:(access auth) ~path ~methods
        ~handler:(Owner (wrapped auth handler)) routes

    let get auth path handler routes =
      register auth ~kind:Exact ~path ~methods:[`GET] handler routes

    let post auth path handler routes =
      register auth ~kind:Exact ~path ~methods:[`POST] handler routes

    let add auth ~path ~methods handler routes =
      register auth ~kind:Exact ~path ~methods handler routes

    let prefix_get auth prefix handler routes =
      register auth ~kind:Prefix ~path:prefix ~methods:[`GET] handler routes

    let prefix_post auth prefix handler routes =
      register auth ~kind:Prefix ~path:prefix ~methods:[`POST] handler routes

    let prefix_put auth prefix handler routes =
      register auth ~kind:Prefix ~path:prefix ~methods:[`PUT] handler routes

    let prefix_delete auth prefix handler routes =
      register auth ~kind:Prefix ~path:prefix ~methods:[`DELETE] handler routes

    module Serving = struct
      let get auth path handler routes =
        add_kind Exact ~access:(access auth) ~path ~methods:[`GET]
          ~handler:(Serving (wrapped auth handler)) routes
    end

    (* The handler checks the credential before it upgrades, so the only kind
       that applies is [Self_authenticated Websocket_upgrade]. *)
    let ws_get path handler routes =
      add_kind Exact
        ~access:(Route_access.Self_authenticated Route_access.Websocket_upgrade)
        ~path ~methods:[`GET] ~handler:(Ws handler) routes
  end

  let starts_with_prefix ~prefix ~plen target target_len =
    if plen > target_len then false
    else
      let rec loop i =
        if i = plen then true
        else if String.unsafe_get prefix i = String.unsafe_get target i then
          loop (i + 1)
        else false
      in
      loop 0

  let resolve_prefix routes req_path =
    let req_len = String.length req_path in
    let rec loop = function
      | [] -> None
      | route :: rest ->
        let plen = String.length route.path in
        if starts_with_prefix ~prefix:route.path ~plen req_path req_len then
          Some route
        else loop rest
    in
    loop routes.prefix_routes

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

  let dispatch router request reqd =
    match resolve router request with
    | `Matched route -> (
        match route.handler with
        | Owner handler | Serving handler -> handler request reqd
        | Ws handler -> handler ~upgrade:(Http_reqd.upgrade reqd) request reqd)
    | `Not_found -> Response.not_found reqd
    | `Method_not_allowed -> Response.method_not_allowed reqd
end
