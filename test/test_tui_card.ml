(* A card is a rectangle of exactly the cells it was given. These cases pin the
   geometry the screens rely on when they stack cards in a column and set
   columns side by side: every row has the card's width, the card has its
   height, nothing is lost silently, and the columns add up to the screen.

   The edge cases check the decision, not the drawn text: which parts of the
   top edge a width keeps, in the order RFC tui-one-screen-grammar section 2
   gives them up, how many rows a body cuts off, and what the bottom edge
   writes for them at a width. *)

open Alcotest
module Card = Masc_tui_card
module Layout = Masc_tui_message_layout
module Mark = Masc_tui_value.Mark

let plain = { Card.border = ""; focused_border = ""; title_style = ""; reset = "" }

let styled =
  { Card.border = "\027[2m"
  ; focused_border = "\027[96m"
  ; title_style = "\027[1m"
  ; reset = "\027[0m"
  }

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

let edge ?key ?status ?count ?(focus = Card.Unfocused) ?border_accent ?(footer_keys = []) name =
  { Card.name; key; status; count; focus; border_accent; footer_keys }

let card ?(title = "Needs your decision") body =
  { Card.edge = edge title; body = (fun ~cells:_ -> body) }

(* Columns of cards no selection reaches, as a grid takes them. *)
let unselectable columns = List.map (List.map (fun card -> (card, Card.Unselectable))) columns

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
    Card.grid ~ko:true ~style ~inner_width ~gap:2 ~row_gap ~max_rows:max_int
      (unselectable columns)
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

(* A card one row too tall squashes to its top edge rather than taking the
   grid with it. The grid draws nothing only when the squashed card still does
   not fit, or when the card may not squash: the selection can reach it or it
   owns the keyboard. Then the caller falls back before any row is put on
   screen. *)
let test_a_grid_draws_nothing_only_when_squashing_does_not_fit () =
  let drawn ?(focus = Card.Unfocused) ?(selection = Card.Unselectable) max_rows =
    Card.grid ~ko:true ~style:plain ~inner_width:60 ~gap:2 ~row_gap:1 ~max_rows
      [ [ ({ Card.edge = edge ~focus "Tasks"; body = (fun ~cells:_ -> rows_of 6) }, selection) ] ]
  in
  let rows_drawn label expected = function
    | Some rows -> check int label expected (List.length rows)
    | None -> fail (label ^ ": the grid drew nothing")
  in
  rows_drawn "exactly its height" 8 (drawn 8);
  rows_drawn "one row short: squashed to one row" 1 (drawn 7);
  rows_drawn "one row: squashed" 1 (drawn 1);
  check bool "no row at all" true (Option.is_none (drawn 0));
  check bool "the selected row's card does not squash" true
    (Option.is_none (drawn ~selection:Card.Holds_selected_row 7));
  check bool "a card the selection can reach must fit full" true
    (Option.is_none (drawn ~selection:Card.Selectable 7));
  List.iter
    (fun focus ->
       check bool "a focused card does not squash" true (Option.is_none (drawn ~focus 7)))
    [ Card.Focused_list; Card.Focused_other ]

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
       (unselectable [ [ probe ]; [ probe ] ]));
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
  ; ( "a focused list"
    , edge ~focus:Card.Focused_list ~status:(yours "your turn")
        ~count:(Card.Partial { loaded = 50; total = 2000 })
        "Tasks" )
  ; ( "a focused card that is not a list"
    , edge ~focus:Card.Focused_other ~status:(yours "your turn")
        ~count:(Card.Whole 12)
        "Execution capacity" )
  ]

