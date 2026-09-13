(* The Board's posts are a plain list, so an empty one cannot say whether a
   list request has answered. The title said "(0)" before the first answer and
   after a first read that failed, the same as for a board with nothing on it.
   The reading is kept beside the list, and these pin how the page is told
   apart from it. *)

open Masc_tui_types

let state () = create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()

let page_name = function
  | Page_unread -> "unread"
  | Page_failed -> "failed"
  | Page_empty -> "empty"

let check_page name expected actual =
  Alcotest.(check string) name (page_name expected) (page_name actual)

let test_a_fresh_board_has_not_been_read () =
  let fresh = state () in
  check_page "nothing has answered yet" Page_unread
    (board_list_page fresh ~error:None)

let test_a_failed_first_read_is_not_an_empty_board () =
  let failed = state () in
  check_page "a first read that failed" Page_failed
    (board_list_page failed ~error:(Some "connect failed"))

let test_an_answered_board_with_no_posts_is_empty () =
  let answered = state () in
  answered.board_list_reading <- Board_list_read;
  check_page "an answer with no posts" Page_empty
    (board_list_page answered ~error:None);
  check_page "and a refresh that fails after it" Page_failed
    (board_list_page answered ~error:(Some "connect failed"))

let () =
  Alcotest.run "tui_board_list_reading"
    [ ( "page"
      , [ Alcotest.test_case "a fresh board has not been read" `Quick
            test_a_fresh_board_has_not_been_read
        ; Alcotest.test_case "a failed first read is not an empty board" `Quick
            test_a_failed_first_read_is_not_an_empty_board
        ; Alcotest.test_case "an answered board with no posts is empty" `Quick
            test_an_answered_board_with_no_posts_is_empty
        ] )
    ]
