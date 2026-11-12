(* The row that says where a screen is takes its steps from strings the
   server sent. Whatever a step holds, no byte of it may reach the terminal
   as a control: a newline would split the row and an escape would be obeyed. *)

let contains ~needle text =
  let n = String.length needle and t = String.length text in
  let rec at index =
    index + n <= t && (String.equal (String.sub text index n) needle || at (index + 1))
  in
  n = 0 || at 0

let row path =
  let state = Masc_tui_types.create_state ~workspace:"here-row" ~port:0 () in
  Masc_tui_render_prim.here_row ~cols:120 state ~path ~readings:[] ~position:None

let hostile = "keeper\nsecond row\027[2Jcleared"

let check_printable label path =
  let drawn = row path in
  Alcotest.(check bool) (label ^ ": no line break") false (String.contains drawn '\n');
  Alcotest.(check bool) (label ^ ": no erase sequence") false
    (contains ~needle:"\027[2J" drawn)

let test_a_step_ahead_of_the_last_is_made_printable () =
  check_printable "first of two" [ hostile; "calls" ];
  check_printable "middle of three" [ "runs"; hostile; "detail" ]

let test_the_last_step_is_made_printable () =
  check_printable "only step" [ hostile ];
  check_printable "last of two" [ "logs"; hostile ]

let () =
  Alcotest.run "here row steps"
    [ ( "printable",
        [ Alcotest.test_case "a step ahead of the last" `Quick
            test_a_step_ahead_of_the_last_is_made_printable
        ; Alcotest.test_case "the last step" `Quick
            test_the_last_step_is_made_printable
        ] )
    ]
