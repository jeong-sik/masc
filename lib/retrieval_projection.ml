let collapse_whitespace text =
  text
  |> String.split_on_char '\n'
  |> List.concat_map (String.split_on_char '\t')
  |> List.concat_map (String.split_on_char '\r')
  |> List.concat_map (String.split_on_char ' ')
  |> List.filter (fun part -> part <> "")
  |> String.concat " "
;;

let trim_to_option text =
  let trimmed = String.trim text in
  if trimmed = "" then None else Some trimmed
;;

let take_chars max_len text =
  if max_len <= 0
  then ""
  else if String.length text <= max_len
  then text
  else String.sub text 0 max_len
;;

let normalize_location ?(max_len = 120) text =
  text |> collapse_whitespace |> take_chars max_len
;;

let normalize_content ?(max_len = 300) text =
  text |> collapse_whitespace |> take_chars max_len
;;

let grep_like_line ~source ~location ~content =
  let source = trim_to_option source |> Option.value ~default:"search" in
  let location =
    trim_to_option location |> Option.value ~default:"result" |> normalize_location
  in
  let content =
    trim_to_option content |> Option.value ~default:"(no content)" |> normalize_content
  in
  Printf.sprintf "%s/%s: %s" source location content
;;

let assoc_string fields keys =
  let rec loop = function
    | [] -> None
    | key :: rest ->
      (match List.assoc_opt key fields with
       | Some (`String value) -> trim_to_option value
       | Some (`Int value) -> Some (string_of_int value)
       | Some (`Float value) -> Some (string_of_float value)
       | Some (`Bool value) -> Some (string_of_bool value)
       | _ -> loop rest)
  in
  loop keys
;;

let assoc_member fields keys =
  let rec loop = function
    | [] -> None
    | key :: rest ->
      (match List.assoc_opt key fields with
       | Some value -> Some value
       | None -> loop rest)
  in
  loop keys
;;

let rec take_list n xs =
  match n, xs with
  | count, _ when count <= 0 -> []
  | _, [] -> []
  | count, x :: rest -> x :: take_list (count - 1) rest
;;

let split_chunks input =
  let separator = "\n---\n" in
  let sep_len = String.length separator in
  let input_len = String.length input in
  let rec find_from start =
    if start > input_len - sep_len
    then None
    else if String.sub input start sep_len = separator
    then Some start
    else find_from (start + 1)
  in
  let rec loop start acc =
    match find_from start with
    | Some idx ->
      let chunk = String.sub input start (idx - start) in
      loop (idx + sep_len) (chunk :: acc)
    | None ->
      let chunk = String.sub input start (input_len - start) in
      List.rev (chunk :: acc)
  in
  if input = "" then [] else loop 0 []
;;

let parse_labeled_chunk chunk =
  let trimmed = String.trim chunk in
  if String.length trimmed >= 4 && trimmed.[0] = '['
  then (
    match String.index_opt trimmed ']' with
    | Some close_idx
      when close_idx + 2 < String.length trimmed && trimmed.[close_idx + 1] = ':' ->
      let label = String.sub trimmed 1 (close_idx - 1) in
      let payload =
        String.sub trimmed (close_idx + 2) (String.length trimmed - close_idx - 2)
        |> String.trim
      in
      trim_to_option label, payload
    | _ -> None, trimmed)
  else None, trimmed
;;

let render_result_object ?prefix fields =
  let source =
    assoc_string fields [ "source"; "engine"; "provider"; "site"; "kind" ]
    |> Option.value ~default:(Option.value prefix ~default:"search")
  in
  let location =
    assoc_string fields [ "file"; "path"; "url"; "title"; "name"; "id" ]
    |> Option.value ~default:"result"
  in
  let content =
    assoc_string
      fields
      [ "snippet"
      ; "content"
      ; "text"
      ; "summary"
      ; "body"
      ; "description"
      ; "excerpt"
      ; "title"
      ]
    |> Option.value ~default:"(no content)"
  in
  grep_like_line ~source ~location ~content
;;

let result_like fields =
  assoc_string
    fields
    [ "snippet"
    ; "content"
    ; "text"
    ; "summary"
    ; "body"
    ; "description"
    ; "excerpt"
    ; "title"
    ; "url"
    ; "file"
    ; "path"
    ]
  <> None
;;

let rec lines_of_json ?prefix (json : Yojson.Safe.t) =
  match json with
  | `List items -> List.concat_map (lines_of_json ?prefix) items
  | `Assoc fields ->
    let obj_json : Yojson.Safe.t = `Assoc fields in
    (match
       assoc_member
         fields
         [ "results"
         ; "items"
         ; "data"
         ; "documents"
         ; "hits"
         ; "entries"
         ; "search_results"
         ; "value"
         ]
     with
     | Some nested ->
       let nested_lines = lines_of_json ?prefix nested in
       if nested_lines <> []
       then nested_lines
       else if result_like fields
       then [ render_result_object ?prefix fields ]
       else
         [ grep_like_line
             ~source:(Option.value prefix ~default:"search")
             ~location:"result"
             ~content:(Yojson.Safe.to_string obj_json)
         ]
     | None ->
       if result_like fields
       then [ render_result_object ?prefix fields ]
       else
         [ grep_like_line
             ~source:(Option.value prefix ~default:"search")
             ~location:"result"
             ~content:(Yojson.Safe.to_string obj_json)
         ])
  | `String text ->
    [ grep_like_line
        ~source:(Option.value prefix ~default:"search")
        ~location:"result"
        ~content:text
    ]
  | `Int value ->
    [ grep_like_line
        ~source:(Option.value prefix ~default:"search")
        ~location:"result"
        ~content:(string_of_int value)
    ]
  | `Float value ->
    [ grep_like_line
        ~source:(Option.value prefix ~default:"search")
        ~location:"result"
        ~content:(string_of_float value)
    ]
  | `Intlit value ->
    [ grep_like_line
        ~source:(Option.value prefix ~default:"search")
        ~location:"result"
        ~content:value
    ]
  | `Bool value ->
    [ grep_like_line
        ~source:(Option.value prefix ~default:"search")
        ~location:"result"
        ~content:(string_of_bool value)
    ]
  | `Null -> []
;;

let lines_of_search_output ?(max_lines = 20) input =
  let render_chunk chunk =
    let prefix, payload = parse_labeled_chunk chunk in
    try
      let json = Yojson.Safe.from_string payload in
      lines_of_json ?prefix json
    with
    | Yojson.Json_error _ ->
      [ grep_like_line
          ~source:(Option.value prefix ~default:"search")
          ~location:"result"
          ~content:payload
      ]
  in
  input |> split_chunks |> List.concat_map render_chunk |> take_list max_lines
;;

let format_search_output ?(max_lines = 20) input =
  lines_of_search_output ~max_lines input |> String.concat "\n"
;;
