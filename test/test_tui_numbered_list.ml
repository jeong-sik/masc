(* A numbered list is rows of an entry's number, two spaces and its text. These
   cases pin what that leaves: the rows read back as the same entries in the
   same order, the numbers are right-aligned to the last one, no row is wider
   than its budget, and an entry that wraps continues indented under its own
   text. Widths are cells, not bytes, over wide characters and combining marks
   too. They check text and cells, not how a screen reads. *)

open Alcotest
module Numbered = Masc_tui_numbered_list
module Layout = Masc_tui_message_layout

let cells_of = Layout.display_width

let budgets = [ 12; 13; 20; 30; 44; 80 ]

let pieces =
  [| "a"; "bc"; "open"; "\xC3\xA9"; "\xE6\x97\xA5"; "\xEA\xB0\x80\xEB\x82\x98"; "\xF0\x9F\x98\x80" |]

let pick state array = array.(Random.State.int state (Array.length array))

(* One to six words of one or two pieces each, single spaces between, some
   words with a combining mark. A word is at most eight cells wide. *)
let random_entry state =
  String.concat " "
    (List.init
       (1 + Random.State.int state 6)
       (fun _ ->
          let word =
            String.concat ""
              (List.init (1 + Random.State.int state 2) (fun _ -> pick state pieces))
          in
          if Random.State.int state 100 < 10 then word ^ "\xCC\x81" else word))

(* One hundred and twenty lists of up to eleven entries, from a fixed seed.
   Lists of ten or more have two-digit numbers. *)
let lists =
  let state = Random.State.make [| 0x57 |] in
  List.init 120 (fun _ -> List.init (Random.State.int state 12) (fun _ -> random_entry state))

let marker_cells entries = String.length (string_of_int (List.length entries)) + 2

(* The widest word is eight cells, so a budget leaves room for every word when
   it leaves the text at least that. *)
let every_case f =
  List.iter
    (fun budget ->
       List.iter
         (fun entries -> if budget - marker_cells entries >= 8 then f budget entries)
         lists)
    budgets

let is_blank_prefix row count =
  String.length row >= count && String.equal (String.sub row 0 count) (String.make count ' ')

(* The rows grouped by entry: a row whose marker columns are blank continues the
   entry above it. *)
let group_by_entry entries rows =
  let marker = marker_cells entries in
  List.fold_left
    (fun groups row ->
       match groups with
       | current :: before when is_blank_prefix row marker ->
         (current @ [ String.sub row marker (String.length row - marker) ]) :: before
       | _ -> [ String.sub row marker (String.length row - marker) ] :: groups)
    []
    rows
  |> List.rev

let test_rows_read_back_as_the_same_entries () =
  every_case (fun budget entries ->
    let rows = Numbered.rows ~max_cells:budget entries in
    check
      (list string)
      "entries"
      entries
      (List.map (String.concat " ") (group_by_entry entries rows)))

let test_numbers_run_from_one_and_are_right_aligned () =
  every_case (fun budget entries ->
    let digits = String.length (string_of_int (List.length entries)) in
    let starts =
      List.filter
        (fun row -> not (is_blank_prefix row (digits + 2)))
        (Numbered.rows ~max_cells:budget entries)
    in
    check
      (list string)
      "numbers"
      (List.mapi (fun index _ -> Printf.sprintf "%*d" digits (index + 1)) entries)
      (List.map (fun row -> String.sub row 0 digits) starts);
    List.iter
      (fun row ->
         check string "two spaces after the number" "  " (String.sub row digits 2))
      starts)

let test_no_row_is_wider_than_the_budget () =
  every_case (fun budget entries ->
    List.iter
      (fun row -> check bool "row fits" true (cells_of row <= budget))
      (Numbered.rows ~max_cells:budget entries))

let test_a_continued_entry_is_indented_under_its_text () =
  every_case (fun budget entries ->
    let marker = marker_cells entries in
    List.iter
      (fun row ->
         if is_blank_prefix row marker
         then
           check
             bool
             "text starts at the column where the entry's text starts"
             true
             (String.length row > marker && not (Char.equal row.[marker] ' ')))
      (Numbered.rows ~max_cells:budget entries))

let test_no_entries_give_no_rows () =
  List.iter
    (fun budget -> check (list string) "rows" [] (Numbered.rows ~max_cells:budget []))
    (0 :: -3 :: budgets)

let test_an_entry_with_no_text_is_its_number () =
  check (list string) "one" [ "1" ] (Numbered.rows ~max_cells:20 [ "" ]);
  check
    (list string)
    "between two"
    [ "1  a"; "2"; "3  b" ]
    (Numbered.rows ~max_cells:20 [ "a"; ""; "b" ])

let test_a_budget_below_the_marker_leaves_the_text_one_cell () =
  let rows = Numbered.rows ~max_cells:0 [ "ab" ] in
  check
    (list string)
    "text"
    [ "ab" ]
    [ String.concat "" (List.map (fun row -> String.sub row 3 (String.length row - 3)) rows) ]

let test_a_row_may_fill_the_budget_exactly () =
  check (list string) "exact" [ "1  ab cd" ] (Numbered.rows ~max_cells:8 [ "ab cd" ]);
  check
    (list string)
    "one cell less"
    [ "1  ab"; "   cd" ]
    (Numbered.rows ~max_cells:7 [ "ab cd" ])

let test_widths_are_cells_not_bytes () =
  let entry = "\xE6\x97\xA5\xE6\x97\xA5 \xE6\x97\xA5\xE6\x97\xA5" in
  check bool "more bytes than cells" true (String.length entry > cells_of entry);
  check (list string) "one row" [ "1  " ^ entry ] (Numbered.rows ~max_cells:(3 + cells_of entry) [ entry ])

let test_ten_entries_align_their_numbers () =
  let entries = List.init 10 (fun index -> Printf.sprintf "e%d" index) in
  let rows = Numbered.rows ~max_cells:20 entries in
  check string "first" " 1  e0" (List.hd rows);
  check string "tenth" "10  e9" (List.nth rows 9)

let () =
  run
    "tui_numbered_list"
    [ ( "rows"
      , [ test_case
            "rows read back as the same entries"
            `Quick
            test_rows_read_back_as_the_same_entries
        ; test_case
            "numbers run from one and are right-aligned"
            `Quick
            test_numbers_run_from_one_and_are_right_aligned
        ; test_case
            "no row is wider than the budget"
            `Quick
            test_no_row_is_wider_than_the_budget
        ; test_case
            "a continued entry is indented under its text"
            `Quick
            test_a_continued_entry_is_indented_under_its_text
        ] )
    ; ( "boundaries"
      , [ test_case "no entries give no rows" `Quick test_no_entries_give_no_rows
        ; test_case
            "an entry with no text is its number"
            `Quick
            test_an_entry_with_no_text_is_its_number
        ; test_case
            "a budget below the marker leaves the text one cell"
            `Quick
            test_a_budget_below_the_marker_leaves_the_text_one_cell
        ; test_case
            "a row may fill the budget exactly"
            `Quick
            test_a_row_may_fill_the_budget_exactly
        ; test_case "widths are cells, not bytes" `Quick test_widths_are_cells_not_bytes
        ; test_case
            "ten entries align their numbers"
            `Quick
            test_ten_entries_align_their_numbers
        ] )
    ]
