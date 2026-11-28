let obsidian_media_scheme = "media"
let is_valid_media_token token = Attachment_store.is_valid_sha256 token

let parse_media_token raw =
  match Attachment_store.parse_id_or_sha256 raw with
  | Ok sha256 -> Some sha256
  | Error _ -> None
;;

let parse_attachment_id_token raw =
  match Attachment_store.parse_id raw with
  | Ok sha256 -> Some sha256
  | Error _ -> None
;;

let strip_url_query url =
  match String.index_opt url '?' with
  | Some idx -> String.sub url 0 idx
  | None -> url
;;

let backtick_run_end text from =
  let length = String.length text in
  let stop = ref from in
  while !stop < length && Char.equal text.[!stop] '`' do
    incr stop
  done;
  !stop
;;

(* A code span is a run of backticks, its content, and a run of the same
   length. [code_span_close text index] is [Some close] when the run at
   [index] opens one, [close] being just past the closing run. An unmatched
   run is [None] and stays plain text. *)
let code_span_close text index =
  let length = String.length text in
  let open_stop = backtick_run_end text index in
  let run = open_stop - index in
  let rec closing from =
    if from >= length
    then None
    else if Char.equal text.[from] '`'
    then (
      let stop = backtick_run_end text from in
      if stop - from = run then Some stop else closing stop)
    else closing (from + 1)
  in
  closing open_stop
;;

(* A code span's bytes become spaces so a link or embed inside it is not
   seen. *)
let blank_code_spans line =
  let length = String.length line in
  let bytes = Bytes.of_string line in
  let rec scan index =
    if index < length
    then
      if Char.equal line.[index] '`'
      then (
        match code_span_close line index with
        | Some close ->
          Bytes.fill bytes index (close - index) ' ';
          scan close
        | None -> scan (backtick_run_end line index))
      else scan (index + 1)
  in
  scan 0;
  Bytes.to_string bytes
;;

(* A fence opens with three or more backticks or tildes after at most three
   spaces, and closes with at least as many of the same character and
   nothing else on the line. *)
let fence_of_line line =
  let length = String.length line in
  let rec indent index =
    if index < length && index < 3 && Char.equal line.[index] ' '
    then indent (index + 1)
    else index
  in
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

let split_obsidian_inner inner =
  match String.index_opt inner '|' with
  | None -> String.trim inner, None
  | Some bar ->
    let raw_target = String.sub inner 0 bar |> String.trim in
    let raw_label =
      String.sub inner (bar + 1) (String.length inner - bar - 1) |> String.trim
    in
    let label = if String.equal raw_label "" then None else Some raw_label in
    raw_target, label
;;

let split_obsidian_scheme_payload target =
  match String.index_opt target ':' with
  | None -> `Bare target
  | Some colon ->
    let scheme = String.sub target 0 colon |> String.trim in
    let payload =
      String.sub target (colon + 1) (String.length target - colon - 1) |> String.trim
    in
    `Qualified (scheme, payload)
;;

let is_url_start_boundary = function
  | '(' | '<' | '"' | '\'' | '=' | ' ' | '\t' | '\n' | '\r' -> true
  | _ -> false
;;

let is_url_end_boundary = function
  | '?' | ')' | '>' | '"' | '\'' | ']' | '|' | ' ' | '\t' | '\n' | '\r' | ',' | ';' -> true
  | _ -> false
;;

let scan_prefixed_url_refs ~prefix ~parse_token ~token_lengths text acc =
  let prefix_len = String.length prefix in
  let len = String.length text in
  let rec try_lengths token_start = function
    | [] -> None
    | tlen :: rest ->
      let token_end = token_start + tlen in
      if token_end <= len && (token_end = len || is_url_end_boundary text.[token_end])
      then (
        match parse_token (String.sub text token_start tlen) with
        | Some sha256 -> Some sha256
        | None -> try_lengths token_start rest)
      else try_lengths token_start rest
  in
  let rec scan pos acc =
    if pos >= len
    then acc
    else (
      match String_util.find_substring ~pos text prefix with
      | None -> acc
      | Some idx ->
        let start_ok = idx = 0 || is_url_start_boundary text.[idx - 1] in
        let token_start = idx + prefix_len in
        let acc =
          if start_ok
          then (
            match try_lengths token_start token_lengths with
            | Some sha256 -> sha256 :: acc
            | None -> acc)
          else acc
        in
        scan (idx + prefix_len) acc)
  in
  scan 0 acc
;;

let extract_url_media_refs text acc =
  let att_id_len = String.length Attachment_store.id_prefix + 64 in
  let acc =
    scan_prefixed_url_refs
      ~prefix:Attachment_store.url_prefix
      ~parse_token:parse_attachment_id_token
      ~token_lengths:[ att_id_len ]
      text
      acc
  in
  scan_prefixed_url_refs
    ~prefix:Masc_network_defaults.media_path_prefix
    ~parse_token:parse_media_token
    ~token_lengths:[ att_id_len; 64 ]
    text
    acc
;;

