(* The window a listing draws, cut from the list it holds.

   The shape being pinned is the one the drawing loops on. Rows are named by
   their index in the whole list, because that is the number the listings
   already had: the same [idx] that marks the cursor row and goes into the
   row's own label is the one that reads the row. A window that answered on
   its own 0-based positions would have made adopting it a rewrite of the
   arithmetic around every loop rather than a change to the lookup. *)

let check = Alcotest.check
let int = Alcotest.int
let str_opt = Alcotest.(option string)

let rows n = List.init n (fun i -> Printf.sprintf "row-%d" i)

let test_rows_answer_at_their_place_in_the_whole_list () =
  let w = Masc_tui_rows.of_list ~first:3 ~height:2 (rows 10) in
  check int "two rows" 2 (Masc_tui_rows.length w);
  check str_opt "the first drawn row keeps its own index" (Some "row-3")
    (Masc_tui_rows.at w 3);
  check str_opt "and the next follows it" (Some "row-4")
    (Masc_tui_rows.at w 4);
  check str_opt "above the window is not the first row" None
    (Masc_tui_rows.at w 2);
  check str_opt "below the window is not the last" None
    (Masc_tui_rows.at w 5)

(* The listings ask for a full window whatever the list holds, and draw a
   blank where the list has run out. *)
let test_a_short_list_leaves_the_window_short () =
  let w = Masc_tui_rows.of_list ~first:8 ~height:5 (rows 10) in
  check int "only what is left" 2 (Masc_tui_rows.length w);
  check str_opt "the last row" (Some "row-9") (Masc_tui_rows.at w 9);
  check str_opt "past the end is a blank row" None (Masc_tui_rows.at w 10);
  check str_opt "and so is far past it" None (Masc_tui_rows.at w 99)

let test_a_first_row_past_the_end_draws_nothing () =
  let w = Masc_tui_rows.of_list ~first:40 ~height:5 (rows 10) in
  check int "no rows" 0 (Masc_tui_rows.length w);
  check str_opt "and none to read" None (Masc_tui_rows.at w 40);
  check str_opt "nor anywhere else" None (Masc_tui_rows.at w 0)

(* Both are read off state a keypress moved, so both can arrive negative
   before a clamp; neither may index backwards into the list. *)
let test_the_edges_of_the_arguments () =
  let w = Masc_tui_rows.of_list ~first:(-5) ~height:2 (rows 10) in
  check str_opt "a negative first reads as the top" (Some "row-0")
    (Masc_tui_rows.at w 0);
  check str_opt "and a negative index is still not a row" None
    (Masc_tui_rows.at w (-1));
  check int "a negative height draws nothing" 0
    (Masc_tui_rows.length (Masc_tui_rows.of_list ~first:0 ~height:(-1) (rows 10)));
  check int "a zero height draws nothing" 0
    (Masc_tui_rows.length (Masc_tui_rows.of_list ~first:0 ~height:0 (rows 10)));
  check int "an empty list draws nothing" 0
    (Masc_tui_rows.length (Masc_tui_rows.of_list ~first:0 ~height:5 []))

(* Deep in a long list, which is the case the module exists for and the one
   an off-by-one in the walk would show up in first. That the walk stops at
   the window rather than running the list out is a structural fact -- no
   [List.length], no second traversal -- and is pinned where the other facts
   the compiler cannot hold are, in test_tui_row_wiring. *)
let test_a_window_deep_in_a_long_list () =
  let w = Masc_tui_rows.of_list ~first:20_000 ~height:3 (rows 21_158) in
  check int "a full window" 3 (Masc_tui_rows.length w);
  check str_opt "at the first row asked for" (Some "row-20000")
    (Masc_tui_rows.at w 20_000);
  check str_opt "and in order" (Some "row-20002") (Masc_tui_rows.at w 20_002);
  let last = Masc_tui_rows.of_list ~first:21_157 ~height:3 (rows 21_158) in
  check int "the last row alone" 1 (Masc_tui_rows.length last);
  check str_opt "is the last one" (Some "row-21157")
    (Masc_tui_rows.at last 21_157)

(* A surface that already holds its rows in an array reads them through the
   same [at], so the whole array is the window. The Code diff pane is the
   caller: it resolves a drawn row's colouring by that row's line number in
   the file, which is scattered rather than a run.

   The line number arrives off the wire as an optional integer with no lower
   bound, so [index - 1] can be negative -- and [List.nth_opt], which this
   replaced, raises [Invalid_argument] on a negative index rather than
   answering [None]. That was a crash inside the drawing loop. *)
let test_the_whole_array_is_a_window () =
  let w = Masc_tui_rows.of_array [| "row-0"; "row-1"; "row-2" |] in
  check int "every row" 3 (Masc_tui_rows.length w);
  check str_opt "the first" (Some "row-0") (Masc_tui_rows.at w 0);
  check str_opt "the last" (Some "row-2") (Masc_tui_rows.at w 2);
  check str_opt "past the end is a blank row" None (Masc_tui_rows.at w 3);
  check str_opt "and a negative index answers rather than raising" None
    (Masc_tui_rows.at w (-1));
  check int "an empty array holds nothing" 0
    (Masc_tui_rows.length (Masc_tui_rows.of_array [||]));
  check str_opt "and reads as blank" None
    (Masc_tui_rows.at (Masc_tui_rows.of_array [||]) 0)

let () =
  Alcotest.run "tui_rows"
    [ ( "window"
      , [ Alcotest.test_case "rows answer at their place in the list" `Quick
            test_rows_answer_at_their_place_in_the_whole_list
        ; Alcotest.test_case "a short list leaves it short" `Quick
            test_a_short_list_leaves_the_window_short
        ; Alcotest.test_case "a first row past the end draws nothing" `Quick
            test_a_first_row_past_the_end_draws_nothing
        ] )
    ; ( "arguments"
      , [ Alcotest.test_case "the edges of the arguments" `Quick
            test_the_edges_of_the_arguments
        ] )
    ; ( "array"
      , [ Alcotest.test_case "the whole array is a window" `Quick
            test_the_whole_array_is_a_window
        ] )
    ; ( "depth"
      , [ Alcotest.test_case "a window deep in a long list" `Quick
            test_a_window_deep_in_a_long_list
        ] )
    ]
