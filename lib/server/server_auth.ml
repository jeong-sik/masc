
open Types
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

let is_loopback_host host =
  let normalized = String.trim host |> String.lowercase_ascii in
  match normalized with
  | "localhost" -> true
  | _ -> (
      match Ipaddr.of_string normalized with
      | Ok ip -> ipaddr_is_loopback ip
      | Error _ -> false)

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
  else if not auth_config.Types.enabled then
    Error (strict_http_auth_error endpoint)
  else if not auth_config.require_token then
    Error (strict_http_auth_error endpoint)
  else
    Ok auth_config

let bearer_token_from_header value =
  let prefix_len = 7 in (* String.length "Bearer " *)
  if String.length value > prefix_len
     && String.lowercase_ascii (String.sub value 0 prefix_len) = "bearer "
  then Some (String.sub value prefix_len (String.length value - prefix_len))
  else None

let auth_token_from_request request =
  Option.bind
    (Httpun.Headers.get request.Httpun.Request.headers "authorization")
    bearer_token_from_header

(** Verify Bearer token for MCP endpoints *)
let verify_mcp_auth ~base_path request =
  let auth_config = Auth.load_auth_config base_path in
  match ensure_strict_http_token_auth ~endpoint:"/mcp" auth_config with
  | Error msg -> Error msg
  | Ok auth_config ->
      if not auth_config.Types.enabled then
        Ok None  (* Auth disabled - allow all *)
      else
        match auth_token_from_request request with
        | None when not auth_config.require_token ->
            Ok None  (* Token not required *)
        | None ->
            Error
              "Authentication required. Use 'Authorization: Bearer <token>' header."
        | Some token -> (
            match Auth.find_credential_by_token base_path ~token with
            | Ok cred -> Ok (Some cred)
            | Error err -> Error (Types.masc_error_to_string err))

let verify_operator_mcp_auth ~base_path request =
  let auth_config = Auth.load_auth_config base_path in
  if not auth_config.Types.enabled then
    Error
      "/mcp/operator requires room auth enabled with require_token=true."
  else if not auth_config.require_token then
    Error "/mcp/operator requires bearer token auth (require_token=true)."
  else
    match auth_token_from_request request with
    | None ->
        Error "Authentication required. Use 'Authorization: Bearer <token>' header."
    | Some token -> (
        match Auth.find_credential_by_token base_path ~token with
        | Ok cred -> Ok (Some cred)
        | Error err -> Error (Types.masc_error_to_string err))

let agent_from_request request =
  let hdr key = Httpun.Headers.get request.Httpun.Request.headers key in
  let qp key = query_param request key in
  let first_some xs = List.find_map Fun.id xs in
  first_some [ hdr "x-gate-agent"; hdr "x-masc-agent"; hdr "x-masc-agent-name"; qp "agent"; qp "agent_name" ]
  |> Option.map Uri.pct_decode

let is_transient_actor_name name =
  let normalized = String.trim name in
  normalized <> ""
  && (String.starts_with ~prefix:"agent-" normalized
      || Nickname.is_generated_nickname normalized)

(** Extract host and explicit port only.
    Host header carries no scheme, so inferring a default port from scheme
    (80 for http, 443 for https) causes mismatches when the browser Origin
    uses https (port 443) but we parse Host with a synthetic "http://" prefix
    (port 80).  Comparing explicit ports avoids this class of bug. *)

let default_port_of_scheme = function
  | Some "http" -> Some 80
  | Some "https" -> Some 443
  | _ -> None

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

