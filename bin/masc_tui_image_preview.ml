type order = Named_is_newer | Staged_is_newer | Unordered

type output_source =
  | Inline_data of string
  | Inline_svg of string
  | Server_path of string
  | Remote_uri of string

type preview =
  | Named_path of string
  | Staged of Masc_tui_keeper_chat_projection.attachment
  | Stored_attachment of { name : string; reference : Tool_output.artifact_ref }
  | Output_image of { name : string; source : output_source }
  | Unavailable_image of { name : string; reason : string }
  | No_image

let persisted_attachment ~name ~mime ~data =
  if not (String.starts_with ~prefix:"image/" mime) then No_image
  else
    match Option.map Tool_output.decode_from_agent_core data with
    | Some (Tool_output.Decoded reference) -> Stored_attachment { name; reference }
    | Some (Tool_output.Not_marker | Tool_output.Invalid_marker _) | None ->
        Unavailable_image { name; reason = "image has no retained payload" }

let output_image ~name ~src =
  let unavailable reason = Unavailable_image { name; reason } in
  match Tool_output.decode_from_agent_core src with
  | Tool_output.Decoded reference -> Stored_attachment { name; reference }
  | Tool_output.Invalid_marker { detail } -> unavailable detail
  | Tool_output.Not_marker ->
    let uri = Uri.of_string src in
    let normalized = Uri.to_string uri in
    match Uri.scheme uri, Uri.host uri with
    | Some "data", None -> Output_image { name; source = Inline_data src }
    | (Some "http" | Some "https"), Some host when host <> "" ->
      Output_image { name; source = Remote_uri normalized }
    | None, None when String.starts_with ~prefix:"/" (Uri.path uri) ->
      Output_image { name; source = Server_path normalized }
    | Some _, _ | None, _ -> unavailable "unsupported image source"
;;

let inline_svg ~name svg = Output_image { name; source = Inline_svg svg }

let in_message ~text ~attachments =
  match List.find_opt (function No_image -> false | _ -> true) (List.rev attachments) with
  | Some image -> image
  | None ->
      match List.rev (Masc_tui_image_ref.paths text) with
      | last :: _ -> Named_path last
      | [] -> No_image

let choose_preview ~conversation ~staged ~order =
  match conversation, List.rev staged with
  | No_image, [] -> No_image
  | image, [] -> image
  | No_image, newest :: _ -> Staged newest
  | image, newest :: _ ->
      match order with
      | Staged_is_newer -> Staged newest
      | Named_is_newer | Unordered -> image

let decode_payload data =
  let data = String.trim data in
  let payload =
    if String.starts_with ~prefix:"data:" data then
      match String.index_opt data ',' with
      | Some comma when String.ends_with ~suffix:";base64" (String.sub data 0 comma) ->
          Ok (String.sub data (comma + 1) (String.length data - comma - 1))
      | Some _ | None -> Error "image data URI is not base64"
    else Ok data
  in
  Result.bind payload (fun payload ->
    Result.map_error (fun (`Msg detail) -> detail) (Base64.decode payload))

let decode_artifact (reference : Tool_output.artifact_ref) = function
  | `Assoc fields ->
      (match List.assoc_opt "sha256" fields, List.assoc_opt "bytes" fields,
             List.assoc_opt "content" fields with
       | Some (`String sha256), Some (`Int bytes), Some (`String content) ->
           if not (String.equal sha256 reference.sha256)
              || bytes <> reference.bytes || String.length content <> bytes then
             Error "sent image response does not match its recorded artifact"
           else if not (String.equal
               Digestif.SHA256.(to_hex (digest_string content)) reference.sha256) then
             Error "sent image content does not match its recorded digest"
           else decode_payload content
       | _ -> Error "sent image response requires sha256, bytes, and content")
  | _ -> Error "invalid sent image response"
