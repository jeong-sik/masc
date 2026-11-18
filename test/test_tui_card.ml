(* A card is a rectangle of exactly the cells it was given. These cases pin the
   geometry the screens rely on when they stack cards in a column and set
   columns side by side: every row has the card's width, the card has its
   height, nothing is lost silently, and the columns add up to the screen.

   The edge cases check the decision, not the drawn text: which parts of the
   top edge a width keeps, in the order RFC tui-one-screen-grammar section 2
   gives them up, and how many rows a body cuts off. *)

open Alcotest
module Card = Masc_tui_card
module Layout = Masc_tui_message_layout
module Mark = Masc_tui_value.Mark

let plain = { Card.border = ""; title_style = ""; reset = "" }

let styled =
  { Card.border = "\027[2m"; title_style = "\027[1m"; reset = "\027[0m" }

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

let edge ?key ?status ?count ?(focus = Card.Unfocused) name =
  { Card.name; key; status; count; focus }

let card ?(title = "Needs your decision") body =
  { Card.edge = edge title; body = (fun ~cells:_ -> body) }

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
                 let rows = Card.render ~ko:true ~style ~width ~height (card body) in
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
  let joined =
    String.concat "\n" (Card.render ~ko:true ~style:plain ~width:30 ~height:8 (card body))
  in
  List.iter
    (fun row -> check bool (row ^ " is shown") true (contains ~needle:row joined))
    body

let test_a_title_wider_than_the_edge_is_cut_not_overflowed () =
  let title = String.make 100 't' in
  let rows = Card.render ~ko:true ~style:plain ~width:24 ~height:4 (card ~title [ "x" ]) in
  List.iter
    (fun row -> check int "row width" 24 (Layout.display_width row))
    rows

(* An overflowing body keeps its head in every body row, and the number it
   cut off is the rest: the bottom edge says it, so no body row is spent on
   it. The count is the one thing a reader cannot get back from the screen. *)
let test_an_overflowing_body_keeps_its_head_and_counts_the_rest () =
  let body = List.init 10 (fun index -> index) in
  List.iter
    (fun (rows, shown, hidden) ->
       let kept, cut = Card.window ~rows body in
       check (list int) (Printf.sprintf "%d rows show the head" rows) shown kept;
       check int (Printf.sprintf "%d rows cut the rest" rows) hidden cut)
    [ (4, [ 0; 1; 2; 3 ], 6)
    ; (10, body, 0)
    ; (12, body, 0)
    ; (0, [], 10)
    ; (-1, [], 10)
    ]

