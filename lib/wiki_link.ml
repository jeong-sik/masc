type target =
  | Page of string
  | Own_file of string
  | External of string
  | Invalid_name of string
  | Unsupported of string

type link =
  { text : string
  ; target : target
  ; raw : string
  ; line : int
  }

let classify raw =
  if String.starts_with ~prefix:"http://" raw || String.starts_with ~prefix:"https://" raw
  then External raw
  else if String.contains raw '#'
  then Unsupported "anchor"
  else if String.contains raw ':'
  then Unsupported "scheme"
  else if String.contains raw '/' || String.contains raw '\\'
  then Unsupported "path"
  else if Filename.check_suffix raw ".md"
  then (
    let stem = Filename.chop_suffix raw ".md" in
    if List.exists (String.equal stem) Wiki_page_name.reserved_page_names
    then Own_file raw
    else (
      match Wiki_page_name.validate_page_name stem with
      | Ok name -> Page name
      | Error
          ( Wiki_page_name.Empty_page_name
          | Wiki_page_name.Bad_page_characters
          | Wiki_page_name.Dash_at_edge
          | Wiki_page_name.Reserved_page_name ) -> Invalid_name raw))
  else Unsupported "not_markdown"
;;

(* The index of the [\]] that closes the [\[] at [from], counting nesting. *)
let closing_bracket text from =
  let length = String.length text in
  let rec go index depth =
    if index >= length
    then None
    else (
      match text.[index] with
      | '[' -> go (index + 1) (depth + 1)
      | ']' -> if depth = 1 then Some index else go (index + 1) (depth - 1)
      | _ -> go (index + 1) depth)
  in
  go from 0
;;

(* The target part of [(…)]: an angle-bracketed target, or the text up to
   the first whitespace, which drops a trailing title. *)
let target_of_inner inner =
  let trimmed = String.trim inner in
  if String.length trimmed >= 2 && Char.equal trimmed.[0] '<'
  then (
    match String.index_opt trimmed '>' with
    | Some close -> String.sub trimmed 1 (close - 1)
    | None -> trimmed)
  else (
    match String.index_opt trimmed ' ' with
    | Some space -> String.sub trimmed 0 space
    | None -> trimmed)
;;

let scan_line ~line_no text found =
  let length = String.length text in
  let rec go index found =
    if index >= length
    then found
    else if
      Char.equal text.[index] '!'
      && index + 2 < length
      && Char.equal text.[index + 1] '['
      && Char.equal text.[index + 2] '['
    then (
      (* An Obsidian embed is handled by [extract_embeds]; skip its whole token. *)
      match String_util.find_substring ~pos:(index + 3) text "]]" with
      | Some stop -> go (stop + 2) found
      | None -> go (index + 3) found)
    else if
      Char.equal text.[index] '!'
      && index + 1 < length
      && Char.equal text.[index + 1] '['
    then (
      (* An image is not a link: skip its target too. *)
      match closing_bracket text (index + 1) with
      | Some close when close + 1 < length && Char.equal text.[close + 1] '(' ->
        (match String.index_from_opt text (close + 2) ')' with
         | Some stop -> go (stop + 1) found
         | None -> go (index + 2) found)
      | Some _ | None -> go (index + 2) found)
    else if
      Char.equal text.[index] '['
      && index + 1 < length
      && Char.equal text.[index + 1] '['
    then (
      match String_util.find_substring ~pos:(index + 2) text "]]" with
      | Some stop ->
        let name = String.sub text (index + 2) (stop - index - 2) in
        go
          (stop + 2)
          ({ text = name
           ; target = Unsupported "wikilink"
           ; raw = "[[" ^ name ^ "]]"
           ; line = line_no
           }
           :: found)
      | None -> go (index + 2) found)
    else if Char.equal text.[index] '['
    then (
      match closing_bracket text index with
      | Some close when close + 1 < length && Char.equal text.[close + 1] '(' ->
        (match String.index_from_opt text (close + 2) ')' with
         | Some stop ->
           let raw = target_of_inner (String.sub text (close + 2) (stop - close - 2)) in
           let label = String.sub text (index + 1) (close - index - 1) in
           go
             (stop + 1)
             ({ text = label; target = classify raw; raw; line = line_no } :: found)
         | None -> go (index + 1) found)
      | Some _ | None -> go (index + 1) found)
    else go (index + 1) found
  in
  go 0 found
;;

let extract body = Media_ref_scan.fold_unquoted_lines scan_line body

type embed_syntax =
  | Obsidian_embed
  | Markdown_media

type embed_kind =
  | Embed_media
  | Embed_wiki
  | Embed_artifact

type embed_target =
  | Media_embed of string
  | Wiki_embed of string
  | Artifact_embed of string
  | Invalid_embed of
      { kind : embed_kind
      ; raw : string
      }
  | Unsupported_embed of
      { scheme : string
      ; raw : string
      }

type embed =
  { target : embed_target
  ; label : string option
  ; syntax : embed_syntax
  ; raw : string
  ; line : int
  }

