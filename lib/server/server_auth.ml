
open Masc_domain
open Server_utils

let trim_opt = function
  | None -> None
  | Some raw ->
      let value = String.trim raw in
      if value = "" then None else Some value

let configured_bind_host () =
  Env_config_core.masc_host ()

let ipaddr_is_loopback = function
  | Ipaddr.V4 addr ->
      let octets = Ipaddr.V4.to_octets addr in
      String.length octets = 4 && Char.code octets.[0] = 127
  | Ipaddr.V6 addr ->
      Ipaddr.V6.compare addr Ipaddr.V6.localhost = 0

let ipaddr_is_unspecified = function
  | Ipaddr.V4 addr -> Ipaddr.V4.compare addr Ipaddr.V4.any = 0
  | Ipaddr.V6 addr -> Ipaddr.V6.compare addr Ipaddr.V6.unspecified = 0

let is_loopback_host = Masc_network_defaults.is_loopback_host

let is_unspecified_host host =
  match Ipaddr.of_string (String.trim host) with
  | Ok ip -> ipaddr_is_unspecified ip
  | Error _ -> false

let base_url_has_non_loopback_host () =
  match Env_config_core.masc_http_base_url_result () with
  | Error _ -> false  (* no base URL configured — defer to bind-host check *)
  | Ok url -> (
      match Uri.host (Uri.of_string url) with
      | None -> true  (* fail-closed: unparseable host → treat as non-local *)
      | Some host -> not (is_loopback_host host))

let http_auth_strict_enabled () =
  Env_config.Transport.http_auth_strict_env_enabled ()
  || not (is_loopback_host (configured_bind_host ()))
  || base_url_has_non_loopback_host ()

let http_auth_bind_host () =
  configured_bind_host ()

let http_auth_bind_is_loopback () =
  is_loopback_host (configured_bind_host ())

let strict_http_auth_error endpoint =
  Printf.sprintf
    "%s requires room auth enabled with require_token=true when server is \
     bound to a non-loopback host or MASC_HTTP_BASE_URL points to a public address."
    endpoint

let ensure_strict_http_token_auth ~endpoint auth_config =
  if not (http_auth_strict_enabled ()) then
    Ok auth_config
  else if not auth_config.Masc_domain.enabled then
    Error (strict_http_auth_error endpoint)
  else if not auth_config.require_token then
    Error (strict_http_auth_error endpoint)
  else
    Ok auth_config

let bearer_token_from_header value =
  let prefix_len = 7 in (* String.length "Bearer " *)
  if String.length value > prefix_len
     && String_util.starts_with_ci ~prefix:"Bearer " value
  then Some (String.sub value prefix_len (String.length value - prefix_len))
  else None

let auth_token_from_request request =
  match
    Option.bind
      (Httpun.Headers.get request.Httpun.Request.headers "authorization")
      bearer_token_from_header
  with
  | Some _ as token -> token
  | None ->
      trim_opt
        (Httpun.Headers.get request.Httpun.Request.headers "x-masc-internal-token")

