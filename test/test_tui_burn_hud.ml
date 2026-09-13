(* What /burn puts at the right of the tab row. It read "[HUD $0.00   ]":
   the widget's name in brackets, and blank bars when nothing was spent. *)

let fresh () =
  Masc_tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()

let test_hidden_says_nothing () =
  Alcotest.(check (option string)) "hidden" None
    (Masc_tui_render_prim.burn_hud_text (fresh ()))

let test_nothing_spent_is_the_cost_alone () =
  let state = fresh () in
  state.Masc_tui_types.burn_hud_visible <- true;
  Alcotest.(check (option string)) "the cost, no word and no blank bars"
    (Some "$0.00")
    (Masc_tui_render_prim.burn_hud_text state)

let () =
  Alcotest.run "tui_burn_hud"
    [ ( "burn hud"
      , [ Alcotest.test_case "hidden says nothing" `Quick test_hidden_says_nothing
        ; Alcotest.test_case "nothing spent is the cost alone" `Quick
            test_nothing_spent_is_the_cost_alone
        ] )
    ]
