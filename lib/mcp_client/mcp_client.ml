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
}

type error =
  | Transport of string
  | Unauthorized of { resource_metadata : string option }
  | Http of { status : int; body : string }
  | Rpc of { code : int; message : string }
  | Malformed of string

let error_to_string = function
  | Transport detail -> Printf.sprintf "the request did not complete: %s" detail
  | Unauthorized { resource_metadata } ->
    (match resource_metadata with
     | Some url ->
       Printf.sprintf
         "the server refused this token; it says how to get one at %s" url
     | None -> "the server refused this token and said nothing about how to get one")
  | Http { status; body } ->
    Printf.sprintf "the server answered HTTP %d: %s" status body
  | Rpc { code; message } ->
    Printf.sprintf "the server refused the call (%d): %s" code message
  | Malformed detail ->
    Printf.sprintf "the server's answer could not be read: %s" detail

type post =
  url:string ->
  headers:(string * string) list ->
  body:string ->
  (Masc_http_client.response, string) result

let default_post ~url ~headers ~body =
  Masc_http_client.post_response_sync ~url ~headers ~body ()

type t = {
  url : string;
  access_token : string;
  session : string option;
  protocol_version : string;
}

let negotiated_protocol_version t = t.protocol_version
let session_id t = t.session

let ( let* ) = Result.bind

(* One header name compared without regard to case, because HTTP says so and
   the two servers this has been pointed at disagree about capitalisation. *)
let header_value headers name =
  let wanted = String.lowercase_ascii name in
  List.find_map
    (fun (key, value) ->
      if String.equal (String.lowercase_ascii key) wanted then Some value else None)
    headers

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

let result_of_rpc json =
  match member "error" json with
  | Some error ->
    let code =
      match member "code" error with
      | Some (`Int code) -> code
      | Some _ | None -> 0
    in
    let message =
      match member "message" error with
      | Some (`String message) -> message
      | Some _ | None -> Yojson.Safe.to_string error
    in
    Error (Rpc { code; message })
  | None ->
    (match member "result" json with
     | Some result -> Ok result
     | None -> Error (Malformed "the answer carries neither result nor error"))

let headers_for t ~include_protocol_version =
  [ "Content-Type", "application/json"
    (* Both, because either is a legal answer and refusing one would make
       the server's choice into our failure. *)
  ; "Accept", "application/json, text/event-stream"
  ; "Authorization", "Bearer " ^ t.access_token
  ]
  @ (if include_protocol_version
     then [ "MCP-Protocol-Version", t.protocol_version ]
     else [])
  @
  match t.session with
  | Some session -> [ "Mcp-Session-Id", session ]
  | None -> []

let request ~post t ~include_protocol_version ~body =
  match post ~url:t.url ~headers:(headers_for t ~include_protocol_version) ~body with
  | Error detail -> Error (Transport detail)
  | Ok response ->
    let status = response.Masc_http_client.status in
    if status = 401 || status = 403
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
    then Error (Http { status; body = response.Masc_http_client.body })
    else Ok response

let rpc ~post t ~include_protocol_version ~id ~method_ ~params =
  let body =
    Yojson.Safe.to_string
      (`Assoc
        [ "jsonrpc", `String "2.0"
        ; "id", `Int id
        ; "method", `String method_
        ; "params", params
        ])
  in
  let* response = request ~post t ~include_protocol_version ~body in
  let* json =
    json_of_body
      ~content_type:(header_value response.Masc_http_client.headers "content-type")
      response.Masc_http_client.body
  in
  let* result = result_of_rpc json in
  Ok (response, result)

let notify ~post t ~method_ =
  let body =
    Yojson.Safe.to_string
      (`Assoc
        [ "jsonrpc", `String "2.0"
        ; "method", `String method_
        ; "params", `Assoc []
        ])
  in
  Result.map (fun _ -> ()) (request ~post t ~include_protocol_version:true ~body)

let client_info =
  `Assoc [ "name", `String "masc"; "version", `String Build_version.current ]

let connect ?(post = default_post) ~url ~access_token () =
  let offered = Mcp_transport_protocol.default_protocol_version in
  let opening =
    { url
    ; access_token
    ; session = None
    ; protocol_version = offered
    }
  in
  let* response, result =
    rpc ~post opening ~include_protocol_version:false ~id:1 ~method_:"initialize"
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
      when Mcp_transport_protocol.is_supported_protocol_version version ->
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

let tool_of_json json =
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
      | None -> `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
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
    Some { name; description; input_schema; read_only }
  | Some _ | None -> None

let list_tools ?(post = default_post) t =
  let* _, result =
    rpc ~post t ~include_protocol_version:true ~id:2 ~method_:"tools/list"
      ~params:(`Assoc [])
  in
  match member "tools" result with
  | Some (`List rows) -> Ok (List.filter_map tool_of_json rows)
  | Some _ | None -> Error (Malformed "the answer carries no tools list")

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

let call_tool ?(post = default_post) t ~name ~arguments =
  let* _, result =
    rpc ~post t ~include_protocol_version:true ~id:3 ~method_:"tools/call"
      ~params:(`Assoc [ "name", `String name; "arguments", arguments ])
  in
  let content =
    match member "content" result with
    | Some content -> content
    | None -> `List []
  in
  let is_error =
    match member "isError" result with
    | Some (`Bool value) -> value
    | Some _ | None -> false
  in
  Ok { is_error; text = text_of_content content; content }