let observer_sse_query_token_from_request request =
  let path = Http_server_eio.Request.path request in
  let observer_stream_requested =
    match query_param request "sse_kind" with
    | Some raw ->
        String.equal "observer" (String.lowercase_ascii (String.trim raw))
    | None -> false
  in
  match request.Httpun.Request.meth with
  | `GET
    when (observer_stream_requested && String.equal path "/mcp")
         || String.equal path "/events/presence" ->
      trim_opt (query_param request "token")
  | _ -> None

let observer_sse_auth_token_from_request request =
  match auth_token_from_request request with
  | Some _ as token -> token
  | None -> observer_sse_query_token_from_request request

let agent_from_request request =
  let hdr key = Httpun.Headers.get request.Httpun.Request.headers key in
  let qp key = query_param request key in
  let first_some xs = List.find_map Fun.id xs in
  first_some [ hdr "x-gate-agent"; hdr "x-masc-agent"; hdr "x-masc-agent-name"; qp "agent"; qp "agent_name" ]
  |> Option.map Uri.pct_decode

let strip_prefix ~prefix value =
  let prefix_len = String.length prefix in
  if String.length value > prefix_len
     && String.starts_with ~prefix value
  then
    String.sub value prefix_len (String.length value - prefix_len)
  else value

let strip_suffix ~suffix value =
  let suffix_len = String.length suffix in
  let value_len = String.length value in
  if value_len > suffix_len
     && String.ends_with ~suffix value
  then
    String.sub value 0 (value_len - suffix_len)
  else value

let internal_keeper_agent_from_request request =
  match Httpun.Headers.get request.Httpun.Request.headers "x-masc-keeper-name" with
  | None -> None
  | Some raw ->
      let normalized =
        raw
        |> Uri.pct_decode
        |> String.trim
        |> String.lowercase_ascii
        |> strip_prefix ~prefix:"keeper-"
        |> strip_suffix ~suffix:"-agent"
      in
      if normalized = ""
      then None
      else Some (Printf.sprintf "keeper-%s-agent" normalized)

let resolve_agent_name_for_auth_raw ~base_path request ~token :
    (string option, Masc_domain.masc_error) result =
  match token with
  | Some t when Auth.verify_internal_keeper_token base_path ~token:t ->
      (match internal_keeper_agent_from_request request with
       | Some agent_name -> Ok (Some agent_name)
       | None ->
           Error
             (Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized
                "Internal keeper auth requires x-masc-keeper-name header.")))
  | Some t -> (
      match Auth.resolve_agent_from_token base_path ~token:t with
      | Ok agent_name -> Ok (Some agent_name)
      | Error err -> Error err)
  | None ->
      (match agent_from_request request with
       | Some raw when String.trim raw <> "" ->
           Ok (Some (String.trim raw))
       | _ -> Ok None)

(** Verify Bearer token for MCP endpoints *)
let verify_mcp_auth ~base_path request =
  let auth_config = Auth.load_auth_config base_path in
  match ensure_strict_http_token_auth ~endpoint:"/mcp" auth_config with
  | Error msg -> Error msg
  | Ok auth_config ->
      if not auth_config.Masc_domain.enabled then
        Ok None  (* Auth disabled - allow all *)
      else
        match auth_token_from_request request with
        | None when not auth_config.require_token ->
            Ok None  (* Token not required *)
        | None ->
            Error
              "Authentication required. Use 'Authorization: Bearer <token>' header."
        | Some token -> (
            match resolve_agent_name_for_auth_raw ~base_path request ~token:(Some token) with
            | Error err -> Error (Masc_domain.masc_error_to_string err)
            | Ok None ->
                (* Fail-closed: dead branch today (resolver:154-157 returns
                   [Ok (Some _)] or [Error] for [Some token]) but kept
                   explicit so a future [Anonymous] case cannot silently
                   rewrite to "dashboard". Spec:
                   [specs/auth/AuthIdentityFSM.tla] invariant
                   [NoSilentRewrite] (I2). *)
                Error
                  "Authentication required. Bearer token did not resolve to \
                   any agent."
            | Ok (Some agent_name) ->
                (match
                   Auth.check_permission base_path ~agent_name ~token:(Some token)
                     ~permission:Masc_domain.CanReadState
                 with
                 | Ok () -> Ok None
                 | Error err -> Error (Masc_domain.masc_error_to_string err)))

let verify_mcp_observer_stream_auth ~base_path request =
  let auth_config = Auth.load_auth_config base_path in
  match ensure_strict_http_token_auth ~endpoint:"/mcp" auth_config with
  | Error msg -> Error msg
  | Ok auth_config ->
      if not auth_config.Masc_domain.enabled then
        Ok None
      else
        match observer_sse_auth_token_from_request request with
        | None when not auth_config.require_token ->
            Ok None
        | None ->
            Error
              "Authentication required. Use 'Authorization: Bearer <token>' header \
               or 'token' query param for the observer/presence SSE stream."
        | Some token -> (
            match resolve_agent_name_for_auth_raw ~base_path request ~token:(Some token) with
            | Error err -> Error (Masc_domain.masc_error_to_string err)
            | Ok None ->
                (* Fail-closed: see verify_mcp_auth above. *)
                Error
                  "Authentication required. Bearer token did not resolve to \
                   any agent."
            | Ok (Some agent_name) ->
                (match
                   Auth.check_permission base_path ~agent_name ~token:(Some token)
                     ~permission:Masc_domain.CanReadState
                 with
                 | Ok () -> Ok None
                 | Error err -> Error (Masc_domain.masc_error_to_string err)))

let verify_operator_mcp_auth ~base_path request =
  let auth_config = Auth.load_auth_config base_path in
  if not auth_config.Masc_domain.enabled then
    Error
      "/mcp/operator requires room auth enabled with require_token=true."
  else if not auth_config.require_token then
    Error "/mcp/operator requires bearer token auth (require_token=true)."
  else
    match auth_token_from_request request with
    | None ->
        Error "Authentication required. Use 'Authorization: Bearer <token>' header."
    | Some token -> (
        match resolve_agent_name_for_auth_raw ~base_path request ~token:(Some token) with
        | Error err -> Error (Masc_domain.masc_error_to_string err)
        | Ok None ->
            (* Fail-closed: see verify_mcp_auth above. *)
            Error
              "Authentication required. Bearer token did not resolve to \
               any agent."
        | Ok (Some agent_name) ->
            (match
               Auth.check_permission base_path ~agent_name ~token:(Some token)
                 ~permission:Masc_domain.CanAdmin
             with
             | Ok () -> Ok None
             | Error err -> Error (Masc_domain.masc_error_to_string err)))

let request_actor_hint request =
  match agent_from_request request with
  | Some raw ->
      let agent_name = String.trim raw in
      if String.equal agent_name "" then None else Some agent_name
  | None -> None

let sanitize_dashboard_actor_name raw =
  let value = String.trim raw in
  let buf = Buffer.create (String.length value) in
  String.iter
    (fun c ->
      match c with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' ->
          Buffer.add_char buf c
      | _ -> ())
    value;
  Buffer.contents buf

let dashboard_actor_for_request ~base_path request =
  match auth_token_from_request request with
  | Some token -> (
      (* First 8 hex chars of the bearer token's SHA-256. Lets operators
         correlate a token-mismatch fallback with the keeper credential
         that holds the matching hash (see [auth.ml:677] credential
         storage). The hash itself is one-way; the prefix alone is
         insufficient to reconstruct the token but unique enough to
         pinpoint a specific credential rotation event in production
         logs (2026-04-27 incident: same hash prefix observed firing
         twice in the same second, masking which keeper was affected). *)
      let token_hash_prefix =
        String.sub (Auth.sha256_hash token) 0 8
      in
      match resolve_agent_name_for_auth_raw ~base_path request ~token:(Some token) with
      | Ok (Some agent_name) -> Some agent_name
      | Ok None ->
          (* PR-I: surface the silent fallback. Token did not resolve to any
             agent, so we drop to the request actor hint (header / query
             param), masking identity drift in the HTTP transport. *)
          Log.Auth.warn
            "[silent:dashboard_actor_fallback] outcome=none token_hash_prefix=%s \
             — bearer token resolved to no agent, falling back to request \
             actor hint"
            token_hash_prefix;
          Prometheus.inc_counter
            Prometheus.metric_silent_dashboard_actor_fallback
            ~labels:[ ("outcome", "none") ]
            ();
          request_actor_hint request
      | Error err ->
          (* The previous warn line elided the actual error string and the
             request actor hint, leaving operators with a counter that only
             told them *something* errored — not what.  Production logs
             showed the warn firing 1–2 times/second with no diagnostic
             surface, so the WARN was loud noise without root-cause
             attribution.  Surface both the error class and the hint. *)
          let err_str = Masc_domain.masc_error_to_string err in
          let hint =
            match request_actor_hint request with
            | Some s -> s
            | None -> "<none>"
          in
          (* err_kind is a closed enum in [Auth_error_kind] — issue #11266
             Track 2a. The stable label is shared with the MCP-side dispatch in
             [mcp_server_eio_execute.ml:silent_auth_token_error_kind]. *)
          let err_kind = Auth_error_kind.to_string (Auth_error_kind.classify err) in
          (* P3-5: token_mismatch means the dashboard's bearer token does not
             match any credential on file.  This is a structural auth-path
             defect: the dashboard is presenting a stale token from a previous
             startup or a browser session whose credential was rotated.  Add a
             one-time remediation hint to guide operators toward the fix:
             clearing the stored dashboard token causes ensure_dashboard_dev_token
             to mint a fresh one on the next page load. *)
          let extra_hint =
            if String.equal err_kind "token_mismatch" then
              " Remediation: clear the browser's stored dashboard token \
               (localStorage masc_dashboard_token) or delete \
               .masc/auth/dashboard.token so a fresh token is minted on \
               the next dashboard load."
            else ""
          in
          Log.Auth.warn
            "[silent:dashboard_actor_fallback] outcome=error \
             token_hash_prefix=%s err_kind=%s actor_hint=%s err=%s — falling \
             back to request actor hint.%s"
            token_hash_prefix err_kind hint err_str extra_hint;
          Prometheus.inc_counter
            Prometheus.metric_silent_dashboard_actor_fallback
            ~labels:[ ("outcome", "error"); ("err_kind", err_kind) ]
            ();
          request_actor_hint request)
  | None -> request_actor_hint request

let is_verified_internal_keeper_request ~base_path request =
  match auth_token_from_request request with
  | Some token when Auth.verify_internal_keeper_token base_path ~token ->
      Option.is_some (internal_keeper_agent_from_request request)
  | _ -> false

let sanitized_dashboard_actor_for_request ~base_path request =
  match dashboard_actor_for_request ~base_path request with
  | Some raw ->
      let sanitized = sanitize_dashboard_actor_name raw in
      if String.equal sanitized "" then None else Some sanitized
  | None -> None

(** Extract host and explicit port only.
    Host header carries no scheme, so inferring a default port from scheme
    (80 for http, 443 for https) causes mismatches when the browser Origin
    uses https (port 443) but we parse Host with a synthetic "http://" prefix
    (port 80).  Comparing explicit ports avoids this class of bug. *)

let default_port_of_scheme = function
  | Some "http" -> Some 80
  | Some "https" -> Some 443
  | _ -> None

let normalize_loopback_host host =
  match String.lowercase_ascii (String.trim host) with
  | "127.0.0.1" -> "localhost"
  | "::1" | "0:0:0:0:0:0:0:1" -> "localhost"
  | other -> other

let trim_nonempty raw =
  let value = String.trim raw in
  if String.equal value "" then None else Some value

let split_csv_nonempty raw =
  raw |> String.split_on_char ',' |> List.filter_map trim_nonempty

(** Returns (host, explicit_port, scheme). *)
let host_port_scheme_of_origin origin =
  try
    let uri = Uri.of_string origin in
    match Uri.host uri with
    | None -> None
    | Some host ->
        Some (String.trim host |> String.lowercase_ascii,
              Uri.port uri, Uri.scheme uri)
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.Auth.debug "host_port_scheme_of_origin: parse failed for %S: %s"
      origin (Printexc.to_string exn);
    None

let host_port_of_request request =
  match Httpun.Headers.get request.Httpun.Request.headers "host" with
  | None -> None
  | Some host_header -> (
      try
        let uri = Uri.of_string ("http://" ^ host_header) in
        match Uri.host uri with
        | None -> None
        | Some host ->
            Some (String.trim host |> String.lowercase_ascii, Uri.port uri)
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        Log.Auth.debug "host_port_of_request: parse failed for %S: %s"
          host_header (Printexc.to_string exn);
        None)

(* Evaluated at module init time (eager). MASC_ALLOW_ANONYMOUS_MUTATIONS
   must be set before the module is loaded. This is safe because the
   server process sets all env vars at startup before any module init. *)
let allow_anonymous_mutations =
  match Sys.getenv_opt "MASC_ALLOW_ANONYMOUS_MUTATIONS" with
  | Some ("1" | "true") -> true
  | _ -> false

let default_loopback_dev_mutation_origins =
  Masc_network_defaults.vite_dev_default_origins

let configured_loopback_dev_mutation_origins () =
  match Sys.getenv_opt "MASC_HTTP_DEV_MUTATION_ORIGINS" with
  | Some raw -> split_csv_nonempty raw
  | None -> default_loopback_dev_mutation_origins

let normalized_origin_key origin =
  match host_port_scheme_of_origin origin with
  | Some (host, port, scheme) ->
      let default = default_port_of_scheme scheme in
      Some
        ( normalize_loopback_host host,
          (match port with Some _ -> port | None -> default),
          Option.map String.lowercase_ascii scheme )
  | None -> None

let is_allowlisted_loopback_dev_origin origin =
  match normalized_origin_key origin with
  | Some ((host, _, _) as candidate) when is_loopback_host host ->
      configured_loopback_dev_mutation_origins ()
      |> List.filter_map normalized_origin_key
      |> List.exists (fun allowed -> allowed = candidate)
  | _ -> false

let ensure_same_origin_browser_request request :
    (unit, Masc_domain.masc_error) result =
  match Httpun.Headers.get request.Httpun.Request.headers "origin" with
  | None ->
    if allow_anonymous_mutations then Ok ()
    else
      Error (Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized
        "Authentication required: provide a bearer token or Origin header. \
         Set MASC_ALLOW_ANONYMOUS_MUTATIONS=true for local development."))
  | Some origin -> (
      match host_port_scheme_of_origin origin, host_port_of_request request with
      | Some (origin_host, origin_port, scheme),
        Some (request_host, request_port)
        when String.equal
               (normalize_loopback_host origin_host)
               (normalize_loopback_host request_host) ->
          let default = default_port_of_scheme scheme in
          let norm p = match p with Some _ -> p | None -> default in
          (* Loopback same-port remains allowed, but cross-port mutations now
             require an explicit dev-origin allowlist instead of trusting any
             localhost page. This preserves the default Vite dashboard proxy
             flow (5173 -> backend) while shrinking the browser trust boundary. *)
          if norm origin_port = norm request_port then
            Ok ()
          else if
            is_loopback_host (normalize_loopback_host origin_host)
            && is_allowlisted_loopback_dev_origin origin
          then
            Ok ()
          else (
            Log.Auth.debug
              "same-origin port mismatch: origin=%S host=%s"
              origin
              (match Httpun.Headers.get request.Httpun.Request.headers "host" with
               | Some h -> Printf.sprintf "%S" h | None -> "<absent>");
            Error
              (Masc_domain.Auth (Masc_domain.Auth_error.Forbidden
                 { agent = "browser";
                   action = "cross-origin HTTP mutation" })))
      | _ ->
          Log.Auth.debug
            "same-origin check failed: origin=%S host=%s"
            origin
            (match Httpun.Headers.get request.Httpun.Request.headers "host" with
             | Some h -> Printf.sprintf "%S" h | None -> "<absent>");
          Error
            (Masc_domain.Auth (Masc_domain.Auth_error.Forbidden
               { agent = "browser";
                 action = "cross-origin HTTP mutation" })))

let http_status_of_auth_error = function
  | Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized _ | Masc_domain.Auth_error.InvalidToken _ | Masc_domain.Auth_error.TokenExpired _) -> `Unauthorized
  | Masc_domain.Auth (Masc_domain.Auth_error.Forbidden _) -> `Forbidden
  | _ -> `Internal_server_error

