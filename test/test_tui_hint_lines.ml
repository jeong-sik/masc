(* Key hints in an info pane are packed whole. These cases pin what that
   leaves: the rows read back as the same hints in the same order, a hint that
   fits a row is never cut, a row takes the next hint whenever it still fits,
   and no hint is dropped at any width. Widths are counted in cells, not bytes,
   over wide characters and combining marks too. They check text and cells, not
   how a screen reads. *)

open Alcotest
module Hint = Masc_tui_hint_lines
module Layout = Masc_tui_message_layout

let cells_of = Layout.display_width

let separator = Layout.clause_separator

let text (item : Hint.item) = item.key ^ ": " ^ item.label

let item key label = { Hint.key; label }

let budgets = [ 1; 2; 3; 5; 8; 13; 20; 30; 44; 52; 80 ]

let keys = [| "Enter"; "Esc"; "d"; "Space"; "[ / ]"; "Ctrl+K"; "\xEA\xB0\x80" |]

let pieces =
  [| "a"; "bc"; "open"; "\xC3\xA9"; "\xE6\x97\xA5"; "\xEA\xB0\x80\xEB\x82\x98"; "\xF0\x9F\x98\x80" |]

let pick state array = array.(Random.State.int state (Array.length array))

(* Labels of one to four words, each word a few narrow or wide pieces, some
   with a combining mark. No label holds the separator. *)
let random_label state =
  String.concat " "
    (List.init
       (1 + Random.State.int state 4)
       (fun _ ->
          let word =
            String.concat ""
              (List.init (1 + Random.State.int state 4) (fun _ -> pick state pieces))
          in
          if Random.State.int state 100 < 10 then word ^ "\xCC\x81" else word))

let random_items state =
  List.init
    (Random.State.int state 8)
    (fun _ -> item (pick state keys) (random_label state))

(* Four hundred lists of up to seven hints, from a fixed seed. *)
let lists =
  let state = Random.State.make [| 0x41 |] in
  List.init 400 (fun _ -> random_items state)

let every_case f =
  List.iter (fun budget -> List.iter (fun items -> f budget items) lists) budgets

let all_fit budget items = List.for_all (fun i -> cells_of (text i) <= budget) items

let split_on_separator row =
  let length = String.length separator in
  let rec from start offset found =
    if offset + length > String.length row
    then List.rev (String.sub row start (String.length row - start) :: found)
    else if String.equal (String.sub row offset length) separator
    then
      from (offset + length) (offset + length) (String.sub row start (offset - start) :: found)
    else from start (offset + 1) found
  in
  from 0 0 []

let first count list = List.filteri (fun index _ -> index < count) list

let after count list = List.filteri (fun index _ -> index >= count) list

(* The rule written the plain way, for hints that each fit a row: a row is the
   longest run of the remaining hints whose joined text fits, measured on the
   joined text. *)
let reference ~max_cells items =
  let max_cells = max 1 max_cells in
  let join list = String.concat separator list in
  let rec rows = function
    | [] -> []
    | all ->
      let rec longest count =
        if count < List.length all && cells_of (join (first (count + 1) all)) <= max_cells
        then longest (count + 1)
        else count
      in
      let count = longest 1 in
      join (first count all) :: rows (after count all)
  in
  rows (List.map text items)

let test_rows_read_back_as_the_same_hints () =
  every_case (fun budget items ->
    if all_fit budget items
    then
      check
        (list string)
        "hints"
        (List.map text items)
        (List.concat_map split_on_separator (Hint.wrap ~max_cells:budget items)))

let test_no_row_is_wider_than_the_budget_when_every_hint_fits () =
  every_case (fun budget items ->
    if all_fit budget items
    then
      List.iter
        (fun row ->
           check bool "row fits" true (cells_of row <= budget);
           check bool "row is not empty" true (not (String.equal row "")))
        (Hint.wrap ~max_cells:budget items))

