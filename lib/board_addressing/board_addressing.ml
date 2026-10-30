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
      (* A run of backticks closes the span when it holds at least [opener] of
         them, and the last [opener] backticks of the run are the closer. Trying
         every position of a run on its own cost the square of the run's length
         on a long run. [cursor] is always the first backtick of a run, because
         [body] follows the opener's whole run and the walk only steps over
         other characters one at a time. *)
      let rec find_close cursor =
        if cursor >= length then None
        else if text.[cursor] = '`' then (
          let run = run_length_at cursor in
          if run >= opener then Some (cursor + run - opener)
          else find_close (cursor + run))
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

(* The selector a token opens, lowercased and without its [@@]: the empty
   string for a bare [@@]. *)
let selector_of_token token =
  let prefix_length = String.length broadcast_selector_prefix in
  if
    String.length token >= prefix_length
    && String.starts_with ~prefix:broadcast_selector_prefix token
  then
    Some
      (String.sub token prefix_length (String.length token - prefix_length)
       |> String.lowercase_ascii)
  else None
;;

(* The direct target a token names, without its [@]. [tokens_of_text] never
   yields empty tokens, so the [String.sub] below is safe. A bare ["@"] leaves
   nothing after the prefix, and that empty candidate is not an address: every
   caller drops it — board_audience folds it away with [Agent_id.of_string]'s
   Error — but the fold is a validator, and a validator logs what it refuses.
   A post whose body carries an email or a decorative "@" produced a WARN per
   occurrence for a candidate no one was ever going to use (208 on 2026-08-29).
   Not producing it says the same thing without asking the gate a question the
   parser can answer. *)
let target_of_token token =
  if
    String.starts_with ~prefix:target_prefix token
    && not (String.starts_with ~prefix:broadcast_selector_prefix token)
  then (
    match String.sub token 1 (String.length token - 1) with
    | "" -> None
    | candidate -> Some candidate)
  else None
;;

let parse text =
  let tokens = tokens_of_text text in
  let selectors =
    tokens |> List.filter_map selector_of_token |> List.sort_uniq String.compare
  in
  if selectors <> [] && List.for_all (String.equal broadcast_all_selector) selectors
  then Broadcast_all
  else if selectors <> []
  then Unsupported_broadcast selectors
  else (
    match List.filter_map target_of_token tokens with
    | [] -> No_explicit_address
    | targets -> Raw_targets targets)
;;

(* The sinks of a routed name build file names from it unchanged: a Keeper's
   metadata path is the name plus a suffix. Only the characters the removed
   regex extractor accepted may reach them, so a path separator or a dot never
   does. That extractor took ['-'] in a direct target and not in a selector. *)
let is_name_character = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
  | _ -> false
;;

let is_routable_selector name =
  (not (String.equal name "")) && String.for_all is_name_character name
;;

let is_routable_target name =
  (not (String.equal name ""))
  && String.for_all (fun character -> is_name_character character || character = '-') name
;;

(* A consumer that notifies one recipient routes on one name, the first one
   written. A selector wins over a direct target, as in [parse]. A token that
   is not a name is prose and is skipped, so a stray [@@], as in a diff hunk
   header, or an npm scope does not hide the recipient written beside it. *)
let routing_target text =
  let tokens = tokens_of_text text in
  match List.find_opt is_routable_selector (List.filter_map selector_of_token tokens) with
  | Some _ as selector -> selector
  | None -> List.find_opt is_routable_target (List.filter_map target_of_token tokens)
;;