(** Server state - initialized at startup *)
let server_state : Mcp_server.server_state option ref = ref None

(** CORS origin *)
let get_origin (request : Httpun.Request.t) =
  Httpun.Headers.get request.headers "origin"
  |> Option.value ~default:"*"

let public_read_cors_origin_opt (request : Httpun.Request.t) =
  match Httpun.Headers.get request.Httpun.Request.headers "origin" with
  | None -> None
  | Some origin -> (
      match host_port_scheme_of_origin origin, host_port_of_request request with
      | Some (origin_host, origin_port, scheme),
        Some (request_host, request_port)
        when String.equal
               (normalize_loopback_host origin_host)
               (normalize_loopback_host request_host) ->
          let default = default_port_of_scheme scheme in
          let norm p = match p with Some _ -> p | None -> default in
          if norm origin_port = norm request_port then
            Some origin
          else if
            is_loopback_host (normalize_loopback_host origin_host)
            && is_allowlisted_loopback_dev_origin origin
          then
            Some origin
          else
            None
      | _ when is_allowlisted_loopback_dev_origin origin -> Some origin
      | _ -> None)

(** CORS headers *)
let cors_allow_headers_value =
  "Content-Type, Accept, Origin, Authorization, Idempotency-Key, Mcp-Session-Id, \
   Mcp-Protocol-Version, Last-Event-Id, X-Gate-Agent, X-MASC-Agent, X-MASC-Agent-Name"

