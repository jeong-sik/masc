open Alcotest

module Selection = Masc_tui_board_selection

let reconcile ?detail_id ~current_ids ~cursor next_ids =
  let source =
    match detail_id with
    | None -> Selection.List_cursor
    | Some id -> Selection.Detail_post id
  in
  Selection.reconcile_cursor ~current_ids ~cursor ~source ~next_ids

let test_list_reorder_preserves_selected_id () =
  check int "B moves to index 2" 2
    (reconcile ~current_ids:[ "A"; "B"; "C" ] ~cursor:1
       [ "NEW"; "A"; "B"; "C" ])

let test_detail_reorder_uses_detail_identity () =
  check int "detail B moves to index 0" 0
    (reconcile ~detail_id:"B" ~current_ids:[ "A"; "B"; "C" ] ~cursor:1
       [ "B"; "A"; "C" ]);
  check int "detail identity overrides the numeric cursor" 2
    (reconcile ~detail_id:"B" ~current_ids:[ "A"; "B"; "C" ] ~cursor:0
       [ "A"; "C"; "B" ])

let test_missing_identity_uses_existing_numeric_fallback () =
  check int "valid cursor remains unchanged" 1
    (reconcile ~detail_id:"B" ~current_ids:[ "A"; "B"; "C" ] ~cursor:1
       [ "A"; "C" ]);
  check int "shrunk list clamps the cursor" 0
    (reconcile ~detail_id:"C" ~current_ids:[ "A"; "B"; "C" ] ~cursor:2
       [ "A" ]);
  check int "empty list resets the cursor" 0
    (reconcile ~current_ids:[ "A" ] ~cursor:0 []);
  check int "negative cursor is normalized" 0
    (reconcile ~current_ids:[ "A" ] ~cursor:(-1) [ "A" ])

let () =
  run "tui_board_selection"
    [ ( "selection identity"
      , [ test_case "list reorder" `Quick
            test_list_reorder_preserves_selected_id
        ; test_case "detail reorder" `Quick
            test_detail_reorder_uses_detail_identity
        ; test_case "missing identity fallback" `Quick
            test_missing_identity_uses_existing_numeric_fallback
        ] )
    ]
