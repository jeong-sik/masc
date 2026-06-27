(** MCP Protocol Utilities.

    SSOT for JSON-RPC types, protocol version negotiation,
    and HTTP content negotiation for MCP Streamable HTTP transport.

    JSON-RPC core: request/response types, builders, validators.
    Protocol version: supported versions, validation, normalization.
    HTTP negotiation: delegates parsing to {!Mcp_protocol.Http_negotiation}
    (SDK) and classifies the Streamable HTTP Accept contract. *)

(* ── JSON-RPC core types ─────────────────────────────────── *)

type jsonrpc_request = {
  jsonrpc : string;
  id : Yojson.Safe.t option; [@default None]
  method_ : string; [@key "method"]
  params : Yojson.Safe.t option; [@default None]
} [@@deriving yojson { strict = false }]

let has_field key = function
  | `Assoc fields -> List.exists (fun (k, _) -> k = key) fields
  | _ -> false

let get_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let is_jsonrpc_v2 json =
  match get_field "jsonrpc" json with
  | Some (`String "2.0") -> true
  | _ -> false

let is_jsonrpc_response json =
  match json with
  | `Assoc _ ->
      let has_result = has_field "result" json in
      let has_error = has_field "error" json in
      let has_method = has_field "method" json in
      let has_id = has_field "id" json in
      is_jsonrpc_v2 json && has_id && (has_result || has_error) && not has_method
  | _ -> false

let is_notification req = req.id = None

let get_id req = match req.id with Some id -> id | None -> `Null