let embed_kind_to_string = function
  | Embed_media -> "media"
  | Embed_wiki -> "wiki"
  | Embed_artifact -> "artifact"
;;

let embed_syntax_to_string = function
  | Obsidian_embed -> "obsidian"
  | Markdown_media -> "markdown_media"
;;

let is_valid_media_token = Media_ref_scan.is_valid_media_token

let classify_wiki_embed raw =
  match Wiki_page_name.validate_page_name raw with
  | Ok slug -> Wiki_embed slug
  | Error
      ( Wiki_page_name.Empty_page_name
      | Wiki_page_name.Bad_page_characters
      | Wiki_page_name.Dash_at_edge
      | Wiki_page_name.Reserved_page_name ) ->
    Invalid_embed { kind = Embed_wiki; raw }
;;

let classify_obsidian_embed raw_target =
  let target = String.trim raw_target in
  match Media_ref_scan.split_obsidian_scheme_payload target with
  | `Bare bare -> classify_wiki_embed bare
  | `Qualified (scheme, payload) ->
    (match scheme with
     | "media" ->
       (match Media_ref_scan.parse_media_token payload with
        | Some sha256 -> Media_embed sha256
        | None -> Invalid_embed { kind = Embed_media; raw = payload })
     | "wiki" -> classify_wiki_embed payload
     | "artifact" ->
       if Published_artifact.valid_id payload
       then Artifact_embed payload
       else Invalid_embed { kind = Embed_artifact; raw = payload }
     | other -> Unsupported_embed { scheme = other; raw = payload })
;;

let split_obsidian_inner = Media_ref_scan.split_obsidian_inner

let scan_embeds_line ~line_no text found =
  let length = String.length text in
  let attachment_prefix = Attachment_store.url_prefix in
  let attachment_prefix_len = String.length attachment_prefix in
  let media_prefix = Masc_network_defaults.media_path_prefix in
  let media_prefix_len = String.length media_prefix in
  let rec go index found =
    if index >= length
    then found
    else if
      Char.equal text.[index] '!'
      && index + 2 < length
      && Char.equal text.[index + 1] '['
      && Char.equal text.[index + 2] '['
    then (
      match String_util.find_substring ~pos:(index + 3) text "]]" with
      | Some stop ->
        let inner = String.sub text (index + 3) (stop - index - 3) in
        let raw_target, label = split_obsidian_inner inner in
        let embed =
          { target = classify_obsidian_embed raw_target
          ; label
          ; syntax = Obsidian_embed
          ; raw = "![[" ^ inner ^ "]]"
          ; line = line_no
          }
        in
        go (stop + 2) (embed :: found)
      | None -> go (index + 3) found)
    else if
      Char.equal text.[index] '!'
      && index + 1 < length
      && Char.equal text.[index + 1] '['
    then (
      match closing_bracket text (index + 1) with
      | Some close when close + 1 < length && Char.equal text.[close + 1] '(' ->
        (match String.index_from_opt text (close + 2) ')' with
         | Some stop ->
           let raw_url =
             target_of_inner (String.sub text (close + 2) (stop - close - 2))
           in
           let matched_target =
             if String.starts_with ~prefix:attachment_prefix raw_url
             then (
               let payload =
                 String.sub
                   raw_url
                   attachment_prefix_len
                   (String.length raw_url - attachment_prefix_len)
                 |> Media_ref_scan.strip_url_query
               in
               Some
                 (match Media_ref_scan.parse_attachment_id_token payload with
                  | Some sha256 -> Media_embed sha256
                  | None -> Invalid_embed { kind = Embed_media; raw = payload }))
             else if String.starts_with ~prefix:media_prefix raw_url
             then (
               let payload =
                 String.sub
                   raw_url
                   media_prefix_len
                   (String.length raw_url - media_prefix_len)
                 |> Media_ref_scan.strip_url_query
               in
               Some
                 (match Media_ref_scan.parse_media_token payload with
                  | Some sha256 -> Media_embed sha256
                  | None -> Invalid_embed { kind = Embed_media; raw = payload }))
             else None
           in
           (match matched_target with
            | Some target ->
              let alt =
                String.sub text (index + 2) (close - index - 2) |> String.trim
              in
              let label = if String.equal alt "" then None else Some alt in
              let embed =
                { target
                ; label
                ; syntax = Markdown_media
                ; raw = raw_url
                ; line = line_no
                }
              in
              go (stop + 1) (embed :: found)
            | None -> go (stop + 1) found)
         | None -> go (index + 2) found)
      | Some _ | None -> go (index + 2) found)
    else go (index + 1) found
  in
  go 0 found
;;

let extract_embeds body = Media_ref_scan.fold_unquoted_lines scan_embeds_line body

let media_refs_of_embeds embeds =
  List.filter_map
    (fun (embed : embed) ->
       match embed.target with
       | Media_embed sha256 -> Some sha256
       | Wiki_embed _
       | Artifact_embed _
       | Invalid_embed _
       | Unsupported_embed _ -> None)
    embeds
  |> List.sort_uniq String.compare
;;
