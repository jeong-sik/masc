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

let columns ?(name = "kidsnote") ?(count = "139") ?(size = "94.4 KB") () =
  [ Table.cell ~header:"KEEPER" ~width:16 name
  ; Table.cell ~align:Table.Right ~header:"FACTS" ~width:5 count
  ; Table.cell ~align:Table.Right ~header:"SIZE" ~width:9 size
  ]

(* The header and the rows are drawn from one description, so the row is
   exactly as wide as the header whatever it carries. This is the property the
   pair of format strings could not have. *)
let test_a_row_is_as_wide_as_its_header () =
  for gap = 0 to 4 do
    let header = Table.header_row ~gap (columns ()) in
    check int
      (Printf.sprintf "gap %d: an ordinary row" gap)
      (width header)
      (width (Table.row ~gap (columns ())));
    check int
      (Printf.sprintf "gap %d: a row past every width" gap)
      (width header)
      (width
         (Table.row ~gap
            (columns ~name:"kidsnote-pr-jira-checker-and-more"
               ~count:"1234567" ~size:"1234567.8 MB" ())));
    check int
      (Printf.sprintf "gap %d: a row of empty readings" gap)
      (width header)
      (width (Table.row ~gap (columns ~name:"" ~count:"" ~size:"" ())))
  done

(* [used_width] is what a caller divides a frame with, so it has to be the
   width the row actually occupies rather than a second count of it. *)
let test_used_width_is_the_width_drawn () =
  for gap = 0 to 4 do
    let cells = columns () in
    check int
      (Printf.sprintf "gap %d" gap)
      (Table.used_width ~gap cells)
      (width (Table.header_row ~gap cells))
  done

(* A left cell starts where its header starts; a right cell ends where its
   header ends. A screen mixes the two in one row, and the alignment has to
   reach the header as well or the numbers sit under nothing. *)
let test_alignment_reaches_the_header () =
  let gap = 2 in
  let header = Table.header_row ~gap (columns ()) in
  let row = Table.row ~gap (columns ~name:"N" ~count:"F" ~size:"Z" ()) in
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
  let gap = 2 in
  let long = String.concat "" (List.init 12 (fun _ -> "abcdefgh")) in
  let cells = columns ~name:long () in
  check int "the row keeps the header's width"
    (width (Table.header_row ~gap cells))
    (width (Table.row ~gap cells));
  check bool "the cut is marked rather than silent" true
    (contains "\xe2\x80\xa6" (Table.row ~gap cells))

(* A screen that hides a column at narrow widths drops it from the description,
   and the header loses it with the rows rather than naming a column nothing
   fills. *)
let test_a_dropped_column_leaves_both_lines () =
  let gap = 2 in
  let full = columns () in
  let without_size = List.filteri (fun index _ -> index < 2) full in
  let header = Table.header_row ~gap without_size in
  check bool "the header no longer names it" true (not (contains "SIZE" header));
  check int "and both lines shrink together" (width header)
    (width (Table.row ~gap without_size))

let () =
  run "tui table"
    [ ( "layout"
      , [ test_case "a row is as wide as its header" `Quick
            test_a_row_is_as_wide_as_its_header
        ; test_case "used width is the width drawn" `Quick
            test_used_width_is_the_width_drawn
        ; test_case "alignment reaches the header" `Quick
            test_alignment_reaches_the_header
        ; test_case "an overlong reading folds rather than pushes" `Quick
            test_an_overlong_reading_folds_rather_than_pushes
        ; test_case "a dropped column leaves both lines" `Quick
            test_a_dropped_column_leaves_both_lines
        ] )
    ]