let test_a_row_takes_the_next_hint_whenever_it_fits () =
  every_case (fun budget items ->
    if all_fit budget items
    then (
      let rows = Hint.wrap ~max_cells:budget items in
      let rec adjacent = function
        | above :: (below :: _ as rest) ->
          let next = List.hd (split_on_separator below) in
          check
            bool
            "the first hint below did not fit above"
            true
            (cells_of above + cells_of separator + cells_of next > budget);
          adjacent rest
        | [ _ ] | [] -> ()
      in
      adjacent rows))

let test_rows_match_the_plain_definition () =
  every_case (fun budget items ->
    if all_fit budget items
    then
      check
        (list string)
        "rows"
        (reference ~max_cells:budget items)
        (Hint.wrap ~max_cells:budget items))

(* Everything the rows carry, less the spaces and the mark between hints. *)
let remove_all ~sub text =
  let length = String.length sub in
  let buffer = Buffer.create (String.length text) in
  let rec from offset =
    if offset >= String.length text
    then ()
    else if offset + length <= String.length text
            && String.equal (String.sub text offset length) sub
    then from (offset + length)
    else (
      Buffer.add_char buffer text.[offset];
      from (offset + 1))
  in
  from 0;
  Buffer.contents buffer

let bare text =
  remove_all ~sub:"\xC2\xB7" (String.concat "" (String.split_on_char ' ' text))

let test_no_hint_is_dropped_at_any_width () =
  every_case (fun budget items ->
    check
      string
      "text"
      (bare (String.concat "" (List.map text items)))
      (bare (String.concat "" (Hint.wrap ~max_cells:budget items))))

let test_no_hints_give_no_rows () =
  List.iter
    (fun budget -> check (list string) "rows" [] (Hint.wrap ~max_cells:budget []))
    (0 :: -3 :: budgets)

let test_a_budget_below_one_is_one () =
  List.iter
    (fun items ->
       check
         (list string)
         "rows"
         (Hint.wrap ~max_cells:1 items)
         (Hint.wrap ~max_cells:0 items))
    lists

let test_a_row_may_fill_the_budget_exactly () =
  let first_hint = item "a" "b" in
  let second_hint = item "c" "d" in
  let exact = cells_of (text first_hint) + cells_of separator + cells_of (text second_hint) in
  check
    (list string)
    "exact"
    [ text first_hint ^ separator ^ text second_hint ]
    (Hint.wrap ~max_cells:exact [ first_hint; second_hint ]);
  check
    (list string)
    "one cell less"
    [ text first_hint; text second_hint ]
    (Hint.wrap ~max_cells:(exact - 1) [ first_hint; second_hint ])

let test_widths_are_cells_not_bytes () =
  let wide = item "a" "\xE6\x97\xA5" in
  let exact = (2 * cells_of (text wide)) + cells_of separator in
  check bool "more bytes than cells" true (String.length (text wide) > cells_of (text wide));
  check
    (list string)
    "one row"
    [ text wide ^ separator ^ text wide ]
    (Hint.wrap ~max_cells:exact [ wide; wide ])

let () =
  run
    "tui_hint_lines"
    [ ( "packing"
      , [ test_case "rows read back as the same hints" `Quick test_rows_read_back_as_the_same_hints
        ; test_case
            "no row is wider than the budget when every hint fits"
            `Quick
            test_no_row_is_wider_than_the_budget_when_every_hint_fits
        ; test_case
            "a row takes the next hint whenever it fits"
            `Quick
            test_a_row_takes_the_next_hint_whenever_it_fits
        ; test_case "rows match the plain definition" `Quick test_rows_match_the_plain_definition
        ; test_case
            "no hint is dropped at any width"
            `Quick
            test_no_hint_is_dropped_at_any_width
        ] )
    ; ( "boundaries"
      , [ test_case "no hints give no rows" `Quick test_no_hints_give_no_rows
        ; test_case "a budget below one is one" `Quick test_a_budget_below_one_is_one
        ; test_case "a row may fill the budget exactly" `Quick test_a_row_may_fill_the_budget_exactly
        ; test_case "widths are cells, not bytes" `Quick test_widths_are_cells_not_bytes
        ] )
    ]
