(* A card is a rectangle of exactly the cells it was given. These cases pin the
   geometry the screens rely on when they stack cards in a column and set
   columns side by side: every row has the card's width, the card has its
   height, nothing is lost silently, and the columns add up to the screen. *)

open Alcotest
module Card = Masc_tui_card
module Layout = Masc_tui_message_layout

let plain = { Card.edge = ""; title_style = ""; reset = "" }

let styled =
  { Card.edge = "\027[2m"; title_style = "\027[1m"; reset = "\027[0m" }

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec loop i = i + n <= h && (String.sub haystack i n = needle || loop (i + 1)) in
  n = 0 || loop 0

let occurrences ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec loop i count =
    if i + n > h then count
    else if String.sub haystack i n = needle then loop (i + n) (count + 1)
    else loop (i + 1) count
  in
  if n = 0 then 0 else loop 0 0

let card ?(title = "Needs your decision") body =
  { Card.title; body = (fun ~cells:_ -> body) }

let bodies =
  [ "empty", []
  ; "one row", [ "short" ]
  ; "ten rows", List.init 10 (fun index -> Printf.sprintf "row %d" index)
  ; "a row wider than the card", [ String.make 200 'x' ]
  ; "korean rows", [ "운영자가 세 후보를 주며 셋 중 하나냐고 되물었다"; "다음 줄" ]
  ; "styled rows", [ "\027[31mred\027[0m and plain"; "\027[1mbold\027[0m" ]
  ]

let sizes = [ 20, 5; 40, 3; 40, 12; 80, 30; 120, 8 ]

let test_every_row_is_the_cards_width_and_there_are_height_rows () =
  List.iter
    (fun (name, body) ->
       List.iter
         (fun (width, height) ->
            List.iter
              (fun style ->
                 let rows = Card.render ~style ~width ~height (card body) in
                 check int (Printf.sprintf "%s at %dx%d: height" name width height)
                   height (List.length rows);
                 List.iter
                   (fun row ->
                      check int
                        (Printf.sprintf "%s at %dx%d: row width" name width height)
                        width (Layout.display_width row))
                   rows)
              [ plain; styled ])
         sizes)
    bodies

let test_a_body_that_fits_loses_no_row () =
  let body = [ "alpha"; "beta"; "gamma" ] in
  let joined = String.concat "\n" (Card.render ~style:plain ~width:30 ~height:8 (card body)) in
  List.iter
    (fun row -> check bool (row ^ " is shown") true (contains ~needle:row joined))
    body

let test_a_title_wider_than_the_edge_is_cut_not_overflowed () =
  let title = String.make 100 't' in
  let rows = Card.render ~style:plain ~width:24 ~height:4 (card ~title [ "x" ]) in
  List.iter
    (fun row -> check int "row width" 24 (Layout.display_width row))
    rows

(* An overflowing body keeps its head and says how many rows it left out: the
   count is the one thing a reader cannot get back from the screen. *)
let test_an_overflowing_body_says_how_many_rows_it_left_out () =
  let body = List.init 10 (fun index -> Printf.sprintf "row-%02d" index) in
  let height = 6 in
  let inner_rows = height - 2 in
  let shown = inner_rows - 1 in
  let joined =
    String.concat "\n" (Card.render ~style:plain ~width:30 ~height (card body))
  in
  List.iteri
    (fun index row ->
       check bool
         (Printf.sprintf "%s is %s" row (if index < shown then "shown" else "not shown"))
         (index < shown) (contains ~needle:row joined))
    body;
  check bool "the number left out is on the card" true
    (contains ~needle:(string_of_int (List.length body - shown)) joined)

let test_a_card_with_no_room_is_blank_rows_of_its_width () =
  List.iter
    (fun (width, height) ->
       let rows = Card.render ~style:plain ~width ~height (card [ "x" ]) in
       check int "height" height (List.length rows);
       List.iter
         (fun row ->
            check string "blank" (String.make width ' ') row)
         rows)
    [ Card.min_width - 1, 10; 40, Card.min_height - 1; 3, 2 ]

let test_columns_and_gaps_add_up_to_the_screen () =
  List.iter
    (fun (inner_width, gap, columns) ->
       let widths = Card.column_widths ~inner_width ~gap ~columns in
       check int "column count" columns (List.length widths);
       check int
         (Printf.sprintf "widths and gaps fill %d" inner_width)
         inner_width
         (List.fold_left ( + ) 0 widths + (gap * (columns - 1)));
       let widest = List.fold_left max 0 widths
       and narrowest = List.fold_left min max_int widths in
       check bool "no column is more than one cell wider than another" true
         (widest - narrowest <= 1))
    [ 100, 2, 2; 101, 2, 2; 150, 3, 3; 77, 1, 1; 200, 4, 4 ]

let test_the_columns_that_fit_each_have_the_minimum_width () =
  List.iter
    (fun inner_width ->
       let max_columns = 3 and min_card_width = 40 and gap = 2 in
       let columns =
         Card.columns_that_fit ~inner_width ~gap ~min_card_width ~max_columns
       in
       check bool "between one and the maximum" true
         (columns >= 1 && columns <= max_columns);
       if columns >= 2 then
         List.iter
           (fun width -> check bool "wide enough" true (width >= min_card_width))
           (Card.column_widths ~inner_width ~gap ~columns))
    [ 1; 39; 40; 81; 82; 83; 123; 124; 125; 300 ]

