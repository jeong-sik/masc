[@@@warning "-32-69"]

open Types
open Server_utils

(** Extract Bearer token from Authorization header *)
let extract_bearer_token request =
  match Httpun.Headers.get request.Httpun.Request.headers "authorization" with
  | Some auth_header ->
    if String.length auth_header > 7 &&
       String.lowercase_ascii (String.sub auth_header 0 7) = "bearer " then
      Some (String.sub auth_header 7 (String.length auth_header - 7))
    else
      None
  | None -> None

(** Verify Bearer token for MCP endpoints *)
let verify_mcp_auth ~base_path request =
  let auth_config = Auth.load_auth_config base_path in
  if not auth_config.Types.enabled then
    Ok None  (* Auth disabled - allow all *)
  else
    match extract_bearer_token request with
    | None when not auth_config.require_token ->
      Ok None  (* Token not required *)
    | None ->
      Error "Authentication required. Use 'Authorization: Bearer <token>' header."
    | Some token ->
      (* Try to find agent by token hash *)
      let token_hash = Auth.sha256_hash token in
      let creds = Auth.list_credentials base_path in
      match List.find_opt (fun c -> c.Types.token = token_hash) creds with
      | None -> Error "Invalid token"
      | Some cred ->
        (* Check expiry *)
        match cred.expires_at with
        | None -> Ok (Some cred)
        | Some exp_str ->
          let now = Types.now_iso () in
          if now > exp_str then
            Error ("Token expired for " ^ cred.agent_name)
          else
            Ok (Some cred)

let verify_operator_mcp_auth ~base_path request =
  let auth_config = Auth.load_auth_config base_path in
  if not auth_config.Types.enabled then
    Error "/mcp/operator requires token auth to be enabled for this room."
  else if not auth_config.require_token then
    Error "/mcp/operator requires bearer token auth (require_token=true)."
  else
    match extract_bearer_token request with
    | None ->
        Error "Authentication required. Use 'Authorization: Bearer <token>' header."
    | Some token -> (
        match Auth.find_credential_by_token base_path ~token with
        | Ok cred -> Ok (Some cred)
        | Error err -> Error (Types.masc_error_to_string err))


let bearer_token_from_header value =
  let prefix = "Bearer " in
  let prefix_lower = "bearer " in
  if String.length value >= String.length prefix &&
     String.sub value 0 (String.length prefix) = prefix then
    Some (String.sub value (String.length prefix) (String.length value - String.length prefix))
  else if String.length value >= String.length prefix_lower &&
          String.sub value 0 (String.length prefix_lower) = prefix_lower then
    Some (String.sub value (String.length prefix_lower) (String.length value - String.length prefix_lower))
  else
    None

let auth_token_from_request request =
  match Httpun.Headers.get request.Httpun.Request.headers "authorization" with
  | Some v -> bearer_token_from_header v
  | None -> query_param request "token"

let env_flag_enabled name =
  match Sys.getenv_opt name with
  | None -> false
  | Some raw ->
      let v = String.trim raw |> String.lowercase_ascii in
      v = "1" || v = "true" || v = "yes" || v = "y" || v = "on"

let http_auth_strict_enabled () = env_flag_enabled "MASC_HTTP_AUTH_STRICT"

let http_status_of_auth_error = function
  | Types.Unauthorized _ | Types.InvalidToken _ | Types.TokenExpired _ -> `Unauthorized
  | Types.Forbidden _ -> `Forbidden
  | _ -> `Internal_server_error

(** Server state - initialized at startup *)
let server_state : Mcp_server.server_state option ref = ref None

(** CORS origin *)
let get_origin (request : Httpun.Request.t) =
  match Httpun.Headers.get request.headers "origin" with
  | Some o -> o
  | None -> "*"

(** CORS headers *)
let cors_allow_headers_value =
  "Content-Type, Accept, Origin, Authorization, Idempotency-Key, Mcp-Session-Id, \
   Mcp-Protocol-Version, Last-Event-Id, X-MASC-Agent, X-MASC-Agent-Name"

let cors_headers origin = [
  ("access-control-allow-origin", origin);
  ("access-control-allow-methods", "GET, POST, DELETE, OPTIONS");
  ("access-control-allow-headers", cors_allow_headers_value);
  ("access-control-expose-headers", "Mcp-Session-Id, Mcp-Protocol-Version");
  ("access-control-allow-credentials", "true");
]

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
      let admin_token = Sys.getenv_opt "MASC_ADMIN_TOKEN" in
      let provided = auth_token_from_request request in
      match admin_token, provided with
      | None, _ ->
          Http_server_eio.Response.json ~status:`Forbidden
            {|{"error":"MASC_ADMIN_TOKEN not configured"}|} reqd
      | Some _, None ->
          Http_server_eio.Response.json ~status:`Unauthorized
            {|{"error":"Admin token required"}|} reqd
      | Some expected, Some given ->
          (* Timing-safe comparison: XOR all bytes, accumulate differences.
             Runs in constant time regardless of where mismatch occurs. *)
          let len_eq = String.length expected = String.length given in
          let content_eq =
            if not len_eq then false
            else
              let diff = ref 0 in
              for i = 0 to String.length expected - 1 do
                diff := !diff lor (Char.code expected.[i] lxor Char.code given.[i])
              done;
              !diff = 0
          in
          if len_eq && content_eq then
            handler state request reqd
          else
            Http_server_eio.Response.json ~status:`Forbidden
              {|{"error":"Invalid admin token"}|} reqd

(** Public read access - no auth required (dashboard, health) *)
let is_public_read_path path =
  String.equal path "/health"
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
  | Some raw when String.trim raw <> "" -> Ok (Some (String.trim raw))
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
  match resolve_agent_name_for_auth ~base_path request ~token with
  | Error err -> Error err
  | Ok agent_name_opt ->
      let agent_name = Option.value ~default:"dashboard" agent_name_opt in
      if auth_cfg.enabled && auth_cfg.require_token && token <> None && agent_name_opt = None then
        Error
          (Types.Unauthorized
             "Agent name required (X-MASC-Agent or token-bound credential)")
      else
        Auth.check_permission base_path ~agent_name ~token
          ~permission

let authorize_read_request ~base_path request : (unit, Types.masc_error) result =
  authorize_permission_request ~base_path ~permission:Types.CanReadState request

let rec with_public_read handler request reqd =
  let strict = http_auth_strict_enabled () in
  let path = Http_server_eio.Request.path request in
  if strict && not (is_public_read_path path) then
    with_read_auth handler request reqd
  else
    match !server_state with
    | None -> Http_server_eio.Response.json {|{"error":"not initialized"}|} reqd
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

