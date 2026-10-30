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

(* The generated option decoder treats explicit JSON null like absence.
   Retain both fields' presence for request admission. *)
let generated_jsonrpc_request_of_yojson = jsonrpc_request_of_yojson

let jsonrpc_request_of_yojson json =
  match generated_jsonrpc_request_of_yojson json with
  | Error error -> Error error
  | Ok request ->
    (match json with
     | `Assoc fields ->
       Ok { request with id = List.assoc_opt "id" fields;
                         params = List.assoc_opt "params" fields }
     | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
       Ok request)

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

let has_unique_jsonrpc_fields = function
  | `Assoc fields ->
    List.for_all
      (fun key ->
         List.fold_left
           (fun count (name, _) -> if String.equal name key then count + 1 else count)
           0 fields <= 1)
      [ "jsonrpc"; "id"; "method"; "params" ]
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> false

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

let initialize_protocol_version params =
  let open Result.Syntax in
  let require_string label = function
    | Some (`String value) -> Ok value
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
      let* requested = require_string "protocolVersion" (get_field "protocolVersion" p) in
      let* client_info = require_assoc "clientInfo" (get_field "clientInfo" p) in
      let* _ = require_string "clientInfo.name" (get_field "name" client_info) in
      let* _ = require_string "clientInfo.version" (get_field "version" client_info) in
      let* _ = require_assoc "capabilities" (get_field "capabilities" p) in
      Ok requested
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

(* ── subscriptions/listen (2026-07-28) ───────────────────── *)

(* Replaces resources/subscribe and the HTTP GET endpoint. A client names the
   notification types it wants; the server "MUST NOT send notification types
   the client has not explicitly requested".

   Modelled as a record rather than a string list so the four types are the
   four the specification defines: an unknown key in the request cannot become
   a subscription, and adding a type later is a compile error at every match
   instead of a silent no-op. *)
type subscription_filter =
  { tools_list_changed : bool
  ; prompts_list_changed : bool
  ; resources_list_changed : bool
  ; resource_subscriptions : string list
  }

let empty_subscription_filter =
  { tools_list_changed = false
  ; prompts_list_changed = false
  ; resources_list_changed = false
  ; resource_subscriptions = []
  }

let subscription_id_meta_key = "io.modelcontextprotocol/subscriptionId"

(* Every notification on the stream carries the id of the listen request that
   opened it, "so clients can demultiplex them". On stdio a client MUST use it,
   because one channel carries every subscription. *)
let tag_notification_with_subscription ~subscription_id notification =
  let add_meta params =
    let meta_entry = (subscription_id_meta_key, subscription_id) in
    match params with
    | `Assoc fields -> (
      match List.assoc_opt "_meta" fields with
      | Some (`Assoc meta) when List.mem_assoc subscription_id_meta_key meta ->
        `Assoc fields
      | Some (`Assoc meta) ->
        `Assoc (("_meta", `Assoc (meta_entry :: meta))
                :: List.remove_assoc "_meta" fields)
      | Some _ | None ->
        `Assoc (("_meta", `Assoc [ meta_entry ])
                :: List.remove_assoc "_meta" fields))
    | other -> other
  in
  match notification with
  | `Assoc fields ->
    let params =
      match List.assoc_opt "params" fields with
      | Some params -> add_meta params
      | None -> add_meta (`Assoc [])
    in
    `Assoc (("params", params) :: List.remove_assoc "params" fields)
  | other -> other

let bool_field fields name =
  match List.assoc_opt name fields with Some (`Bool b) -> b | _ -> false

let string_list_field fields name =
  match List.assoc_opt name fields with
  | Some (`List items) ->
    List.filter_map (function `String s -> Some s | _ -> None) items
  | _ -> []

(* "All fields are optional. Omitting a field is equivalent to not subscribing
   to that notification type." An absent [notifications] object is therefore a
   subscription to nothing, not an error. *)
let subscription_filter_of_params params =
  match params with
  | Some (`Assoc fields) -> (
    match List.assoc_opt "notifications" fields with
    | Some (`Assoc n) ->
      { tools_list_changed = bool_field n "toolsListChanged"
      ; prompts_list_changed = bool_field n "promptsListChanged"
      ; resources_list_changed = bool_field n "resourcesListChanged"
      ; resource_subscriptions = string_list_field n "resourceSubscriptions"
      }
    | Some _ | None -> empty_subscription_filter)
  | Some _ | None -> empty_subscription_filter

let validate_subscription_filter_params params =
  let ( let* ) = Result.bind in
  let values key fields =
    List.filter_map (fun (name, value) ->
      if String.equal name key then Some value else None) fields
  in
  let bool key fields =
    match values key fields with
    | [] -> Ok false
    | [ `Bool value ] -> Ok value
    | _ -> Error (Printf.sprintf "notifications.%s must be a unique boolean" key)
  in
  let strings key fields =
    match values key fields with
    | [] -> Ok []
    | [ `List items ] ->
      let rec collect acc = function
        | [] -> Ok (List.rev acc)
        | `String value :: rest -> collect (value :: acc) rest
        | _ :: _ -> Error (Printf.sprintf "notifications.%s must contain only strings" key)
      in
      collect [] items
    | _ -> Error (Printf.sprintf "notifications.%s must be a unique string array" key)
  in
  match params with
  | Some (`Assoc fields) ->
    (match values "notifications" fields with
     | [ `Assoc filter ] ->
       let* tools_list_changed = bool "toolsListChanged" filter in
       let* prompts_list_changed = bool "promptsListChanged" filter in
       let* resources_list_changed = bool "resourcesListChanged" filter in
       let* resource_subscriptions = strings "resourceSubscriptions" filter in
       Ok { tools_list_changed; prompts_list_changed; resources_list_changed
          ; resource_subscriptions }
     | _ -> Error "notifications must be a unique object")
  | Some _ | None -> Error "subscriptions/listen params must be an object"

(* The acknowledgement reports the subset the server agreed to honour, and
   "notification types the server does not support are omitted" -- so a field
   the caller did not ask for, or that this server cannot serve, is absent
   rather than false. *)
let subscription_filter_to_json filter =
  let fields =
    List.concat
      [ (if filter.tools_list_changed then [ ("toolsListChanged", `Bool true) ] else [])
      ; (if filter.prompts_list_changed then
           [ ("promptsListChanged", `Bool true) ]
         else [])
      ; (if filter.resources_list_changed then
           [ ("resourcesListChanged", `Bool true) ]
         else [])
      ; (match filter.resource_subscriptions with
         | [] -> []
         | uris ->
           [ ("resourceSubscriptions", `List (List.map (fun u -> `String u) uris)) ])
      ]
  in
  `Assoc fields

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

let header_value_prefix = "=?base64?"
let header_value_suffix = "?="

let has_header_value_sentinel value =
  String.starts_with ~prefix:header_value_prefix value
  && String.ends_with ~suffix:header_value_suffix value

let safe_plain_header_value value =
  let length = String.length value in
  let whitespace = function ' ' | '\t' -> true | _ -> false in
  (length = 0
   || (not (whitespace value.[0]) && not (whitespace value.[length - 1])))
  && String.for_all
       (fun c ->
         let code = Char.code c in
         code = 9 || (code >= 32 && code <= 126))
       value

let encode_header_value value =
  if safe_plain_header_value value && not (has_header_value_sentinel value)
  then value
  else header_value_prefix ^ Base64.encode_string value ^ header_value_suffix

let decode_header_value value =
  if not (safe_plain_header_value value) then
    Error "header value is not safe ASCII"
  else if not (has_header_value_sentinel value) then Ok value
  else
    let offset = String.length header_value_prefix in
    let length = String.length value - offset - String.length header_value_suffix in
    if length < 0 then Error "header value has an incomplete Base64 sentinel"
    else
      let encoded = String.sub value offset length in
      match Base64.decode encoded with
      | Ok decoded
        when String.equal (Base64.encode_string decoded) encoded
             && String.is_valid_utf_8 decoded -> Ok decoded
      | Ok _ | Error _ -> Error "header value has invalid Base64 or UTF-8"

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

(* The ordinary default: it answers a request that names no version, or an
   unsupported one, outside [initialize]. It follows the SDK's latest on
   purpose. The [initialize] counter-offer must stay legacy even if the SDK's
   latest becomes a stateless revision, so it uses
   [legacy_default_protocol_version] below. *)
let default_protocol_version = Mcp_protocol.Version.latest

let is_supported_protocol_version version =
  List.mem version supported_protocol_versions

let is_stateless_protocol_version version =
  String.equal version protocol_version_2026_07_28
  || String.equal version protocol_version_draft_2026_v1

(* [supported] lists legacy versions oldest first (the SDK's order), so the
   last legacy entry is the newest one. *)
let legacy_default_protocol_version_of ~latest ~supported =
  if not (is_stateless_protocol_version latest) then Ok latest
  else
    match
      List.fold_left
        (fun newest version ->
          if is_stateless_protocol_version version then newest
          else Some version)
        None supported
    with
    | Some version -> Ok version
    | None -> Error "no legacy protocol version is supported"

(* A supported set without any legacy version can only come from moving the SDK
   pin to stateless-only revisions. Fail when the module loads, where every
   test binary sees it, instead of answering [initialize] with a stateless
   version. *)
let legacy_default_protocol_version =
  match
    legacy_default_protocol_version_of ~latest:Mcp_protocol.Version.latest
      ~supported:supported_protocol_versions
  with
  | Ok version -> version
  | Error message -> invalid_arg ("Mcp_transport_protocol: " ^ message)

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

let negotiate_legacy_protocol_version_with ~legacy_default version =
  if is_supported_protocol_version version
     && not (is_stateless_protocol_version version)
  then version
  else legacy_default

let negotiate_legacy_protocol_version =
  negotiate_legacy_protocol_version_with
    ~legacy_default:legacy_default_protocol_version

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

type request_protocol = Legacy_protocol | Stateless_protocol of string

type request_protocol_error =
  | Invalid_request_meta of string
  | Unsupported_request_version of string

let request_has_continuation_fields = function
  | Some (`Assoc fields) ->
    List.mem_assoc "requestState" fields || List.mem_assoc "inputResponses" fields
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _)
  | None -> false

let classify_request_protocol ~require_stateless ~method_ ~params =
  let values key fields =
    List.filter_map (fun (name, value) ->
      if String.equal name key then Some value else None) fields
  in
  let meta_values =
    match params with
    | Some (`Assoc fields) -> values "_meta" fields
    | Some _ | None -> []
  in
  let reserved_keys =
    [ protocol_version_meta_key; client_capabilities_meta_key
    ; "io.modelcontextprotocol/clientInfo"; "io.modelcontextprotocol/logLevel" ]
  in
  let has_modern_field =
    List.exists
      (function
        | `Assoc fields ->
          List.exists (fun key -> List.mem_assoc key fields) reserved_keys
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> false)
      meta_values
  in
  let modern_only =
    String.equal method_ "server/discover"
    || String.equal method_ "subscriptions/listen"
  in
  if not (require_stateless || modern_only || has_modern_field) then
    Ok Legacy_protocol
  else
    match meta_values with
    | [ `Assoc meta ] ->
      (match values protocol_version_meta_key meta with
       | [ `String version ] ->
         if not (is_supported_protocol_version version) then
           Error (Unsupported_request_version version)
         else if not (is_stateless_protocol_version version) then
           Error (Invalid_request_meta "per-request protocolVersion must name a stateless version")
         else
           (match values client_capabilities_meta_key meta with
            | [ `Assoc _ ] -> Ok (Stateless_protocol version)
            | _ ->
              Error
                (Invalid_request_meta
                   (Printf.sprintf "missing, duplicate or invalid params._meta.%s"
                      client_capabilities_meta_key)))
       | _ ->
         Error
           (Invalid_request_meta
              (Printf.sprintf "missing, duplicate or invalid params._meta.%s"
                 protocol_version_meta_key)))
    | _ -> Error (Invalid_request_meta "missing, duplicate or invalid params._meta")

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

let request_meta_has_object body_str key =
  match Yojson.Safe.from_string body_str with
  | json ->
    (match request_meta_of_json json with
     | Some meta -> (match List.assoc_opt key meta with Some (`Assoc _) -> true | _ -> false)
     | None -> false)
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
            (protocol_version_from_params params |> negotiate_legacy_protocol_version)
      | _ -> None)
  | _ -> None

let protocol_version_from_body body_str =
  try
    Yojson.Safe.from_string body_str
    |> protocol_version_from_initialize_request_json
  with Yojson.Json_error _ -> None
