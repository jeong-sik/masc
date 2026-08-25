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

type request_id =
  | String_id of string
  | Integer_id of string

type request_id_error =
  | Null_request_id
  | Non_lossless_number
  | Invalid_integer_lexeme of string
  | Invalid_request_id_kind

let is_digit c = c >= '0' && c <= '9'

let is_json_integer_lexeme value =
  let length = String.length value in
  let first_digit =
    if length > 0 && value.[0] = '-' then 1 else 0
  in
  if first_digit >= length
  then false
  else
    let first = value.[first_digit] in
    if first = '0'
    then first_digit + 1 = length
    else
      first >= '1'
      && first <= '9'
      &&
      let rec all_digits index =
        index = length
        || (is_digit value.[index] && all_digits (index + 1))
      in
      all_digits (first_digit + 1)
;;

let request_id_of_yojson = function
  | `String value -> Ok (String_id value)
  | `Int value -> Ok (Integer_id (string_of_int value))
  | `Intlit value when is_json_integer_lexeme value -> Ok (Integer_id value)
  | `Intlit value -> Error (Invalid_integer_lexeme value)
  | `Float _ -> Error Non_lossless_number
  | `Null -> Error Null_request_id
  | `Assoc _ | `List _ | `Bool _ -> Error Invalid_request_id_kind
;;

let request_id_to_yojson = function
  | String_id value -> `String value
  | Integer_id value -> `Intlit value
;;

let request_id_equal left right =
  match left, right with
  | String_id left, String_id right
  | Integer_id left, Integer_id right -> String.equal left right
  | String_id _, Integer_id _ | Integer_id _, String_id _ -> false
;;

let request_id_error_to_string = function
  | Null_request_id -> "MCP request id must not be null"
  | Non_lossless_number ->
    "MCP request id must be an integer; floating JSON numbers are not lossless"
  | Invalid_integer_lexeme value ->
    Printf.sprintf "invalid MCP integer request id lexeme: %S" value
  | Invalid_request_id_kind -> "MCP request id must be a string or integer"
;;

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

let is_valid_request_id value = Result.is_ok (request_id_of_yojson value)

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

(* SEP-2322 (protocol revision 2026-07-28): every result carries a
   [resultType] -- ["complete"] for an ordinary result, ["input_required"]
   for a Multi Round-Trip interim result.  Clients reject a result that
   omits it when the negotiated revision is 2026-07-28 or later.

   The field is added here rather than at each of the 22 call sites so a
   new handler cannot forget it.  Handlers that already set [resultType]
   (server/discover, and any future ["input_required"] responder) keep
   their own value.  Adding the field unconditionally is safe for earlier
   revisions: they treat an unknown result member as ignorable, and the
   negotiated version is not threaded down to this builder. *)
(* Every result identifies the server (2026-07-28 basic/index, per-response
   protocol fields). Built here from [Build_version], the leaf every layer can
   reach, rather than restated: [Runtime_build_version] exists because a
   connector that could not reach the version carried a literal and it drifted.

   Injected in [make_response] for the same reason [resultType] is -- 22 call
   sites cannot each remember it. A handler that sets its own [_meta] keeps it;
   this only adds the key when absent.

   The spec marks this self-reported and not verified: for display, logging,
   and debugging, never for a behavioural or security decision. *)
let server_info_meta_key = "io.modelcontextprotocol/serverInfo"

let server_info_meta_value =
  `Assoc
    [ ("name", `String "masc")
    ; ("title", `String "MASC MCP Server")
    ; ("version", `String Build_version.current)
    ]

let with_server_info = function
  | `Assoc fields ->
    let meta =
      match List.assoc_opt "_meta" fields with
      | Some (`Assoc meta) when List.mem_assoc server_info_meta_key meta ->
        None
      | Some (`Assoc meta) ->
        Some (`Assoc ((server_info_meta_key, server_info_meta_value) :: meta))
      | Some _ -> None
      | None -> Some (`Assoc [ (server_info_meta_key, server_info_meta_value) ])
    in
    (match meta with
     | None -> `Assoc fields
     | Some meta ->
       `Assoc (("_meta", meta) :: List.remove_assoc "_meta" fields))
  | other -> other

let make_response ~id result =
  let result =
    match result with
    | `Assoc fields when not (List.mem_assoc "resultType" fields) ->
      `Assoc (("resultType", `String "complete") :: fields)
    | other -> other
  in
  let result = with_server_info result in
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
  let add acc version =
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

(* The other _meta field 2026-07-28 marks required on every client request.
   Its value is a ClientCapabilities object; nothing here reads inside it,
   because a server "MUST NOT rely on capabilities the client has not
   declared" -- what matters at this layer is that the client declared
   something. *)
let client_capabilities_meta_key = "io.modelcontextprotocol/clientCapabilities"

let request_meta_of_json = function
  | `Assoc fields -> (
    match List.assoc_opt "params" fields with
    | Some (`Assoc params) -> (
      match List.assoc_opt "_meta" params with
      | Some (`Assoc meta) -> Some meta
      | Some _ | None -> None)
    | Some _ | None -> None)
  | _ -> None

(* Absent and present-but-null are the same answer to "did the client declare
   its capabilities?": neither is a declaration. *)
let request_meta_has_key body_str key =
  match Yojson.Safe.from_string body_str with
  | json -> (
    match request_meta_of_json json with
    | None -> false
    | Some meta -> (
      match List.assoc_opt key meta with
      | Some `Null | None -> false
      | Some _ -> true))
  | exception Yojson.Json_error _ -> false

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
