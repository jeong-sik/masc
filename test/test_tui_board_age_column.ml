open Masc_tui_types
let every_sort =
  [ Board_hot; Board_trending; Board_recent; Board_updated; Board_discussed ]

(* The list is drawn in the order the server returned, so the column beside it
   is only a reading of that order when it holds the time the order was made
   from. Four of the five orders rank or break ties on the moment the post
   appeared; only [updated] ranks on the last move. *)
let test_each_sort_names_the_time_it_ordered_by () =
  let time_of sort =
    match board_sort_time sort with
    | Board_time_posted -> "posted"
    | Board_time_changed -> "changed"
  in
  Alcotest.(check string) "hot breaks ties on the posting" "posted"
    (time_of Board_hot);
  Alcotest.(check string) "trending divides by the posting age" "posted"
    (time_of Board_trending);
  Alcotest.(check string) "recent is newest post first" "posted"
    (time_of Board_recent);
  Alcotest.(check string) "updated is latest changed first" "changed"
    (time_of Board_updated);
  Alcotest.(check string) "discussed breaks ties on the posting" "posted"
    (time_of Board_discussed)

let () =
  Alcotest.run "masc_tui_board_age_column"
    [ ( "board age column"
      , [ Alcotest.test_case "each sort names the time it ordered by" `Quick
            test_each_sort_names_the_time_it_ordered_by
        ;] )
    ]
