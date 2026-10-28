(** See mcp_client.mli. *)

type tool = {
  name : string;
  description : string;
  input_schema : Yojson.Safe.t;
  read_only : bool option;
}

type tool_result = {
  is_error : bool;
  text : string;
  content : Yojson.Safe.t;
  structured_content : Yojson.Safe.t option;
}

let model_text result =
  match result.text, result.structured_content with
  | "", Some value -> Yojson.Safe.to_string value
  | text, Some value -> text ^ "\nstructuredContent: " ^ Yojson.Safe.to_string value
  | text, None -> text

type error =
  | Transport of string
  | Unauthorized of { resource_metadata : string option }
  | Http of
      { status : int
      ; body : string
      ; www_authenticate : string list
      ; bearer_error : string option
      ; required_scope : string option
      ; resource_metadata : string option
      }
  | Rpc of
      { code : int
      ; message : string
      ; data : Yojson.Safe.t option
      ; http_status : int option
      }
  | Input_required of
      { input_requests : Yojson.Safe.t option
      ; request_state : string option
      }
  | Before_tool_call of error
  | Malformed of string

let rec error_to_string = function
  | Transport detail -> Printf.sprintf "the request did not complete: %s" detail
  | Unauthorized { resource_metadata } ->
    (match resource_metadata with
     | Some url ->
       Printf.sprintf
         "the server refused this token; it says how to get one at %s" url
     | None -> "the server refused this token and said nothing about how to get one")
  | Http { status; body; required_scope; _ } ->
    (match required_scope with
     | Some scope ->
       Printf.sprintf "the server answered HTTP %d (required scope: %s): %s" status scope body
     | None -> Printf.sprintf "the server answered HTTP %d: %s" status body)
  | Rpc { code; message; _ } ->
    Printf.sprintf "the server refused the call (%d): %s" code message
  | Input_required _ ->
    "the server requires additional input; the operation has not completed"
  | Before_tool_call error ->
    "the tool request was not sent: " ^ error_to_string error
  | Malformed detail ->
    Printf.sprintf "the server's answer could not be read: %s" detail

type post =
  url:string ->
  headers:(string * string) list ->
  body:string ->
  (Masc_http_client.response, string) result

