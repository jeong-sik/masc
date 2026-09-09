type order = Named_is_newer | Staged_is_newer | Unordered

type preview =
  | Named_path of string
  | Staged of Masc_tui_keeper_chat_projection.attachment
  | Stored_attachment of { name : string; reference : Tool_output.artifact_ref }
  | Unavailable_attachment of string
  | No_image

let persisted_attachment ~name ~mime ~data =
  if not (String.starts_with ~prefix:"image/" mime) then No_image
  else
    match Option.map Tool_output.decode_from_agent_core data with
    | Some (Tool_output.Decoded reference) -> Stored_attachment { name; reference }
    | Some (Tool_output.Not_marker | Tool_output.Invalid_marker _) | None ->
        Unavailable_attachment name

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
