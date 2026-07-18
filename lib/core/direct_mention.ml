let trim_token_edges token =
  let is_word = function
    | 'a' .. 'z' | '0' .. '9' | '@' | '_' | '-' -> true
    | _ -> false
  in
  let length = String.length token in
  let rec find_first index =
    if index >= length || is_word token.[index]
    then index
    else find_first (index + 1)
  in
  let first = find_first 0 in
  let rec find_last index =
    if index < first || is_word token.[index]
    then index
    else find_last (index - 1)
  in
  let last = find_last (length - 1) in
  if last < first
  then ""
  else String.sub token first (last - first + 1)
;;

let targets_of_content content =
  let normalized =
    String.map
      (function
        | '\t' | '\n' | '\r' -> ' '
        | character -> character)
      (String.lowercase_ascii content)
  in
  String.split_on_char ' ' normalized
  |> List.filter_map (fun token ->
    let trimmed = trim_token_edges token in
    if String.length trimmed >= 2 && Char.equal trimmed.[0] '@'
    then Some (String.sub trimmed 1 (String.length trimmed - 1))
    else None)
  |> List.sort_uniq String.compare
;;