(* The one production transport. Each request of a session -- initialize,
   the initialized notification, tools/list, tools/call -- runs under
   [deadline_s] on [clock], one window per request. Building one takes a
   clock and a deadline, so a caller without either cannot open a session. Before this the default was the shared client's
   unbounded arm, and a server that accepted the connection and never
   answered held the keeper turn that called it for as long as the socket
   stayed open: the attempt watchdog does not watch a tool in flight, so
   the transport's deadline is the only liveness the call has. *)
let http_post ~clock ~deadline_s : post =
  fun ~url ~headers ~body ->
    Masc_http_client.post_response_sync
      ~clock ~timeout_sec:deadline_s ~url ~headers ~body ()

type era = Legacy | Modern

type catalog_binding = { input_schema : Yojson.Safe.t; read_only : bool option }
type catalog_authority = Unbound | Bound of catalog_binding option

type request_ids =
  { list_used : bool Atomic.t
  ; call_used : bool Atomic.t
  ; next : int Atomic.t
  }

let request_ids () =
  { list_used = Atomic.make false; call_used = Atomic.make false; next = Atomic.make 4 }

let next_request_id ids ~slot ~primary =
  if Atomic.compare_and_set slot false true then
    primary
  else Atomic.fetch_and_add ids.next 1

type t = {
  url : string;
  access_token : string;
  session : string option;
  protocol_version : string;
  era : era;
  tools : tool list option Atomic.t;
  request_ids : request_ids;
}

let negotiated_protocol_version t = t.protocol_version
let session_id t = t.session

open Result.Syntax

(* One header name compared without regard to case, because HTTP says so and
   the two servers this has been pointed at disagree about capitalisation. *)
let header_value headers name =
  let wanted = String.lowercase_ascii name in
  List.find_map
    (fun (key, value) ->
      if String.equal (String.lowercase_ascii key) wanted then Some value else None)
    headers

let bearer_challenge_parameters headers =
  let module Challenge = Masc_http_client.Www_authenticate in
  let parameter params wanted =
    List.find_map
      (fun (key, value) ->
        if String.equal (String.lowercase_ascii key) wanted then Some value else None)
      params
  in
  let candidates =
    headers
    |> List.concat_map (fun (name, value) ->
         if not (String.equal (String.lowercase_ascii name) "www-authenticate") then []
         else match Challenge.parse value with
           | Error _ -> []
           | Ok challenges ->
             List.filter_map
               (fun (challenge : Challenge.challenge) ->
                 match challenge.credentials with
                 | Challenge.Params params ->
                   if String.equal (String.lowercase_ascii challenge.scheme) "bearer"
                   then Some params else None
                 | Challenge.Token68 _ -> None)
               challenges)
  in
  let selected =
    match List.find_opt
            (fun params -> parameter params "error" = Some "insufficient_scope")
            candidates with
    | Some _ as selected -> selected
    | None -> List.nth_opt candidates 0
  in
  match selected with
  | None -> None, None, None
  | Some params ->
    parameter params "error", parameter params "scope", parameter params "resource_metadata"

(* Streamable HTTP answers a POST either with a JSON body or with an event
   stream carrying the same message. Which one arrives is the server's
   choice, so both are read. The content type decides -- not the shape of
   the bytes, which would make a JSON body that happens to start with
   "data:" into a stream. *)
let json_of_body ~content_type body =
  let is_event_stream =
    match content_type with
    | Some value ->
      let lowered = String.lowercase_ascii value in
      let prefix = "text/event-stream" in
      String.length lowered >= String.length prefix
      && String.equal (String.sub lowered 0 (String.length prefix)) prefix
    | None -> false
  in
  if not is_event_stream
  then (
    match Yojson.Safe.from_string body with
    | json -> Ok json
    | exception Yojson.Json_error detail -> Error (Malformed detail))
  else (
    (* One event is the lines up to a blank one, and its payload is every
       [data:] line in it joined with a newline -- a JSON object wrapped at
       eighty columns arrives as several of them, and reading each line as
       its own message would find nothing parseable in any of them.

       The last event that parses is the answer: a stream may carry progress
       notifications first, and those are messages of their own. *)
    let strip_cr line =
      match String.length line with
      | length when length > 0 && Char.equal line.[length - 1] '\r' ->
        String.sub line 0 (length - 1)
      | _ -> line
    in
    let payload_of_event lines =
      let prefix = "data:" in
      let data =
        List.filter_map
          (fun line ->
            if String.length line >= String.length prefix
               && String.equal (String.sub line 0 (String.length prefix)) prefix
            then (
              let rest = String.sub line 5 (String.length line - 5) in
              (* One optional space after the colon belongs to the framing,
                 not to the payload. *)
              Some
                (if String.length rest > 0 && Char.equal rest.[0] ' '
                 then String.sub rest 1 (String.length rest - 1)
                 else rest))
            else None)
          lines
      in
      if data = [] then None else Some (String.concat "\n" data)
    in
    let events =
      List.fold_left
        (fun (current, finished) line ->
          let line = strip_cr line in
          if String.equal (String.trim line) ""
          then ([], List.rev current :: finished)
          else (line :: current, finished))
        ([], [])
        (String.split_on_char '\n' body)
      |> fun (current, finished) -> List.rev (List.rev current :: finished)
    in
    let parsed =
      List.filter_map
        (fun lines ->
          match payload_of_event lines with
          | None -> None
          | Some payload -> (
            match Yojson.Safe.from_string payload with
            | json -> Some json
            | exception Yojson.Json_error _ -> None))
        events
    in
    match List.rev parsed with
    | last :: _ -> Ok last
    | [] -> Error (Malformed "the event stream carried no readable message"))

let member key json =
  match json with
  | `Assoc pairs -> List.assoc_opt key pairs
  | _ -> None

let unique_member key json =
  match json with
  | `Assoc fields ->
    (match List.filter_map (fun (name, value) -> if String.equal name key then Some value else None) fields with
     | [] -> Ok None
     | [ value ] -> Ok (Some value)
     | _ :: _ :: _ -> Error (Malformed ("the response repeats " ^ key)))
  | _ -> Error (Malformed "the result is not an object")

let result_of_rpc ~id json =
  let* version = unique_member "jsonrpc" json in
  let* response_id = unique_member "id" json in
  let* result = unique_member "result" json in
  let* error = unique_member "error" json in
  match version, response_id, result, error with
  | Some (`String "2.0"), Some (`Int actual), Some (`Assoc _ as result), None
    when actual = id -> Ok result
  | Some (`String "2.0"), Some (`Int actual), None, Some error when actual = id ->
    let* code = unique_member "code" error in
    let* message = unique_member "message" error in
    let* data = unique_member "data" error in
    (match code, message with
     | Some (`Int code), Some (`String message) ->
       Error (Rpc { code; message; data; http_status = None })
     | _ -> Error (Malformed "the JSON-RPC error has no valid code or message"))
  | _ -> Error (Malformed "the JSON-RPC response does not match the request")

let headers_for t ~include_protocol_version ~method_ ~name ~extra_headers =
  [ "Content-Type", "application/json"
    (* Both, because either is a legal answer and refusing one would make
       the server's choice into our failure. *)
  ; "Accept", "application/json, text/event-stream"
  ; "Authorization", "Bearer " ^ t.access_token
  ]
  @ (if include_protocol_version
     then [ "MCP-Protocol-Version", t.protocol_version ]
     else [])
  @ (match t.era with
     | Legacy -> []
     | Modern ->
       [ "Mcp-Method", method_ ]
       @ (match name with
          | None -> []
          | Some value -> [ "Mcp-Name", Mcp_transport_protocol.encode_header_value value ]))
  @ (match t.session with
     | Some session -> [ "Mcp-Session-Id", session ]
     | None -> [])
  @ extra_headers

let request ~post t ~include_protocol_version ~method_ ~name ~extra_headers ~body =
  match post ~url:t.url
          ~headers:(headers_for t ~include_protocol_version ~method_ ~name ~extra_headers) ~body with
  | Error detail -> Error (Transport detail)
  | Ok response ->
    let status = response.Masc_http_client.status in
    if status = 401
    then
      Error
        (Unauthorized
           { resource_metadata =
               (* RFC 9728 5.1: the Bearer challenge names where this
                  server's protected-resource metadata lives. Worth carrying
                  up, because it is what an OAuth client would go read
                  next. *)
               Masc_http_client.Www_authenticate.resource_metadata_of_headers
                 response.Masc_http_client.headers
           })
    else if status < 200 || status >= 300
    then
      let headers = response.Masc_http_client.headers in
      let www_authenticate =
        List.filter_map
          (fun (name, value) ->
            if String.equal (String.lowercase_ascii name) "www-authenticate"
            then Some value else None)
          headers
      in
      let bearer_error, required_scope, resource_metadata =
        bearer_challenge_parameters headers
      in
      Error
        (Http
           { status
           ; body = response.Masc_http_client.body
           ; www_authenticate
           ; bearer_error
           ; required_scope
           ; resource_metadata
           })
    else Ok response

let client_info =
  `Assoc [ "name", `String "masc"; "version", `String Build_version.current ]

let rpc ~extra_headers ~post t ~include_protocol_version ~id ~method_ ~params =
  let name =
    match method_ with
    | "tools/call" | "prompts/get" -> (match member "name" params with Some (`String name) -> Some name | _ -> None)
    | "resources/read" -> (match member "uri" params with Some (`String uri) -> Some uri | _ -> None)
    | _ -> None
  in
  let params =
    match t.era, params with
    | Modern, `Assoc fields ->
      `Assoc
        (fields @ [ "_meta", `Assoc
          [ Mcp_transport_protocol.protocol_version_meta_key, `String t.protocol_version
          ; Mcp_transport_protocol.client_capabilities_meta_key, `Assoc []
          ; "io.modelcontextprotocol/clientInfo", client_info
          ] ])
    | (Legacy, _) | (Modern, _) -> params
  in
  let body =
    Yojson.Safe.to_string
      (`Assoc
        [ "jsonrpc", `String "2.0"
        ; "id", `Int id
        ; "method", `String method_
        ; "params", params
        ])
  in
  match request ~post t ~include_protocol_version ~method_ ~name ~extra_headers ~body with
  | Ok response ->
    let* json =
      json_of_body
        ~content_type:(header_value response.Masc_http_client.headers "content-type")
        response.Masc_http_client.body
    in
    let* result = result_of_rpc ~id json in
    Ok (response, result)
  | Error (Http { status = (400 | 404) as status; body; _ } as original)
    when t.era = Modern ->
    (match Yojson.Safe.from_string body with
     | json ->
       (match result_of_rpc ~id json with
        | Error (Rpc { code; message; data; _ })
          when (status = 400 && List.mem code
                  [ -32700; -32600; -32601; -32602; -32603; -32020; -32021; -32022 ])
               || (status = 404 && code = -32601) ->
          Error (Rpc { code; message; data; http_status = Some status })
        | Ok _ | Error (Transport _ | Unauthorized _ | Http _ | Rpc _
                        | Input_required _ | Before_tool_call _ | Malformed _) -> Error original)
     | exception Yojson.Json_error _ -> Error original)
  | Error ((Transport _ | Unauthorized _ | Http _ | Rpc _
           | Input_required _ | Before_tool_call _ | Malformed _) as error) -> Error error

let notify ~post t ~method_ =
  let body =
    Yojson.Safe.to_string
      (`Assoc
        [ "jsonrpc", `String "2.0"
        ; "method", `String method_
        ; "params", `Assoc []
        ])
  in
  Result.map (fun _ -> ())
    (request ~post t ~include_protocol_version:true ~method_ ~name:None ~extra_headers:[] ~body)

let connect_legacy ~post ~url ~access_token () =
  let offered = Mcp_transport_protocol.legacy_default_protocol_version in
  let opening =
    { url
    ; access_token
    ; session = None
    ; protocol_version = offered
    ; era = Legacy
    ; tools = Atomic.make None
    ; request_ids = request_ids ()
    }
  in
  let* response, result =
    rpc ~extra_headers:[] ~post opening ~include_protocol_version:false ~id:1 ~method_:"initialize"
      ~params:
        (`Assoc
          [ "protocolVersion", `String offered
          ; "capabilities", `Assoc []
          ; "clientInfo", client_info
          ])
  in
  (* The server's answer, not what we offered. A server that names a version
     this build does not know is refused here rather than being talked to in
     a dialect neither side agreed on. *)
  let* protocol_version =
    match member "protocolVersion" result with
    | Some (`String version)
      when Mcp_transport_protocol.is_supported_protocol_version version
           && not (Mcp_transport_protocol.is_stateless_protocol_version version) ->
      Ok version
    | Some (`String version) ->
      Error
        (Malformed
           (Printf.sprintf "the server negotiated %S, which this build does not speak"
              version))
    | Some _ | None ->
      Error (Malformed "the initialize answer carries no protocolVersion")
  in
  let session =
    header_value response.Masc_http_client.headers "mcp-session-id"
  in
  let connected = { opening with session; protocol_version } in
  let* () = notify ~post connected ~method_:"notifications/initialized" in
  Ok connected

let connect ~post ~url ~access_token () =
  let fallback () = connect_legacy ~post ~url ~access_token () in
  let modern_version =
    List.find_opt Mcp_transport_protocol.is_stateless_protocol_version
      Mcp_transport_protocol.supported_protocol_versions
  in
  match modern_version with
  | None -> fallback ()
  | Some initial_version ->
    let rec probe version tried =
    let opening = { url; access_token; session = None; protocol_version = version; era = Modern; tools = Atomic.make None; request_ids = request_ids () } in
    match rpc ~extra_headers:[] ~post opening ~include_protocol_version:true ~id:1
            ~method_:"server/discover" ~params:(`Assoc []) with
    | Ok (_, result) ->
      (match member "supportedVersions" result with
       | Some (`List versions) ->
         let* () =
           match member "resultType" result, member "capabilities" result with
           | Some (`String "complete"), Some (`Assoc _) -> Ok ()
           | _ -> Error (Malformed "server/discover returned an invalid result")
         in
         let versions = List.filter_map (function `String v -> Some v | _ -> None) versions in
         (match List.find_opt
                  (fun v -> Mcp_transport_protocol.is_stateless_protocol_version v
                            && List.mem v versions)
                  Mcp_transport_protocol.supported_protocol_versions with
          | Some protocol_version -> Ok { opening with protocol_version }
          | None when List.exists Mcp_transport_protocol.is_supported_protocol_version versions -> fallback ()
          | None -> Error (Malformed "the server offers no supported MCP version"))
       | Some _ | None -> fallback ())
    | Error (Rpc { code = -32022; data; _ } as error) ->
      (match Option.bind data (member "supported") with
       | Some (`List versions) ->
         let versions = List.filter_map (function `String v -> Some v | _ -> None) versions in
         (match List.find_opt
                  (fun v -> Mcp_transport_protocol.is_stateless_protocol_version v
                            && List.mem v versions && not (List.mem v tried))
                  Mcp_transport_protocol.supported_protocol_versions with
          | Some next -> probe next (next :: tried)
          | None when List.exists
              (fun v -> Mcp_transport_protocol.is_supported_protocol_version v
                        && not (Mcp_transport_protocol.is_stateless_protocol_version v)) versions -> fallback ()
          | None -> Error error)
       | Some _ | None -> Error error)
    | Error (Rpc { code = (-32020 | -32021); _ } as error) -> Error error
    | Error (Rpc { code = -32601; http_status = Some 404; _ } as error) -> Error error
    | Error (Http { status = (400 | 404); _ }) -> fallback ()
    | Error (Rpc _ | Malformed _) -> fallback ()
    | Error ((Transport _ | Unauthorized _ | Http _ | Input_required _ | Before_tool_call _) as error) -> Error error
    in
    probe initial_version [ initial_version ]

type header_kind = Header_string | Header_integer | Header_boolean

type header_binding = { header_name : string; path : string list; kind : header_kind }

let valid_header_name name =
  let token_char = function
    | 'a'..'z' | 'A'..'Z' | '0'..'9'
    | '!' | '#' | '$' | '%' | '&' | '\'' | '*' | '+' | '-' | '.'
    | '^' | '_' | '`' | '|' | '~' -> true
    | _ -> false
  in
  String.length name > 0 && String.for_all token_char name

(* Only a chain of [properties] reaches a header annotation. The other
   JSON Schema keywords below contain schemas too, but cannot create a
   statically addressable argument path. Literal data such as [default] or
   [examples] is not interpreted as a schema. *)
let header_bindings schema =
  let schema_fields =
    [ "items"; "contains"; "additionalProperties"; "unevaluatedProperties";
      "propertyNames"; "not"; "if"; "then"; "else"; "contentSchema";
      "unevaluatedItems"; "additionalItems" ]
  in
  let schema_arrays = [ "allOf"; "anyOf"; "oneOf"; "prefixItems" ] in
  let schema_maps = [ "$defs"; "definitions"; "patternProperties"; "dependentSchemas"; "dependencies" ] in
  let rec scan reachable path bindings json =
    match json with
    | `Assoc fields ->
      let* bindings =
        match List.assoc_opt "x-mcp-header" fields with
        | None -> Ok bindings
        | Some (`String header_name) when reachable && path <> [] && valid_header_name header_name ->
          let* kind =
            match List.assoc_opt "type" fields with
            | Some (`String "string") -> Ok Header_string
            | Some (`String "integer") -> Ok Header_integer
            | Some (`String "boolean") -> Ok Header_boolean
            | Some _ | None -> Error "a header parameter must have a primitive type"
          in
          if List.exists
               (fun binding -> String.equal (String.lowercase_ascii binding.header_name)
                   (String.lowercase_ascii header_name)) bindings
          then Error "duplicate x-mcp-header name"
          else Ok ({ header_name; path; kind } :: bindings)
        | Some _ -> Error "invalid or unreachable x-mcp-header annotation"
      in
      List.fold_left
        (fun accumulated (key, value) ->
          let* bindings = accumulated in
          if String.equal key "properties" then
            (match value with
             | `Assoc properties ->
               List.fold_left
                 (fun acc (property, child) ->
                   let* bindings = acc in
                   scan reachable (path @ [ property ]) bindings child)
                 (Ok bindings) properties
             | _ -> Ok bindings)
          else if List.mem key schema_fields then scan false path bindings value
          else if List.mem key schema_arrays then
            (match value with
             | `List children ->
               List.fold_left (fun acc child -> let* bindings = acc in scan false path bindings child)
                 (Ok bindings) children
             | _ -> Ok bindings)
          else if List.mem key schema_maps then
            (match value with
             | `Assoc children ->
               List.fold_left (fun acc (_, child) -> let* bindings = acc in scan false path bindings child)
                 (Ok bindings) children
             | _ -> Ok bindings)
          else Ok bindings)
        (Ok bindings) fields
    | `List children ->
      List.fold_left
        (fun acc child -> let* bindings = acc in scan false path bindings child)
        (Ok bindings) children
    | _ -> Ok bindings
  in
  scan true [] [] schema

let headers_for_arguments bindings arguments =
  let rec at_path value = function
    | [] -> Some value
    | key :: rest -> Option.bind (member key value) (fun child -> at_path child rest)
  in
  let safe_integer value =
    let bound = 9007199254740991L in
    match Int64.of_string_opt value with
    | Some number when Int64.compare number (Int64.neg bound) >= 0
                       && Int64.compare number bound <= 0 -> Some (Int64.to_string number)
    | Some _ | None -> None
  in
  List.fold_left
    (fun acc binding ->
      let* headers = acc in
      match at_path arguments binding.path with
      | None | Some `Null -> Ok headers
      | Some value ->
        let converted =
          match binding.kind with
          | Header_string -> (match value with `String s -> Some s | _ -> None)
          | Header_boolean -> (match value with `Bool b -> Some (string_of_bool b) | _ -> None)
          | Header_integer ->
            (match value with
             | `Int i -> safe_integer (string_of_int i)
             | `Intlit s -> safe_integer s
             | `Float f when Float.is_finite f && Float.floor f = f
                              && f >= -9007199254740991.
                              && f <= 9007199254740991. -> Some (Printf.sprintf "%.0f" f)
             | _ -> None)
        in
        (match converted with
         | None -> Error ("invalid value for header parameter " ^ binding.header_name)
         | Some value ->
           Ok (("Mcp-Param-" ^ binding.header_name,
                Mcp_transport_protocol.encode_header_value value) :: headers)))
    (Ok []) bindings

(* JSON objects are unordered. Duplicate keys are not an unambiguous schema
   identity and therefore cannot authorize a routing decision. *)
let rec same_json left right =
  match left, right with
  | `Assoc left_fields, `Assoc right_fields ->
    let unique fields =
      List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields))
    in
    unique left_fields && unique right_fields
    && List.length left_fields = List.length right_fields
    && List.for_all
         (fun (key, value) ->
           match List.assoc_opt key right_fields with
           | None -> false
           | Some other -> same_json value other)
         left_fields
  | `List left_values, `List right_values ->
    List.length left_values = List.length right_values
    && List.for_all2 same_json left_values right_values
  | `Int integer, `Intlit literal | `Intlit literal, `Int integer ->
    Int64.of_string_opt literal = Some (Int64.of_int integer)
  | `Int integer, `Float value | `Float value, `Int integer ->
    Float.is_finite value && Float.floor value = value
    && value >= -9007199254740991. && value <= 9007199254740991.
    && Int64.of_float value = Int64.of_int integer
  | `Intlit literal, `Float value | `Float value, `Intlit literal ->
    Float.is_finite value && Float.floor value = value
    && value >= -9007199254740991. && value <= 9007199254740991.
    && Int64.of_string_opt literal = Some (Int64.of_float value)
  | (`Assoc _ | `List _), _ | _, (`Assoc _ | `List _) -> false
  | _ -> left = right

let tool_of_json ~era json =
  match member "name" json with
  | Some (`String name) when String.trim name <> "" ->
    let description =
      match member "description" json with
      | Some (`String description) -> description
      | Some _ | None -> ""
    in
    let input_schema =
      match member "inputSchema" json with
      | Some schema -> schema
      (* A tool that declares no schema takes no arguments; saying so beats
         handing a runtime a tool it cannot describe. *)
      | None ->
        (match era with
         | Legacy -> `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
         | Modern -> `Null)
    in
    let read_only =
      match member "annotations" json with
      | None -> None
      | Some annotations -> (
        match annotations with
        | `Assoc pairs -> (
          match List.assoc_opt "readOnlyHint" pairs with
          | Some (`Bool value) -> Some value
          (* Present but not a boolean is the server saying something this
             cannot read. Silence and nonsense both mean "did not say". *)
          | Some _ | None -> None)
        | _ -> None)
    in
    (match era with
     | Legacy -> Some { name; description; input_schema; read_only }
     | Modern ->
       (match header_bindings input_schema with
        | Error _ -> None
        | Ok _ ->
          (match input_schema with
           | `Assoc fields when List.assoc_opt "type" fields = Some (`String "object") ->
             Some { name; description; input_schema; read_only }
           | _ -> None)))
  | Some _ | None -> None

(* WORKAROUND: a server that keeps returning cursors never ends the listing,
   and every page still answers inside the per-request deadline, so that
   deadline never fires. This page count stands in for one deadline shared by
   the whole listing, which RFC #46355 D4 chose for continuation rounds. 1000
   is not measured against any real server. The cursors stay opaque: this
   counts pages and never looks at a cursor. Root fix: #46538. *)
let max_tools_list_pages = 1000

let list_tools ~post t =
  let rec pages fetched cursor acc =
    if fetched >= max_tools_list_pages then
      Error
        (Malformed
           (Printf.sprintf "tools/list did not end within %d pages"
              max_tools_list_pages))
    else
    let params =
      match cursor with
      | None -> `Assoc []
      | Some cursor -> `Assoc [ "cursor", `String cursor ]
    in
    let* _, result =
      let id = next_request_id t.request_ids ~slot:t.request_ids.list_used ~primary:2 in
      rpc ~extra_headers:[] ~post t ~include_protocol_version:true ~id ~method_:"tools/list"
        ~params
    in
    let* result_type = unique_member "resultType" result in
    let* () =
      match t.era, result_type with
      | Legacy, None | (Legacy | Modern), Some (`String "complete") -> Ok ()
      | Modern, None | (Legacy | Modern), Some _ ->
        Error (Malformed "tools/list did not return a complete result")
    in
    let* rows =
      match member "tools" result with
      | Some (`List rows) -> Ok rows
      | Some _ | None -> Error (Malformed "the answer carries no tools list")
    in
    let acc = List.rev_append (List.filter_map (tool_of_json ~era:t.era) rows) acc in
    match member "nextCursor" result with
    | None | Some `Null -> Ok (List.rev acc)
    | Some (`String next) ->
      pages (fetched + 1) (Some next) acc
    | Some _ -> Error (Malformed "tools/list returned a non-string cursor")
  in
  let* tools = pages 0 None [] in
  Atomic.set t.tools (Some tools);
  Ok tools

(* Text blocks joined; anything else named by its type. A model shown a
   shorter answer than the one that arrived would reason from a gap it
   cannot see. *)
let text_of_content content =
  match content with
  | `List blocks ->
    blocks
    |> List.map (fun block ->
         match member "type" block, member "text" block with
         | Some (`String "text"), Some (`String text) -> text
         | Some (`String kind), _ -> Printf.sprintf "[%s]" kind
         | (Some _ | None), _ -> "[block]")
    |> String.concat "\n"
  | _ -> ""

let call_tool_internal ~post ~catalog_authority ~claim_send ~request_state
    ~refresh_catalog ~observe_tool t ~name ~arguments =
  let headers_result =
    match t.era, catalog_authority with
    | Legacy, Unbound -> Ok []
    | (Legacy | Modern), (Unbound | Bound _) ->
      let* () =
        match catalog_authority with
        | Unbound | Bound (Some _) -> Ok ()
        | Bound None -> Error (Malformed "the approval does not bind a tool schema")
      in
      let* tools =
        match refresh_catalog, Atomic.get t.tools with
        | false, Some tools -> Ok tools
        | true, (Some _ | None) | false, None -> list_tools ~post t
      in
      (match List.find_opt (fun tool -> String.equal tool.name name) tools with
       | None -> Error (Malformed "the tool is absent from the current catalog")
       | Some tool ->
         let* () =
           match catalog_authority with
           | Unbound -> Ok ()
           | Bound (Some expected)
             when same_json expected.input_schema tool.input_schema
                  && expected.read_only = tool.read_only -> Ok ()
           | Bound (Some _) -> Error (Malformed "the tool schema changed since approval")
           | Bound None -> Error (Malformed "the approval does not bind a tool schema")
         in
         let* headers = match t.era with
           | Legacy -> Ok []
           | Modern ->
             let* bindings = Result.map_error (fun detail -> Malformed detail) (header_bindings tool.input_schema) in
             Result.map_error (fun detail -> Malformed detail) (headers_for_arguments bindings arguments)
         in
         observe_tool tool;
         Ok headers)
  in
  let* extra_headers = Result.map_error (fun error -> Before_tool_call error) headers_result in
  let* () =
    if claim_send () then Ok ()
    else Error (Before_tool_call (Malformed "the continuation was already consumed"))
  in
  let id = next_request_id t.request_ids ~slot:t.request_ids.call_used ~primary:3 in
  let params =
    [ "name", `String name; "arguments", arguments ]
    @ (match request_state with Some state -> [ "requestState", `String state ] | None -> [])
  in
  let* _, result =
    rpc ~extra_headers ~post t ~include_protocol_version:true ~id ~method_:"tools/call"
      ~params:(`Assoc params)
  in
  let* result_type = unique_member "resultType" result in
  let* () =
    match t.era, result_type with
    | Legacy, None | (Legacy | Modern), Some (`String "complete") -> Ok ()
    | (Legacy | Modern), Some (`String "input_required") ->
      let* input_requests_field = unique_member "inputRequests" result in
      let* input_requests =
        match input_requests_field with
        | None -> Ok None
        | Some (`Assoc _ as requests) -> Ok (Some requests)
        | Some _ -> Error (Malformed "inputRequests must be an object")
      in
      let* request_state_field = unique_member "requestState" result in
      let* request_state =
        match request_state_field with
        | None -> Ok None
        | Some (`String state) -> Ok (Some state)
        | Some _ -> Error (Malformed "requestState must be a string")
      in
      (match input_requests, request_state with
       | None, None -> Error (Malformed "input-required result has no input or state")
       | _ -> Error (Input_required { input_requests; request_state }))
    | Modern, None | (Legacy | Modern), Some _ -> Error (Malformed "the resultType is not supported")
  in
  let* content_field = unique_member "content" result in
  let* content =
    match content_field with
    | Some (`List _ as content) -> Ok content
    | None when t.era = Legacy -> Ok (`List [])
    | Some _ | None -> Error (Malformed "the tool result has no content array")
  in
  let* is_error_field = unique_member "isError" result in
  let* is_error =
    match is_error_field with
    | Some (`Bool value) -> Ok value
    | None -> Ok false
    | Some _ -> Error (Malformed "the tool result has a non-boolean isError")
  in
  let* structured_content = unique_member "structuredContent" result in
  let text = text_of_content content in
  Ok { is_error; text; content; structured_content }

let call_tool ~post ?(catalog_authority = Unbound) t ~name ~arguments =
  call_tool_internal ~post ~catalog_authority ~claim_send:(fun () -> true)
    ~request_state:None ~refresh_catalog:false ~observe_tool:(fun _ -> ()) t ~name ~arguments

type state_only_continuation =
  { client : t
  ; name : string
  ; arguments : Yojson.Safe.t
  ; catalog_authority : catalog_authority
  ; request_state : string
  ; consumed : bool Atomic.t
  }

type state_only_step =
  | Tool_completed of tool_result
  | Tool_continuation of state_only_continuation

type continuation_error =
  | Continuation_consumed
  | Continuation_failed of error

let state_only_step ~client ~name ~arguments ~catalog_authority = function
  | Ok result -> Ok (Tool_completed result)
  | Error (Input_required { input_requests = None; request_state = Some request_state } as error) ->
    (match client.era, catalog_authority with
     | Modern, Bound (Some _) ->
       Ok (Tool_continuation
             { client; name; arguments; catalog_authority; request_state
             ; consumed = Atomic.make false })
     | Modern, (Unbound | Bound None) -> Error (Malformed "the original tool schema was not observed")
     | Legacy, (Unbound | Bound _) -> Error error)
  | Error (Transport _ | Unauthorized _ | Http _ | Rpc _ | Input_required _
          | Before_tool_call _ | Malformed _ as error) -> Error error

let start_tool_with_continuation ~post ?(catalog_authority = Unbound) client ~name ~arguments =
  let offered = ref None in
  let observe_tool (tool : tool) =
    offered := Some { input_schema = tool.input_schema; read_only = tool.read_only }
  in
  let result = call_tool_internal ~post ~catalog_authority ~claim_send:(fun () -> true)
      ~request_state:None ~refresh_catalog:false ~observe_tool client ~name ~arguments in
  let authority = match !offered with
    | Some binding -> Bound (Some binding)
    | None -> catalog_authority
  in
  state_only_step ~client ~name ~arguments ~catalog_authority:authority result

let resume_tool_with_state ~post continuation =
  if Atomic.get continuation.consumed then Error Continuation_consumed
  else
    let claim_rejected = ref false in
    let claim_send () =
      if Atomic.compare_and_set continuation.consumed false true then true
      else (claim_rejected := true; false)
    in
    let result =
      call_tool_internal ~post ~catalog_authority:continuation.catalog_authority
        ~claim_send ~request_state:(Some continuation.request_state)
        ~refresh_catalog:true ~observe_tool:(fun _ -> ())
        continuation.client ~name:continuation.name ~arguments:continuation.arguments
    in
    if !claim_rejected then Error Continuation_consumed
    else
      result
      |> state_only_step ~client:continuation.client ~name:continuation.name
           ~arguments:continuation.arguments ~catalog_authority:continuation.catalog_authority
      |> Result.map_error (fun error -> Continuation_failed error)
