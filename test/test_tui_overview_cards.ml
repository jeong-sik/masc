(* The Overview cards decide one thing a test can see without reading the
   screen: whether the cards are drawn at all ([Some]) or the caller falls
   back to the plain rows ([None]). RFC tui-one-screen-grammar section 2 says
   the card that holds the selected row never squashes, so the selection
   stays on screen. These cases pin that decision through the result's shape:
   the same rows fit when the selection is elsewhere and do not when the
   selected card would have had to squash. *)

open Alcotest
module Cards = Masc_tui_overview_cards
module Card = Masc_tui_card
module Layout = Masc_tui_message_layout

(* Wide enough for the two columns, each holding a short row on one line. *)
let inner = 94

let edge name = { Card.name; key = None; status = None; count = None; focus = Card.Unfocused }

let edges =
  { Cards.decisions = edge "decisions"
  ; continuation = edge "continuation"
  ; capacity = edge "capacity"
  ; actions = edge "actions"
  }

let entries prefix count =
  List.init count (fun index ->
    let action = Printf.sprintf "%s%d" prefix index in
    (action, action))

let draw ~rows ~selected ~decisions ~continuation ~actions =
  Cards.draw ~ko:true ~edges ~empty_decisions:"none" ~inner ~rows
    ~is_selected:(fun action -> Option.equal String.equal (Some action) selected)
    ~decisions ~decisions_whole:true ~continuation
    ~status:(fun ~cells:_ -> [ "status" ])
    ~actions

let drawn label = function
  | Some _ -> ()
  | None -> fail (label ^ ": fell back to the plain rows")

let fell_back label = function
  | Some _ -> fail (label ^ ": drew the cards")
  | None -> ()

(* The right column is the status card (3 rows) over the action card (5 rows,
   7 tall), one row between them: 11 rows. The left column is 8. *)
let test_the_selected_action_card_never_squashes () =
  let decisions = [] and continuation = entries "c" 2 and actions = entries "a" 5 in
  (* Nothing selected: the action card squashes and the grid fits in 8. *)
  drawn "nothing selected"
    (draw ~rows:8 ~selected:None ~decisions ~continuation ~actions);
  (* Selected: the action card stays full, the status card squashes, and the
     column needs 1 + 1 + 7 = 9 rows. *)
  fell_back "a selected action, 8 rows"
    (draw ~rows:8 ~selected:(Some "a0") ~decisions ~continuation ~actions);
  drawn "a selected action, 9 rows"
    (draw ~rows:9 ~selected:(Some "a0") ~decisions ~continuation ~actions)

(* The left column is the decision card (6 rows, 8 tall) over the continue
   card (2 rows, 4 tall): 13 rows. The right column is 11. *)
let test_the_selected_decision_card_never_squashes () =
  let decisions = entries "d" 6 and continuation = entries "c" 2 and actions = entries "a" 5 in
  (* The selection is on an action: the decision card squashes, the left
     column is 1 + 1 + 4, the right column 1 + 1 + 7. *)
  drawn "an action selected"
    (draw ~rows:9 ~selected:(Some "a0") ~decisions ~continuation ~actions);
  (* The selection is on a decision: the continue card squashes and the left
     column still needs 8 + 1 + 1 = 10 rows. *)
  fell_back "a decision selected, 9 rows"
    (draw ~rows:9 ~selected:(Some "d0") ~decisions ~continuation ~actions);
  drawn "a decision selected, 10 rows"
    (draw ~rows:10 ~selected:(Some "d0") ~decisions ~continuation ~actions)

(* The continue card (6 rows, 8 tall) sits under the decision card (3 tall). *)
let test_the_selected_continue_card_never_squashes () =
  let decisions = [] and continuation = entries "c" 6 and actions = entries "a" 1 in
  (* Right: 3 + 1 + 3 = 7. Left with nothing selected: the continue card
     squashes, 3 + 1 + 1. *)
  drawn "nothing selected"
    (draw ~rows:7 ~selected:None ~decisions ~continuation ~actions);
  (* Selected: the decision card squashes instead, 1 + 1 + 8 = 10. *)
  fell_back "a continuation selected, 9 rows"
    (draw ~rows:9 ~selected:(Some "c0") ~decisions ~continuation ~actions);
  drawn "a continuation selected, 10 rows"
    (draw ~rows:10 ~selected:(Some "c0") ~decisions ~continuation ~actions)

(* Whatever is selected, drawn cards never take more lines than [rows] and
   every line is [inner] cells. *)
let test_drawn_cards_stay_inside_their_rows () =
  let decisions = entries "d" 3 and continuation = entries "c" 4 and actions = entries "a" 5 in
  List.iter
    (fun selected ->
       for rows = 0 to 24 do
         match draw ~rows ~selected ~decisions ~continuation ~actions with
         | None -> ()
         | Some lines ->
             let at = Printf.sprintf "%d rows" rows in
             check bool (at ^ ": within the rows") true (List.length lines <= rows);
             check bool (at ^ ": every line is the inner width") true
               (List.for_all (fun line -> Layout.display_width line = inner) lines)
       done)
    [ None; Some "d1"; Some "c2"; Some "a4" ]

let () =
  run "tui overview cards"
    [ ( "selection"
      , [ test_case "the selected action card never squashes" `Quick
            test_the_selected_action_card_never_squashes
        ; test_case "the selected decision card never squashes" `Quick
            test_the_selected_decision_card_never_squashes
        ; test_case "the selected continue card never squashes" `Quick
            test_the_selected_continue_card_never_squashes
        ; test_case "drawn cards stay inside their rows" `Quick
            test_drawn_cards_stay_inside_their_rows
        ] )
    ]