let ensure_same_origin_browser_request request :
    (unit, Types.masc_error) result =
  match Httpun.Headers.get request.Httpun.Request.headers "origin" with
  | None ->
    if allow_anonymous_mutations then Ok ()
    else
      Error (Types.Unauthorized
        "Authentication required: provide a bearer token or Origin header. \
         Set MASC_ALLOW_ANONYMOUS_MUTATIONS=true for local development.")
  | Some origin -> (
      match host_port_scheme_of_origin origin, host_port_of_request request with
      | Some (origin_host, origin_port, scheme),
        Some (request_host, request_port)
        when String.equal origin_host request_host ->
          (* Normalize implicit ports using Origin's scheme so that
             e.g. Origin "https://h" (port=None→443) matches Host "h:443". *)
          let default = default_port_of_scheme scheme in
          let norm p = match p with Some _ -> p | None -> default in
          if norm origin_port = norm request_port then Ok ()
          else (
            Log.Auth.debug
              "same-origin port mismatch: origin=%S host=%s"
              origin
              (match Httpun.Headers.get request.Httpun.Request.headers "host" with
               | Some h -> Printf.sprintf "%S" h | None -> "<absent>");
            Error
              (Types.Forbidden
                 { agent = "browser";
                   action = "cross-origin HTTP mutation" }))
      | _ ->
          Log.Auth.debug
            "same-origin check failed: origin=%S host=%s"
            origin
            (match Httpun.Headers.get request.Httpun.Request.headers "host" with
             | Some h -> Printf.sprintf "%S" h | None -> "<absent>");
          Error
            (Types.Forbidden
               { agent = "browser";
                 action = "cross-origin HTTP mutation" }))

