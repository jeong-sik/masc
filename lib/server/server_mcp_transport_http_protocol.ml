(** Server_mcp_transport_http protocol — version management, headers, session utils.

    Session state (Hashtbl tables + mutex) lives in Server_mcp_transport_http_session.
    This module includes it and adds HTTP-specific utilities. *)

module Http = Http_server_eio
module Http_negotiation = Mcp_protocol.Http_negotiation

(* Session management: single source of truth with Eio.Mutex protection.
   Brings in Mcp_eio alias, Hashtbl tables, mutex, and all session functions. *)
include Server_mcp_transport_http_session

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
