module Blocks = Masc.Keeper_chat_blocks

type t =
  | Image of Blocks.image_block
  | Voice of Blocks.voice_block
  | Attach of Blocks.attach_block
  | Svg of Blocks.svg_block

let of_json json =
  match Blocks.blocks_of_yojson json with
  | None -> []
  | Some blocks -> List.filter_map (function
      | Blocks.Image image -> Some (Image image)
      | Blocks.Voice voice -> Some (Voice voice)
      | Blocks.Attach attachment -> Some (Attach attachment)
      | Blocks.Svg svg -> Some (Svg svg)
      | Blocks.Text _ | Blocks.Heading _ | Blocks.Unordered_list _
      | Blocks.Callout _ | Blocks.Table _ | Blocks.Code _ | Blocks.Mermaid _
      | Blocks.Link _ | Blocks.Fusion _ | Blocks.Status _ | Blocks.Trace _
      | Blocks.Thinking _ -> None) blocks
;;

let source_label src =
  match Uri.scheme (Uri.of_string src) with
  | Some "data" -> "inline payload"
  | Some _ | None -> src
;;

let with_caption label = function
  | None | Some "" -> label
  | Some caption -> label ^ " · " ^ caption
;;

let source_line label = function
  | None -> label
  | Some src -> label ^ " · " ^ source_label src
;;

let describe = function
  | Image image -> source_line (with_caption "Image" image.cap) (Some image.src)
  | Svg svg -> with_caption "SVG" svg.cap
  | Attach attachment ->
    source_line (with_caption "File" (Some attachment.name)) attachment.src
  | Voice voice ->
    let label = match voice.secs with
      | Some secs when Float.is_finite secs && secs >= 0. ->
        Printf.sprintf "Voice · %.1fs" secs
      | Some _ | None -> "Voice" in
    let label = source_line label voice.src in
    match voice.transcript with
    | None | Some "" -> label
    | Some transcript -> label ^ "\n" ^ transcript
;;

let append_text ~text media =
  match media with
  | [] -> text
  | _ ->
    let notes = String.concat "\n" (List.map describe media) in
    if text = "" then notes
    else text ^ (if String.ends_with ~suffix:"\n" text then "" else "\n") ^ notes
;;

let newest_image media =
  List.rev media |> List.find_map (function
    | Image image ->
      Some (Masc_tui_image_preview.output_image
        ~name:(Option.value image.cap ~default:"Image") ~src:image.src)
    | Attach attachment ->
      let preview = match attachment.svg with
        | Some svg -> Masc_tui_image_preview.inline_svg ~name:attachment.name svg
        | None ->
          let retained = Masc_tui_image_preview.persisted_attachment
            ~name:attachment.name
            ~mime:(Option.value attachment.mime_type ~default:"") ~data:attachment.data in
          (match retained, attachment.data, attachment.src with
           | Masc_tui_image_preview.Unavailable_image _, None, Some src ->
             Masc_tui_image_preview.output_image ~name:attachment.name ~src
           | _, _, _ -> retained) in
      (match preview with Masc_tui_image_preview.No_image -> None | _ -> Some preview)
    | Svg svg -> Some (Masc_tui_image_preview.inline_svg
        ~name:(Option.value svg.cap ~default:"SVG") svg.svg)
    | Voice _ -> None)
;;
