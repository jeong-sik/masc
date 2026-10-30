open Alcotest

module Selection = Masc_tui_planning_selection

let pp_navigation formatter = function
  | Selection.List_cursor cursor ->
      Format.fprintf formatter "List_cursor %d" cursor
  | Selection.Detail_goal { goal_id; cursor } ->
      Format.fprintf formatter "Detail_goal { goal_id = %S; cursor = %d }"
        goal_id cursor

let navigation = testable pp_navigation ( = )

let reconcile current_ids current next_ids =
  Selection.reconcile ~current_ids ~next_ids ~current

let test_list_identity_across_replacement () =
  check navigation "B moves to index 2" (Selection.List_cursor 2)
    (reconcile [ "A"; "B"; "C" ] (Selection.List_cursor 1)
       [ "NEW"; "A"; "B"; "C" ]);
  check navigation "missing B keeps bounded cursor 1"
    (Selection.List_cursor 1)
    (reconcile [ "A"; "B"; "C" ] (Selection.List_cursor 1)
       [ "A"; "C"; "D" ])

let test_detail_identity_across_replacement () =
  check navigation "detail B moves to index 2"
    (Selection.Detail_goal { goal_id = "B"; cursor = 2 })
    (reconcile [ "A"; "B"; "C" ]
       (Selection.Detail_goal { goal_id = "B"; cursor = 0 })
       [ "C"; "A"; "B" ]);
  check navigation "missing detail B returns to list"
    (Selection.List_cursor 1)
    (reconcile [ "A"; "B"; "C" ]
       (Selection.Detail_goal { goal_id = "B"; cursor = 1 })
       [ "A"; "C"; "D" ])

let test_empty_replacement_returns_list_origin () =
  check navigation "empty list resets list cursor" (Selection.List_cursor 0)
    (reconcile [ "A"; "B" ] (Selection.List_cursor 1) []);
  check navigation "empty list leaves detail mode" (Selection.List_cursor 0)
    (reconcile [ "A"; "B" ]
       (Selection.Detail_goal { goal_id = "B"; cursor = 1 })
       [])

let test_pathological_cursors_are_total () =
  check navigation "negative list cursor normalizes to zero"
    (Selection.List_cursor 0)
    (reconcile [ "A"; "B" ] (Selection.List_cursor min_int) [ "A"; "B" ]);
  check navigation "oversized list cursor clamps to the last goal"
    (Selection.List_cursor 1)
    (reconcile [ "A"; "B" ] (Selection.List_cursor max_int) [ "A"; "B" ]);
  check navigation "detail identity overrides an invalid cursor"
    (Selection.Detail_goal { goal_id = "B"; cursor = 1 })
    (reconcile [ "A"; "B" ]
       (Selection.Detail_goal { goal_id = "B"; cursor = min_int })
       [ "A"; "B" ]);
  check navigation "missing detail clamps an oversized cursor"
    (Selection.List_cursor 1)
    (reconcile [ "A"; "B" ]
       (Selection.Detail_goal { goal_id = "X"; cursor = max_int })
       [ "A"; "B" ])

let () =
  run "tui_planning_selection"
    [ ( "selection identity"
      , [ test_case "list replacement" `Quick
            test_list_identity_across_replacement
        ; test_case "detail replacement" `Quick
            test_detail_identity_across_replacement
        ; test_case "empty replacement" `Quick
            test_empty_replacement_returns_list_origin
        ; test_case "pathological cursors" `Quick
            test_pathological_cursors_are_total
        ] )
    ]