let cors_expose_headers_value =
  "Mcp-Session-Id, Mcp-Protocol-Version, X-RateLimit-Limit, X-RateLimit-Remaining"

let cors_headers origin =
  let base = [
    ("access-control-allow-origin", origin);
    ("access-control-allow-methods", "GET, POST, DELETE, OPTIONS");
    ("access-control-allow-headers", cors_allow_headers_value);
    ("access-control-expose-headers", cors_expose_headers_value);
    ("vary", "Origin");
  ] in
  (* CORS spec: Access-Control-Allow-Credentials must not be paired with
     wildcard "*" origin.  Only include it when reflecting a real origin. *)
  if origin <> "*" then
    ("access-control-allow-credentials", "true") :: base
  else
    base

let respond_json_with_cors ?(status = `OK) request reqd body =
  let origin = get_origin request in
  Http_server_eio.Response.json ~status ~extra_headers:(cors_headers origin) body reqd

let public_read_cors_headers request =
  match public_read_cors_origin_opt request with
  | Some origin -> cors_headers origin
  | None -> [ ("vary", "Origin") ]

let respond_public_read_json ?(status = `OK) request reqd body =
  Http_server_eio.Response.json ~status
    ~extra_headers:(public_read_cors_headers request) body reqd

let auth_error_json err =
  Yojson.Safe.to_string
    (`Assoc [ ("error", `String (Masc_domain.masc_error_to_string err)) ])

