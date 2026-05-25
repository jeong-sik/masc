let collapse_whitespace text =
  text
  |> String.split_on_char '\n'
  |> List.concat_map (String.split_on_char '\t')
  |> List.concat_map (String.split_on_char '\r')
  |> List.concat_map (String.split_on_char ' ')
  |> List.filter (fun part -> part <> "")
  |> String.concat " "


let take_chars max_len text =
  if max_len <= 0 then ""
  else if String.length text <= max_len then text
  else String.sub text 0 max_len

let normalize_location ?(max_len = 120) text =
  text
  |> collapse_whitespace
  |> take_chars max_len

let normalize_content ?(max_len = 300) text =
  text
  |> collapse_whitespace
  |> take_chars max_len

let grep_like_line ~source ~location ~content =
  let source =
    String_util.trim_to_option source |> Option.value ~default:"search"
  in
  let location =
    String_util.trim_to_option location |> Option.value ~default:"result"
    |> normalize_location
  in
  let content =
    String_util.trim_to_option content |> Option.value ~default:"(no content)"
    |> normalize_content
  in
  Printf.sprintf "%s/%s: %s" source location content