let is_valid_request_id = function
  | `Null | `String _ | `Int _ | `Intlit _ | `Float _ -> true
  | _ -> false

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

(* ── JSON-RPC response builders ──────────────────────────── *)

let make_response ~id result =
  `Assoc [
    ("jsonrpc", `String "2.0");
    ("id", id);
    ("result", result);
  ]

let make_error ?data ~id code message =
  let error_fields =
    [("code", `Int code); ("message", `String message)]
  in
  let error_fields =
    match data with
    | None -> error_fields
    | Some payload -> error_fields @ [("data", payload)]
  in
  `Assoc [
    ("jsonrpc", `String "2.0");
    ("id", id);
    ("error", `Assoc error_fields);
  ]

let jsonrpc_notification ?params method_name =
  let base =
    [
      ("jsonrpc", `String "2.0");
      ("method", `String method_name);
    ]
  in
  `Assoc
    (base
    @
    match params with
    | Some params -> [ ("params", params) ]
    | None -> [])

(* ── HTTP content negotiation ────────────────────────────── *)

module Http_negotiation = struct
  (** MASC-specific accept classification.
      Streamable HTTP requires both JSON and SSE media types. *)
  type accept_mode =
    | Streamable
    | Rejected

  (* Re-export SDK constants so callers' [Http_negotiation.sse_content_type]
     keeps compiling without an extra open. *)
  let sse_content_type = Mcp_protocol.Http_negotiation.sse_content_type
  let json_content_type = Mcp_protocol.Http_negotiation.json_content_type

  let exists_accepted h ~check =
    Mcp_protocol.Http_negotiation.parse_accept_header h
    |> List.exists
         (fun (mt : Mcp_protocol.Http_negotiation.media_type) ->
           mt.quality > 0.0
           && check
                ~type_:(String.lowercase_ascii mt.type_)
                ~subtype:(String.lowercase_ascii mt.subtype))

  (* [exists_accepted] already passes [type_]/[subtype] lowercased to
     [check] (see above), so callbacks compare against lowercase
     literals directly — no second lowercase allocation per media
     type. *)
  let accepts_sse_header = function
    | None -> false
    | Some h ->
        exists_accepted h ~check:(fun ~type_ ~subtype ->
            type_ = "text" && subtype = "event-stream")

  let accepts_json = function
    | None -> false
    | Some h ->
        exists_accepted h ~check:(fun ~type_ ~subtype ->
            (type_ = "application" && subtype = "json")
            || (type_ = "*" && subtype = "*"))

  (* Content-Type is a single media type (no comma-separated list, no q
     parameter). Parse it locally rather than reusing the Accept-list parser,
     which splits on commas and understands quality values. *)
  type parsed_content_type =
    { type_ : string
    ; subtype : string
    }

  let split_content_type_segments s =
    let len = String.length s in
    let segment start stop = String.sub s start (stop - start) in
    let rec loop i start in_quote escaped acc =
      if i >= len
      then if in_quote then None else Some (List.rev (segment start len :: acc))
      else
        match s.[i], in_quote, escaped with
        | _, _, true -> loop (i + 1) start in_quote false acc
        | '\\', true, false -> loop (i + 1) start in_quote true acc
        | '"', _, false -> loop (i + 1) start (not in_quote) false acc
        | ';', false, false ->
          loop (i + 1) (i + 1) false false (segment start i :: acc)
        | ',', false, false -> None
        | _ -> loop (i + 1) start in_quote false acc
    in
    loop 0 0 false false []

  let parse_media_type media =
    let media = String.trim media in
    match String.index_opt media '/' with
    | None -> None
    | Some slash -> (
      if slash + 1 >= String.length media
         || (String.index_from_opt media (slash + 1) '/' |> Option.is_some)
      then None
      else
        let type_ =
          String.sub media 0 slash |> String.trim |> String.lowercase_ascii
        in
        let subtype =
          String.sub media (slash + 1) (String.length media - slash - 1)
          |> String.trim
          |> String.lowercase_ascii
        in
        if String.equal type_ "" || String.equal subtype ""
        then None
        else Some { type_; subtype })

  let valid_content_type_parameter param =
    let param = String.trim param in
    if String.equal param ""
    then true
    else
      match String.index_opt param '=' with
      | None -> false
      | Some eq ->
        let name =
          String.sub param 0 eq |> String.trim |> String.lowercase_ascii
        in
        let value =
          String.sub param (eq + 1) (String.length param - eq - 1)
          |> String.trim
        in
        (not (String.equal name ""))
        && (not (String.equal name "q"))
        && not (String.equal value "")

  let parse_content_type s =
    let s = String.trim s in
    if String.equal s ""
    then None
    else
      match split_content_type_segments s with
      | Some (media :: params) when List.for_all valid_content_type_parameter params ->
        parse_media_type media
      | Some _ | None -> None

  let is_json_content_type = function
    | None -> false
    | Some h ->
        (match parse_content_type h with
         | Some { type_ = "application"; subtype = "json" } -> true
         | Some _ | None -> false)

  let accepts_streamable_mcp = function
    | None -> false
    | Some h ->
        accepts_json (Some h) && accepts_sse_header (Some h)

  let classify_mcp_accept accept_header =
    if accepts_streamable_mcp accept_header then Streamable
    else Rejected
end

let protocol_version_2026_07_28 = "2026-07-28"
let protocol_version_draft_2026_v1 = "DRAFT-2026-v1"

let supported_protocol_versions =
  let rec add acc version =
    if List.mem version acc then acc else acc @ [ version ]
  in
  List.fold_left add []
    (protocol_version_2026_07_28
     :: protocol_version_draft_2026_v1
     :: Mcp_protocol.Version.supported_versions)

let default_protocol_version = Mcp_protocol.Version.latest

let is_supported_protocol_version version =
  List.mem version supported_protocol_versions

let is_stateless_protocol_version version =
  String.equal version protocol_version_2026_07_28
  || String.equal version protocol_version_draft_2026_v1

let validate_protocol_version version =
  if is_supported_protocol_version version then
    Ok version
  else
    Error
      (Printf.sprintf
         "Unsupported protocolVersion '%s' (supported: %s)" version
         (String.concat ", " supported_protocol_versions))

let normalize_protocol_version version =
  if is_supported_protocol_version version then version
  else default_protocol_version

let protocol_version_from_params = function
  | Some (`Assoc fields) -> (
      match List.assoc_opt "protocolVersion" fields with
      | Some (`String version) -> version
      | _ -> default_protocol_version)
  | _ -> default_protocol_version

let protocol_version_meta_key = "io.modelcontextprotocol/protocolVersion"

let protocol_version_from_request_meta_json = function
  | `Assoc fields -> (
      match List.assoc_opt "params" fields with
      | Some (`Assoc params) -> (
          match List.assoc_opt "_meta" params with
          | Some (`Assoc meta) -> (
              match List.assoc_opt protocol_version_meta_key meta with
              | Some (`String version) -> Some version
              | _ -> None)
          | _ -> None)
      | _ -> None)
  | _ -> None

let protocol_version_from_request_meta_body body_str =
  try Yojson.Safe.from_string body_str |> protocol_version_from_request_meta_json
  with Yojson.Json_error _ -> None

let body_uses_stateless_protocol body_str =
  match protocol_version_from_request_meta_body body_str with
  | Some version -> is_stateless_protocol_version version
  | None -> false

let protocol_version_from_initialize_request_json = function
  | `Assoc fields -> (
      match
        (List.assoc_opt "jsonrpc" fields, List.assoc_opt "method" fields)
      with
      | Some (`String "2.0"), Some (`String "initialize") ->
          let params = List.assoc_opt "params" fields in
          Some
            (protocol_version_from_params params |> normalize_protocol_version)
      | _ -> None)
  | _ -> None

let protocol_version_from_body body_str =
  try
    Yojson.Safe.from_string body_str
    |> protocol_version_from_initialize_request_json
  with Yojson.Json_error _ -> None
