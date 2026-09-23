open Masc_tui_types
module Schedule = Masc_tui_render_schedule

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

(* One word per time, so the header never stands for both. *)
let test_the_two_times_are_not_spelled_the_same () =
  Alcotest.(check bool) "the posting and the last move read differently" true
    (not
       (String.equal
          (board_age_header Board_time_posted)
          (board_age_header Board_time_changed)))

(* The column is a fixed width and [Table] clips a header that does not fit,
   so a word that outgrew it would reach the screen shortened rather than
   refused. Both words are checked through the row the surface draws. *)
let test_both_headers_reach_the_header_row_whole () =
  let title_width = Schedule.board_title_width ~inner_width:100 in
  List.iter
    (fun time ->
      let word = board_age_header time in
      let row = Schedule.board_header_row ~age_header:word ~title_width in
      Alcotest.(check bool)
        (Printf.sprintf "%S is drawn whole" word)
        true
        (Astring.String.is_infix ~affix:word row))
    [ Board_time_posted; Board_time_changed ]

(* The title takes what the named columns leave, and the header word must not
   move that line: a wider word would push the title column and redraw every
   row at a different width the moment the reader changed the sort. *)
let test_the_header_word_does_not_move_the_title_column () =
  let title_width = Schedule.board_title_width ~inner_width:100 in
  let width_of word =
    String.length (Schedule.board_header_row ~age_header:word ~title_width)
  in
  Alcotest.(check int) "both headers draw the same row width"
    (width_of (board_age_header Board_time_posted))
    (width_of (board_age_header Board_time_changed))

(* The row that started this: on the live board a post made 1444 seconds ago
   had a reply 24 seconds ago, and under "newest post first" it sat sixth
   while the column read "24s" -- a number smaller than the five rows above
   it. Under that sort the column measures from the posting. *)
let test_a_replied_post_is_as_old_as_its_posting_under_the_post_orders () =
  let now = 10_000. in
  let posted = Some (now -. 1444.) and changed = Some (now -. 24.) in
  let text sort =
    Schedule.board_age_text ~now
      (board_age_source ~time:(board_sort_time sort) ~posted ~changed)
  in
  Alcotest.(check string) "newest post first measures from the posting"
    "24m04s" (text Board_recent);
  Alcotest.(check string) "so does the tie-break of most replies first"
    "24m04s" (text Board_discussed);
  Alcotest.(check string) "latest changed first measures from the last move"
    "24s" (text Board_updated)

(* A post that carries the one time the sort did not order by draws a dash,
   not that other time. Drawing the last move under a header that says AGE is
   the reading this whole change exists to stop, and a server that sends
   [updated_at] without a numeric [created_at] is the case where the two come
   apart. The column then says it has no age rather than showing the wrong
   one. *)
let test_the_time_the_sort_did_not_order_by_is_not_borrowed () =
  let text time =
    Schedule.board_age_text ~now:10_000.
      (board_age_source ~time ~posted:None ~changed:(Some 9_000.))
  in
  Alcotest.(check string) "the posting side has no time to measure from"
    "\xe2\x80\x94" (text Board_time_posted);
  Alcotest.(check string) "the last-move side has one" "16m40s"
    (text Board_time_changed)

(* A post that carried no numeric time at all draws a dash rather than an age
   measured from the epoch. *)
let test_a_post_with_no_time_draws_a_dash () =
  let text time =
    Schedule.board_age_text ~now:10_000.
      (board_age_source ~time ~posted:None ~changed:None)
  in
  Alcotest.(check string) "the posting side" "\xe2\x80\x94"
    (text Board_time_posted);
  Alcotest.(check string) "the last-move side" "\xe2\x80\x94"
    (text Board_time_changed)

let () =
  Alcotest.run "masc_tui_board_age_column"
    [ ( "board age column"
      , [ Alcotest.test_case "each sort names the time it ordered by" `Quick
            test_each_sort_names_the_time_it_ordered_by
        ; Alcotest.test_case "the two times are not spelled the same" `Quick
            test_the_two_times_are_not_spelled_the_same
        ; Alcotest.test_case "both headers reach the header row whole" `Quick
            test_both_headers_reach_the_header_row_whole
        ; Alcotest.test_case "the header word does not move the title column"
            `Quick test_the_header_word_does_not_move_the_title_column
        ; Alcotest.test_case
            "a replied post is as old as its posting under the post orders"
            `Quick
            test_a_replied_post_is_as_old_as_its_posting_under_the_post_orders
        ; Alcotest.test_case
            "the time the sort did not order by is not borrowed" `Quick
            test_the_time_the_sort_did_not_order_by_is_not_borrowed
        ; Alcotest.test_case "a post with no time draws a dash" `Quick
            test_a_post_with_no_time_draws_a_dash
        ] )
    ]