let respond_auth_error request reqd err =
  let status = http_status_of_auth_error err in
  let origin = get_origin request in
  let body = auth_error_json err in
  let headers = Httpun.Headers.of_list (
    ("content-length", string_of_int (String.length body))
    :: cors_headers origin
  ) in
  let response = Httpun.Response.create ~headers status in
  Httpun.Reqd.respond_with_string reqd response body

(** Respond with 429 Too Many Requests when the per-agent rate limit is
    exceeded.  Includes standard rate-limit headers and CORS so browser
    clients can inspect the response. *)
let respond_agent_rate_limited ~rl_key request reqd =
  let origin = get_origin request in
  let body = Rate_limit.too_many_agent_requests_body () in
  let rl_headers = Rate_limit.headers_agent_global ~key:rl_key in
  let headers = Httpun.Headers.of_list (
    ("content-type", "application/json") ::
    ("content-length", string_of_int (String.length body)) ::
    rl_headers @
    cors_headers origin
  ) in
  Httpun.Reqd.respond_with_string reqd
    (Httpun.Response.create ~headers `Too_many_requests) body

(** Extract a per-agent rate-limit key from the request.  Prefers the bearer
    token (keyed by a short SHA-256 prefix) over the declared agent-name
    header so that token-bearing clients cannot evade per-agent limits by
    rotating their agent-name header. *)
let agent_rl_key_of_request request =
  let token = auth_token_from_request request in
  let agent_name = agent_from_request request in
  Rate_limit.agent_key_of_token_or_name ?token ?agent_name ()

(** Check the per-agent rate limit for a request.  Returns [Ok ()] when the
    request is allowed.  Returns [Error ()] and sends a 429 response when the
    per-agent limit is exceeded.  Anonymous requests (no token, no agent
    header) are always allowed through — the per-IP limit in
    [bin/main_eio.ml:try_rate_limit_block] covers that case. *)
let check_agent_rate_limit request reqd =
  match agent_rl_key_of_request request with
  | None -> Ok ()  (* anonymous — covered by per-IP limit *)
  | Some rl_key ->
      if Rate_limit.check_agent_global ~key:rl_key then
        Ok ()
      else begin
        respond_agent_rate_limited ~rl_key request reqd;
        Error ()
      end

(** Admin-only access - requires MASC_ADMIN_TOKEN.
    Uses timing-safe comparison (XOR-based constant-time) to prevent
    timing side-channel attacks that could leak token bytes. *)
let with_admin_auth handler request reqd =
  match !server_state with
  | None -> Http_server_eio.Response.json {|{"error":"not initialized"}|} reqd
  | Some state ->
      let admin_token = Env_config_core.admin_token_opt () in
      let provided = auth_token_from_request request in
      match admin_token, provided with
      | None, _ ->
          Http_server_eio.Response.json ~status:`Forbidden
            {|{"error":"MASC_ADMIN_TOKEN not configured"}|} reqd
      | Some _, None ->
          Http_server_eio.Response.json ~status:`Unauthorized
            {|{"error":"Admin token required"}|} reqd
      | Some expected, Some given ->
          (* Constant-time comparison: always XOR max(len_a, len_b) bytes.
             Length difference is folded into the diff accumulator so both
             length and content mismatches cost the same wall-clock time. *)
          let len_a = String.length expected in
          let len_b = String.length given in
          let max_len = max len_a len_b in
          let diff = ref (len_a lxor len_b) in
          for i = 0 to max_len - 1 do
            let a = if i < len_a then Char.code expected.[i] else 0 in
            let b = if i < len_b then Char.code given.[i] else 0 in
            diff := !diff lor (a lxor b)
          done;
          if !diff = 0 then
            handler state request reqd
          else
            Http_server_eio.Response.json ~status:`Forbidden
              {|{"error":"Invalid admin token"}|} reqd

(** Public read access - no auth required (dashboard, health) *)
let is_public_read_path path =
  String.equal path "/health"
  (* Issue #8403: derive probe whitelist from Server_health_paths SSOT
     so adding/renaming a probe automatically refreshes the auth filter
     instead of leaking an auth-required probe through. *)
  || Server_health_paths.is_public path
  || String.equal path "/api/v1/gate/health"
  || String.equal path "/api/v1/gate/status"
  || String.equal path "/api/v1/gate/connectors"
  || String.equal path "/api/v1/gate/connector/status"
  || String.equal path "/api/v1/gate/events"
  || String.equal path "/"
  || String.equal path "/dashboard"
  || String.equal path "/dashboard/"
  || String.equal path "/favicon.ico"
  || String.equal path "/favicon.svg"
  || String.starts_with ~prefix:"/dashboard/" path
  || String.starts_with ~prefix:"/static/" path
  || String.starts_with ~prefix:"/graphiql/" path
  (* Tier F2 dashboard reads — multimodal artifact gallery + detail
     panel. The Bonsai dashboard issues these via [Brr_io.Fetch.url]
     with no credentials, mirroring the rest of the dashboard's
     read-only surface. Routes themselves are wrapped in
     [with_public_read] in [server_routes_http_routes_multimodal];
     this whitelist entry is what makes that wrapper actually
     public when [http_auth_strict_enabled] is on. *)
  || String.starts_with ~prefix:"/api/v1/multimodal/list" path
  || String.starts_with ~prefix:"/api/v1/multimodal/get/" path
  || String.starts_with ~prefix:"/api/v1/multimodal/provenance/" path

let resolve_agent_name_for_auth ~base_path request ~token :
    (string option, Masc_domain.masc_error) result =
  resolve_agent_name_for_auth_raw ~base_path request ~token

let authorize_permission_request ~base_path ~permission request :
    (unit, Masc_domain.masc_error) result =
  let auth_cfg = Auth.load_auth_config base_path in
  let token = auth_token_from_request request in
  match ensure_strict_http_token_auth ~endpoint:"HTTP read access" auth_cfg with
  | Error msg -> Error (Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized msg))
  | Ok auth_cfg -> (
      match resolve_agent_name_for_auth ~base_path request ~token with
      | Error err -> Error err
      | Ok agent_name_opt ->
          let agent_name = Option.value ~default:"dashboard" agent_name_opt in
          if
            auth_cfg.enabled && auth_cfg.require_token && token <> None
            && agent_name_opt = None
          then
            Error
              (Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized
                 "Agent name required (X-Gate-Agent / X-MASC-Agent or token-bound credential)"))
          else
            Auth.check_permission base_path ~agent_name ~token ~permission)

