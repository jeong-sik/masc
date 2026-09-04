(** What the questions panel can afford to draw.

    The panel is the last block on the Approvals surface, and a surface that
    overruns its budget loses its final rows rather than its composer. Before
    this arithmetic existed the block drew every question of every open ask and
    let the frame cut whatever ran past the bottom -- with a four-question ask
    on screen (one exists in this workspace's own store, measured 2026-09-04)
    the cut reached the cursor, so [/] and j/k moved a selection nothing on
    screen showed.

    Every case here is stated in rows, because rows are what the panel spends.
    Heights arrive measured: the caller draws each question into a buffer of
    its own, since a prompt wraps against the terminal's width. *)

module Layout = Masc_tui_ask_layout

let plan ?(budget = 40) ?(spent = 2) ?(question_heights = [ 5 ])
    ?(question_cursor = 0) ?(context_height = 0) ?(other_asks = 0) () =
  Layout.plan ~budget ~spent ~question_heights ~question_cursor ~context_height
    ~other_asks
;;

(* The ordinary case: one ask, room for all of it, nothing folded. *)
let test_everything_fits () =
  let p = plan ~question_heights:[ 5; 4; 6 ] ~context_height:2 ~other_asks:2 () in
  Alcotest.(check int) "every question drawn" 3 p.Layout.questions_shown;
  Alcotest.(check int) "from the top" 0 p.Layout.question_start;
  Alcotest.(check int) "nothing counted away" 0 p.Layout.questions_hidden;
  Alcotest.(check bool) "the reason too" true p.Layout.context_shown;
  Alcotest.(check int) "and both folded asks get a line" 2
    p.Layout.summaries_shown;
  Alcotest.(check int) "with none left over" 0 p.Layout.summaries_hidden
;;

(* The measured shape that broke the panel: four questions of five rows each in
   a budget that holds about half of them. What is cut is counted, not dropped
   silently. *)
let test_a_tall_ask_is_counted_not_cut () =
  let p = plan ~budget:16 ~question_heights:[ 5; 5; 5; 5 ] () in
  Alcotest.(check bool) "some questions drawn" true (p.Layout.questions_shown > 0);
  Alcotest.(check int) "and the rest are counted" 4
    (p.Layout.questions_shown + p.Layout.questions_hidden)
;;

(* The whole point of the window: the question the keys are on is drawn even
   when filling from the top would have stopped before it. *)
let test_the_cursor_question_is_always_drawn () =
  let p = plan ~budget:10 ~question_heights:[ 5; 5; 5; 5 ] ~question_cursor:3 () in
  let last = p.Layout.question_start + p.Layout.questions_shown - 1 in
  Alcotest.(check bool) "the window reaches the cursor" true
    (p.Layout.question_start <= 3 && last >= 3)
;;

let test_the_window_starts_at_the_top_when_the_cursor_fits () =
  let p = plan ~budget:20 ~question_heights:[ 4; 4; 4 ] ~question_cursor:2 () in
  Alcotest.(check int) "no need to scroll" 0 p.Layout.question_start;
  Alcotest.(check int) "all three drawn" 3 p.Layout.questions_shown
;;

(* Folded asks are cheap, but they do not get to starve the ask the keys act
   on: three rows is the least a question can occupy. *)
let test_the_expanded_ask_keeps_room_from_the_folded_ones () =
  let p = plan ~budget:8 ~spent:2 ~question_heights:[ 3 ] ~other_asks:10 () in
  Alcotest.(check int) "the cursor's question survives" 1
    p.Layout.questions_shown;
  Alcotest.(check bool) "and the rest are counted away" true
    (p.Layout.summaries_hidden > 0)
;;

(* Counting away asks costs a row of its own, so the count cannot claim rows
   the panel does not have. *)
let test_folded_asks_pay_for_their_own_count_line () =
  let p = plan ~budget:9 ~spent:2 ~question_heights:[ 3 ] ~other_asks:5 () in
  let rows_used =
    3 + p.Layout.summaries_shown + if p.Layout.summaries_hidden > 0 then 1 else 0
  in
  Alcotest.(check bool) "the plan fits in what it was given" true (rows_used <= 7)
;;

(* The reason explains the ask; the questions are the ask. It goes in only
   where it costs no question its place. *)
let test_the_reason_yields_to_a_question () =
  (* Twelve rows to spend: the two questions take ten, the reason wants four,
     and the questions keep the room. *)
  let p = plan ~budget:14 ~question_heights:[ 5; 5 ] ~context_height:4 () in
  Alcotest.(check int) "both questions drawn" 2 p.Layout.questions_shown;
  Alcotest.(check bool) "the reason waits" false p.Layout.context_shown
;;

let test_the_reason_is_drawn_when_it_costs_nothing () =
  let p = plan ~budget:20 ~question_heights:[ 4 ] ~context_height:3 () in
  Alcotest.(check bool) "there was room" true p.Layout.context_shown
;;

(* A pane too small to draw anything asks for nothing rather than for a
   negative number of rows. *)
let test_a_budget_that_is_gone_asks_for_nothing () =
  let p = plan ~budget:2 ~spent:2 ~question_heights:[ 5; 5 ] ~other_asks:3 () in
  Alcotest.(check int) "no question drawn" 0 p.Layout.questions_shown;
  Alcotest.(check int) "all of them counted" 2 p.Layout.questions_hidden;
  Alcotest.(check bool) "no summary either" true (p.Layout.summaries_shown = 0);
  Alcotest.(check bool) "and no reason" false p.Layout.context_shown
;;

(* An ask with no questions at all is not a shape the server sends, but the
   arithmetic must not index into an empty list to say so. *)
let test_an_ask_with_no_questions_is_survivable () =
  let p = plan ~question_heights:[] ~question_cursor:3 () in
  Alcotest.(check int) "nothing to draw" 0 p.Layout.questions_shown;
  Alcotest.(check int) "and nothing hidden" 0 p.Layout.questions_hidden;
  Alcotest.(check int) "the window starts at the top" 0 p.Layout.question_start
;;

(* A cursor past the end of the list -- a snapshot that shrank under the
   operator -- clamps rather than scrolling into nothing. *)
let test_a_cursor_past_the_end_clamps () =
  let p = plan ~budget:8 ~question_heights:[ 3; 3 ] ~question_cursor:9 () in
  Alcotest.(check bool) "the window stays inside the list" true
    (p.Layout.question_start < 2)
;;

(* The contract, stated once and checked over every shape the panel can be
   handed: what the plan asks for fits in what it was given. Every row the
   panel draws is here -- the questions, the two count lines, the reason, the
   folded asks -- because a count line that announces a fold in a row nobody
   budgeted is exactly how the block overran in the first place.

   The floor is two rows of slack: [render_approvals] never asks for fewer
   than four and the divider and header always take two, so a pane with less
   than that to spend is not a shape this is asked to plan for. *)
let test_a_plan_always_fits_what_it_was_given () =
  let heights =
    [ []; [ 1 ]; [ 5 ]; [ 3; 3 ]; [ 5; 5; 5; 5 ]; [ 1; 9; 2 ]; [ 12 ] ]
  in
  let spent = 2 in
  List.iter
    (fun question_heights ->
       for budget = spent + 2 to 30 do
         for question_cursor = 0 to 4 do
           List.iter
             (fun other_asks ->
                List.iter
                  (fun context_height ->
                     let p =
                       Layout.plan ~budget ~spent ~question_heights
                         ~question_cursor ~context_height ~other_asks
                     in
                     let drawn_questions =
                       List.filteri
                         (fun index _ ->
                            index >= p.Layout.question_start
                            && index
                               < p.Layout.question_start
                                 + p.Layout.questions_shown)
                         question_heights
                     in
                     let rows =
                       spent
                       + List.fold_left ( + ) 0 drawn_questions
                       + (if p.Layout.questions_hidden > 0 then 1 else 0)
                       + (if p.Layout.context_shown then context_height else 0)
                       + p.Layout.summaries_shown
                       + if p.Layout.summaries_hidden > 0 then 1 else 0
                     in
                     if rows > budget then
                       Alcotest.failf
                         "budget=%d heights=[%s] cursor=%d others=%d why=%d \
                          planned %d rows"
                         budget
                         (String.concat ";" (List.map string_of_int question_heights))
                         question_cursor other_asks context_height rows)
                  [ 0; 2; 5 ])
             [ 0; 1; 4; 9 ]
         done
       done)
    heights
;;

(* Nothing is lost on the way: every question is either drawn or counted. *)
let test_every_question_is_drawn_or_counted () =
  List.iter
    (fun question_heights ->
       for budget = 4 to 30 do
         let p =
           Layout.plan ~budget ~spent:2 ~question_heights ~question_cursor:1
             ~context_height:2 ~other_asks:3
         in
         Alcotest.(check int) "drawn plus counted is all of them"
           (List.length question_heights)
           (p.Layout.questions_shown + p.Layout.questions_hidden)
       done)
    [ [ 5 ]; [ 3; 3 ]; [ 5; 5; 5; 5 ]; [ 1; 9; 2 ] ]
;;

let () =
  Alcotest.run "tui_ask_layout"
    [ ( "fit"
      , [ Alcotest.test_case "everything fits" `Quick test_everything_fits
        ; Alcotest.test_case "a tall ask is counted, not cut" `Quick
            test_a_tall_ask_is_counted_not_cut
        ; Alcotest.test_case "the cursor's question is always drawn" `Quick
            test_the_cursor_question_is_always_drawn
        ; Alcotest.test_case "the window starts at the top when it can" `Quick
            test_the_window_starts_at_the_top_when_the_cursor_fits
        ] )
    ; ( "folding"
      , [ Alcotest.test_case "the expanded ask keeps its room" `Quick
            test_the_expanded_ask_keeps_room_from_the_folded_ones
        ; Alcotest.test_case "folded asks pay for their count line" `Quick
            test_folded_asks_pay_for_their_own_count_line
        ] )
    ; ( "reason"
      , [ Alcotest.test_case "yields to a question" `Quick
            test_the_reason_yields_to_a_question
        ; Alcotest.test_case "drawn when it costs nothing" `Quick
            test_the_reason_is_drawn_when_it_costs_nothing
        ] )
    ; ( "contract"
      , [ Alcotest.test_case "a plan always fits what it was given" `Quick
            test_a_plan_always_fits_what_it_was_given
        ; Alcotest.test_case "every question is drawn or counted" `Quick
            test_every_question_is_drawn_or_counted
        ] )
    ; ( "edges"
      , [ Alcotest.test_case "a spent budget asks for nothing" `Quick
            test_a_budget_that_is_gone_asks_for_nothing
        ; Alcotest.test_case "an ask with no questions" `Quick
            test_an_ask_with_no_questions_is_survivable
        ; Alcotest.test_case "a cursor past the end clamps" `Quick
            test_a_cursor_past_the_end_clamps
        ] )
    ]
;;
