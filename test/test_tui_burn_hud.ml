(* What /burn puts at the right of the tab row. It read "[HUD $0.00   ]":
   the widget's name in brackets, and blank bars when nothing was spent. *)

let fresh () =
  Masc_tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()

let test_hidden_says_nothing () =
  Alcotest.(check (option string)) "hidden" None
    (Masc_tui_render_prim.burn_hud_text (fresh ()))

(* #38717: the cost is keeper-costs' 24h reading in the Team title's words.
   It was each Keeper's lifetime float added up, which took a turn with no
   price as $0, so an unread or unpriced fleet read "$0.00". *)
let test_an_unread_cost_is_not_zero () =
  let state = fresh () in
  state.Masc_tui_types.burn_hud_visible <- true;
  Alcotest.(check (option string)) "not read yet, never $0.00"
    (Some "cost not read yet")
    (Masc_tui_render_prim.burn_hud_text state)

let reading ~keepers =
  Masc_tui_types.Cost_read
    { Masc.Tui_decode.kcs_window_minutes = 24 * 60
    ; kcs_keepers = keepers
    ; kcs_keepers_unread = []
    ; kcs_cache = Masc.Tui_decode.Keeper_costs_fresh
    }

let row ?(unreported = 0) cost : Masc.Tui_decode.keeper_cost_row =
  { kc_keeper_name = "k"
  ; kc_cost = cost
  ; kc_unreported_samples = unreported
  ; kc_unread_samples = 0
  ; kc_metrics_read =
      Masc.Tui_decode.Metrics_read { malformed_rows = 0; unread_turn_rows = 0 }
  }

let test_the_cost_says_floor_and_unknown () =
  let state = fresh () in
  state.Masc_tui_types.burn_hud_visible <- true;
  state.overview_cost <-
    reading ~keepers:[ row ~unreported:3 Masc.Tui_decode.Cost_not_reported ];
  Alcotest.(check (option string)) "a subscription fleet" (Some "cost unknown 24h")
    (Masc_tui_render_prim.burn_hud_text state);
  state.overview_cost <-
    reading
      ~keepers:
        [ row ~unreported:1 (Masc.Tui_decode.Cost_reported { usd = 1.5; samples = 2 }) ];
  Alcotest.(check (option string)) "some turns unpriced" (Some "at least $1.50 24h")
    (Masc_tui_render_prim.burn_hud_text state)

let () =
  Alcotest.run "tui_burn_hud"
    [ ( "burn hud"
      , [ Alcotest.test_case "hidden says nothing" `Quick test_hidden_says_nothing
        ; Alcotest.test_case "an unread cost is not zero" `Quick
            test_an_unread_cost_is_not_zero
        ; Alcotest.test_case "the cost says floor and unknown" `Quick
            test_the_cost_says_floor_and_unknown
        ] )
    ]
