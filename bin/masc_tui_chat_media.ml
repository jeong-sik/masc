module Blocks = Masc.Keeper_chat_blocks

type t =
  | Image of Blocks.image_block
  | Voice of Blocks.voice_block
  | Attach of Blocks.attach_block
  | Svg of Blocks.svg_block
  | Mermaid of Blocks.mermaid_block

let of_generated (media : Masc.Keeper_chat_events.generated_media) =
  match Masc.Keeper_chat_media_store.category_of_media_type media.media_type with
  | Masc.Keeper_chat_media_store.Image -> Image {src=media.media_ref; cap=None}
  | Masc.Keeper_chat_media_store.Audio ->
      Voice {secs=None; wave=None; via=None; size=None; transcript=None; src=Some media.media_ref}
  | Masc.Keeper_chat_media_store.Document | Masc.Keeper_chat_media_store.Other ->
      Attach {name="generated media"; dims=None; src=Some media.media_ref; svg=None;
        ph=None; via=None; size=None; data=None; mime_type=Some media.media_type;
        size_bytes=None; kind=None}

let of_json json =
  match Blocks.blocks_of_yojson json with
  | None -> []
  | Some blocks -> List.filter_map (function
      | Blocks.Image image -> Some (Image image)
      | Blocks.Voice voice -> Some (Voice voice)
      | Blocks.Attach attachment -> Some (Attach attachment)
      | Blocks.Svg svg -> Some (Svg svg)
      | Blocks.Mermaid diagram -> Some (Mermaid diagram)
      | Blocks.Text _ | Blocks.Heading _ | Blocks.Unordered_list _
      | Blocks.Callout _ | Blocks.Table _ | Blocks.Code _
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
  | Mermaid diagram ->
      let source = match Masc_tui_markdown.non_colliding_fence_marker
          (String.split_on_char '\n' diagram.source) with
        | Some marker -> marker ^ "mermaid\n" ^ diagram.source ^ "\n" ^ marker
        | None -> diagram.source in
      with_caption "Mermaid · Ctrl-O:diagram" diagram.caption ^ "\n" ^ source
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
  let sources = Masc_tui_markdown.mermaid_sources text in
  let media = List.filter (function
    | Mermaid diagram -> not (List.mem diagram.source sources)
    | Image _ | Voice _ | Attach _ | Svg _ -> true) media in
  match media with
  | [] -> text
  | _ ->
    let notes = String.concat "\n" (List.map describe media) in
    if text = "" then notes
    else text ^ (if String.ends_with ~suffix:"\n" text then "" else "\n") ^ notes
;;

let images media =
  media |> List.filter_map (function
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
           | (Masc_tui_image_preview.Named_path _, _, _) | (Masc_tui_image_preview.Staged _, _, _)
           | (Masc_tui_image_preview.Stored_attachment _, _, _)
           | (Masc_tui_image_preview.Output_image _, _, _)
           | (Masc_tui_image_preview.Unavailable_image _, _, _)
           | (Masc_tui_image_preview.No_image, _, _) -> retained) in
      (match preview with
        | Masc_tui_image_preview.No_image -> None
        | Masc_tui_image_preview.Named_path _ | Staged _ | Stored_attachment _ | Output_image _
        | Unavailable_image _ -> Some preview)
    | Svg svg -> Some (Masc_tui_image_preview.inline_svg
        ~name:(Option.value svg.cap ~default:"SVG") svg.svg)
    | Mermaid diagram -> Some (Masc_tui_image_preview.mermaid
        ~name:(Option.value diagram.caption ~default:"Mermaid") diagram.source)
    | Voice _ -> None)
;;

