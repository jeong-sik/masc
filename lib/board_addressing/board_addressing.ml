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

(* Markdown code spans and fences are not address text. A comment that
   mentions `@internals/libs/datadogRum`, `@/lib/constants` or `@@` is
   discussing code, and tokenizing inside those regions turns every such
   comment into Malformed_targets and rejects it whole. Live board comments
   carry exactly those three shapes.

   Blanking rather than deleting keeps the surrounding text separated: a
   fence between two words must not join them into one token. Content is
   replaced with spaces so offsets and word boundaries survive.

   An unterminated backtick blanks to end of text. That is the fail-closed
   direction for this function: an author who opened a code span and did not
   close it addressed nobody after it. *)
let blank_code_regions text =
  let length = String.length text in
  let buffer = Bytes.of_string text in
  let blank_range start stop =
    for index = start to min stop (length - 1) do
      Bytes.set buffer index ' '
    done
  in
  let run_length_at index =
    let rec count offset =
      if index + offset < length && text.[index + offset] = '`' then count (offset + 1)
      else offset
    in
    count 0
  in
  let rec scan index =
    if index >= length then ()
    else if text.[index] = '`' then (
      let opener = run_length_at index in
      let body = index + opener in
      let rec find_close cursor =
        if cursor >= length then None
        else if text.[cursor] = '`' && run_length_at cursor = opener then Some cursor
        else find_close (cursor + 1)
      in
      match find_close body with
      | Some closer ->
        blank_range index (closer + opener - 1);
        scan (closer + opener)
      | None ->
        blank_range index (length - 1);
        ())
    else scan (index + 1)
  in
  scan 0;
  Bytes.to_string buffer
;;

let tokens_of_text text =
  let text = blank_code_regions text in
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
           below is safe. A bare ["@"] leaves nothing after the prefix, and
           that empty candidate is not an address: every caller drops it —
           board_audience folds it away with [Agent_id.of_string]'s Error —
           but the fold is a validator, and a validator logs what it refuses.
           A post whose body carries an email or a decorative "@" produced a
           WARN per occurrence for a candidate no one was ever going to use
           (208 on 2026-08-29). Not producing it says the same thing without
           asking the gate a question the parser can answer. *)
        if
          String.starts_with ~prefix:target_prefix token
          && not (String.starts_with ~prefix:broadcast_selector_prefix token)
        then (
          match String.sub token 1 (String.length token - 1) with
          | "" -> None
          | candidate -> Some candidate)
        else None)
    in
    match targets with
    | [] -> No_explicit_address
    | _ :: _ -> Raw_targets targets)
;;
