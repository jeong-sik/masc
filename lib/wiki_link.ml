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

(* A code span is a run of backticks, its content, and a run of the same
   length. Its bytes become spaces so a link shape inside it is not seen.
   An unmatched run is left alone. *)
let blank_code_spans line =
  let length = String.length line in
  let bytes = Bytes.of_string line in
  let run_end from =
    let stop = ref from in
    while !stop < length && Char.equal line.[!stop] '`' do
      incr stop
    done;
    !stop
  in
  let rec closing ~run from =
    if from >= length
    then None
    else if Char.equal line.[from] '`'
    then (
      let stop = run_end from in
      if stop - from = run then Some stop else closing ~run stop)
    else closing ~run (from + 1)
  in
  let rec scan index =
    if index < length
    then
      if Char.equal line.[index] '`'
      then (
        let stop = run_end index in
        match closing ~run:(stop - index) stop with
        | Some close ->
          Bytes.fill bytes index (close - index) ' ';
          scan close
        | None -> scan stop)
      else scan (index + 1)
  in
  scan 0;
  Bytes.to_string bytes
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

(* A fence opens with three or more backticks or tildes after at most three
   spaces, and closes with at least as many of the same character and
   nothing else on the line. *)
let fence_of_line line =
  let length = String.length line in
  let rec indent index = if index < length && index < 3 && Char.equal line.[index] ' ' then indent (index + 1) else index in
  let start = indent 0 in
  if start >= length
  then None
  else (
    let mark = line.[start] in
    if not (Char.equal mark '`' || Char.equal mark '~')
    then None
    else (
      let stop = ref start in
      while !stop < length && Char.equal line.[!stop] mark do
        incr stop
      done;
      let count = !stop - start in
      if count >= 3
      then Some (mark, count, String.trim (String.sub line !stop (length - !stop)))
      else None))
;;

let fold_unquoted_lines scan body =
  let lines = String.split_on_char '\n' body in
  let strip_cr line =
    let length = String.length line in
    if length > 0 && Char.equal line.[length - 1] '\r'
    then String.sub line 0 (length - 1)
    else line
  in
  let _, _, found =
    List.fold_left
      (fun (fence, line_no, found) raw_line ->
         let line = strip_cr raw_line in
         match fence, fence_of_line line with
         | None, Some (mark, count, _info) -> Some (mark, count), line_no + 1, found
         | None, None ->
           None, line_no + 1, scan ~line_no (blank_code_spans line) found
         | Some (mark, count), Some (closing_mark, closing_count, rest)
           when Char.equal mark closing_mark
                && closing_count >= count
                && String.equal rest "" -> None, line_no + 1, found
         | Some open_fence, (Some _ | None) -> Some open_fence, line_no + 1, found)
      (None, 1, [])
      lines
  in
  List.rev found
;;

let extract body = fold_unquoted_lines scan_line body

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

let is_valid_media_token token = Result.is_ok (Tool_output.validate_sha256 token)

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
  match String.index_opt raw_target ':' with
  | None -> classify_wiki_embed raw_target
  | Some colon ->
    let scheme = String.sub raw_target 0 colon in
    let payload =
      String.sub raw_target (colon + 1) (String.length raw_target - colon - 1)
    in
    (match scheme with
     | "media" ->
       if is_valid_media_token payload
       then Media_embed payload
       else Invalid_embed { kind = Embed_media; raw = payload }
     | "wiki" -> classify_wiki_embed payload
     | "artifact" ->
       if Published_artifact.valid_id payload
       then Artifact_embed payload
       else Invalid_embed { kind = Embed_artifact; raw = payload }
     | other -> Unsupported_embed { scheme = other; raw = payload })
;;

let split_obsidian_inner inner =
  match String.index_opt inner '|' with
  | None -> inner, None
  | Some bar ->
    let raw_target = String.sub inner 0 bar in
    let raw_label =
      String.sub inner (bar + 1) (String.length inner - bar - 1) |> String.trim
    in
    let label = if String.equal raw_label "" then None else Some raw_label in
    raw_target, label
;;

let scan_embeds_line ~line_no text found =
  let length = String.length text in
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
           if String.starts_with ~prefix:media_prefix raw_url
           then (
             let payload =
               String.sub raw_url media_prefix_len (String.length raw_url - media_prefix_len)
             in
             let target =
               if is_valid_media_token payload
               then Media_embed payload
               else Invalid_embed { kind = Embed_media; raw = payload }
             in
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
             go (stop + 1) (embed :: found))
           else go (stop + 1) found
         | None -> go (index + 2) found)
      | Some _ | None -> go (index + 2) found)
    else go (index + 1) found
  in
  go 0 found
;;

let extract_embeds body = fold_unquoted_lines scan_embeds_line body

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