let test_a_card_with_no_room_is_blank_rows_of_its_width () =
  List.iter
    (fun (width, height) ->
       let rows = Card.render ~ko:true ~style:plain ~width ~height (card [ "x" ]) in
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
    Card.grid ~ko:true ~style ~inner_width ~gap:2 ~row_gap ~max_rows:max_int columns
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
        (occurrences ~needle:Masc_tui_theme.Box.br_round last)
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
    Card.grid ~ko:true ~style:plain ~inner_width:60 ~gap:2 ~row_gap:1 ~max_rows columns
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
    { Card.edge = edge "probe"
    ; body = (fun ~cells -> seen := cells :: !seen; [ String.make cells 'x' ])
    }
  in
  ignore
    (Card.grid ~ko:true ~style:plain ~inner_width ~gap ~row_gap:0 ~max_rows:max_int
       [ [ probe ]; [ probe ] ]);
  let expected =
    List.map
      (fun width -> Card.content_cells ~width)
      (Card.column_widths ~inner_width ~gap ~columns:2)
  in
  check (list int) "one ask per card, at each column's content width" expected
    (List.rev !seen)

(* A cut body writes its count into the styled bottom edge; styled and cut
   together the card still fills exactly its width, at every width down to the
   narrowest card and in both languages. *)
let test_a_cut_body_with_styled_rows_keeps_the_width () =
  let body = List.init 1234 (fun index -> Printf.sprintf "\027[31mrow-%d\027[0m" index) in
  List.iter
    (fun ko ->
       List.iter
         (fun width ->
            let rows = Card.render ~ko ~style:styled ~width ~height:5 (card body) in
            check int "height" 5 (List.length rows);
            List.iter
              (fun row ->
                 check int (Printf.sprintf "row width at %d" width) width
                   (Layout.display_width row))
              rows)
         (List.init 40 (fun index -> Card.min_width + index)))
    [ true; false ]

(* The Korean name and word below, as escapes: "확인할 일 및 실행 여력" and
   "사람 차례". *)
let korean_name =
  "\xed\x99\x95\xec\x9d\xb8\xed\x95\xa0 \xec\x9d\xbc \xeb\xb0\x8f \xec\x8b\xa4\xed\x96\x89 \xec\x97\xac\xeb\xa0\xa5"

let korean_word = "\xec\x82\xac\xeb\x9e\x8c \xec\xb0\xa8\xeb\xa1\x80"

let yours word = { Card.symbol = Card.Mark Mark.Yours; word; tone = "" }

(* Edges with every mix of parts, so the decision is checked where a part is
   missing as well as where all are there. *)
let edges =
  [ ( "every part"
    , edge ~key:("p", "") ~status:(yours "your turn") ~count:(Card.Whole 3)
        "Needs your decision" )
  ; ( "korean, a partial count"
    , edge ~key:("m", "\027[1;36m") ~status:(yours korean_word)
        ~count:(Card.Partial { loaded = 50; total = 2000 })
        korean_name )
  ; ("name and count", edge ~count:(Card.Whole 1234) "Conversations")
  ; ( "an unread status with no word"
    , edge
        ~status:{ Card.symbol = Card.Unknown Masc_tui_value.Unknown.Unread; word = ""; tone = "" }
        "Scheduler lag" )
  ; ("name alone", edge "Memory flow")
  ; ( "focused"
    , edge ~focus:Card.Focused ~status:(yours "your turn")
        ~count:(Card.Partial { loaded = 50; total = 2000 })
        "Tasks" )
  ]

let name_fit =
  testable
    (fun formatter -> function
       | Card.Whole_name -> Format.pp_print_string formatter "whole"
       | Card.Shortened_name cells -> Format.fprintf formatter "shortened to %d" cells
       | Card.No_name -> Format.pp_print_string formatter "none")
    ( = )

(* One edge at the widths where it gives up each part: the key first, then the
   name is shortened while the word stays, then the word goes and the name
   takes its room back, then the name goes. The mark and the count stay until
   the edge has room for nothing else. *)
let test_the_top_edge_gives_up_its_parts_in_order () =
  let every_part =
    edge ~key:("p", "") ~status:(yours "your turn") ~count:(Card.Whole 3)
      "Needs your decision"
  in
  List.iter
    (fun (width, key, name, word, mark_and_count) ->
       let fit = Card.top_fit ~ko:false ~width every_part in
       let at what = Printf.sprintf "%s at %d" what width in
       check bool (at "key") key fit.key_kept;
       check name_fit (at "name") name fit.name_kept;
       check bool (at "word") word fit.word_kept;
       check bool (at "mark") mark_and_count fit.symbol_kept;
       check bool (at "count") mark_and_count fit.count_kept)
    [ (60, true, Card.Whole_name, true, true)
    ; (43, true, Card.Whole_name, true, true)
    ; (42, false, Card.Whole_name, true, true)
    ; (41, false, Card.Whole_name, true, true)
    ; (40, false, Card.Shortened_name 18, true, true)
    ; (25, false, Card.Shortened_name 3, true, true)
    ; (24, false, Card.Shortened_name 12, false, true)
    ; (15, false, Card.Shortened_name 3, false, true)
    ; (14, false, Card.No_name, false, true)
    ; (11, false, Card.No_name, false, true)
    ; (10, false, Card.No_name, false, false)
    ]

(* How far down the RFC's order an edge has gone. *)
let stage (fit : Card.top_fit) =
  match fit.key_kept, fit.name_kept, fit.word_kept with
  | true, (Card.Whole_name | Card.Shortened_name _ | Card.No_name), (true | false) -> 0
  | false, Card.Whole_name, true -> 1
  | false, Card.Shortened_name _, true -> 2
  | false, (Card.Whole_name | Card.Shortened_name _), false -> 3
  | false, Card.No_name, (true | false) ->
      if fit.symbol_kept || fit.count_kept then 4 else 5

let name_cells name (fit : Card.top_fit) =
  match fit.name_kept with
  | Card.Whole_name -> Layout.display_width name
  | Card.Shortened_name cells -> cells
  | Card.No_name -> 0

(* At every width and for every mix of parts: a narrower edge is never
   further back in the order; the key leaves only whole things behind it; a
   shortened name keeps its first character and is shorter than the name; the
   mark and the count stay while anything else does; a focused card has no
   count. *)
let test_the_order_holds_at_every_width () =
  List.iter
    (fun (label, (edge : Card.edge)) ->
       List.iter
         (fun ko ->
            let fits = List.init 91 (fun width -> (width, Card.top_fit ~ko ~width edge)) in
            let has_symbol = Option.is_some edge.status in
            let has_count =
              Option.is_some edge.count && edge.focus = Card.Unfocused
            in
            List.iter
              (fun (width, (fit : Card.top_fit)) ->
                 let at what = Printf.sprintf "%s, %s at %d" label what width in
                 if fit.key_kept then
                   check name_fit (at "the key leaves the name whole") Card.Whole_name
                     fit.name_kept;
                 (match fit.name_kept with
                  | Card.Shortened_name cells ->
                      check bool (at "a shortened name keeps its first character") true
                        (cells >= 3);
                      check bool (at "a shortened name is shorter") true
                        (cells < Layout.display_width edge.name)
                  | Card.Whole_name | Card.No_name -> ());
                 if fit.key_kept || fit.word_kept || fit.name_kept <> Card.No_name then begin
                   check bool (at "the mark stays") has_symbol fit.symbol_kept;
                   check bool (at "the count stays") has_count fit.count_kept
                 end;
                 if edge.focus = Card.Focused then
                   check bool (at "a focused card has no count") false fit.count_kept)
              fits;
            List.iter2
              (fun (width, wider) (_, narrower) ->
                 let at what = Printf.sprintf "%s, %s from %d" label what width in
                 check bool (at "a narrower edge is not further forward") true
                   (stage narrower >= stage wider);
                 if stage narrower = stage wider then
                   check bool (at "within a stage the name does not grow") true
                     (name_cells edge.name narrower <= name_cells edge.name wider))
              (List.tl fits |> List.rev)
              (List.rev fits |> List.tl))
         [ true; false ])
    edges

(* Every row of a card with every kind of edge is the card's width, focused or
   not, at every width down to the narrowest card. *)
let test_every_edge_keeps_the_cards_width () =
  List.iter
    (fun (label, edge) ->
       List.iter
         (fun ko ->
            List.iter
              (fun width ->
                 let rows =
                   Card.render ~ko ~style:styled ~width ~height:4
                     { Card.edge; body = (fun ~cells:_ -> [ "alpha"; "beta"; "gamma" ]) }
                 in
                 check int (label ^ ": height") 4 (List.length rows);
                 List.iter
                   (fun row ->
                      check int (Printf.sprintf "%s: width at %d" label width) width
                        (Layout.display_width row))
                   rows)
              (List.init 80 (fun index -> Card.min_width + index)))
         [ true; false ])
    edges;
  match
    Card.grid ~ko:true ~style:styled ~inner_width:82 ~gap:2 ~row_gap:1
      ~max_rows:max_int
      (List.map (fun (_, edge) -> [ { Card.edge; body = (fun ~cells:_ -> [ "a" ]) } ]) edges)
  with
  | None -> fail "grid drew nothing"
  | Some rows ->
    List.iter
      (fun row -> check int "grid row width" 82 (Layout.display_width row))
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
        ; test_case "an overflowing body keeps its head and counts the rest" `Quick
            test_an_overflowing_body_keeps_its_head_and_counts_the_rest
        ; test_case "a card with no room is blank rows" `Quick
            test_a_card_with_no_room_is_blank_rows_of_its_width
        ; test_case "every edge keeps the card's width" `Quick
            test_every_edge_keeps_the_cards_width
        ] )
    ; ( "top edge"
      , [ test_case "the top edge gives up its parts in order" `Quick
            test_the_top_edge_gives_up_its_parts_in_order
        ; test_case "the order holds at every width" `Quick
            test_the_order_holds_at_every_width
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