(* The rows of a grid that has room for everything. *)
let grid ?(inner_width = 101) ?(row_gap = 1) ?(style = plain) columns =
  match
    Card.grid ~style ~inner_width ~gap:2 ~row_gap ~max_rows:max_int columns
  with
  | Some rows -> rows
  | None -> fail "a grid with no row limit drew nothing"

let rows_of count = List.init count (fun index -> Printf.sprintf "r%d" index)

let test_the_grid_fills_the_width_and_ends_every_column_on_one_row () =
  let columns =
    [ [ card (rows_of 3); card (rows_of 2) ]; [ card (rows_of 1) ] ]
  in
  let rows = grid columns in
  (* The left column stacks cards of 5 and 4 rows with one row between them.
     The right card is 3 rows on its own and is stretched to match. *)
  check int "as tall as the tallest column" (5 + 1 + 4) (List.length rows);
  List.iter
    (fun row -> check int "row width" 101 (Layout.display_width row))
    rows;
  match List.rev rows with
  | last :: _ ->
      check int "both columns close on the last row" 2
        (occurrences ~needle:Masc_tui_theme.Box.br last)
  | [] -> fail "the grid drew no rows"

let test_a_card_is_as_tall_as_its_body_and_does_not_fill_the_screen () =
  check int "two body rows and two edges" 4
    (List.length (grid ~inner_width:60 [ [ card (rows_of 2) ] ]))

let test_stacked_cards_are_separated_by_the_row_gap () =
  let stack = [ [ card (rows_of 1); card (rows_of 1) ] ] in
  check int "two cards of three rows and the gap" (3 + 1 + 3)
    (List.length (grid ~inner_width:60 ~row_gap:1 stack));
  check int "no gap" (3 + 3)
    (List.length (grid ~inner_width:60 ~row_gap:0 stack))

(* A grid that needs more rows than it has draws nothing, so the caller falls
   back before any row is put on screen. *)
let test_a_grid_that_does_not_fit_draws_nothing () =
  let columns = [ [ card (rows_of 6) ] ] in
  let drawn max_rows =
    Card.grid ~style:plain ~inner_width:60 ~gap:2 ~row_gap:1 ~max_rows columns
  in
  check bool "one row short" true (Option.is_none (drawn 7));
  match drawn 8 with
  | Some rows -> check int "exactly its height" 8 (List.length rows)
  | None -> fail "a grid with exactly enough rows drew nothing"

(* Each body is asked for the width the layout chose, and only once. *)
let test_each_body_is_asked_once_for_its_layout_width () =
  let inner_width = 101 and gap = 2 in
  let seen = ref [] in
  let probe =
    { Card.title = "probe"
    ; body = (fun ~cells -> seen := cells :: !seen; [ String.make cells 'x' ])
    }
  in
  ignore
    (Card.grid ~style:plain ~inner_width ~gap ~row_gap:0 ~max_rows:max_int
       [ [ probe ]; [ probe ] ]);
  let expected =
    List.map
      (fun width -> Card.content_cells ~width)
      (Card.column_widths ~inner_width ~gap ~columns:2)
  in
  check (list int) "one ask per card, at each column's content width" expected
    (List.rev !seen)

(* The "+N more" row carries style codes into the width fit; styled and cut
   together it still fills exactly the card's width. *)
let test_a_cut_body_with_styled_rows_keeps_the_width () =
  let body = List.init 10 (fun index -> Printf.sprintf "\027[31mrow-%d\027[0m" index) in
  let rows = Card.render ~style:styled ~width:30 ~height:5 (card body) in
  check int "height" 5 (List.length rows);
  List.iter
    (fun row -> check int "row width" 30 (Layout.display_width row))
    rows

let () =
  run "tui card"
    [ ( "geometry"
      , [ test_case "every row is the card's width and there are height rows" `Quick
            test_every_row_is_the_cards_width_and_there_are_height_rows
        ; test_case "a body that fits loses no row" `Quick
            test_a_body_that_fits_loses_no_row
        ; test_case "a title wider than the edge is cut" `Quick
            test_a_title_wider_than_the_edge_is_cut_not_overflowed
        ; test_case "an overflowing body says how many rows it left out" `Quick
            test_an_overflowing_body_says_how_many_rows_it_left_out
        ; test_case "a card with no room is blank rows" `Quick
            test_a_card_with_no_room_is_blank_rows_of_its_width
        ] )
    ; ( "columns"
      , [ test_case "columns and gaps add up to the screen" `Quick
            test_columns_and_gaps_add_up_to_the_screen
        ; test_case "the columns that fit each have the minimum width" `Quick
            test_the_columns_that_fit_each_have_the_minimum_width
        ; test_case "the grid fills the width and ends every column on one row" `Quick
            test_the_grid_fills_the_width_and_ends_every_column_on_one_row
        ; test_case "a card is as tall as its body" `Quick
            test_a_card_is_as_tall_as_its_body_and_does_not_fill_the_screen
        ; test_case "stacked cards are separated by the row gap" `Quick
            test_stacked_cards_are_separated_by_the_row_gap
        ; test_case "a grid that does not fit draws nothing" `Quick
            test_a_grid_that_does_not_fit_draws_nothing
        ; test_case "each body is asked once for its layout width" `Quick
            test_each_body_is_asked_once_for_its_layout_width
        ; test_case "a cut body with styled rows keeps the width" `Quick
            test_a_cut_body_with_styled_rows_keeps_the_width
        ] )
    ]
