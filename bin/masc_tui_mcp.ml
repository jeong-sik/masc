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

let string_field fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
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
