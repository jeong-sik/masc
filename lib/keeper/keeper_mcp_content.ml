module Mcp = Mcp_protocol.Mcp_types
module P = Llm_provider.Types

let private_result_mime = "application/vnd.masc.mcp-result+json"

type block =
  | Native_block of P.content_block
  | Binary_resource of { uri : string; mime_type : string option; bytes : string }

type projection =
  { content : string
  ; content_blocks : block list option
  }

let ( let* ) = Result.bind

let object_fields = function
  | `Assoc fields ->
    let rec unique seen = function
      | [] -> Ok fields
      | (key, _) :: rest ->
        if Set_util.StringSet.mem key seen then Error "duplicate object field"
        else unique (Set_util.StringSet.add key seen) rest
    in
    unique Set_util.StringSet.empty fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "expected an object"

let optional_string fields key =
  match List.assoc_opt key fields with
  | None | Some (`String _) -> Ok ()
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) ->
    Error "optional content field must be a string"

let validate_annotations fields =
  match List.assoc_opt "annotations" fields with
  | None -> Ok ()
  | Some raw ->
    let* fields = object_fields raw in
    let* () = match List.assoc_opt "audience" fields with
      | None -> Ok ()
      | Some (`List roles) ->
        List.fold_left (fun result role ->
          let* () = result in
          match Mcp.role_of_yojson role with
          | Ok (Mcp.User | Mcp.Assistant) -> Ok ()
          | Error _ -> Error "invalid audience role") (Ok ()) roles
      | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _) ->
        Error "audience must be an array"
    in
    match List.assoc_opt "priority" fields with
    | None -> Ok ()
    | Some (`Int value) when value = 0 || value = 1 -> Ok ()
    | Some (`Float value) when Float.is_finite value && value >= 0. && value <= 1. -> Ok ()
    | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _) ->
      Error "priority must be a number between zero and one"

let validate_shape raw =
  let* fields = object_fields raw in
  let* () = validate_annotations fields in
  let* () = List.fold_left (fun result key ->
    let* () = result in optional_string fields key) (Ok ())
    [ "type"; "text"; "data"; "mimeType"; "uri"; "name"; "description" ] in
  match List.assoc_opt "resource" fields with
  | None -> Ok ()
  | Some resource ->
    let* fields = object_fields resource in
    let* () = List.fold_left (fun result key ->
      let* () = result in optional_string fields key) (Ok ())
      [ "uri"; "text"; "blob"; "mimeType"; "mime_type" ] in
    (* The SDK accepts both body fields and a second MIME spelling. Neither
       may silently select one of two contradictory source values. *)
    let* () = match List.assoc_opt "mimeType" fields, List.assoc_opt "mime_type" fields with
      | Some _, Some _ -> Error "embedded resource has two MIME declarations"
      | None, None | Some _, None | None, Some _ -> Ok () in
    match List.assoc_opt "text" fields, List.assoc_opt "blob" fields with
    | Some _, Some _ -> Error "embedded resource has both text and blob"
    | None, None -> Error "embedded resource has no body"
    | Some _, None | None, Some _ -> Ok ()

let assistant_visible = function
  | None | Some { Mcp.audience = None; _ } -> true
  | Some { Mcp.audience = Some roles; _ } ->
    List.exists (function Mcp.Assistant -> true | Mcp.User -> false) roles

let annotations = function
  | Mcp.TextContent { annotations; _ }
  | Mcp.ImageContent { annotations; _ }
  | Mcp.AudioContent { annotations; _ }
  | Mcp.ResourceContent { annotations; _ }
  | Mcp.ResourceLinkContent { annotations; _ } -> annotations

let decode_base64 data =
  match Base64.decode data with
  | Error (`Msg _) -> Error "payload is not valid base64"
  | Ok bytes when not (String.equal (Base64.encode_string bytes) data) ->
    Error "payload is not canonical padded base64"
  | Ok bytes -> Ok bytes

let media ~kind ~media_type ~data make =
  (* MIME type/subtype are case-insensitive; parameter values need not be.
     Keep the original spelling in the retained MCP envelope. *)
  let media_type = match String.index_opt media_type ';' with
    | None -> String.trim media_type |> String.lowercase_ascii
    | Some index ->
      (String.sub media_type 0 index |> String.trim |> String.lowercase_ascii)
      ^ String.sub media_type index (String.length media_type - index)
  in
  if String.trim media_type = "" then Error "media has no MIME type"
  else
    let* raw = decode_base64 data in
    if String.equal raw "" then Error "media payload is empty"
    else
        Ok
          ( Printf.sprintf "[MCP %s: %s, %d bytes]" kind media_type (String.length raw)
          , [ Native_block (make ~media_type ~source:(P.Base64 data)) ] )

