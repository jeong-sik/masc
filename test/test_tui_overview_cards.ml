(* The Overview cards decide two things a test can see without reading the
   screen. One is which card the selection reaches: a card that lists the
   selected destination holds it, a card that lists others can take it, and a
   card that lists none never does. The other is whether the cards are drawn
   at all ([Some]) or the caller falls back to the plain rows ([None]).

   RFC tui-one-screen-grammar section 2 makes the second one independent of
   the selection: the cards are drawn only when each card the selection can
   reach fits full in turn. So pressing j or k never switches the body
   between the cards and the plain rows (section 8), and a card the
   selection can reach is never too tall to stay full once it holds it. *)

open Alcotest
module Cards = Masc_tui_overview_cards
module Card = Masc_tui_card
module Layout = Masc_tui_message_layout

(* Wide enough for the two columns, each holding a short row on one line. *)
let inner = 94

let edge name = { Card.name; key = None; status = None; count = None; focus = Card.Unfocused; border_accent = None; footer_keys = [] }

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
  Cards.draw ~ko:true ~edges ~inner ~rows
    ~is_selected:(fun action -> Option.equal String.equal (Some action) selected)
    ~decisions ~decisions_whole:true ~continuation
    ~status:(fun ~cells:_ -> [ "status" ])
    ~keep_actions_card:false ~actions

(* Nothing selected, then each destination in turn. *)
let selections ~decisions ~continuation ~actions =
  None :: List.map (fun (action, _) -> Some action) (decisions @ continuation @ actions)

(* The same answer wherever the selection is: drawn at [fits] rows and the
   plain rows one row shorter. *)
let check_threshold label ~fits ~decisions ~continuation ~actions =
  List.iter
    (fun selected ->
       let at what =
         Printf.sprintf "%s, %s selected: %s" label
           (Option.value selected ~default:"nothing") what
       in
       check bool (at "one row short falls back") true
         (Option.is_none (draw ~rows:(fits - 1) ~selected ~decisions ~continuation ~actions));
       check bool (at "drawn") true
         (Option.is_some (draw ~rows:fits ~selected ~decisions ~continuation ~actions)))
    (selections ~decisions ~continuation ~actions)

let selection =
  testable
    (fun formatter selection ->
       Format.pp_print_string formatter
         (match selection with
          | Card.Unselectable -> "unselectable"
          | Card.Selectable -> "selectable"
          | Card.Holds_selected_row -> "holds the selected row"))
    ( = )

let test_a_card_with_destinations_can_hold_the_selection () =
  let rows = entries "c" 3 in
  let is_selected action = String.equal action "c1" in
  check selection "lists the selected one" Card.Holds_selected_row
    (Cards.card_selection ~is_selected rows);
  check selection "lists others" Card.Selectable
    (Cards.card_selection ~is_selected:(fun _ -> false) rows);
  check selection "lists none" Card.Unselectable (Cards.card_selection ~is_selected [])

(* The right column is the status card (3 rows) over the action card (5 rows,
   7 tall), one row between them. The selection can reach the action card,
   so the column needs 1 + 1 + 7 = 9 rows wherever the selection is. The left
   column needs 3 + 1 + 1 at most. *)
let test_the_action_card_must_fit_full () =
  check_threshold "actions" ~fits:9 ~decisions:[] ~continuation:(entries "c" 2)
    ~actions:(entries "a" 5)

(* The left column is the decision card (6 rows, 8 tall) over the continue
   card (2 rows, 4 tall). With the decision card full and the continue card
   squashed it needs 8 + 1 + 1 = 10 rows. The right column needs 9. *)
let test_the_decision_card_must_fit_full () =
  check_threshold "decisions" ~fits:10 ~decisions:(entries "d" 6)
    ~continuation:(entries "c" 2) ~actions:(entries "a" 5)

(* The continue card (6 rows, 8 tall) sits under the decision card, which
   lists no decision and so never holds the selection: 1 + 1 + 8 = 10. The
   right column needs 1 + 1 + 3 = 5. *)
