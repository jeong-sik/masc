(* A numbered list is rows of an entry's number, two spaces and its text. These
   cases pin what that leaves: the rows read back as the same entries in the
   same order, the numbers are right-aligned to the last one, no row is wider
   than its budget, and an entry that wraps continues indented under its own
   text. That holds for a word wider than a row too, which is what a model id
   is: it has no space to wrap at. Widths are cells, not bytes, over wide
   characters and combining marks too. They check text and cells, not how a
   screen reads. *)

open Alcotest
module Numbered = Masc_tui_numbered_list
module Layout = Masc_tui_message_layout

let cells_of = Layout.display_width

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

let segments =
  [| "glm"
   ; "coding"
   ; "ollama"
   ; "cloud"
   ; "deepseek"
   ; "v4"
   ; "1"
   ; "flash"
   ; "openrouter"
   ; "claude"
   ; "\xE6\x97\xA5\xE6\x9C\xAC"
   ; "\xC3\xA9"
  |]

let separators = [| "-"; "."; "_"; ":"; "/" |]

(* Three to ten segments joined by what a model id joins its parts with, and no
   space: one word, up to about a hundred cells wide. *)
let random_id state =
  String.concat
    ""
    (List.init
       (3 + Random.State.int state 8)
       (fun index -> (if index = 0 then "" else pick state separators) ^ pick state segments))

(* A family is lists of entries, the budgets to wrap them at, the cells of text
   every budget must leave, and what the rows of one entry read back with. *)
type family =
  { lists : string list list
  ; budgets : int list
  ; least_text_cells : int
  ; rejoin : string
  }

(* One hundred and twenty lists of up to eleven entries, from a fixed seed.
   Lists of ten or more have two-digit numbers. *)
let random_lists seed entry =
  let state = Random.State.make [| seed |] in
  List.init 120 (fun _ -> List.init (Random.State.int state 12) (fun _ -> entry state))

(* Phrases wrap at spaces, and the widest word is eight cells, so a budget
   leaves room for every word when it leaves the text at least that. *)
let phrases =
  { lists = random_lists 0x57 random_entry
  ; budgets = [ 12; 13; 20; 30; 44; 80 ]
  ; least_text_cells = 8
  ; rejoin = " "
  }

(* A model id is cut inside the word, so the rows of one entry read back with
   nothing between them. The widest grapheme is two cells. *)
let ids =
  { lists = random_lists 0x58 random_id
  ; budgets = [ 6; 8; 12; 20; 30; 44 ]
  ; least_text_cells = 2
  ; rejoin = ""
  }

let families = [ phrases; ids ]

let marker_cells entries = String.length (string_of_int (List.length entries)) + 2

let every_case family f =
  List.iter
    (fun budget ->
       List.iter
         (fun entries ->
            if budget - marker_cells entries >= family.least_text_cells then f budget entries)
         family.lists)
    family.budgets

let each_family f = List.iter f families

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
  each_family (fun family ->
    every_case family (fun budget entries ->
      let rows = Numbered.rows ~max_cells:budget entries in
      check
        (list string)
        "entries"
        entries
        (List.map (String.concat family.rejoin) (group_by_entry entries rows))))

let test_numbers_run_from_one_and_are_right_aligned () =
  each_family (fun family ->
    every_case family (fun budget entries ->
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
        starts))

let test_no_row_is_wider_than_the_budget () =
  each_family (fun family ->
    every_case family (fun budget entries ->
      List.iter
        (fun row -> check bool "row fits" true (cells_of row <= budget))
        (Numbered.rows ~max_cells:budget entries)))

let test_a_continued_entry_is_indented_under_its_text () =
  each_family (fun family ->
    every_case family (fun budget entries ->
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
        (Numbered.rows ~max_cells:budget entries)))

(* The id family is there for the word that has no space to wrap at. Every one
   of its budgets must meet a word wider than the row. *)
let test_every_budget_meets_a_word_wider_than_the_row () =
  List.iter
    (fun budget ->
       let wider =
         List.exists
           (fun entries ->
              let text_cells = budget - marker_cells entries in
              text_cells >= ids.least_text_cells
              && List.exists (fun entry -> cells_of entry > text_cells) entries)
           ids.lists
       in
       check bool (Printf.sprintf "budget %d meets one" budget) true wider)
    ids.budgets

let test_no_entries_give_no_rows () =
  List.iter
    (fun budget -> check (list string) "rows" [] (Numbered.rows ~max_cells:budget []))
    (0 :: -3 :: phrases.budgets)

(* Entries with no text, among entries with some, at three budgets. *)
let test_an_entry_with_no_text_is_its_number () =
  let entries = [ "a"; ""; "b c"; ""; "" ] in
  List.iter
    (fun budget ->
       let starts =
         List.filter
           (fun row -> not (is_blank_prefix row (marker_cells entries)))
           (Numbered.rows ~max_cells:budget entries)
       in
       check int "one start per entry" (List.length entries) (List.length starts);
       List.iteri
         (fun index entry ->
            if String.equal entry ""
            then
              check
                string
                "its number alone"
                (string_of_int (index + 1))
                (String.trim (List.nth starts index)))
         entries)
    [ 12; 20; 44 ]

let test_a_budget_below_the_marker_leaves_the_text_one_cell () =
  List.iter
    (fun entries ->
       let at_one_cell = Numbered.rows ~max_cells:(marker_cells entries + 1) entries in
       List.iter
         (fun budget ->
            check (list string) "rows" at_one_cell (Numbered.rows ~max_cells:budget entries))
         [ marker_cells entries; 0; -3 ])
    phrases.lists

(* One entry takes one row at the width that holds it whole, and more rows one
   cell short of it. *)
let test_a_row_may_fill_the_budget_exactly () =
  List.iter
    (fun entries ->
       List.iter
         (fun entry ->
            if String.contains entry ' '
            then (
              let exact = marker_cells [ entry ] + cells_of entry in
              check
                int
                "rows at the exact width"
                1
                (List.length (Numbered.rows ~max_cells:exact [ entry ]));
              check
                bool
                "more rows one cell short"
                true
                (List.length (Numbered.rows ~max_cells:(exact - 1) [ entry ]) > 1)))
         entries)
    phrases.lists

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
        ; test_case
            "every budget meets a word wider than the row"
            `Quick
            test_every_budget_meets_a_word_wider_than_the_row
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
        ] )
    ]
