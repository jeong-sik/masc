(** Backend mirror of dashboard/src/lib/chat-blocks.ts:parseTextToChatBlocks.

    The output JSON is intentionally identical to the dashboard's block
    shape so the dashboard can prefer server-provided blocks and skip its
    local parser. *)

type image_block = {
  src : string;
  cap : string option;
}

type link_block = {
  url : string;
  title : string;
  meta : string;
}

type text_block = { html : string }

type chat_block =
  | Text of text_block
  | Image of image_block
  | Link of link_block

let escape_html raw =
  raw
  |> String.split_on_char '&'
  |> String.concat "&amp;"
  |> String.split_on_char '<'
  |> String.concat "&lt;"
  |> String.split_on_char '>'
  |> String.concat "&gt;"
  |> String.split_on_char '"'
  |> String.concat "&quot;"
  |> String.split_on_char '\''
  |> String.concat "&#39;"
;;

let image_extensions = [ "png"; "jpg"; "jpeg"; "gif"; "webp"; "svg" ];;

let path_extension pathname =
  match String.rindex_opt pathname '.' with
  | None -> ""
  | Some i ->
    let ext = String.sub pathname (i + 1) (String.length pathname - i - 1) in
    String.lowercase_ascii ext
;;

let is_image_url url =
  try
    let uri = Uri.of_string url in
    let path = Uri.path uri in
    List.mem (path_extension path) image_extensions
  with
  | _ -> false
;;

let hostname_title url =
  try
    let uri = Uri.of_string url in
    let host = Option.value (Uri.host uri) ~default:url in
    let host =
      if String.length host > 4 && String.sub host 0 4 = "www."
      then String.sub host 4 (String.length host - 4)
      else host
    in
    if host = "" then url else host
  with
  | _ -> url
;;

let standalone_url_re =
  Re.Pcre.re ~flags:[ `CASELESS ] "^https?://\\S+$" |> Re.compile |> Re.execp
;;

let is_http_url url =
  try
    let scheme = Uri.scheme (Uri.of_string url) in
    match scheme with
    | Some "http" | Some "https" -> true
    | _ -> false
  with
  | _ -> false
;;

let line_to_block line : chat_block option =
  let trimmed = String.trim line in
  if trimmed = ""
  then None
  else if standalone_url_re trimmed && is_http_url trimmed
  then (
    if is_image_url trimmed
    then Some (Image { src = trimmed; cap = None })
    else
      Some
        (Link
           { url = trimmed
           ; title = hostname_title trimmed
           ; meta = hostname_title trimmed
           }))
  else Some (Text { html = escape_html line })
;;

let push_text_fragment acc fragment =
  fragment
  |> String.split_on_char '\n'
  |> List.fold_left
       (fun acc line ->
          match line_to_block line with
          | None -> acc
          | Some block -> block :: acc)
       acc
;;

let md_image_re = Re.Pcre.re "!\\[([^\\]]*)\\]\\(([^)]+)\\)" |> Re.compile

let parse_text_to_blocks text : chat_block list =
  let rec scan acc last_index =
    match Re.exec_opt ~pos:last_index md_image_re text with
    | None -> push_text_fragment acc (String.sub text last_index (String.length text - last_index))
    | Some group ->
      let start = Re.Group.start group 0 in
      let stop = Re.Group.stop group 0 in
      let before = String.sub text last_index (start - last_index) in
      let alt = Re.Group.get group 1 in
      let url = Re.Group.get group 2 in
      let acc = push_text_fragment acc before in
      if is_http_url url then
        let cap = if String.trim alt = "" then None else Some alt in
        let acc = Image { src = url; cap } :: acc in
        scan acc stop
      else
        let fallback = String.sub text start (stop - start) in
        scan (push_text_fragment acc fallback) stop
  in
  List.rev (scan [] 0)
;;

let block_to_yojson = function
  | Text { html } ->
    `Assoc [ ("t", `String "p"); ("html", `String html) ]
  | Image { src; cap } ->
    let fields = [ ("t", `String "image"); ("src", `String src) ] in
    let fields =
      match cap with
      | None -> fields
      | Some c -> fields @ [ ("cap", `String c) ]
    in
    `Assoc fields
  | Link { url; title; meta } ->
    `Assoc
      [ ("t", `String "link")
      ; ("url", `String url)
      ; ("title", `String title)
      ; ("meta", `String meta)
      ]
;;

let blocks_to_yojson blocks = `List (List.map block_to_yojson blocks)

let block_of_yojson json : chat_block option =
  match json with
  | `Assoc fields ->
    let get_string key =
      match List.assoc_opt key fields with
      | Some (`String s) -> Some s
      | _ -> None
    in
    (match get_string "t" with
     | Some "p" ->
       Option.map (fun html -> Text { html }) (get_string "html")
     | Some "image" ->
       Option.bind (get_string "src") (fun src ->
         let cap = get_string "cap" in
         Some (Image { src; cap }))
     | Some "link" ->
       Option.bind (get_string "url") (fun url ->
         Option.bind (get_string "title") (fun title ->
           let meta = Option.value (get_string "meta") ~default:title in
           Some (Link { url; title; meta })))
     | _ -> None)
  | _ -> None
;;

let blocks_of_yojson = function
  | `List items ->
    let blocks = List.filter_map block_of_yojson items in
    if blocks = [] then None else Some blocks
  | _ -> None
