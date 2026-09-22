open Alcotest

module Table = Masc_tui_table

let width = Masc_tui_message_layout.display_width

let index_of needle text =
  let text_length = String.length text in
  let needle_length = String.length needle in
  let rec walk index =
    if index + needle_length > text_length then None
    else if String.sub text index needle_length = needle then Some index
    else walk (index + 1)
  in
  walk 0

let contains needle text = Option.is_some (index_of needle text)

let columns ?(name = "pinewood") ?(count = "139") ?(size = "94.4 KB") () =
  [ Table.cell ~header:"KEEPER" ~width:16 name
  ; Table.cell ~align:Table.Right ~header:"FACTS" ~width:5 count
  ; Table.cell ~align:Table.Right ~header:"SIZE" ~width:9 size
  ]

(* The header and the rows are drawn from one description, so the row is
   exactly as wide as the header whatever it carries. This is the property the
   pair of format strings could not have. *)
let test_a_row_is_as_wide_as_its_header () =
  let header = Table.header_row (columns ()) in
  check int "an ordinary row" (width header) (width (Table.row (columns ())));
  check int "a row past every width" (width header)
    (width
       (Table.row
          (columns ~name:"pinewood-pr-jira-checker-and-more" ~count:"1234567"
             ~size:"1234567.8 MB" ())));
  check int "a row of empty readings" (width header)
    (width (Table.row (columns ~name:"" ~count:"" ~size:"" ())))

(* One cell between columns, and the same one on every screen. The tables each
   carried a spacing of their own: nine chose one and the Memory table chose
   two, recording no reason, so moving between two screens moved the columns
   under the reader's eye. There is nothing for a table to pass now, and this
   measures what the contract actually draws against what it says it draws. *)
let test_columns_stand_one_cell_apart () =
  let header = Table.header_row (columns ()) in
  let starts needle =
    match index_of needle header with
    | Some at -> width (String.sub header 0 at)
    | None -> failf "%S is not in %S" needle header
  in
  (* KEEPER is 16 cells and FACTS is 5, so each name starts after the one
     before it plus the gap. *)
  check int "FACTS follows the KEEPER column" (16 + Table.cell_gap)
    (starts "FACTS");
  (* SIZE is right-aligned in nine cells, so its name ends where its column
     does rather than starting where it starts. *)
  check int "the SIZE column ends one gap past FACTS plus its own width"
    (16 + Table.cell_gap + 5 + Table.cell_gap + 9)
    (starts "SIZE" + width "SIZE")

(* [used_width] is what a caller divides a frame with, so it has to be the
   width the row actually occupies rather than a second count of it. *)
let test_used_width_is_the_width_drawn () =
  let cells = columns () in
  check int "the width a caller divides a frame with"
    (Table.used_width cells)
    (width (Table.header_row cells))

(* A left cell starts where its header starts; a right cell ends where its
   header ends. A screen mixes the two in one row, and the alignment has to
   reach the header as well or the numbers sit under nothing. *)
let test_alignment_reaches_the_header () =
  let header = Table.header_row (columns ()) in
  let row = Table.row (columns ~name:"N" ~count:"F" ~size:"Z" ()) in
  let starts needle text =
    match index_of needle text with
    | Some index -> width (String.sub text 0 index)
    | None -> failf "%S is not in %S" needle text
  in
  let ends needle text = starts needle text + width needle in
  check int "a left column starts with its header" (starts "KEEPER" header)
    (starts "N" row);
  check int "a right column ends with its header" (ends "FACTS" header)
    (ends "F" row);
  check int "the last column ends with its header" (ends "SIZE" header)
    (ends "Z" row)

(* A reading wider than its column is folded, never allowed to widen it: the
   cells after it must not move. *)
let test_an_overlong_reading_folds_rather_than_pushes () =
  let long = String.concat "" (List.init 12 (fun _ -> "abcdefgh")) in
  let cells = columns ~name:long () in
  check int "the row keeps the header's width"
    (width (Table.header_row cells))
    (width (Table.row cells));
  check bool "the cut is marked rather than silent" true
    (contains "\xe2\x80\xa6" (Table.row cells))

(* An identifier and a sentence give way at different ends. Both ends of an
   identifier decide which one it is; a sentence is read from the front. *)
let test_a_column_chooses_which_end_gives_way () =
  let title = "Verify: run-exact-output-lane-board-attention-9e327af211400cba" in
  let folded fold =
    Table.row [ Table.cell ~fold ~header:"TITLE" ~width:24 title ]
  in
  let middle = folded Table.Fold_middle in
  let tail = folded Table.Fold_tail in
  check bool "the middle fold keeps the tail" true
    (contains "9e327af211400cba" middle);
  check bool "the middle fold loses the subject" false
    (contains "Verify: run-exact" middle);
  check bool "the tail fold keeps the subject" true
    (contains "Verify: run-exact" tail);
  check bool "the tail fold loses the tail" false
    (contains "9e327af211400cba" tail);
  check int "and both stay in the column" (width middle) (width tail);
  check bool "both mark the cut" true
    (contains "\xe2\x80\xa6" middle && contains "\xe2\x80\xa6" tail)

(* A Planning title from the live fleet, in Hangul: two cells a syllable. The
   column is measured in cells, so a tail fold has to stop on a syllable edge
   and still fill the column exactly, or every column after it moves. *)
