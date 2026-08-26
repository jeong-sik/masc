(* A keypress that finds nothing under the cursor has to say so. Both gates
   returned unit, so pressing the key with an empty or stale roster looked
   identical to a key that does nothing -- and one of them is the only way to
   reach keeper settings from the TUI.

   Asserted as source structure rather than behaviour: the handlers live inside
   the event loop and take the terminal, so reaching them from a test would
   mean standing up the loop. What can be pinned is that the [None] arm reaches
   [add_event] instead of falling through. *)

let tui = "bin/masc_tui.ml"

(* Counting [add_event] calls does not answer this: both handlers already report
   other outcomes, so the count stays positive with the [None] arm silent again.
   Measured -- that version of this test passed the mutation. What identifies
   the arm is the message it says, which is a named constant both gates share. *)
let reports ~binding =
  Ast_grep.count_identifiers_outside_calls_in_value_binding ~module_path:tui
    ~binding_name:binding ~callees:[] ~identifiers:[ "no_keeper_under_cursor" ]

let test_the_action_gate_reports () =
  Alcotest.(check bool)
    "handle_keeper_action tells the operator when no keeper is selected" true
    (reports ~binding:"handle_keeper_action" > 0)

let test_the_settings_gate_reports () =
  Alcotest.(check bool)
    "handle_keeper_settings_edit tells the operator when no keeper is selected"
    true
    (reports ~binding:"handle_keeper_settings_edit" > 0)

(* The background refresh is deliberately left silent: nothing was pressed, so
   there is nobody to answer. Pinned so that "make every None arm speak" does
   not sweep it in later. *)
let test_the_background_refresh_stays_silent () =
  Alcotest.(check int)
    "refresh_keeper_detail_selection does not report an empty roster" 0
    (reports ~binding:"refresh_keeper_detail_selection")

let () =
  Alcotest.run "masc_tui_keypress_gates"
    [ ( "gates"
      , [ Alcotest.test_case "the action gate reports" `Quick
            test_the_action_gate_reports
        ; Alcotest.test_case "the settings gate reports" `Quick
            test_the_settings_gate_reports
        ; Alcotest.test_case "the background refresh stays silent" `Quick
            test_the_background_refresh_stays_silent
        ] )
    ]
