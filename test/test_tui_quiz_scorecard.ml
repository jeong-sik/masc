(** The Home quiz line: what the reading holds for each quiz state.

    The line is a projection of the decoded rows the refresh stored; this
    covers that stored state and the reading the operator is shown, not the
    screen's layout. *)

open Alcotest

module Types = Masc_tui_types
module Rows = Masc.Lane_addon_types

let score_row lane subject fields =
  { Rows.id = "row-" ^ subject
  ; lane_id = lane
  ; kind = Rows.Value
  ; title = "성적표"
  ; observed_at = 0.0
  ; subject_id = subject
  ; clock = None
  ; actor = None
  ; fields
  ; evidence = []
  ; related_ids = [] }

let window subject n d =
  score_row "01a1785b/quiz/scorecard" subject
    [ "score", `Assoc ["n", `Int n; "d", `Int d] ]

let review_row item =
  { (window item 0 0) with
    Rows.lane_id = "01a1785b/quiz/review"; Rows.kind = Rows.Event }

let state_with quiz error =
  let state = Types.create_state ~workspace:"quiz-reading" ~port:0 () in
  state.Types.quiz_scorecard <- quiz;
  state.Types.quiz_scorecard_error <- error;
  state

let test_the_line_names_each_window_and_the_open_misses () =
  let state =
    state_with
      (Some { Types.quiz_scorecards =
                [ window "day" 2 3; window "7d" 5 8; window "30d" 12 20; window "all" 12 20 ]
            ; quiz_reviews = [ review_row "i2"; review_row "i3" ] })
      None in
  check (option string) "the three windows and the miss count"
    (Some " Quiz: · 1일 2/3 · 7일 5/8 · 30일 12/20 · unrecovered misses 2 · g opens the notes")
    (Types.quiz_scorecard_reading state)
;;

let test_an_inventory_without_the_quiz_shows_no_line () =
  (* No scorecard rows at all is no live installation, not zero misses. *)
  check (option string) "empty rows is no line"
    None
    (Types.quiz_scorecard_reading
       (state_with (Some { Types.quiz_scorecards = []; quiz_reviews = [] }) None))
;;

let test_nothing_read_is_no_line_not_an_error () =
  check (option string) "unread is no line"
    None (Types.quiz_scorecard_reading (state_with None None))
;;

let test_a_failed_read_says_so_without_dropping_the_hint () =
  check (option string) "the line names the failure"
    (Some " Quiz: reading unavailable · g opens the lane")
    (Types.quiz_scorecard_reading (state_with None (Some "workspace unreachable")))
;;

let test_a_score_row_of_the_wrong_shape_shows_a_dash_not_a_crash () =
  let odd = score_row "01a1785b/quiz/scorecard" "day" [ "score", `String "later" ] in
  let state =
    state_with (Some { Types.quiz_scorecards = [odd]; quiz_reviews = [] }) None in
  check (option string) "the window falls back to a dash"
    (Some " Quiz: · 1일 - · unrecovered misses 0 · g opens the notes")
    (Types.quiz_scorecard_reading state)
;;

let () =
  run "quiz scorecard reading"
    [ "line", [
        test_case "the line names each window and the open misses" `Quick
          test_the_line_names_each_window_and_the_open_misses
      ; test_case "an inventory without the quiz shows no line" `Quick
          test_an_inventory_without_the_quiz_shows_no_line
      ; test_case "nothing read is no line, not an error" `Quick
          test_nothing_read_is_no_line_not_an_error
      ; test_case "a failed read says so without dropping the hint" `Quick
          test_a_failed_read_says_so_without_dropping_the_hint
      ; test_case "a score row of the wrong shape shows a dash, not a crash" `Quick
          test_a_score_row_of_the_wrong_shape_shows_a_dash_not_a_crash
      ] ]
;;