let test_a_hangul_title_folds_at_its_tail_on_a_syllable_edge () =
  let title =
    "\xec\xb5\x9c\xea\xb7\xbc 6\xec\x9d\xbc\xea\xb0\x84 MASC \
     \xec\xbd\x94\xeb\x93\x9c\xeb\xb2\xa0\xec\x9d\xb4\xec\x8a\xa4 \
     \xed\x9a\x8c\xea\xb7\x80\xc2\xb7SSOT \xec\x9c\x84\xeb\xb0\x98"
  in
  List.iter
    (fun column ->
      let row =
        Table.row
          [ Table.cell ~fold:Table.Fold_tail ~header:"TITLE" ~width:column title
          ; Table.cell ~header:"AGE" ~width:3 "9h"
          ]
      in
      check int
        (Printf.sprintf "at %d cells the row is exactly as wide as its header"
           column)
        (width
           (Table.header_row
              [ Table.cell ~header:"TITLE" ~width:column ""
              ; Table.cell ~header:"AGE" ~width:3 ""
              ]))
        (width row);
      check bool
        (Printf.sprintf "at %d cells the head is kept: %s" column row)
        true
        (String.starts_with ~prefix:"\xec\xb5\x9c\xea\xb7\xbc 6" row);
      check bool
        (Printf.sprintf "at %d cells the cut is marked" column)
        true
        (contains "\xe2\x80\xa6" row))
    (* Odd and even widths: an odd one leaves a cell a syllable cannot fill. *)
    [ 12; 13; 20; 21 ]

(* Nothing passes a fold at most call sites, and an identifier is the reading
   that must not lose an end. *)
let test_a_column_that_says_nothing_keeps_both_ends () =
  let id = "run-exact-output-lane-board-attention" in
  let row = Table.row [ Table.cell ~header:"ID" ~width:16 id ] in
  check bool "the head is drawn" true (contains "run-" row);
  check bool "and so is the tail" true (contains "attention" row)

(* A screen that hides a column at narrow widths drops it from the description,
   and the header loses it with the rows rather than naming a column nothing
   fills. *)
let test_a_dropped_column_leaves_both_lines () =
  let full = columns () in
  let without_size = List.filteri (fun index _ -> index < 2) full in
  let header = Table.header_row without_size in
  check bool "the header no longer names it" true (not (contains "SIZE" header));
  check int "and both lines shrink together" (width header)
    (width (Table.row without_size))

(* A dressed cell occupies the same display cells as an undressed one: the
   escapes have no width, so colouring one reading cannot move the column after
   it. This is what lets a row say which of its readings deviates without the
   layout depending on whether anything did. *)
let test_a_styled_cell_occupies_no_extra_cells () =
  let plain = columns () in
  let dressed =
    [ Table.cell ~header:"KEEPER" ~width:16 "pinewood"
    ; Table.cell ~align:Table.Right ~style:"\027[33m" ~header:"FACTS" ~width:5
        "139"
    ; Table.cell ~align:Table.Right ~header:"SIZE" ~width:9 "94.4 KB"
    ]
  in
  check int "a dressed row is as wide as a plain one"
    (width (Table.row plain))
    (width (Table.row dressed));
  check int "and as wide as the header"
    (width (Table.header_row dressed))
    (width (Table.row dressed));
  check bool "the dress reaches the reading" true
    (contains "\027[33m" (Table.row dressed));
  check bool "and closes after it" true
    (contains "\027[0m" (Table.row dressed))

(* The header names columns; it never wears a reading's colour. *)
let test_the_header_ignores_cell_style () =
  let dressed =
    [ Table.cell ~style:"\027[31m" ~header:"KEEPER" ~width:16 "pinewood" ]
  in
  check bool "no escape in the header" false
    (contains "\027[" (Table.header_row dressed))

(* A row inside a dimmed or selected line closes its cells back to that line's
   dress rather than to a bare reset, which would undress everything after. *)
let test_close_returns_to_the_lines_own_dress () =
  let dressed =
    [ Table.cell ~style:"\027[33m" ~header:"KEEPER" ~width:8 "late"
    ; Table.cell ~header:"FACTS" ~width:5 "139"
    ]
  in
  let row = Table.row ~close:"\027[2m" dressed in
  check bool "the line's dress is restored" true (contains "\027[2m" row);
  check bool "not a bare reset" false (contains "\027[0m" row)

let () =
  run "tui table"
    [ ( "layout"
      , [ test_case "a row is as wide as its header" `Quick
            test_a_row_is_as_wide_as_its_header
        ; test_case "used width is the width drawn" `Quick
            test_used_width_is_the_width_drawn
        ; test_case "columns stand one cell apart" `Quick
            test_columns_stand_one_cell_apart
        ; test_case "alignment reaches the header" `Quick
            test_alignment_reaches_the_header
        ; test_case "an overlong reading folds rather than pushes" `Quick
            test_an_overlong_reading_folds_rather_than_pushes
        ; test_case "a column chooses which end gives way" `Quick
            test_a_column_chooses_which_end_gives_way
        ; test_case "a hangul title folds at its tail on a syllable edge"
            `Quick test_a_hangul_title_folds_at_its_tail_on_a_syllable_edge
        ; test_case "a column that says nothing keeps both ends" `Quick
            test_a_column_that_says_nothing_keeps_both_ends
        ; test_case "a dropped column leaves both lines" `Quick
            test_a_dropped_column_leaves_both_lines
        ; test_case "a styled cell occupies no extra cells" `Quick
            test_a_styled_cell_occupies_no_extra_cells
        ; test_case "the header ignores cell style" `Quick
            test_the_header_ignores_cell_style
        ; test_case "close returns to the line's own dress" `Quick
            test_close_returns_to_the_lines_own_dress
        ] )
    ]
