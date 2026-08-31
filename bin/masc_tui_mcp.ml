module Projection = Masc_tui_keeper_chat_projection

let request_body ~request_id ~tool ~arguments =
  Yojson.Safe.to_string
    (`Assoc
      [ ("jsonrpc", `String "2.0")
      ; ("id", `String request_id)
      ; ("method", `String "tools/call")
      ; ( "params"
        , `Assoc [ ("name", `String tool); ("arguments", `Assoc arguments) ] )
      ])

type outcome = {
  text : string;
  is_error : bool;
}

type resource = {
  uri : string;
  name : string;
  title : string option;
  description : string option;
  mime_type : string option;
  size : int option;
}

let string_field fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | Some _ | None -> None

let int_field fields name =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Some value
  | Some _ | None -> None

(* The response object, whichever framing carried it. An SSE body holds it
   on its [data:] line; the first such line is the answer. A body with no
   such line is read as the object itself. *)
let response_json body =
  let data_lines =
    String.split_on_char '\n' body
    |> List.filter_map (fun line ->
           match Projection.classify_sse_line line with
           | Projection.Sse_data payload -> Some payload
           | Projection.Sse_ignored | Projection.Sse_noncanonical_data -> None)
  in
  let raw = match data_lines with first :: _ -> first | [] -> String.trim body in
  match Yojson.Safe.from_string raw with
  | json -> Ok json
  | exception Yojson.Json_error detail -> Error ("tools/call answer was not JSON: " ^ detail)

let ( let* ) = Result.bind

let text_of_content (content : Yojson.Safe.t) =
  match content with
  | `List parts ->
      parts
      |> List.filter_map (fun part ->
             match part with
             | `Assoc fields -> (
                 match (string_field fields "type", string_field fields "text") with
                 | Some "text", Some text -> Some text
                 | _, _ -> None)
             | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _
               ->
                 None)
      |> String.concat "\n"
  | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _ -> ""

let outcome_of_body ~request_id body =
  let* json = response_json body in
  match json with
  | `Assoc fields -> (
      let answered =
        match List.assoc_opt "id" fields with
        | Some (`String id) -> Some id
        | Some (`Int id) -> Some (string_of_int id)
        | Some _ | None -> None
      in
      match answered with
      | Some id when not (String.equal id request_id) ->
          Error (Printf.sprintf "tools/call answered request %s, not %s" id request_id)
      | Some _ | None -> (
          match List.assoc_opt "error" fields with
          | Some (`Assoc error) ->
              Error
                (Printf.sprintf "tools/call refused: %s"
                   (Option.value ~default:"(no message)" (string_field error "message")))
          | Some _ -> Error "tools/call refused with an error this cannot read"
          | None -> (
              match List.assoc_opt "result" fields with
              | Some (`Assoc result) -> (
                  let is_error =
                    match List.assoc_opt "isError" result with
                    | Some (`Bool value) -> value
                    | Some _ | None -> false
                  in
                  match List.assoc_opt "content" result with
                  | Some content -> (
                      match text_of_content content with
                      | "" -> Error "tools/call answered with no text content"
                      | text -> Ok { text; is_error })
                  | None -> Error "tools/call answered with no content")
              | Some _ | None -> Error "tools/call answered with no result")))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
      Error "tools/call answer was not an object"

let task_id_of_add_task text =
  match Yojson.Safe.from_string text with
  | `Assoc fields -> (
      match string_field fields "task_id" with
      | Some id -> Ok id
      | None -> Error ("masc_add_task answered without a task_id: " ^ text))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
      Error ("masc_add_task did not answer with an object: " ^ text)
  | exception Yojson.Json_error _ -> Error ("masc_add_task did not answer JSON: " ^ text)

(* The resources side of the same wire: list and read, framed exactly like
   tools/call and read through the same SSE-or-plain body reader. *)

let plain_request_body ~request_id ~method_ ~params =
  Yojson.Safe.to_string
    (`Assoc
      [ ("jsonrpc", `String "2.0")
      ; ("id", `String request_id)
      ; ("method", `String method_)
      ; ("params", params)
      ])

let resources_list_request_body ~request_id =
  plain_request_body ~request_id ~method_:"resources/list" ~params:(`Assoc [])

let resources_read_request_body ~request_id ~uri =
  plain_request_body ~request_id ~method_:"resources/read"
    ~params:(`Assoc [ ("uri", `String uri) ])

(* Every data payload on the stream, in order. A Streamable-HTTP server may
   put notifications ahead of the response, and the colon-no-space spelling
   is legal SSE, so this reads more than [response_json]'s first line. *)
let response_candidates body =
  let data_payloads =
    String.split_on_char '\n' body
    |> List.filter_map (fun line ->
           let line =
             if String.length line > 0 && line.[String.length line - 1] = '\r'
             then String.sub line 0 (String.length line - 1)
             else line
           in
           if String.length line >= 5 && String.sub line 0 5 = "data:" then
             let payload = String.sub line 5 (String.length line - 5) in
             Some (String.trim payload)
           else None)
    |> List.filter_map (fun payload ->
           match Yojson.Safe.from_string payload with
           | json -> Some json
           | exception Yojson.Json_error _ -> None)
  in
  match data_payloads with
  | [] -> (
      match Yojson.Safe.from_string (String.trim body) with
      | json -> [ json ]
      | exception Yojson.Json_error _ -> [])
  | payloads -> payloads

let result_of_body ~request_id ~label body =
  let candidates = response_candidates body in
  let id_of fields =
    match List.assoc_opt "id" fields with
    | Some (`String value) -> Some value
    | Some (`Int value) -> Some (string_of_int value)
    | Some `Null -> None
    | _ -> None
  in
  let matching =
    List.find_map
      (fun json ->
        match json with
        | `Assoc fields when id_of fields = Some request_id -> Some fields
        | _ -> None)
      candidates
  in
  match matching with
  | Some fields -> (
      match List.assoc_opt "error" fields with
      | Some error -> Error (label ^ " error: " ^ Yojson.Safe.to_string error)
      | None -> (
          match List.assoc_opt "result" fields with
          | Some (`Assoc result) -> Ok result
          | Some _ | None -> Error (label ^ " answered with no result")))
  | None -> (
      (* No frame names our id. A parse-refusal answers with a null id and
         an error member -- that error is the diagnosis, not the id gate. *)
      let null_id_error =
        List.find_map
          (fun json ->
            match json with
            | `Assoc fields when id_of fields = None ->
                List.assoc_opt "error" fields
            | _ -> None)
          candidates
      in
      match null_id_error with
      | Some error -> Error (label ^ " error: " ^ Yojson.Safe.to_string error)
      | None ->
          if candidates = [] then Error (label ^ " answer was not JSON")
          else Error (label ^ " answered a different request id"))

let resources_of_body ~request_id body =
  let* result = result_of_body ~request_id ~label:"resources/list" body in
  match List.assoc_opt "resources" result with
  | Some (`List rows) ->
      Ok
        (List.filter_map
           (fun row ->
             match row with
             | `Assoc fields -> (
                 match string_field fields "uri" with
                 | Some uri ->
                     let name =
                       match string_field fields "name" with
                       | Some name when String.trim name <> "" -> name
                       | Some _ | None -> uri
                     in
                     Some
                       { uri
                       ; name
                       ; title = string_field fields "title"
                       ; description = string_field fields "description"
                       ; mime_type = string_field fields "mimeType"
                       ; size = int_field fields "size"
                       }
                 | None -> None)
             | _ -> None)
           rows)
  | Some _ | None -> Error "resources/list answered with no resources"

let resource_text_of_body ~request_id body =
  let* result = result_of_body ~request_id ~label:"resources/read" body in
  match List.assoc_opt "contents" result with
  | Some (`List parts) ->
      (* A blob-only part must not read as an empty text file: name it. *)
      let rendered =
        List.filter_map
          (fun part ->
            match part with
            | `Assoc fields -> (
                match string_field fields "text" with
                | Some text -> Some text
                | None -> (
                    match string_field fields "blob" with
                    | Some blob ->
                        Some
                          (Printf.sprintf
                             "(binary resource \xe2\x80\x94 %d base64 bytes, not rendered)"
                             (String.length blob))
                    | None -> None))
            | _ -> None)
          parts
      in
      Ok (String.concat "\n" rendered)
  | Some _ | None -> Error "resources/read answered with no contents"

let resource_body_for_markdown resource text =
  let media_type =
    resource.mime_type
    |> Option.map (fun value ->
           let media_type =
             match String.split_on_char ';' value with
             | first :: _ -> first
             | [] -> value
           in
           media_type |> String.trim |> String.lowercase_ascii)
  in
  let is_json =
    match media_type with
    | Some "application/json" -> true
    | Some value -> String.ends_with ~suffix:"+json" value
    | None -> false
  in
  if is_json then
    let pretty =
      match Yojson.Safe.from_string text with
      | json -> Yojson.Safe.pretty_to_string json
      | exception Yojson.Json_error _ -> text
    in
    "```json\n" ^ pretty ^ "\n```"
  else text

(* Cancel is an exit-class action on the masc_transition contract: it wants
   [reason] and a non-empty [handoff_context.summary]. The one operator-typed
   reason serves as both, and this stays a pure function so the test suite can
   pin the contract without a transport. *)
let task_cancel_arguments ~task_id ~reason =
  [ ("task_id", `String task_id)
  ; ("action", `String "cancel")
  ; ("reason", `String reason)
  ; ("handoff_context", `Assoc [ ("summary", `String reason) ])
  ]
