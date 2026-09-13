(* The Resources pane's row for a list with nothing to draw. An answered read
   with no resources and a read not answered yet used to be the same empty
   list, and the pane said "(loading...)" to both. *)

let note = Masc_tui_types.resources_empty_note

let resource uri : Masc_tui_mcp.resource =
  { uri; name = uri; title = None; description = None; mime_type = None; size = None }

let test_unanswered_is_loading () =
  Alcotest.(check (option string)) "no answer yet" (Some " (loading\xe2\x80\xa6)") (note None)

let test_answered_empty_is_not_loading () =
  Alcotest.(check (option string)) "an answer with nothing in it" (Some " (no resources)")
    (note (Some []))

let test_rows_need_no_note () =
  Alcotest.(check (option string)) "rows to draw" None (note (Some [ resource "masc://a" ]))

let () =
  Alcotest.run "tui_resources_empty_note"
    [ ( "resources empty note"
      , [ Alcotest.test_case "unanswered is loading" `Quick test_unanswered_is_loading
        ; Alcotest.test_case "answered empty is not loading" `Quick
            test_answered_empty_is_not_loading
        ; Alcotest.test_case "rows need no note" `Quick test_rows_need_no_note
        ] )
    ]