let extract_obsidian_media_refs line acc =
  let open_tok = "![[" in
  let open_len = String.length open_tok in
  let len = String.length line in
  let rec scan pos acc =
    if pos >= len
    then acc
    else (
      match String_util.find_substring ~pos line open_tok with
      | None -> acc
      | Some idx ->
        let inner_start = idx + open_len in
        (match String_util.find_substring ~pos:inner_start line "]]" with
         | None -> acc
         | Some stop ->
           let inner = String.sub line inner_start (stop - inner_start) in
           let target, _label = split_obsidian_inner inner in
           let acc =
             match split_obsidian_scheme_payload target with
             | `Qualified (scheme, payload) when String.equal scheme obsidian_media_scheme ->
               (match parse_media_token payload with
                | Some sha256 -> sha256 :: acc
                | None -> acc)
             | `Bare _ | `Qualified _ -> acc
           in
           scan (stop + 2) acc))
  in
  scan 0 acc
;;

let ascii_lower_equal_at ~lower_needle text pos =
  let nlen = String.length lower_needle in
  if pos + nlen > String.length text
  then false
  else (
    let rec loop i =
      if i = nlen
      then true
      else if Char.equal (Char.lowercase_ascii text.[pos + i]) lower_needle.[i]
      then loop (i + 1)
      else false
    in
    loop 0)
;;

let is_html_space = function
  | ' ' | '\t' | '\n' | '\r' | '\012' -> true
  | _ -> false
;;

let is_tag_name_boundary c = is_html_space c || Char.equal c '>' || Char.equal c '/'

let find_closing_tag ~lower_close text from =
  let len = String.length text in
  let clen = String.length lower_close in
  let rec scan pos =
    if pos >= len
    then len
    else if
      Char.equal text.[pos] '<'
      && ascii_lower_equal_at ~lower_needle:lower_close text pos
    then (
      let after = ref (pos + clen) in
      while !after < len && is_html_space text.[!after] do
        incr after
      done;
      if !after < len && Char.equal text.[!after] '>'
      then !after + 1
      else scan (pos + 1))
    else scan (pos + 1)
  in
  scan from
;;

let blank_html_comments_and_scripts html =
  let len = String.length html in
  let bytes = Bytes.of_string html in
  let comment_open = "<!--" in
  let script_open = "<script" in
  let script_len = String.length script_open in
  let rec scan pos =
    if pos < len
    then
      if Char.equal html.[pos] '<'
      then
        if ascii_lower_equal_at ~lower_needle:comment_open html pos
        then (
          let after_open = pos + 4 in
          let close_end =
            match String_util.find_substring ~pos:after_open html "-->" with
            | Some idx -> idx + 3
            | None -> len
          in
          Bytes.fill bytes pos (close_end - pos) ' ';
          scan close_end)
        else if
          ascii_lower_equal_at ~lower_needle:script_open html pos
          && pos + script_len < len
          && is_tag_name_boundary html.[pos + script_len]
        then (
          match String.index_from_opt html (pos + script_len) '>' with
          | None -> Bytes.fill bytes pos (len - pos) ' '
          | Some open_end ->
            let block_end = find_closing_tag ~lower_close:"</script" html (open_end + 1) in
            Bytes.fill bytes pos (block_end - pos) ' ';
            scan block_end)
        else scan (pos + 1)
      else scan (pos + 1)
  in
  scan 0;
  Bytes.to_string bytes
;;

let extract_markdown_media_refs content =
  fold_unquoted_lines
    (fun ~line_no:_ line acc ->
       let acc = extract_url_media_refs line acc in
       extract_obsidian_media_refs line acc)
    content
  |> List.sort_uniq String.compare
;;

let extract_html_media_refs content =
  extract_url_media_refs (blank_html_comments_and_scripts content) []
  |> List.sort_uniq String.compare
;;

(* Attachment GC reads raw store bytes, while a reader resolves the decoded
   Markdown. Inside a JSON string a line break, quote or tab is escaped, so the
   reader's grammar (a [![[]/[]]] pair on one line, a URL end boundary) can fail
   on the raw bytes. This scan keeps only the parts no JSON escape touches: the
   route prefix or the scheme and colon, then the digest. *)
let is_hex_digit = function
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
  | _ -> false
;;

let digest_at text pos =
  let stop = pos + 64 in
  let length = String.length text in
  if stop <= length && (stop = length || not (is_hex_digit text.[stop]))
  then (
    let candidate = String.sub text pos 64 in
    if is_valid_media_token candidate then Some candidate else None)
  else None
;;

let is_embed_space = function
  | ' ' | '\t' | '\r' | '\012' -> true
  | _ -> false
;;

(* The letter after a backslash when JSON escapes an [is_embed_space] byte. *)
let is_escaped_embed_space = function
  | 't' | 'r' | 'f' -> true
  | _ -> false
;;

(* The reader blanks code spans to spaces before it trims the scheme and the
   digest, so [media:`x`<64hex>] resolves there; a whole span is skipped here
   too. *)
let rec skip_embed_space text pos =
  let length = String.length text in
  if pos < length && is_embed_space text.[pos]
  then skip_embed_space text (pos + 1)
  else if pos + 1 < length
          && Char.equal text.[pos] '\\'
          && is_escaped_embed_space text.[pos + 1]
  then skip_embed_space text (pos + 2)
  else if pos < length && Char.equal text.[pos] '`'
  then (
    match code_span_close text pos with
    | Some close -> skip_embed_space text close
    | None -> pos)
  else pos
;;

let fold_after needle text f acc =
  let needle_length = String.length needle in
  let rec go pos acc =
    match String_util.find_substring ~pos text needle with
    | None -> acc
    | Some index -> go (index + needle_length) (f (index + needle_length) acc)
  in
  go 0 acc
;;

let extract_bare_media_digests text =
  let add found acc =
    match found with
    | Some sha256 -> sha256 :: acc
    | None -> acc
  in
  let url_digests =
    fold_after
      Masc_network_defaults.media_path_prefix
      text
      (fun after acc -> add (digest_at text after) acc)
      []
  in
  fold_after
    obsidian_media_scheme
    text
    (fun after acc ->
       let colon = skip_embed_space text after in
       if colon < String.length text && Char.equal text.[colon] ':'
       then add (digest_at text (skip_embed_space text (colon + 1))) acc
       else acc)
    url_digests
  |> List.sort_uniq String.compare
;;
