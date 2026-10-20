let essence mime =
  match String.split_on_char ';' (String.lowercase_ascii (String.trim mime)) with
  | first :: _ -> String.trim first
  | [] -> ""

let is_image mime =
  match String.split_on_char '/' (essence mime) with
  | [ "image"; subtype ] -> subtype <> ""
  | _ -> false

let images ~mime_type contents =
  List.mapi (fun index (part : Masc_tui_mcp.resource_content) ->
    let mime = match part.rc_mime_type with Some _ as mime -> mime | None -> mime_type in
    let name = Printf.sprintf "Resource image · part %d" (index + 1) in
    match mime, part.rc_kind with
    | Some mime, Masc_tui_mcp.Resource_blob {base64} when is_image mime ->
      Some (index + 1, Masc_tui_image_preview.inline_payload ~name ~base64)
    | Some mime, Resource_text source when String.equal (essence mime) "image/svg+xml" ->
      Some (index + 1, Masc_tui_image_preview.inline_svg ~name source)
    | (Some _ | None), (Resource_text _ | Resource_blob _) -> None)
    contents
  |> List.filter_map Fun.id

let same_reading ~equal left right =
  match left, right with
  | Some (left_uri, left_parts), Some (right_uri, right_parts) ->
    equal left_uri right_uri && left_parts == right_parts
  | (Some _ | None), None | None, Some _ -> false