let without_drawn_generated ~covered media previews =
  let rec consume matches = function
    | [] -> None
    | head :: tail when matches head -> Some tail
    | head :: tail -> Option.map (List.cons head) (consume matches tail) in
  let remaining, kept = List.fold_left (fun (remaining, kept) block ->
    match consume (fun observed -> of_generated observed = block) remaining with
    | None -> remaining, block :: kept
    | Some remaining -> remaining, kept) (covered, []) media in
  let _, kept_previews = List.fold_left (fun (remaining, kept) preview ->
    match consume (fun observed -> List.mem preview (images [of_generated observed])) remaining with
    | None -> remaining, preview :: kept
    | Some remaining -> remaining, kept) (covered, []) previews in
  List.rev kept, List.rev kept_previews, remaining
;;

let newest_image media =
  match List.rev (images media) with
  | newest :: _ -> Some newest
  | [] -> None
;;

let without_drawn_diagrams ~sources media previews =
  let rec consume source = function
    | [] -> None
    | head :: tail when String.equal source head -> Some tail
    | head :: tail -> Option.map (List.cons head) (consume source tail)
  in
  let uncovered source_of values =
    let _, kept = List.fold_left (fun (remaining, kept) value ->
      match source_of value with
      | None -> remaining, value :: kept
      | Some source ->
          match consume source remaining with
          | None -> remaining, value :: kept
          | Some remaining -> remaining, kept) (sources, []) values in
    List.rev kept
  in
  let media_source = function
    | Mermaid diagram -> Some diagram.source
    | Image _ | Voice _ | Attach _ | Svg _ -> None in
  let preview_source = function
    | Masc_tui_image_preview.Output_image {source=Inline_mermaid source;_} -> Some source
    | Named_path _ | Staged _ | Stored_attachment _
    | Output_image {source=(Inline_data _ | Inline_svg _ | Server_path _ | Remote_uri _);_}
    | Unavailable_image _ | No_image -> None in
  uncovered media_source media, uncovered preview_source previews
;;

(* {1 Playback}

   What /listen plays: an attach with an audio or MIDI extension whose bytes
   are in the block or fetchable from our own server, or a voice block.
   External http(s) sources are out of scope — fetching arbitrary URLs is a
   different trust boundary from reading our own media store. *)

type playable = {
  name : string;
  kind : [ `Audio | `Midi ];
  source : [ `Data of string | `Server_path of string | `Local_path of string ];
}

let audio_extensions = [ "mp3"; "wav"; "ogg"; "flac"; "m4a"; "aac" ]
let midi_extensions = [ "mid"; "midi" ]

let extension_of name =
  match String.rindex_opt name '.' with
  | Some dot when dot > 0 && dot < String.length name - 1 ->
      Some (String.lowercase_ascii (String.sub name (dot + 1) (String.length name - dot - 1)))
  | Some _ | None -> None

let resolve_src = function
  | Some src when String.starts_with ~prefix:"/api/" src -> Some (`Server_path src)
  | Some src when String.starts_with ~prefix:"/" src -> Some (`Local_path src)
  | Some src when String.starts_with ~prefix:"data:" src -> Some (`Data src)
  | Some _ | None -> None

let attach_bytes (attachment : Blocks.attach_block) =
  match attachment.data with
  | Some data -> Some (`Data data)
  | None -> resolve_src attachment.src

let playable_attach (attachment : Blocks.attach_block) =
  match extension_of attachment.name with
  | Some extension when List.mem extension audio_extensions ->
      Option.map
        (fun source -> { name = attachment.name; kind = `Audio; source })
        (attach_bytes attachment)
  | Some extension when List.mem extension midi_extensions ->
      Option.map
        (fun source -> { name = attachment.name; kind = `Midi; source })
        (attach_bytes attachment)
  | Some _ | None -> None

let playable_voice (voice : Blocks.voice_block) =
  let name =
    match voice.src with
    | Some src -> Filename.basename src
    | None -> "voice message"
  in
  Option.map
    (fun source -> { name; kind = `Audio; source })
    (resolve_src voice.src)

let newest_playable media =
  List.rev media |> List.find_map (function
    | Attach attachment -> playable_attach attachment
    | Voice voice -> playable_voice voice
    | Image _ | Svg _ | Mermaid _ -> None)
;;
