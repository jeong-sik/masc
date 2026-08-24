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

let pp_message_switch formatter = function
  | Selection.No_alternative -> Format.pp_print_string formatter "No_alternative"
  | Selection.Switch_to { keeper_name; cursor } ->
      Format.fprintf formatter "Switch_to { keeper_name = %S; cursor = %d }"
        keeper_name cursor

let message_switch = testable pp_message_switch ( = )

let reconcile current_ids current next_ids =
  Selection.reconcile ~current_ids ~next_ids ~current

let test_list_identity_across_replacement () =
  check navigation "haneul moves to index 2" (Selection.List_cursor 2)
    (reconcile [ "haneul"; "seongsu"; "tukkomi" ]
       (Selection.List_cursor 0)
       [ "seongsu"; "tukkomi"; "haneul" ]);
  check navigation "missing selected Keeper keeps a bounded cursor"
    (Selection.List_cursor 1)
    (reconcile [ "haneul"; "seongsu"; "tukkomi" ]
       (Selection.List_cursor 1)
       [ "haneul"; "tukkomi" ])

let test_detail_and_logs_identity_across_replacement () =
  check navigation "detail keeps its Keeper and reindexes"
    (Selection.Detail_keeper { keeper_name = "seongsu"; cursor = 2 })
    (reconcile [ "haneul"; "seongsu"; "tukkomi" ]
       (Selection.Detail_keeper { keeper_name = "seongsu"; cursor = 0 })
       [ "tukkomi"; "haneul"; "seongsu" ]);
  check navigation "logs keep their Keeper and reindex"
    (Selection.Logs_keeper { keeper_name = "tukkomi"; cursor = 0 })
    (reconcile [ "haneul"; "seongsu"; "tukkomi" ]
       (Selection.Logs_keeper { keeper_name = "tukkomi"; cursor = 1 })
       [ "tukkomi"; "haneul"; "seongsu" ]);
  check navigation "missing detail returns to the list"
    (Selection.List_cursor 1)
    (reconcile [ "haneul"; "seongsu"; "tukkomi" ]
       (Selection.Detail_keeper { keeper_name = "seongsu"; cursor = 1 })
       [ "haneul"; "tukkomi" ]);
  check navigation "missing logs return to the list"
    (Selection.List_cursor 0)
    (reconcile [ "haneul"; "seongsu" ]
       (Selection.Logs_keeper { keeper_name = "seongsu"; cursor = 1 })
       [])

let test_message_target_survives_unavailability () =
  check navigation "explicit target reindexes even if absent from the old roster"
    (Selection.Message_keeper { keeper_name = "new-keeper"; cursor = 1 })
    (reconcile [ "haneul" ]
       (Selection.Message_keeper { keeper_name = "new-keeper"; cursor = 0 })
       [ "haneul"; "new-keeper" ]);
  check navigation "missing target stays in message mode with a bounded cursor"
    (Selection.Message_keeper { keeper_name = "seongsu"; cursor = 1 })
    (reconcile [ "haneul"; "seongsu"; "tukkomi" ]
       (Selection.Message_keeper { keeper_name = "seongsu"; cursor = 2 })
       [ "haneul"; "tukkomi" ]);
  check navigation "empty roster preserves the unavailable message target"
    (Selection.Message_keeper { keeper_name = "seongsu"; cursor = 0 })
    (reconcile [ "haneul"; "seongsu" ]
       (Selection.Message_keeper { keeper_name = "seongsu"; cursor = 1 })
       [])

let test_pathological_cursors_are_total () =
  check navigation "negative list cursor normalizes to zero"
    (Selection.List_cursor 0)
    (reconcile [ "haneul"; "seongsu" ] (Selection.List_cursor min_int)
       [ "haneul"; "seongsu" ]);
  check navigation "oversized list cursor clamps to the last Keeper"
    (Selection.List_cursor 1)
    (reconcile [ "haneul"; "seongsu" ] (Selection.List_cursor max_int)
       [ "haneul"; "seongsu" ]);
  check navigation "retained detail identity overrides an invalid cursor"
    (Selection.Detail_keeper { keeper_name = "seongsu"; cursor = 1 })
    (reconcile [ "haneul"; "seongsu" ]
       (Selection.Detail_keeper { keeper_name = "seongsu"; cursor = min_int })
       [ "haneul"; "seongsu" ]);
  check navigation "missing logs clamp an oversized cursor"
    (Selection.List_cursor 1)
    (reconcile [ "haneul"; "seongsu" ]
       (Selection.Logs_keeper { keeper_name = "missing"; cursor = max_int })
       [ "haneul"; "seongsu" ]);
  check navigation "missing message target clamps a negative cursor"
    (Selection.Message_keeper { keeper_name = "missing"; cursor = 0 })
    (reconcile [ "haneul"; "seongsu" ]
       (Selection.Message_keeper { keeper_name = "missing"; cursor = min_int })
       [ "haneul"; "seongsu" ])

let test_message_switch_wraps_and_recovers () =
  let next current_keeper keeper_ids =
    Selection.next_message_target ~current_keeper ~keeper_ids
  in
  check message_switch "an empty roster has no destination"
    Selection.No_alternative (next "alpha" []);
  check message_switch "one current Keeper has no alternative"
    Selection.No_alternative (next "alpha" [ "alpha" ]);
  check message_switch "a missing current Keeper recovers to the first row"
    (Selection.Switch_to { keeper_name = "alpha"; cursor = 0 })
    (next "missing" [ "alpha" ]);
  check message_switch "the next row is selected"
    (Selection.Switch_to { keeper_name = "beta"; cursor = 1 })
    (next "alpha" [ "alpha"; "beta"; "gamma" ]);
  check message_switch "the final row wraps to the first"
    (Selection.Switch_to { keeper_name = "alpha"; cursor = 0 })
    (next "gamma" [ "alpha"; "beta"; "gamma" ])

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
        ; test_case "message switch wraps and recovers" `Quick
            test_message_switch_wraps_and_recovers
        ] )
    ]
