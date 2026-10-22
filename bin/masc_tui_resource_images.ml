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
    let candidates = match mime, part.rc_kind with
      | Some mime, Masc_tui_mcp.Resource_blob {base64} when is_image mime ->
        [Masc_tui_image_preview.inline_payload ~name
          (Masc_tui_image_payload.of_base64 ~mime_type:mime base64)]
      | Some mime, Resource_text source when String.equal (essence mime) "image/svg+xml" ->
        [Masc_tui_image_preview.inline_svg ~name source]
      | Some mime, Resource_text source when String.equal (essence mime) "text/html" ->
        source |> Masc_tui_artifact_html.project |> Masc_tui_artifact_html.images
        |> List.map (fun (image : Masc_tui_artifact_html.image) ->
          let name = name ^ " · " ^ image.label in
          match image.source with
          | Masc_tui_artifact_html.Embedded_base64 payload ->
            Masc_tui_image_preview.inline_payload ~name payload
          | Embedded_svg source -> Masc_tui_image_preview.inline_svg ~name source
          | Unavailable reason -> Masc_tui_image_preview.Unavailable_image {name;reason})
      | (Some _ | None), (Resource_text _ | Resource_blob _) -> [] in
    List.map (fun image -> index + 1, image) candidates) contents
  |> List.concat

let same_reading ~equal left right =
  match left, right with
  | Some (left_uri, left_parts), Some (right_uri, right_parts) ->
    equal left_uri right_uri && left_parts == right_parts
  | (Some _ | None), None | None, Some _ -> false
