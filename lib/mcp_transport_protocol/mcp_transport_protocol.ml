(** MCP Protocol Utilities.

    SSOT for JSON-RPC types, protocol version negotiation,
    and HTTP content negotiation for MCP Streamable HTTP transport.

    JSON-RPC core: request/response types, builders, validators.
    Protocol version: supported versions, validation, normalization.
    HTTP negotiation: delegates parsing to {!Mcp_protocol.Http_negotiation}
    (SDK); adds [accept_mode] with [Legacy_accepted] for backward-compat. *)

(* ── JSON-RPC core types ─────────────────────────────────── *)

type jsonrpc_request =
  { jsonrpc : string
  ; id : Yojson.Safe.t option [@default None]
  ; method_ : string [@key "method"]
  ; params : Yojson.Safe.t option [@default None]
  }
[@@deriving yojson { strict = false }]

let has_field key = function
  | `Assoc fields -> List.exists (fun (k, _) -> k = key) fields
  | _ -> false
;;

let get_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let is_jsonrpc_v2 json =
  match get_field "jsonrpc" json with
  | Some (`String "2.0") -> true
  | _ -> false
;;

let is_jsonrpc_response json =
  match json with
  | `Assoc _ ->
    let has_result = has_field "result" json in
    let has_error = has_field "error" json in
    let has_method = has_field "method" json in
    let has_id = has_field "id" json in
    is_jsonrpc_v2 json && has_id && (has_result || has_error) && not has_method
  | _ -> false
;;

let is_notification req = req.id = None

let get_id req =
  match req.id with
  | Some id -> id
  | None -> `Null
;;

let is_valid_request_id = function
  | `Null | `String _ | `Int _ | `Intlit _ | `Float _ -> true
  | _ -> false
;;

let validate_initialize_params params =
  let ( let* ) = Result.bind in
  let require_string label = function
    | Some (`String _) -> Ok ()
    | None | Some `Null -> Error ("Missing " ^ label)
    | Some _ -> Error ("Invalid " ^ label)
  in
  let require_assoc label = function
    | Some (`Assoc _ as v) -> Ok v
    | None | Some `Null -> Error ("Missing " ^ label)
    | Some _ -> Error ("Invalid " ^ label)
  in
  match params with
  | None -> Error "Missing params"
  | Some (`Assoc _ as p) ->
    let* () = require_string "protocolVersion" (get_field "protocolVersion" p) in
    let* client_info = require_assoc "clientInfo" (get_field "clientInfo" p) in
    let* () = require_string "clientInfo.name" (get_field "name" client_info) in
    let* () = require_string "clientInfo.version" (get_field "version" client_info) in
    let* _ = require_assoc "capabilities" (get_field "capabilities" p) in
    Ok ()
  | Some _ -> Error "Invalid params: expected object"
;;

(* ── JSON-RPC response builders ──────────────────────────── *)

let make_response ~id result =
  `Assoc [ "jsonrpc", `String "2.0"; "id", id; "result", result ]
;;

let make_error ?data ~id code message =
  let error_fields = [ "code", `Int code; "message", `String message ] in
  let error_fields =
    match data with
    | None -> error_fields
    | Some payload -> error_fields @ [ "data", payload ]
  in
  `Assoc [ "jsonrpc", `String "2.0"; "id", id; "error", `Assoc error_fields ]
;;

let jsonrpc_notification ?params method_name =
  let base = [ "jsonrpc", `String "2.0"; "method", `String method_name ] in
  `Assoc
    (base
     @
     match params with
     | Some params -> [ "params", params ]
     | None -> [])
;;

(* ── HTTP content negotiation ────────────────────────────── *)

module Http_negotiation = struct
  (** MASC-specific accept classification.
      [Legacy_accepted] has no SDK equivalent — it gates on
      [MASC_ALLOW_LEGACY_ACCEPT] to accept requests that lack both
      JSON and SSE in the Accept header. *)
  type accept_mode =
    | Streamable
    | Legacy_accepted
    | Rejected

  (* Re-export SDK constants so callers' [Http_negotiation.sse_content_type]
     keeps compiling without an extra open. *)
  let sse_content_type = Mcp_protocol.Http_negotiation.sse_content_type
  let json_content_type = Mcp_protocol.Http_negotiation.json_content_type

  let exists_accepted h ~check =
    Mcp_protocol.Http_negotiation.parse_accept_header h
    |> List.exists (fun (mt : Mcp_protocol.Http_negotiation.media_type) ->
      mt.quality > 0.0
      && check
           ~type_:(String.lowercase_ascii mt.type_)
           ~subtype:(String.lowercase_ascii mt.subtype))
  ;;

  (* [exists_accepted] already passes [type_]/[subtype] lowercased to
     [check] (see above), so callbacks compare against lowercase
     literals directly — no second lowercase allocation per media
     type. *)
  let accepts_sse_header = function
    | None -> false
    | Some h ->
      exists_accepted h ~check:(fun ~type_ ~subtype ->
        type_ = "text" && subtype = "event-stream")
  ;;

  let accepts_json = function
    | None -> false
    | Some h ->
      exists_accepted h ~check:(fun ~type_ ~subtype ->
        (type_ = "application" && subtype = "json") || (type_ = "*" && subtype = "*"))
  ;;

  let accepts_streamable_mcp = function
    | None -> false
    | Some h -> accepts_json (Some h) && accepts_sse_header (Some h)
  ;;

  let classify_mcp_accept ~allow_legacy accept_header =
    if accepts_streamable_mcp accept_header
    then Streamable
    else if allow_legacy
    then Legacy_accepted
    else Rejected
  ;;
end

let supported_protocol_versions = Mcp_protocol.Version.supported_versions
let default_protocol_version = Mcp_protocol.Version.latest
let is_supported_protocol_version version = Mcp_protocol.Version.is_supported version

let validate_protocol_version version =
  if is_supported_protocol_version version
  then Ok version
  else
    Error
      (Printf.sprintf
         "Unsupported protocolVersion '%s' (supported: %s)"
         version
         (String.concat ", " supported_protocol_versions))
;;

let normalize_protocol_version version =
  if is_supported_protocol_version version then version else default_protocol_version
;;

let protocol_version_from_params = function
  | Some (`Assoc fields) ->
    (match List.assoc_opt "protocolVersion" fields with
     | Some (`String version) -> version
     | _ -> default_protocol_version)
  | _ -> default_protocol_version
;;

let protocol_version_from_initialize_request_json = function
  | `Assoc fields ->
    (match List.assoc_opt "jsonrpc" fields, List.assoc_opt "method" fields with
     | Some (`String "2.0"), Some (`String "initialize") ->
       let params = List.assoc_opt "params" fields in
       Some (protocol_version_from_params params |> normalize_protocol_version)
     | _ -> None)
  | _ -> None
;;

let protocol_version_from_body body_str =
  try
    Yojson.Safe.from_string body_str |> protocol_version_from_initialize_request_json
  with
  | Yojson.Json_error _ -> None
;;