let resource_reference ~uri ~name ~description ~mime_type =
  let optional key = function None -> [] | Some value -> [ key, `String value ] in
  "MCP resource reference: " ^ Yojson.Safe.to_string
    (`Assoc ([ "uri", `String uri ] @ optional "name" name
             @ optional "description" description @ optional "mimeType" mime_type))

type resource_media = Resource_image | Resource_audio | Resource_pdf

(* MCP's ResourceContent has no modality tag. Decode only the declared MIME
   forms our existing image and H5 readers carry. Other blobs remain binary
   resources; a URI supplies no authority to reinterpret them as documents.
   Of the nine document formats only a PDF becomes a document block here;
   the other eight stay binary resources. *)
let resource_media media_type =
  let mime = Tool_blob_media_store.blob_mime media_type |> String.lowercase_ascii in
  if List.mem mime Runtime_official_client_tool.official_client_image_media_types
  then Some Resource_image
  else match mime with
    | "audio/wav" | "audio/x-wav" | "audio/wave" | "audio/mpeg" | "audio/mp3"
    | "audio/ogg" | "audio/flac" | "audio/mp4" | "audio/m4a" | "audio/x-m4a"
    | "audio/webm" -> Some Resource_audio
    | other ->
      (match Document_format.of_wire_mime other with
       | Some Pdf -> Some Resource_pdf
       | Some (Hwp | Hwpx | Doc | Docx | Xls | Xlsx | Ppt | Pptx) | None -> None)

let project_item = function
  | Mcp.TextContent { text; _ } -> Ok (text, [ Native_block (P.Text text) ])
  | Mcp.ImageContent { data; mime_type; _ } ->
    media ~kind:"image" ~media_type:mime_type ~data P.image_block
  | Mcp.AudioContent { data; mime_type; _ } ->
    media ~kind:"audio" ~media_type:mime_type ~data P.audio_block
  | Mcp.ResourceLinkContent { uri; name; description; mime_type; _ } ->
    let reference = resource_reference ~uri ~name ~description ~mime_type in
    Ok (reference, [ Native_block (P.Text reference) ])
  | Mcp.ResourceContent { resource; _ } ->
    let reference = resource_reference ~uri:resource.uri ~name:None
      ~description:None ~mime_type:resource.mime_type in
    (match resource.text, resource.blob with
     | Some text, None ->
       Ok (reference ^ "\n" ^ text, [ Native_block (P.Text reference); Native_block (P.Text text) ])
     | None, Some data ->
       (match resource.mime_type, Option.bind resource.mime_type resource_media with
        | Some media_type, Some kind ->
          let kind, make = match kind with
            | Resource_image -> "image", P.image_block
            | Resource_audio -> "audio", P.audio_block
            | Resource_pdf -> "document", P.document_block in
          let* summary, blocks = media ~kind ~media_type ~data make in
          Ok (reference ^ "\n" ^ summary, Native_block (P.Text reference) :: blocks)
        | (None | Some _), None | None, Some _ ->
          let* bytes = decode_base64 data in
          let summary = Printf.sprintf "[MCP binary resource: %d bytes]" (String.length bytes) in
          Ok (reference ^ "\n" ^ summary,
              [ Native_block (P.Text reference)
              ; Binary_resource { uri = resource.uri; mime_type = resource.mime_type; bytes }
              ]))
     | Some _, Some _ -> Error "embedded resource has both text and blob"
     | None, None -> Error "embedded resource has no body")

let project (result : Mcp_client.tool_result) =
  let* items = match result.content with
    | `List items -> Ok items
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ ->
      Error "MCP content must be an array" in
  let rec collect index texts blocks = function
    | [] -> Ok (List.rev texts, List.rev blocks)
    | raw :: rest ->
      let projected =
        let* () = validate_shape raw in
        let* item = match Mcp.tool_content_of_yojson raw with
          | Ok item -> Ok item
          | Error _ -> Error "unsupported or malformed content item" in
        if assistant_visible (annotations item) then Result.map Option.some (project_item item)
        else Ok None
      in
      (match projected with
       | Error reason -> Error (Printf.sprintf "MCP content[%d]: %s" index reason)
       | Ok None -> collect (index + 1) texts blocks rest
       | Ok (Some (text, projected_blocks)) ->
         collect (index + 1) (text :: texts) (List.rev_append projected_blocks blocks) rest)
  in
  let* texts, blocks = collect 0 [] [] items in
  let texts, blocks = match result.structured_content with
    | None -> texts, blocks
    | Some structured ->
      let text = (if blocks = [] then "" else "structuredContent: ")
                 ^ Yojson.Safe.to_string structured in
      texts @ [ text ], blocks @ [ Native_block (P.Text text) ] in
  Ok { content = String.concat "\n" texts
     ; content_blocks = (match blocks with [] -> None | _ :: _ -> Some blocks) }