let authorize_read_request ~base_path request : (unit, Masc_domain.masc_error) result =
  authorize_permission_request ~base_path ~permission:Masc_domain.CanReadState request

let authorize_tool_request ~base_path ~tool_name request :
    (unit, Masc_domain.masc_error) result =
  let auth_cfg = Auth.load_auth_config base_path in
  let token = auth_token_from_request request in
  match
    if Option.is_some token then Ok ()
    else ensure_same_origin_browser_request request
  with
  | Error err -> Error err
  | Ok () ->
      (match ensure_strict_http_token_auth
               ~endpoint:("HTTP tool access for " ^ tool_name) auth_cfg
       with
  | Error msg -> Error (Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized msg))
  | Ok auth_cfg -> (
      match resolve_agent_name_for_auth ~base_path request ~token with
      | Error err -> Error err
      | Ok agent_name_opt ->
          let agent_name = Option.value ~default:"dashboard" agent_name_opt in
          if
            auth_cfg.enabled && auth_cfg.require_token && token <> None
            && agent_name_opt = None
          then
            Error
              (Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized
                 "Agent name required (X-Gate-Agent / X-MASC-Agent or token-bound credential)"))
          else
            Auth.authorize_tool_v2 base_path ~agent_name ~token ~tool_name))

let authorize_token_bound_permission_request ~base_path ~permission request :
    (string, Masc_domain.masc_error) result =
  let auth_cfg = Auth.load_auth_config base_path in
  if not auth_cfg.enabled then
    Error
      (Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized
         "HTTP mutation requires room auth enabled with require_token=true."))
  else if not auth_cfg.require_token then
    Error
      (Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized
         "HTTP mutation requires bearer token auth (require_token=true)."))
  else
    match auth_token_from_request request with
    | None ->
        Error
          (Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized
             "Authentication required. Use 'Authorization: Bearer <token>' header."))
    | Some token -> (
        match Auth.find_credential_by_token base_path ~token with
        | Error err -> Error err
        | Ok cred ->
            if Masc_domain.has_permission cred.role permission then
              Ok cred.agent_name
            else
              Error
                (Masc_domain.Auth (Masc_domain.Auth_error.Forbidden
                   {
                     agent = cred.agent_name;
                     action = Masc_domain.show_permission permission;
                   })))

