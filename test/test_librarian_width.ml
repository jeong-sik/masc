(* RFC librarian-call-only-proposes §7.6: the writer narrows what the lane
   refused and widens again as commits pass it. The same rules are in
   specs/bug-models/LibrarianWidth.tla; each case below is a path that
   model checks. *)

open Alcotest
module Width = Masc.Librarian_width

let width_text : Width.width -> string = function
  | All -> "all"
  | Units count -> Printf.sprintf "%d units" (count :> int)
  | Items count -> Printf.sprintf "%d items" (count :> int)
;;

(* What one question carried, and what became of it. *)
type step =
  | Refused of Width.offered
  | Committed of Width.offered * Masc.Librarian_log.within

let item = Masc.Librarian_log.Item { store = Agent_core; at = 0 }

(* The width each step leaves for the next ask. A refusal is of a question
   asked at the width the step before left. *)
let widths steps =
  let step (t, seen) = function
    | Refused offered ->
      let wider =
        match Width.breadth offered with
        | Wider wider -> wider
        | One_item -> failf "a question of %d units carried one item" offered.units
      in
      let t = Width.refused t ~asked:(Width.next t) wider in
      t, width_text (Width.next t) :: seen
    | Committed (offered, within) ->
      let t = Width.committed t (Width.passed offered within) in
      t, width_text (Width.next t) :: seen
  in
  List.rev (snd (List.fold_left step (Width.empty, []) steps))
;;

let carried units head_items : Width.offered = { units; head_items }

(* Halves the units refused, then asks what is left of each range. *)
let test_units_narrow_and_widen () =
  check (list string) "half, half, the rest of the inner range, the rest of the outer, all"
    [ "5 units"; "2 units"; "3 units"; "5 units"; "all" ]
    (widths
       [ Refused (carried 10 3)
       ; Refused (carried 5 3)
       ; Committed (carried 2 3, Whole)
       ; Committed (carried 3 3, Whole)
       ; Committed (carried 5 3, Whole)
       ])
;;

(* A question of one unit goes on to its items, and reading that unit to
   its end empties the items level. *)
let test_one_unit_goes_to_its_items () =
  check (list string) "half the items, half again, the rest, the rest of the outer, all"
    [ "4 items"; "2 items"; "2 items"; "4 items"; "all" ]
    (widths
       [ Refused (carried 1 8)
       ; Refused (carried 1 4)
       ; Committed (carried 1 2, item)
       ; Committed (carried 1 2, item)
       ; Committed (carried 1 4, Whole)
       ])
;;

(* A range partly committed and refused for what is left is another range:
   the next ask is narrower, not the same width again. *)
let test_rest_refused_is_another_range () =
  check (list string) "the rest is refused, so half of the rest"
    [ "4 items"; "4 items"; "2 items" ]
    (widths [ Refused (carried 1 8); Committed (carried 1 4, item); Refused (carried 1 4) ])
;;

(* The bottom is one item: no width is narrower, and the writer does not
   push it. *)
let test_one_item_is_the_bottom () =
  let breadth offered =
    match Width.breadth offered with
    | One_item -> "one item"
    | Wider (_ : Width.wider) -> "wider"
  in
  check (list string) "one unit of one item, then the wider ones"
    [ "one item"; "wider"; "wider" ]
    (List.map breadth [ carried 1 1; carried 1 2; carried 2 1 ])
;;

let () =
  run "librarian_width"
    [ ( "width"
      , [ test_case "units narrow and widen" `Quick test_units_narrow_and_widen
        ; test_case "one unit goes to its items" `Quick test_one_unit_goes_to_its_items
        ; test_case "the rest refused is another range" `Quick test_rest_refused_is_another_range
        ; test_case "one item is the bottom" `Quick test_one_item_is_the_bottom
        ] )
    ]
;;