(* Whether an edge has a count it may write: a focused list writes none,
   since zone 2's position counts its rows. *)
let writes_count (edge : Card.edge) =
  match edge.focus with
  | Card.Focused_list -> false
  | Card.Focused_other | Card.Unfocused -> Option.is_some edge.count

let name_fit =
  testable
    (fun formatter -> function
       | Card.Whole_name -> Format.pp_print_string formatter "whole"
       | Card.Shortened_name cells -> Format.fprintf formatter "shortened to %d" cells
       | Card.No_name -> Format.pp_print_string formatter "none")
    ( = )

(* One edge at the widths where it gives up each part: the key first, then the
   name is shortened while the word stays, then the word goes and the name
   takes its room back, then the name goes. The mark and the count stay while
   they fit together; then the count goes and the mark stays until the edge
   has room for nothing. *)
let check_widths ~ko edge rows =
  List.iter
    (fun (width, key, name, word, mark, count) ->
       let fit = Card.top_fit ~ko ~width edge in
       let at what = Printf.sprintf "%s at %d" what width in
       check bool (at "key") key fit.key_kept;
       check name_fit (at "name") name fit.name_kept;
       check bool (at "word") word fit.word_kept;
       check bool (at "mark") mark fit.symbol_kept;
       check bool (at "count") count fit.count_kept)
    rows

let test_the_top_edge_gives_up_its_parts_in_order () =
  check_widths ~ko:false
    (edge ~key:("p", "") ~status:(yours "your turn") ~count:(Card.Whole 3)
       "Needs your decision")
    [ (60, true, Card.Whole_name, true, true, true)
    ; (43, true, Card.Whole_name, true, true, true)
    ; (42, false, Card.Whole_name, true, true, true)
    ; (41, false, Card.Whole_name, true, true, true)
    ; (40, false, Card.Shortened_name 18, true, true, true)
    ; (25, false, Card.Shortened_name 3, true, true, true)
    ; (24, false, Card.Shortened_name 12, false, true, true)
    ; (15, false, Card.Shortened_name 3, false, true, true)
    ; (14, false, Card.No_name, false, true, true)
    ; (11, false, Card.No_name, false, true, true)
    ; (10, false, Card.No_name, false, true, false)
    ; (6, false, Card.No_name, false, true, false)
    ; (5, false, Card.No_name, false, false, false)
    ]

(* A count read in part is wide: [50 · of 2,000] is thirteen cells. Where the
   mark and that count do not fit together the mark stays alone, rather than
   both leaving a bare rule while the mark alone would fit. *)
let test_a_wide_count_goes_before_the_mark () =
  check_widths ~ko:false
    (edge
       ~status:{ Card.symbol = Card.Mark Mark.Waiting; word = "idle"; tone = "" }
       ~count:(Card.Partial { loaded = 50; total = 2000 })
       "Tasks")
    [ (35, false, Card.Whole_name, true, true, true)
    ; (23, false, Card.No_name, false, true, true)
    ; (22, false, Card.No_name, false, true, false)
    ; (6, false, Card.No_name, false, true, false)
    ; (5, false, Card.No_name, false, false, false)
    ];
  (* An edge with a count and no status keeps the count alone to the end. *)
  check_widths ~ko:false
    (edge ~count:(Card.Partial { loaded = 50; total = 2000 }) "Tasks")
    [ (19, false, Card.No_name, false, false, true)
    ; (18, false, Card.No_name, false, false, false)
    ]

(* A focused list writes no count, since zone 2's position counts its rows.
   A focused card that is not a list keeps its count: zone 2 counts
   something else (RFC tui-one-screen-grammar section 2). *)
let test_only_a_focused_list_drops_its_count () =
  let counted focus =
    (Card.top_fit ~ko:true ~width:200
       (edge ~focus ~count:(Card.Whole 12) "Execution capacity"))
      .count_kept
  in
  check bool "unfocused" true (counted Card.Unfocused);
  check bool "a focused list" false (counted Card.Focused_list);
  check bool "a focused card that is not a list" true (counted Card.Focused_other)

(* How far down the RFC's order an edge has gone. With no name, one step for
   each of the mark and the count it no longer keeps. *)
let stage (fit : Card.top_fit) =
  match fit.key_kept, fit.name_kept, fit.word_kept with
  | true, (Card.Whole_name | Card.Shortened_name _ | Card.No_name), (true | false) -> 0
  | false, Card.Whole_name, true -> 1
  | false, Card.Shortened_name _, true -> 2
  | false, (Card.Whole_name | Card.Shortened_name _), false -> 3
  | false, Card.No_name, (true | false) ->
      4 + (if fit.symbol_kept then 0 else 1) + if fit.count_kept then 0 else 1

let name_cells name (fit : Card.top_fit) =
  match fit.name_kept with
  | Card.Whole_name -> Layout.display_width name
  | Card.Shortened_name cells -> cells
  | Card.No_name -> 0

(* At every width and for every mix of parts: a narrower edge is never
   further back in the order; the key leaves only whole things behind it; a
   shortened name keeps its first character and is shorter than the name; the
   mark and the count stay while anything else does; the mark is the last
   part an edge keeps; a focused list has no count. *)
let test_the_order_holds_at_every_width () =
  List.iter
    (fun (label, (edge : Card.edge)) ->
       List.iter
         (fun ko ->
            let fits = List.init 91 (fun width -> (width, Card.top_fit ~ko ~width edge)) in
            let has_symbol = Option.is_some edge.status in
            let has_count = writes_count edge in
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
                 if has_symbol && (fit.count_kept || fit.name_kept <> Card.No_name) then
                   check bool (at "the mark is the last part kept") true fit.symbol_kept;
                 if not has_count then
                   check bool (at "an edge with no count to write keeps none") false
                     fit.count_kept)
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

(* With room to spare an edge keeps every part it has. *)
let test_a_wide_edge_keeps_every_part () =
  List.iter
    (fun (label, (edge : Card.edge)) ->
       List.iter
         (fun ko ->
            let fit = Card.top_fit ~ko ~width:200 edge in
            let at what = Printf.sprintf "%s, %s" label what in
            check bool (at "key") (Option.is_some edge.key) fit.key_kept;
            check name_fit (at "name") Card.Whole_name fit.name_kept;
            check bool (at "word")
              (match edge.status with
               | Some status -> status.word <> ""
               | None -> false)
              fit.word_kept;
            check bool (at "mark") (Option.is_some edge.status) fit.symbol_kept;
            check bool (at "count") (writes_count edge) fit.count_kept)
         [ true; false ])
    edges

(* RFC tui-one-screen-grammar section 2 keeps the status symbol and the count
   to the end, so the name goes before them: an edge that has either keeps it
   at a width too narrow for any of its name. *)
let test_the_name_goes_before_the_mark_and_the_count () =
  List.iter
    (fun (label, (edge : Card.edge)) ->
       if Option.is_some edge.status || writes_count edge then
         List.iter
           (fun ko ->
              let narrowest keeps =
                List.find_opt
                  (fun width -> keeps (Card.top_fit ~ko ~width edge))
                  (List.init 201 Fun.id)
              in
              let name_from =
                narrowest (fun (fit : Card.top_fit) -> fit.name_kept <> Card.No_name)
              and tail_from =
                narrowest (fun (fit : Card.top_fit) -> fit.symbol_kept || fit.count_kept)
              in
              match name_from, tail_from with
              | Some name_from, Some tail_from ->
                  check bool
                    (Printf.sprintf "%s: the mark or the count outlives the name (%d < %d)"
                       label tail_from name_from)
                    true (tail_from < name_from)
              | None, _ | _, None -> fail (label ^ ": no width keeps the name and the tail"))
           [ true; false ])
    edges

(* The border's colour class follows focus. An unfocused card draws its
   border in the caller's border code. A focused card draws it in the
   caller's focused code, the border.focused token, and never in the other
   (RFC tui-one-screen-grammar section 2). The two codes below are ones no
   other part of the card uses, so finding one in a row means that row's
   border carried it. The body overflows, so the bottom edge carries a count
   as well. *)
let test_a_focused_card_borders_in_the_focus_token () =
  let caller_border = "\027[38;5;201m" and focused_border = "\027[38;5;45m" in
  let style =
    { Card.border = caller_border; focused_border; title_style = "\027[1m"; reset = "\027[0m" }
  in
  let drawn focus =
    Card.render ~ko:true ~style ~width:40 ~height:5
      { Card.edge =
          edge ~focus ~status:(yours "your turn") ~count:(Card.Whole 6) "Tasks"
      ; body = (fun ~cells:_ -> List.init 6 string_of_int)
      }
  in
  List.iter
    (fun row ->
       check bool "an unfocused border is in the caller's code" true
         (contains ~needle:caller_border row);
       check bool "an unfocused border carries no focused code" false
         (contains ~needle:focused_border row))
    (drawn Card.Unfocused);
  List.iter
    (fun focus ->
       List.iter
         (fun row ->
            check bool "a focused border carries none of the unfocused code" false
              (contains ~needle:caller_border row);
            check bool "a focused border is in the focused code" true
              (contains ~needle:focused_border row))
         (drawn focus))
    [ Card.Focused_list; Card.Focused_other ]

(* The bottom edge writes the rows a card cut off whole or not at all: the
   word goes first, then the number, and the number is never shortened,
   since a cut number reads as a different one. [외 1,234] is eight cells,
   [1,234 more] ten and [1,234] five; the edge spends six around them. *)
let bottom_fit =
  testable
    (fun formatter fit ->
       Format.pp_print_string formatter
         (match fit with
          | Card.Says_more -> "says more"
          | Card.Number_only -> "number only"
          | Card.Plain -> "plain"))
    ( = )

let test_the_bottom_edge_keeps_the_number_whole () =
  List.iter
    (fun (ko, width, expected) ->
       check bottom_fit
         (Printf.sprintf "%s at %d" (if ko then "ko" else "en") width)
         expected
         (Card.bottom_fit ~ko ~width ~hidden:1234))
    [ (true, 40, Card.Says_more)
    ; (true, 14, Card.Says_more)
    ; (true, 13, Card.Number_only)
    ; (true, 11, Card.Number_only)
    ; (true, 10, Card.Plain)
    ; (false, 16, Card.Says_more)
    ; (false, 15, Card.Number_only)
    ; (false, 11, Card.Number_only)
    ; (false, 10, Card.Plain)
    ];
  List.iter
    (fun width ->
       check bottom_fit (Printf.sprintf "nothing cut at %d" width) Card.Plain
         (Card.bottom_fit ~ko:true ~width ~hidden:0))
    [ 5; 40; 200 ]

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
      (unselectable
         (List.map (fun (_, edge) -> [ { Card.edge; body = (fun ~cells:_ -> [ "a" ]) } ]) edges))
  with
  | None -> fail "grid drew nothing"
  | Some rows ->
    List.iter
      (fun row -> check int "grid row width" 82 (Layout.display_width row))
      rows


(* ---- squashing: which cards a short grid squashes (RFC section 2) ---- *)

let height =
  testable
    (fun formatter shape ->
       Format.pp_print_string formatter
         (match shape with Card.Full -> "full" | Card.Squashed -> "squashed"))
    ( = )

let plan = option (list (list height))

(* A card no key reaches, one the selection can move to, one that holds the
   selected row, and one that owns the keyboard. *)
let may natural = (natural, Card.By_selection Card.Unselectable)
let reach natural = (natural, Card.By_selection Card.Selectable)
let held natural = (natural, Card.By_selection Card.Holds_selected_row)
let keyboard natural = (natural, Card.Owns_keyboard)
let full = Card.Full
let squashed = Card.Squashed

let reachable (_, squash) =
  match squash with
  | Card.By_selection (Card.Holds_selected_row | Card.Selectable) -> true
  | Card.By_selection Card.Unselectable | Card.Owns_keyboard -> false

let holds (_, squash) =
  match squash with
  | Card.By_selection Card.Holds_selected_row -> true
  | Card.By_selection (Card.Selectable | Card.Unselectable) | Card.Owns_keyboard -> false

(* The rows a column takes at the heights chosen for it. *)
let column_rows ~row_gap column shapes =
  let rows =
    List.map2
      (fun (natural, _) shape ->
         match shape with Card.Full -> natural | Card.Squashed -> 1)
      column shapes
  in
  List.fold_left ( + ) 0 rows + (row_gap * max 0 (List.length rows - 1))

let test_a_grid_that_fits_squashes_nothing () =
  List.iter
    (fun (row_gap, columns, max_rows) ->
       let expected = List.map (List.map (fun _ -> full)) columns in
       check plan
         (Printf.sprintf "%d rows" max_rows)
         (Some expected)
         (Card.heights ~row_gap ~max_rows columns))
    [ (1, [ [ may 3; may 3; may 3 ]; [ may 3; may 3 ] ], 11)
    ; (1, [ [ reach 3; held 3; may 3 ]; [ keyboard 3; reach 3 ] ], 11)
    ; (1, [ [ may 3; may 3; may 3 ]; [ may 3; may 3 ] ], 40)
    ; (0, [ [ may 10 ]; [ keyboard 4 ]; [] ], 10)
    ; (1, [], 0)
    ]

(* As the rows run out a column too tall for them gives up its lowest full
   card, and a column that fits gives up nothing. The left column is eleven
   rows and the right seven, one row between cards. *)
let test_a_tall_columns_lowest_card_squashes_first () =
  let columns = [ [ may 3; may 3; may 3 ]; [ may 3; may 3 ] ] in
  List.iter
    (fun (max_rows, expected) ->
       check plan (Printf.sprintf "%d rows" max_rows) expected
         (Card.heights ~row_gap:1 ~max_rows columns))
    [ (10, Some [ [ full; full; squashed ]; [ full; full ] ])
    ; (8, Some [ [ full; squashed; squashed ]; [ full; full ] ])
    ; (6, Some [ [ squashed; squashed; squashed ]; [ full; squashed ] ])
    ; (5, Some [ [ squashed; squashed; squashed ]; [ full; squashed ] ])
    ; (4, None)
    ];
  check plan "the column too tall, not the leftmost"
    (Some [ [ full ]; [ full; squashed ] ])
    (Card.heights ~row_gap:1 ~max_rows:6 [ [ may 3 ]; [ may 3; may 3 ] ])

(* An upper card too tall on its own squashes, and the cards under it open as
   far as they fit, the top one first. Deciding from the bottom would keep the
   bottom card of the second column full and squash the middle one. *)
let test_cards_under_a_card_too_tall_alone_open_top_first () =
  check plan "the short card under the tall one is full"
    (Some [ [ squashed; full ] ])
    (Card.heights ~row_gap:0 ~max_rows:8 [ [ may 10; may 3 ] ]);
  check plan "the middle card opens, the bottom card stays squashed"
    (Some [ [ squashed; full; squashed ] ])
    (Card.heights ~row_gap:0 ~max_rows:7 [ [ may 10; may 4; may 4 ] ])

(* A card that holds the selected row or owns the keyboard stays full: the
   next card up squashes in its place, and when no card is left to squash
   the grid does not fit. *)
let test_a_card_that_stays_full_is_never_squashed () =
  List.iter
    (fun (kind, label) ->
       check plan (label ^ ": the card under it squashes")
         (Some [ [ full; squashed ] ])
         (Card.heights ~row_gap:1 ~max_rows:7 [ [ kind 5; may 4 ] ]);
       check plan (label ^ ": the card over it squashes")
         (Some [ [ squashed; full ] ])
         (Card.heights ~row_gap:1 ~max_rows:7 [ [ may 5; kind 4 ] ]);
       check plan (label ^ ": nothing left to squash") None
         (Card.heights ~row_gap:1 ~max_rows:6 [ [ kind 5; may 4 ] ]))
    [ (held, "the selected row's card"); (keyboard, "the focused card") ]

(* Whether the grid fits does not depend on which card holds the selected
   row (RFC section 2). The column is a card of three rows over one of eight,
   one row between them: with either full and the other squashed it needs
   five or ten rows. *)
let test_the_selection_does_not_decide_whether_the_grid_fits () =
  let at max_rows column = Card.heights ~row_gap:1 ~max_rows [ column ] in
  List.iter
    (fun (label, column) ->
       check bool (label ^ ": nine rows cannot open the tall card") true
         (Option.is_none (at 9 column));
       check bool (label ^ ": ten rows can") true (Option.is_some (at 10 column)))
    [ ("nothing selected", [ reach 3; reach 8 ])
    ; ("the short card selected", [ held 3; reach 8 ])
    ; ("the tall card selected", [ reach 3; held 8 ])
    ];
  check plan "a tall card the selection never reaches squashes"
    (Some [ [ full; squashed ] ])
    (at 9 [ held 3; may 8 ])

(* Every column of up to three cards, each three or six rows tall and of any
   kind, at most one of them holding the selected row, at every row limit up
   to 25 and both row gaps:
   - the chosen heights never pass the limit;
   - a card that holds the selected row or owns the keyboard is full;
   - a column that fits squashes nothing;
   - no squashed card could be full on its own;
   - the column fits exactly when it fits with each card the selection can
     reach full in turn, the focused cards full and the rest squashed;
   - moving the selected row to another card it can reach, or off them all,
     does not change whether the column fits. *)
let test_the_heights_hold_for_every_small_column () =
  let cards = List.concat_map (fun kind -> [ kind 3; kind 6 ]) [ may; reach; held; keyboard ] in
  let rec stacks size =
    if size = 0 then [ [] ]
    else
      []
      :: List.concat_map (fun card -> List.map (fun rest -> card :: rest) (stacks (size - 1))) cards
  in
  let columns =
    List.sort_uniq compare (stacks 3)
    |> List.filter (fun column -> List.length (List.filter holds column) <= 1)
  in
  let fits ~row_gap ~max_rows column shapes = column_rows ~row_gap column shapes <= max_rows in
  let reached column =
    List.concat (List.mapi (fun index card -> if reachable card then [ index ] else []) column)
  in
  (* The column's shapes with the selection on the card at [opened]. *)
  let opened_on opened column =
    List.mapi
      (fun index (_, squash) ->
         match squash with
         | Card.Owns_keyboard -> full
         | Card.By_selection (Card.Holds_selected_row | Card.Selectable) ->
             if Option.equal Int.equal opened (Some index) then full else squashed
         | Card.By_selection Card.Unselectable -> squashed)
      column
  in
  (* The same column with the selected row on the card at [index], or on none. *)
  let moved index column =
    List.mapi
      (fun i ((natural, _) as card) ->
         if not (reachable card) then card
         else if Option.equal Int.equal index (Some i) then held natural
         else reach natural)
      column
  in
  List.iter
    (fun row_gap ->
       List.iter
         (fun column ->
            let all_full = List.map (fun _ -> full) column in
            let every_selection_fits ~max_rows =
              match reached column with
              | [] -> fits ~row_gap ~max_rows column (opened_on None column)
              | indices ->
                  List.for_all
                    (fun index -> fits ~row_gap ~max_rows column (opened_on (Some index) column))
                    indices
            in
            for max_rows = 0 to 25 do
              let at what = Printf.sprintf "%s, gap %d at %d rows" what row_gap max_rows in
              let answer = Card.heights ~row_gap ~max_rows [ column ] in
              check bool (at "fits exactly when every selection fits")
                (every_selection_fits ~max_rows) (Option.is_some answer);
              List.iter
                (fun index ->
                   check bool (at "the selection moved, the answer kept") (Option.is_some answer)
                     (Option.is_some (Card.heights ~row_gap ~max_rows [ moved index column ])))
                (None :: List.map Option.some (reached column));
              match answer with
              | None -> ()
              | Some shapes ->
                  let shapes = List.concat shapes in
                  check bool (at "never past the limit") true (fits ~row_gap ~max_rows column shapes);
                  if fits ~row_gap ~max_rows column all_full then
                    check (list height) (at "a fit squashes nothing") all_full shapes;
                  List.iteri
                    (fun index ((_, squash), shape) ->
                       (match shape, squash with
                        | Card.Squashed, Card.By_selection Card.Holds_selected_row ->
                            fail (at "the selected row's card squashed")
                        | Card.Squashed, Card.Owns_keyboard -> fail (at "the focused card squashed")
                        | Card.Squashed, Card.By_selection (Card.Selectable | Card.Unselectable)
                        | ( Card.Full
                          , ( Card.By_selection
                                (Card.Holds_selected_row | Card.Selectable | Card.Unselectable)
                            | Card.Owns_keyboard ) ) -> ());
                       match shape with
                       | Card.Full -> ()
                       | Card.Squashed ->
                           let opened =
                             List.mapi (fun i shape -> if i = index then full else shape) shapes
                           in
                           check bool (at "a squashed card could not be full") false
                             (fits ~row_gap ~max_rows column opened))
                    (List.combine column shapes)
            done)
         columns)
    [ 0; 1 ]

(* Columns are settled on their own: a grid's heights are each column's
   heights, and the grid fits when every column does. *)
let test_each_column_is_settled_on_its_own () =
  let cards = List.concat_map (fun kind -> [ kind 3; kind 6 ]) [ may; reach; held; keyboard ] in
  let stacks =
    [] :: List.map (fun card -> [ card ]) cards
    @ List.concat_map (fun top -> List.map (fun bottom -> [ top; bottom ]) cards) cards
  in
  List.iter
    (fun row_gap ->
       List.iter
         (fun left ->
            List.iter
              (fun right ->
                 for max_rows = 0 to 14 do
                   let alone column = Card.heights ~row_gap ~max_rows [ column ] in
                   let expected =
                     match alone left, alone right with
                     | Some left, Some right -> Some (left @ right)
                     | None, (Some _ | None) | Some _, None -> None
                   in
                   check plan
                     (Printf.sprintf "gap %d at %d rows" row_gap max_rows)
                     expected
                     (Card.heights ~row_gap ~max_rows [ left; right ])
                 done)
              stacks)
         stacks)
    [ 0; 1 ]

(* A squashed card is one row of its column's width, so its top edge keeps
   what a full card's keeps at that width: the count and the mark stay. The
   unfocused cards here may squash and some do; the focused ones stay full.
   Each squashed edge's fit at its column's width still writes the count it
   has. *)
let test_a_squashed_card_keeps_its_count () =
  let inner_width = 101 and gap = 2 and row_gap = 1 and max_rows = 13 in
  let body = rows_of 4 in
  let columns =
    let rec split = function
      | first :: second :: rest -> (first :: fst (split rest), second :: snd (split rest))
      | [ only ] -> ([ only ], [])
      | [] -> ([], [])
    in
    let left, right = split (List.map snd edges) in
    [ left; right ]
  in
  let widths = Card.column_widths ~inner_width ~gap ~columns:2 in
  let natural = List.length body + 2 in
  let shapes =
    Card.heights ~row_gap ~max_rows
      (List.map (List.map (fun (edge : Card.edge) ->
         ( natural
         , match edge.focus with
           | Card.Unfocused -> Card.By_selection Card.Unselectable
           | Card.Focused_list | Card.Focused_other -> Card.Owns_keyboard )))
         columns)
  in
  (match shapes with
   | None -> fail "the grid squashed nothing it could"
   | Some shapes ->
       List.iter2
         (fun (width, column) column_shapes ->
            List.iter2
              (fun (edge : Card.edge) shape ->
                 match shape with
                 | Card.Full -> ()
                 | Card.Squashed ->
                     List.iter
                       (fun ko ->
                          let fit = Card.top_fit ~ko ~width edge in
                          check bool (edge.name ^ ": the count stays") (writes_count edge)
                            fit.count_kept;
                          check bool (edge.name ^ ": the mark stays")
                            (Option.is_some edge.status) fit.symbol_kept)
                       [ true; false ])
              column column_shapes)
         (List.combine widths columns) shapes;
       check bool "some card squashed" true
         (List.exists (List.exists (fun shape -> shape = Card.Squashed)) shapes));
  match
    Card.grid ~ko:true ~style:styled ~inner_width ~gap ~row_gap ~max_rows
      (unselectable
         (List.map (List.map (fun edge -> { Card.edge; body = (fun ~cells:_ -> body) })) columns))
  with
  | None -> fail "the grid drew nothing"
  | Some rows ->
      check bool "within the row limit" true (List.length rows <= max_rows);
      List.iter
        (fun row -> check int "a squashing grid fills the width" inner_width (Layout.display_width row))
        rows

(* A squashed row draws the parts its top edge's fit keeps. Each part is
   painted in a style code no other part uses, so finding a code in the row
   means that part was drawn; the text is not read. A one-card column given
   one row is the squashed card alone. *)
let test_a_squashed_row_paints_what_its_edge_keeps () =
  let border = "\027[38;5;201m" and title_style = "\027[38;5;202m"
  and key_style = "\027[38;5;203m" and tone = "\027[38;5;204m" in
  let style = { Card.border; focused_border = "\027[38;5;205m"; title_style; reset = "\027[0m" } in
  let marked word = { Card.symbol = Card.Mark Mark.Yours; word; tone } in
  let squashable =
    [ edge ~key:("p", key_style) ~status:(marked "your turn") ~count:(Card.Whole 3)
        "Needs your decision"
    ; edge ~key:("m", key_style) ~status:(marked korean_word)
        ~count:(Card.Partial { loaded = 50; total = 2000 })
        korean_name
    ; edge ~count:(Card.Whole 1234) "Conversations"
    ; edge
        ~status:{ Card.symbol = Card.Unknown Masc_tui_value.Unknown.Unread; word = ""; tone }
        "Scheduler lag"
    ; edge "Memory flow"
    ]
  in
  List.iter
    (fun ko ->
       List.iter
         (fun (edge : Card.edge) ->
            for width = Card.min_width to 60 do
              let at what = Printf.sprintf "%s at %d: %s" edge.name width what in
              match
                Card.grid ~ko ~style ~inner_width:width ~gap:2 ~row_gap:1 ~max_rows:1
                  [ [ ({ Card.edge; body = (fun ~cells:_ -> rows_of 4) }, Card.Unselectable) ] ]
              with
              | Some [ row ] ->
                  let fit = Card.top_fit ~ko ~width edge in
                  let name_kept =
                    match fit.name_kept with
                    | Card.No_name -> false
                    | Card.Whole_name | Card.Shortened_name _ -> true
                  in
                  check bool (at "drawn in the border") true (contains ~needle:border row);
                  check bool (at "the key") fit.key_kept (contains ~needle:key_style row);
                  check bool (at "the name") name_kept (contains ~needle:title_style row);
                  check bool (at "the mark or the word") (fit.symbol_kept || fit.word_kept)
                    (contains ~needle:tone row)
              | Some _ | None -> fail (at "not one squashed row")
            done)
         squashable)
    [ true; false ]

(* A grid that squashes still asks each body once, at its column's width. *)
let test_a_squashing_grid_asks_each_body_once () =
  let seen = ref 0 in
  let probe = { Card.edge = edge "probe"; body = (fun ~cells:_ -> incr seen; rows_of 5) } in
  (match
     Card.grid ~ko:true ~style:plain ~inner_width:101 ~gap:2 ~row_gap:1 ~max_rows:9
       (unselectable [ [ probe; probe ]; [ probe ] ])
   with
   | Some _ -> ()
   | None -> fail "the grid drew nothing");
  check int "one ask per card" 3 !seen

(* Whatever the heights squash, the grid is the rectangle they promise. It
   draws exactly when {!Card.heights} finds a fit, its rows are those of the
   tallest column at the chosen heights, and every row is the grid's width. A
   shorter column ends on the same row whether its lowest card is full,
   squashed or the column has no full card at all. *)
let test_a_squashing_grid_keeps_its_rectangle () =
  let inner_width = 101 and gap = 2 in
  let kinds =
    [ (1, Card.Unselectable)
    ; (4, Card.Unselectable)
    ; (4, Card.Selectable)
    ; (4, Card.Holds_selected_row)
    ]
  in
  let rec stacks size =
    if size = 0 then [ [] ]
    else
      []
      :: List.concat_map
           (fun kind -> List.map (fun rest -> kind :: rest) (stacks (size - 1)))
           kinds
  in
  let lefts = List.sort_uniq compare (stacks 3) in
  let rights = List.sort_uniq compare (stacks 2) in
  let card_of (rows, selection) =
    ( { Card.edge = edge ~count:(Card.Whole rows) "Tasks"; body = (fun ~cells:_ -> rows_of rows) }
    , selection )
  in
  let natural (rows, selection) = (rows + 2, Card.By_selection selection) in
  List.iter
    (fun row_gap ->
       List.iter
         (fun left ->
            List.iter
              (fun right ->
                 let columns = [ left; right ] in
                 let cards = List.map (List.map card_of) columns in
                 let naturals = List.map (List.map natural) columns in
                 for max_rows = 0 to 20 do
                   let at what = Printf.sprintf "%s, gap %d at %d rows" what row_gap max_rows in
                   match
                     ( Card.heights ~row_gap ~max_rows naturals
                     , Card.grid ~ko:true ~style:styled ~inner_width ~gap ~row_gap ~max_rows
                         cards )
                   with
                   | None, None -> ()
                   | None, Some _ -> fail (at "drew a grid the heights do not fit")
                   | Some _, None -> fail (at "drew nothing for heights that fit")
                   | Some shapes, Some rows ->
                       let tallest =
                         List.fold_left max 0
                           (List.map2 (column_rows ~row_gap) naturals shapes)
                       in
                       check int (at "as tall as the tallest column") tallest
                         (List.length rows);
                       if
                         not
                           (List.for_all
                              (fun row -> Layout.display_width row = inner_width)
                              rows)
                       then fail (at "a row is not the grid's width")
                 done)
              rights)
         lefts)
    [ 0; 1 ]

let scrollbar_cell_t =
  testable
    (fun fmt cell ->
       Format.pp_print_string fmt
         (match cell with
          | Card.Track -> "Track"
          | Card.Thumb -> "Thumb"
          | Card.Arrow_up -> "Arrow_up"
          | Card.Arrow_down -> "Arrow_down"))
    ( = )

(* Focus stays distinguishable without colour: focused cards switch to heavy
   border glyphs while preserving the exact cell geometry. *)
let test_focused_card_uses_distinct_border_glyphs_without_colour () =
  let unfocused =
    Card.render ~ko:true ~style:plain ~width:24 ~height:4
      { Card.edge = edge ~focus:Card.Unfocused "Title"; body = (fun ~cells:_ -> [ "a" ]) }
  in
  List.iter
    (fun focus ->
       let focused =
         Card.render ~ko:true ~style:plain ~width:24 ~height:4
           { Card.edge = edge ~focus "Title"; body = (fun ~cells:_ -> [ "a" ]) }
       in
       check bool "focused differs from unfocused even without SGR" true
         (focused <> unfocused);
       List.iter
         (fun row -> check int "focused row width" 24 (Layout.display_width row))
         focused)
    [ Card.Focused_list; Card.Focused_other ]

let test_scrollbar_cells_decisions () =
  check (option (list scrollbar_cell_t)) "fits: no scrollbar" None
    (Card.scrollbar_cells ~rows:6 { Card.offset = 0; visible = 6; total = 6 });
  check (option (list scrollbar_cell_t)) "non-positive rows: no scrollbar" None
    (Card.scrollbar_cells ~rows:0 { Card.offset = 0; visible = 5; total = 20 });
  check (option (list scrollbar_cell_t)) "top of scrollable body"
    (Some [ Card.Arrow_up; Card.Thumb; Card.Track; Card.Track; Card.Track; Card.Arrow_down ])
    (Card.scrollbar_cells ~rows:6 { Card.offset = 0; visible = 5; total = 20 });
  check (option (list scrollbar_cell_t)) "bottom of scrollable body"
    (Some [ Card.Arrow_up; Card.Track; Card.Track; Card.Track; Card.Thumb; Card.Arrow_down ])
    (Card.scrollbar_cells ~rows:6 { Card.offset = 999; visible = 5; total = 20 });
  check (option (list scrollbar_cell_t)) "compact 2-row track omits arrows"
    (Some [ Card.Thumb; Card.Track ])
    (Card.scrollbar_cells ~rows:2 { Card.offset = 0; visible = 2; total = 10 });
  check (option (list scrollbar_cell_t)) "high-ratio overflow keeps at least one track cell so thumb moves"
    (Some [ Card.Arrow_up; Card.Track; Card.Thumb; Card.Arrow_down ])
    (Card.scrollbar_cells ~rows:4 { Card.offset = 4; visible = 6; total = 10 });
  check (option (list scrollbar_cell_t)) "negative offset clamps to top"
    (Some [ Card.Arrow_up; Card.Thumb; Card.Track; Card.Arrow_down ])
    (Card.scrollbar_cells ~rows:4 { Card.offset = -5; visible = 6; total = 10 });
  let rows =
    Card.render ~scrollbar:{ Card.offset = 3; visible = 4; total = 12 }
      ~ko:true ~style:styled ~width:28 ~height:6 (card [ "a"; "b"; "c"; "d" ])
  in
  check int "scrollable card height" 6 (List.length rows);
  List.iter (fun row -> check int "scrollable card row width" 28 (Layout.display_width row)) rows

let test_border_accent_applies_only_when_unfocused () =
  let accent = "\027[38;5;108m" in
  let unfocused =
    Card.render ~ko:true ~style:styled ~width:24 ~height:4
      { Card.edge = edge ~border_accent:accent ~focus:Card.Unfocused "Fleet"
      ; body = (fun ~cells:_ -> [ "ok" ]) }
  in
  List.iter
    (fun row ->
       check bool "unfocused card uses its border_accent" true (contains ~needle:accent row);
       check int "unfocused accented row width" 24 (Layout.display_width row))
    unfocused;
  let focused =
    Card.render ~ko:true ~style:styled ~width:24 ~height:4
      { Card.edge = edge ~border_accent:accent ~focus:Card.Focused_other "Fleet"
      ; body = (fun ~cells:_ -> [ "ok" ]) }
  in
  List.iter
    (fun row ->
       check bool "focused card keeps focused_border over border_accent" true
         (contains ~needle:styled.focused_border row);
       check bool "focused card drops unfocused border_accent" false
         (contains ~needle:accent row))
    focused
let test_footer_keys_and_superscript_digit () =
  check (option string) "superscript 1" (Some "\xc2\xb9") (Card.superscript_digit 1);
  check (option string) "superscript 4" (Some "\xe2\x81\xb4") (Card.superscript_digit 4);
  check (option string) "superscript out of range" None (Card.superscript_digit 0);
  check (option string) "superscript 10 out of range" None (Card.superscript_digit 10);
  let footer_keys =
    [ { Card.key = "p"; label = "work" }
    ; { Card.key = "Enter"; label = "open" }
    ]
  in
  List.iter
    (fun (width, body) ->
       let rows =
         Card.render ~ko:true ~style:styled ~width ~height:4
           { Card.edge = edge ~footer_keys "Title"
           ; body = (fun ~cells:_ -> body) }
       in
       List.iter
         (fun row ->
            check int (Printf.sprintf "footer_keys row width at %d" width)
              width (Layout.display_width row))
         rows)
    [ (5, [ "a" ])
    ; (10, [ "a"; "b" ])
    ; (16, [ "a"; "b" ])
    ; (16, [ "a"; "b"; "c"; "d" ])
    ; (24, [ "a"; "b" ])
    ; (24, [ "a"; "b"; "c"; "d" ])
    ; (36, [ "a"; "b"; "c"; "d" ])
    ; (60, [ "a"; "b"; "c"; "d" ])
    ]
let test_accented_card_keeps_text_contrast_on_edge_meta_and_footer_keys () =
  let accent = "\027[38;5;108m" in
  let footer_keys = [ { Card.key = "m"; label = "Usage" } ] in
  let rows =
    Card.render ~ko:true ~style:styled ~width:34 ~height:4
      { Card.edge =
          edge ~count:(Card.Whole 7) ~border_accent:accent ~footer_keys
            ~focus:Card.Unfocused "Fleet"
      ; body = (fun ~cells:_ -> [ "row 1"; "row 2"; "row 3" ]) }
  in
  let top = List.hd rows in
  let bottom = List.hd (List.rev rows) in
  check bool "top border uses border_accent" true (contains ~needle:accent top);
  check bool "top count uses text-grade style.border, not 3:1 accent" true
    (contains ~needle:(styled.border ^ "7" ^ styled.reset) top);
  check bool "bottom border uses border_accent" true (contains ~needle:accent bottom);
  check bool "footer key label uses text-grade style.border" true
    (contains ~needle:(styled.border ^ "Usage" ^ styled.reset) bottom);
  check bool "footer key atom is not bolded with title_style" false
    (contains ~needle:(styled.title_style ^ "m") bottom);
  check bool "overflow count uses text-grade style.border" true
    (contains ~needle:(styled.border ^ "외 1" ^ styled.reset) bottom)

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
        ; test_case "a wide edge keeps every part" `Quick
            test_a_wide_edge_keeps_every_part
        ; test_case "the name goes before the mark and the count" `Quick
            test_the_name_goes_before_the_mark_and_the_count
        ; test_case "a wide count goes before the mark" `Quick
            test_a_wide_count_goes_before_the_mark
        ; test_case "only a focused list drops its count" `Quick
            test_only_a_focused_list_drops_its_count
        ; test_case "a focused card borders in the focus token" `Quick
            test_a_focused_card_borders_in_the_focus_token
        ; test_case "a focused card uses distinct border glyphs without colour" `Quick
            test_focused_card_uses_distinct_border_glyphs_without_colour
        ; test_case "scrollbar cells and scrollable card geometry" `Quick
            test_scrollbar_cells_decisions
        ; test_case "a border_accent applies when unfocused and yields to focus" `Quick
            test_border_accent_applies_only_when_unfocused
        ] )
    ; ( "bottom edge"
      , [ test_case "the bottom edge keeps the number whole" `Quick
            test_the_bottom_edge_keeps_the_number_whole
        ; test_case "footer_keys and superscript_digit keep width invariants" `Quick
            test_footer_keys_and_superscript_digit
        ; test_case "accented card keeps text contrast on edge meta and footer keys" `Quick
            test_accented_card_keeps_text_contrast_on_edge_meta_and_footer_keys
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
        ; test_case "a grid draws nothing only when squashing does not fit" `Quick
            test_a_grid_draws_nothing_only_when_squashing_does_not_fit
        ; test_case "each body is asked once for its layout width" `Quick
            test_each_body_is_asked_once_for_its_layout_width
        ; test_case "a cut body with styled rows keeps the width" `Quick
            test_a_cut_body_with_styled_rows_keeps_the_width
        ] )
    ; ( "squashing"
      , [ test_case "a grid that fits squashes nothing" `Quick
            test_a_grid_that_fits_squashes_nothing
        ; test_case "a tall column's lowest card squashes first" `Quick
            test_a_tall_columns_lowest_card_squashes_first
        ; test_case "cards under a card too tall alone open top first" `Quick
            test_cards_under_a_card_too_tall_alone_open_top_first
        ; test_case "a card that stays full is never squashed" `Quick
            test_a_card_that_stays_full_is_never_squashed
        ; test_case "the selection does not decide whether the grid fits" `Quick
            test_the_selection_does_not_decide_whether_the_grid_fits
        ; test_case "the heights hold for every small column" `Quick
            test_the_heights_hold_for_every_small_column
        ; test_case "each column is settled on its own" `Quick
            test_each_column_is_settled_on_its_own
        ; test_case "a squashed card keeps its count" `Quick
            test_a_squashed_card_keeps_its_count
        ; test_case "a squashed row paints what its edge keeps" `Quick
            test_a_squashed_row_paints_what_its_edge_keeps
        ; test_case "a squashing grid asks each body once" `Quick
            test_a_squashing_grid_asks_each_body_once
        ; test_case "a squashing grid keeps its rectangle" `Quick
            test_a_squashing_grid_keeps_its_rectangle
        ] )
    ]
