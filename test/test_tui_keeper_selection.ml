open Alcotest

module Selection = Masc_tui_keeper_selection

let pp_navigation formatter = function
  | Selection.List_cursor cursor ->
      Format.fprintf formatter "List_cursor %d" cursor
  | Selection.Detail_keeper { keeper_name; cursor } ->
      Format.fprintf formatter
        "Detail_keeper { keeper_name = %S; cursor = %d }" keeper_name cursor
  | Selection.Logs_keeper { keeper_name; cursor } ->
      Format.fprintf formatter "Logs_keeper { keeper_name = %S; cursor = %d }"
        keeper_name cursor
  | Selection.Message_keeper { keeper_name; cursor } ->
      Format.fprintf formatter
        "Message_keeper { keeper_name = %S; cursor = %d }" keeper_name cursor
  | Selection.Calls_keeper { keeper_name; cursor } ->
      Format.fprintf formatter "Calls_keeper { keeper_name = %S; cursor = %d }"
        keeper_name cursor

let navigation = testable pp_navigation ( = )

let reconcile current_ids current next_ids =
  Selection.reconcile ~current_ids ~next_ids ~current

let test_list_identity_across_replacement () =
  check navigation "sangsu moves to index 2" (Selection.List_cursor 2)
    (reconcile [ "sangsu"; "seongsu"; "tukkomi" ]
       (Selection.List_cursor 0)
       [ "seongsu"; "tukkomi"; "sangsu" ]);
  check navigation "missing selected Keeper keeps a bounded cursor"
    (Selection.List_cursor 1)
    (reconcile [ "sangsu"; "seongsu"; "tukkomi" ]
       (Selection.List_cursor 1)
       [ "sangsu"; "tukkomi" ])

let test_detail_and_logs_identity_across_replacement () =
  check navigation "detail keeps its Keeper and reindexes"
    (Selection.Detail_keeper { keeper_name = "seongsu"; cursor = 2 })
    (reconcile [ "sangsu"; "seongsu"; "tukkomi" ]
       (Selection.Detail_keeper { keeper_name = "seongsu"; cursor = 0 })
       [ "tukkomi"; "sangsu"; "seongsu" ]);
  check navigation "logs keep their Keeper and reindex"
    (Selection.Logs_keeper { keeper_name = "tukkomi"; cursor = 0 })
    (reconcile [ "sangsu"; "seongsu"; "tukkomi" ]
       (Selection.Logs_keeper { keeper_name = "tukkomi"; cursor = 1 })
       [ "tukkomi"; "sangsu"; "seongsu" ]);
  check navigation "missing detail returns to the list"
    (Selection.List_cursor 1)
    (reconcile [ "sangsu"; "seongsu"; "tukkomi" ]
       (Selection.Detail_keeper { keeper_name = "seongsu"; cursor = 1 })
       [ "sangsu"; "tukkomi" ]);
  check navigation "missing logs return to the list"
    (Selection.List_cursor 0)
    (reconcile [ "sangsu"; "seongsu" ]
       (Selection.Logs_keeper { keeper_name = "seongsu"; cursor = 1 })
       [])

let test_message_target_survives_unavailability () =
  check navigation "explicit target reindexes even if absent from the old roster"
    (Selection.Message_keeper { keeper_name = "new-keeper"; cursor = 1 })
    (reconcile [ "sangsu" ]
       (Selection.Message_keeper { keeper_name = "new-keeper"; cursor = 0 })
       [ "sangsu"; "new-keeper" ]);
  check navigation "missing target stays in message mode with a bounded cursor"
    (Selection.Message_keeper { keeper_name = "seongsu"; cursor = 1 })
    (reconcile [ "sangsu"; "seongsu"; "tukkomi" ]
       (Selection.Message_keeper { keeper_name = "seongsu"; cursor = 2 })
       [ "sangsu"; "tukkomi" ]);
  check navigation "empty roster preserves the unavailable message target"
    (Selection.Message_keeper { keeper_name = "seongsu"; cursor = 0 })
    (reconcile [ "sangsu"; "seongsu" ]
       (Selection.Message_keeper { keeper_name = "seongsu"; cursor = 1 })
       [])

let test_pathological_cursors_are_total () =
  check navigation "negative list cursor normalizes to zero"
    (Selection.List_cursor 0)
    (reconcile [ "sangsu"; "seongsu" ] (Selection.List_cursor min_int)
       [ "sangsu"; "seongsu" ]);
  check navigation "oversized list cursor clamps to the last Keeper"
    (Selection.List_cursor 1)
    (reconcile [ "sangsu"; "seongsu" ] (Selection.List_cursor max_int)
       [ "sangsu"; "seongsu" ]);
  check navigation "retained detail identity overrides an invalid cursor"
    (Selection.Detail_keeper { keeper_name = "seongsu"; cursor = 1 })
    (reconcile [ "sangsu"; "seongsu" ]
       (Selection.Detail_keeper { keeper_name = "seongsu"; cursor = min_int })
       [ "sangsu"; "seongsu" ]);
  check navigation "missing logs clamp an oversized cursor"
    (Selection.List_cursor 1)
    (reconcile [ "sangsu"; "seongsu" ]
       (Selection.Logs_keeper { keeper_name = "missing"; cursor = max_int })
       [ "sangsu"; "seongsu" ]);
  check navigation "missing message target clamps a negative cursor"
    (Selection.Message_keeper { keeper_name = "missing"; cursor = 0 })
    (reconcile [ "sangsu"; "seongsu" ]
       (Selection.Message_keeper { keeper_name = "missing"; cursor = min_int })
       [ "sangsu"; "seongsu" ])

let () =
  run "tui_keeper_selection"
    [ ( "selection identity"
      , [ test_case "list replacement" `Quick
            test_list_identity_across_replacement
        ; test_case "detail and logs replacement" `Quick
            test_detail_and_logs_identity_across_replacement
        ; test_case "message unavailable recovery" `Quick
            test_message_target_survives_unavailability
        ; test_case "pathological cursors" `Quick
            test_pathological_cursors_are_total
        ] )
    ]
