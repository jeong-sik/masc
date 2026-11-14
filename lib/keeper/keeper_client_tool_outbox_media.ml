module P = Llm_provider.Types

type kind = Image | Document | Audio

let kind_label = function
  | Image -> "image"
  | Document -> "document"
  | Audio -> "audio"
;;

let omitted ~kind ~media_type encoded =
  let identity =
    match Base64.decode encoded with
    | Ok raw ->
      let stored = Agent_core.History.stored_of_raw raw in
      [ "bytes", `Int stored.bytes; "content_sha256", `String stored.sha256 ]
    | Error (`Msg _) -> [ "invalid_base64_characters", `Int (String.length encoded) ]
  in
  `Assoc
    ([ "type", `String "media_omitted"
     ; "kind", `String (kind_label kind)
     ; "media_type", `String media_type
     ]
     @ identity)
;;

(* A block that does not decode is kept as it is: the projection never
   invents a reading of a value it cannot type. *)
let host_block json =
  match Agent_core.Checkpoint.wire_content_block_of_json json with
  | Error _ -> json
  | Ok (P.Image { media_type; source = P.Base64 encoded }) ->
    omitted ~kind:Image ~media_type encoded
  | Ok (P.Document { media_type; source = P.Base64 encoded }) ->
    omitted ~kind:Document ~media_type encoded
  | Ok (P.Audio { media_type; source = P.Base64 encoded }) ->
    omitted ~kind:Audio ~media_type encoded
  | Ok
      ( P.Image { source = (P.Url _ | P.File_id _); media_type = _ }
      | P.Document { source = (P.Url _ | P.File_id _); media_type = _ }
      | P.Audio { source = (P.Url _ | P.File_id _); media_type = _ } ) -> json
  (* Neither official-client transport sends nested tool-call content
     ([Runtime_official_client_tool.project_content] refuses it), so a nested
     ToolResult is kept whole like the other non-media blocks. *)
  | Ok
      ( P.Text _ | P.Thinking _ | P.ReasoningDetails _ | P.RedactedThinking _
      | P.ToolUse _ | P.ToolResult _ ) -> json
;;

(* [Runtime_official_client_tool.project_content] writes a Codex image as
   ["data:" ^ media_type ^ ";base64," ^ payload]. *)
let data_url_base64 url =
  match String.index_opt url ',' with
  | None -> None
  | Some comma ->
    let header = String.sub url 0 comma in
    let payload = String.sub url (comma + 1) (String.length url - comma - 1) in
    let prefix = "data:" and suffix = ";base64" in
    if String.starts_with ~prefix header && String.ends_with ~suffix header
       && String.length header >= String.length prefix + String.length suffix
    then
      Some
        ( String.sub header (String.length prefix)
            (String.length header - String.length prefix - String.length suffix)
        , payload )
    else None
;;

type codex_item =
  | Input_text of string
  | Data_url_image of
      { media_type : string
      ; payload : string
      }
  | Other_item

let codex_item = function
  | `Assoc fields ->
    (match List.assoc_opt "type" fields with
     | Some (`String "inputText") ->
       (match List.assoc_opt "text" fields with
        | Some (`String text) -> Input_text text
        | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) | None ->
          Other_item)
     | Some (`String "inputImage") ->
       (match List.assoc_opt "imageUrl" fields with
        | Some (`String url) ->
          (match data_url_base64 url with
           | Some (media_type, payload) -> Data_url_image { media_type; payload }
           | None -> Other_item)
        | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) | None ->
          Other_item)
     | Some (`String _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _)
     | None -> Other_item)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Other_item
;;

let map_list f = function
  | `List items -> `List (List.map f items)
  | (`Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as value -> value
;;

let map_field name f = function
  | `Assoc fields ->
    `Assoc (List.map (fun (key, value) -> key, if String.equal key name then f value else value) fields)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) as value -> value
;;

let codex_items = function
  | `Assoc fields ->
    (match List.assoc_opt "result" fields with
     | Some (`Assoc result) ->
       (match List.assoc_opt "contentItems" result with
        | Some (`List items) -> Some (List.map (fun item -> item, codex_item item) items)
        | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _) | None ->
          None)
     | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) | None -> None)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

let with_codex_items items response =
  map_field "result" (map_field "contentItems" (fun _ -> `List items)) response
;;

let with_input_text text item = map_field "text" (fun _ -> `String text) item

let response json =
  let json = map_field "content_blocks" (map_list host_block) json in
  match codex_items json with
  | None -> json
  | Some items ->
    with_codex_items
      (List.map
         (fun (item, held) ->
            match held with
            | Data_url_image { media_type; payload } -> omitted ~kind:Image ~media_type payload
            | Input_text _ | Other_item -> item)
         items)
      json
;;

let carrier_row receipt = map_field "response" response receipt
