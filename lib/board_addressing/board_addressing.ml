(** Shared @-mention addressing grammar — see the interface.  The
    tokenization is the case-preserving superset of the two legacy clones
    ([keeper_lane_mentions] pre-folded case, [board_audience] preserved
    it); equivalence against both legacy decision procedures is pinned by
    test_keeper_lane_mentions, test_board_dispatch, and
    test_board_addressing. *)

let target_prefix = "@"
let broadcast_selector_prefix = "@@"
let broadcast_all_selector = "all"

let trim_token_edges value =
  let is_word = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '@' | '_' | '-' -> true
    | _ -> false
  in
  let length = String.length value in
  let first = ref 0 in
  let last = ref (length - 1) in
  while !first < length && not (is_word value.[!first]) do
    incr first
  done;
  while !last >= !first && not (is_word value.[!last]) do
    decr last
  done;
  if !last < !first then "" else String.sub value !first (!last - !first + 1)
;;

let tokens_of_text text =
  text
  |> String.map (function
    | '\t' | '\n' | '\r' -> ' '
    | character -> character)
  |> String.split_on_char ' '
  |> List.map trim_token_edges
  |> List.filter (fun token -> not (String.equal token ""))
;;

type raw_address =
  | No_explicit_address
  | Raw_targets of string list
  | Broadcast_all
  | Unsupported_broadcast of string list

let parse text =
  let tokens = tokens_of_text text in
  let prefix_length = String.length broadcast_selector_prefix in
  let selectors =
    tokens
    |> List.filter_map (fun token ->
      if
        String.length token >= prefix_length
        && String.starts_with ~prefix:broadcast_selector_prefix token
      then
        Some
          (String.sub token prefix_length (String.length token - prefix_length)
           |> String.lowercase_ascii)
      else None)
    |> List.sort_uniq String.compare
  in
  if selectors <> [] && List.for_all (String.equal broadcast_all_selector) selectors
  then Broadcast_all
  else if selectors <> []
  then Unsupported_broadcast selectors
  else (
    let targets =
      tokens
      |> List.filter_map (fun token ->
        (* [tokens_of_text] never yields empty tokens, so the [String.sub]
           below is safe; a bare ["@"] reaches the caller as the empty
           candidate. *)
        if
          String.starts_with ~prefix:target_prefix token
          && not (String.starts_with ~prefix:broadcast_selector_prefix token)
        then Some (String.sub token 1 (String.length token - 1))
        else None)
    in
    match targets with
    | [] -> No_explicit_address
    | _ :: _ -> Raw_targets targets)
;;