let is_dashboard_bootstrap_path path =
  String.starts_with ~prefix:"/api/v1/dashboard/" path

let not_initialized_response path =
  if is_dashboard_bootstrap_path path then
    {|{"status":"initializing","message":"Server is warming up"}|}
  else
    {|{"error":"not initialized"}|}

let rec with_public_read handler request reqd =
  let strict = http_auth_strict_enabled () in
  let path = Http_server_eio.Request.path request in
  if strict && not (is_public_read_path path) then
    with_read_auth handler request reqd
  else
    match !server_state with
    | None -> Http_server_eio.Response.json (not_initialized_response path) reqd
    | Some state -> handler state request reqd

and with_read_auth handler request reqd =
  match !server_state with
  | None -> Http_server_eio.Response.json {|{"error":"not initialized"}|} reqd
  | Some state ->
      let base_path = state.Mcp_server.room_config.base_path in
      (match authorize_read_request ~base_path request with
      | Ok () ->
          (match check_agent_rate_limit request reqd with
          | Ok () -> handler state request reqd
          | Error () -> ())
      | Error err -> respond_auth_error request reqd err)

and with_permission_auth ~permission handler request reqd =
  match !server_state with
  | None -> Http_server_eio.Response.json {|{"error":"not initialized"}|} reqd
  | Some state ->
      let base_path = state.Mcp_server.room_config.base_path in
      (match authorize_permission_request ~base_path ~permission request with
      | Ok () ->
          (match check_agent_rate_limit request reqd with
          | Ok () -> handler state request reqd
          | Error () -> ())
      | Error err -> respond_auth_error request reqd err)

and with_tool_auth ~tool_name handler request reqd =
  match !server_state with
  | None -> Http_server_eio.Response.json {|{"error":"not initialized"}|} reqd
  | Some state ->
      let base_path = state.Mcp_server.room_config.base_path in
      (match authorize_tool_request ~base_path ~tool_name request with
      | Ok () ->
          (match check_agent_rate_limit request reqd with
          | Ok () -> handler state request reqd
          | Error () -> ())
      | Error err -> respond_auth_error request reqd err)

and with_token_permission_auth ~permission handler request reqd =
  match !server_state with
  | None -> Http_server_eio.Response.json {|{"error":"not initialized"}|} reqd
  | Some state ->
      let base_path = state.Mcp_server.room_config.base_path in
      (match authorize_token_bound_permission_request ~base_path ~permission request with
      | Ok agent_name ->
          (match check_agent_rate_limit request reqd with
          | Ok () -> handler state agent_name request reqd
          | Error () -> ())
      | Error err -> respond_auth_error request reqd err)