let http_status_of_auth_error = function
  | Types.Unauthorized _ | Types.InvalidToken _ | Types.TokenExpired _ -> `Unauthorized
  | Types.Forbidden _ -> `Forbidden
  | _ -> `Internal_server_error

(** Server state - initialized at startup *)
let server_state : Mcp_server.server_state option ref = ref None

(** CORS origin *)
let get_origin (request : Httpun.Request.t) =
  Httpun.Headers.get request.headers "origin"
  |> Option.value ~default:"*"

(** CORS headers *)
let cors_allow_headers_value =
  "Content-Type, Accept, Origin, Authorization, Idempotency-Key, Mcp-Session-Id, \
   Mcp-Protocol-Version, Last-Event-Id, X-Gate-Agent, X-MASC-Agent, X-MASC-Agent-Name"

let cors_headers origin =
  let base = [
    ("access-control-allow-origin", origin);
    ("access-control-allow-methods", "GET, POST, DELETE, OPTIONS");
    ("access-control-allow-headers", cors_allow_headers_value);
    ("access-control-expose-headers", "Mcp-Session-Id, Mcp-Protocol-Version");
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

let auth_error_json err =
  Yojson.Safe.to_string
    (`Assoc [ ("error", `String (Types.masc_error_to_string err)) ])

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
  || String.equal path "/health/live"
  || String.equal path "/health/ready"
  || String.equal path "/api/v1/gate/health"
  || String.equal path "/api/v1/gate/status"
  || String.equal path "/api/v1/gate/discord/status"
  || String.equal path "/api/v1/gate/events"
  || String.equal path "/"
  || String.equal path "/dashboard"
  || String.equal path "/dashboard/"
  || String.equal path "/favicon.ico"
  || String.equal path "/favicon.svg"
  || String.starts_with ~prefix:"/dashboard/" path
  || String.starts_with ~prefix:"/static/" path
  || String.starts_with ~prefix:"/graphiql/" path

let resolve_agent_name_for_auth ~base_path request ~token :
    (string option, Types.masc_error) result =
  match agent_from_request request with
  | Some raw when String.trim raw <> "" ->
      let agent_name = String.trim raw in
      if is_transient_actor_name agent_name then
        (match token with
         | Some t ->
             (match Auth.resolve_agent_from_token base_path ~token:t with
              | Ok resolved -> Ok (Some resolved)
              | Error (Types.InvalidToken _ as e) -> Error e
              | Error (Types.TokenExpired _ as e) -> Error e
              | Error _ -> Ok (Some agent_name))
         | None -> Ok (Some agent_name))
      else
        Ok (Some agent_name)
  | _ ->
      (match token with
       | None -> Ok None
       | Some t ->
           (match Auth.resolve_agent_from_token base_path ~token:t with
            | Ok agent_name -> Ok (Some agent_name)
            | Error (Types.InvalidToken _ as e) -> Error e
            | Error (Types.TokenExpired _ as e) -> Error e
            | Error _ -> Ok None))

let authorize_permission_request ~base_path ~permission request :
    (unit, Types.masc_error) result =
  let auth_cfg = Auth.load_auth_config base_path in
  let token = auth_token_from_request request in
  match ensure_strict_http_token_auth ~endpoint:"HTTP read access" auth_cfg with
  | Error msg -> Error (Types.Unauthorized msg)
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
              (Types.Unauthorized
                 "Agent name required (X-Gate-Agent / X-MASC-Agent or token-bound credential)")
          else
            Auth.check_permission base_path ~agent_name ~token ~permission)

let authorize_read_request ~base_path request : (unit, Types.masc_error) result =
  authorize_permission_request ~base_path ~permission:Types.CanReadState request

let authorize_tool_request ~base_path ~tool_name request :
    (unit, Types.masc_error) result =
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
  | Error msg -> Error (Types.Unauthorized msg)
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
              (Types.Unauthorized
                 "Agent name required (X-Gate-Agent / X-MASC-Agent or token-bound credential)")
          else
            Auth.authorize_tool_v2 base_path ~agent_name ~token ~tool_name))

let authorize_token_bound_permission_request ~base_path ~permission request :
    (string, Types.masc_error) result =
  let auth_cfg = Auth.load_auth_config base_path in
  if not auth_cfg.enabled then
    Error
      (Types.Unauthorized
         "HTTP mutation requires room auth enabled with require_token=true.")
  else if not auth_cfg.require_token then
    Error
      (Types.Unauthorized
         "HTTP mutation requires bearer token auth (require_token=true).")
  else
    match auth_token_from_request request with
    | None ->
        Error
          (Types.Unauthorized
             "Authentication required. Use 'Authorization: Bearer <token>' header.")
    | Some token -> (
        match Auth.find_credential_by_token base_path ~token with
        | Error err -> Error err
        | Ok cred ->
            if Types.has_permission cred.role permission then
              Ok cred.agent_name
            else
              Error
                (Types.Forbidden
                   {
                     agent = cred.agent_name;
                     action = Types.show_permission permission;
                   }))

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
      match authorize_read_request ~base_path request with
      | Ok () -> handler state request reqd
      | Error err -> respond_auth_error request reqd err

and with_permission_auth ~permission handler request reqd =
  match !server_state with
  | None -> Http_server_eio.Response.json {|{"error":"not initialized"}|} reqd
  | Some state ->
      let base_path = state.Mcp_server.room_config.base_path in
      match authorize_permission_request ~base_path ~permission request with
      | Ok () -> handler state request reqd
      | Error err -> respond_auth_error request reqd err

and with_tool_auth ~tool_name handler request reqd =
  match !server_state with
  | None -> Http_server_eio.Response.json {|{"error":"not initialized"}|} reqd
  | Some state ->
      let base_path = state.Mcp_server.room_config.base_path in
      match authorize_tool_request ~base_path ~tool_name request with
      | Ok () -> handler state request reqd
      | Error err -> respond_auth_error request reqd err

and with_token_permission_auth ~permission handler request reqd =
  match !server_state with
  | None -> Http_server_eio.Response.json {|{"error":"not initialized"}|} reqd
  | Some state ->
      let base_path = state.Mcp_server.room_config.base_path in
      match authorize_token_bound_permission_request ~base_path ~permission request with
      | Ok agent_name -> handler state agent_name request reqd
      | Error err -> respond_auth_error request reqd err

let serve_agent_card ~host ~port request reqd =
  with_read_auth
    (fun _state req reqd ->
      let host_header = Httpun.Headers.get req.Httpun.Request.headers "host" in
      let resolved_host, resolved_port =
        match host_header with
        | None -> (host, port)
        | Some host_value -> (
            match String.split_on_char ':' host_value with
            | [ host_name ] -> (host_name, port)
            | host_name :: port_str :: _ ->
                let resolved_port =
                  Option.value ~default:port (int_of_string_opt port_str)
                in
                (host_name, resolved_port)
            | _ -> (host, port))
      in
      let (_card, json) =
        Agent_card.get_cached ~host:resolved_host
          ~port:resolved_port ~schemas:Config.raw_all_tool_schemas ()
      in
      let a2a_version = A2a_tools.default_a2a_version in
      Http_server_eio.Response.json ~extra_headers:[ ("A2A-Version", a2a_version) ] json
        reqd)
    request reqd
