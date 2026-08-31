module Thread = Masc_tui_board_comment_thread
open Masc_tui_types

let comment ?parent id =
  { bc_id = id
  ; bc_parent_id = parent
  ; bc_author = "author-" ^ id
  ; bc_content = "content-" ^ id
  ; bc_created_at = "2026-08-31T00:00:00Z"
  }

let shape comments =
  Thread.order comments
  |> List.map (fun (depth, c) -> (depth, c.bc_id))

let check_shape name expected comments =
  Alcotest.(check (list (pair int string))) name expected (shape comments)

(* The order a reader expects: every reply directly under what it answers, and
   siblings in the order they arrived. *)
let test_replies_follow_their_parent () =
  check_shape
    "a reply sits under its parent"
    [ 0, "a"; 1, "a1"; 2, "a1x"; 1, "a2"; 0, "b" ]
    [ comment "a"
    ; comment "b"
    ; comment "a1" ~parent:"a"
    ; comment "a2" ~parent:"a"
    ; comment "a1x" ~parent:"a1"
    ]

(* A flat page must draw exactly what it drew before threading existed:
   arrival order, no indent. *)
let test_a_flat_page_is_unchanged () =
  check_shape
    "no parent means no nesting"
    [ 0, "a"; 0, "b"; 0, "c" ]
    [ comment "a"; comment "b"; comment "c" ];
  Alcotest.(check string) "depth zero draws no rail" "" (Thread.rail ~depth:0)

(* A parent that expired under the board's TTL, or one the pagination cut. The
   reply is still a comment somebody wrote: it reads at the top level rather
   than vanishing. *)
let test_an_orphan_is_drawn_not_dropped () =
  check_shape
    "a reply to a comment this page does not hold reads at the top"
    [ 0, "a"; 0, "orphan"; 1, "orphan-child" ]
    [ comment "a"
    ; comment "orphan" ~parent:"gone"
    ; comment "orphan-child" ~parent:"orphan"
    ]

(* Totality. A self-parented row is its own root and would descend forever
   without the visited mark; a two-cycle is reachable from no root at all.
   Neither may hide a comment or hang the pane. *)
let test_cycles_terminate_and_keep_every_row () =
  check_shape
    "a self-parented comment is drawn once"
    [ 0, "a"; 0, "loop" ]
    [ comment "a"; comment "loop" ~parent:"loop" ];
  check_shape
    "a mutual cycle is appended rather than lost"
    [ 0, "a"; 0, "x"; 0, "y" ]
    [ comment "a"; comment "x" ~parent:"y"; comment "y" ~parent:"x" ]

(* The indent stops growing so a deep reply cannot walk off a narrow pane. The
   nesting order is unaffected -- only the rail stops widening. *)
let test_the_rail_stops_at_max_depth () =
  Alcotest.(check int)
    "past the ceiling the rail keeps its width"
    (String.length (Thread.rail ~depth:Thread.max_depth))
    (String.length (Thread.rail ~depth:(Thread.max_depth + 7)));
  Alcotest.(check bool)
    "each level indents further up to the ceiling"
    true
    (String.length (Thread.rail ~depth:1)
     < String.length (Thread.rail ~depth:2));
  let deep =
    List.init 8 (fun index ->
      let id = Printf.sprintf "c%d" index in
      if index = 0 then comment id
      else comment id ~parent:(Printf.sprintf "c%d" (index - 1)))
  in
  Alcotest.(check (list int))
    "order still nests past the rail's ceiling"
    [ 0; 1; 2; 3; 4; 5; 6; 7 ]
    (List.map fst (Thread.order deep))

let () =
  Alcotest.run
    "tui board comment thread"
    [ ( "order"
      , [ Alcotest.test_case "replies follow their parent" `Quick
            test_replies_follow_their_parent
        ; Alcotest.test_case "a flat page is unchanged" `Quick
            test_a_flat_page_is_unchanged
        ; Alcotest.test_case "an orphan is drawn, not dropped" `Quick
            test_an_orphan_is_drawn_not_dropped
        ; Alcotest.test_case "cycles terminate and keep every row" `Quick
            test_cycles_terminate_and_keep_every_row
        ; Alcotest.test_case "the rail stops at max depth" `Quick
            test_the_rail_stops_at_max_depth
        ] )
    ]