let test_the_continue_card_must_fit_full () =
  check_threshold "continuation" ~fits:10 ~decisions:[] ~continuation:(entries "c" 6)
    ~actions:(entries "a" 1)

(* At every height the answer is the same for every selection, and drawn
   cards never take more lines than [rows], every line [inner] cells. *)
let test_the_selection_never_switches_the_layout () =
  List.iter
    (fun (decisions, continuation, actions) ->
       for rows = 0 to 24 do
         let at = Printf.sprintf "%d rows" rows in
         let answers =
           List.map
             (fun selected -> draw ~rows ~selected ~decisions ~continuation ~actions)
             (selections ~decisions ~continuation ~actions)
         in
         check bool (at ^ ": the same layout for every selection") true
           (List.for_all Option.is_some answers || List.for_all Option.is_none answers);
         List.iter
           (function
             | None -> ()
             | Some lines ->
                 check bool (at ^ ": within the rows") true (List.length lines <= rows);
                 check bool (at ^ ": every line is the inner width") true
                   (List.for_all (fun line -> Layout.display_width line = inner) lines))
           answers
       done)
    [ (entries "d" 3, entries "c" 4, entries "a" 5)
    ; ([], entries "c" 2, entries "a" 5)
    ; (entries "d" 6, entries "c" 2, [])
    ; ([], [], [])
    ]

let test_narrow_width_keeps_one_column_cards () =
  let decisions = entries "d" 2 in
  let continuation = entries "c" 2 in
  let actions = entries "a" 1 in
  let draw_at ~inner ~rows ~selected =
    Cards.draw ~ko:true ~edges ~inner ~rows
      ~is_selected:(fun action -> Option.equal String.equal (Some action) selected)
      ~decisions ~decisions_whole:true ~continuation
      ~status:(fun ~cells:_ -> [ "running" ])
      ~keep_actions_card:false ~actions
  in
  check bool "43 inner cells falls back to plain list" true
    (Option.is_none (draw_at ~inner:43 ~rows:24 ~selected:None));
  List.iter
    (fun width ->
       match draw_at ~inner:width ~rows:24 ~selected:(Some "d1") with
       | None -> fail (Printf.sprintf "expected cards at inner=%d" width)
       | Some lines ->
           check bool (Printf.sprintf "height <= 24 at inner=%d" width) true
             (List.length lines <= 24);
           check bool (Printf.sprintf "every line matches inner=%d" width) true
             (List.for_all (fun line -> Layout.display_width line = width) lines))
    [ 44; 60; 89; 90 ];
  for rows = 0 to 24 do
    let at = Printf.sprintf "1-col at %d rows" rows in
    let answers =
      List.map
        (fun selected -> draw_at ~inner:60 ~rows ~selected)
        (selections ~decisions ~continuation ~actions)
    in
    check bool (at ^ ": the same layout for every selection") true
      (List.for_all Option.is_some answers || List.for_all Option.is_none answers);
    List.iter
      (function
        | None -> ()
        | Some lines ->
            check bool (at ^ ": within the rows") true (List.length lines <= rows);
            check bool (at ^ ": every line is 60 cells") true
              (List.for_all (fun line -> Layout.display_width line = 60) lines))
      answers
  done

let () =
  run "tui overview cards"
    [ ( "selection"
      , [ test_case "a card with destinations can hold the selection" `Quick
            test_a_card_with_destinations_can_hold_the_selection
        ; test_case "the action card must fit full" `Quick test_the_action_card_must_fit_full
        ; test_case "the decision card must fit full" `Quick
            test_the_decision_card_must_fit_full
        ; test_case "the continue card must fit full" `Quick
            test_the_continue_card_must_fit_full
        ; test_case "the selection never switches the layout" `Quick
            test_the_selection_never_switches_the_layout
        ; test_case "narrow widths step down to 1-column cards" `Quick
            test_narrow_width_keeps_one_column_cards
        ] )
    ]
