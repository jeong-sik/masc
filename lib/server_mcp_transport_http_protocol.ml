[@@@warning "-32-33-69"]
(** Server_mcp_transport_http protocol — version management, headers, session utils. *)

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
