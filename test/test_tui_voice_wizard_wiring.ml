(* The wizard's rules live in Voice_wizard and its session in Masc_tui_types,
   and both are tested where they live. Neither test can tell whether the
   screen ever draws the wizard or whether any key reaches it -- a helper that
   no dispatcher calls compiles, passes its own tests, and is dead.

   This repository has been caught by that shape three times: a footer built
   every frame and never shown, a key in the help table that ran nothing, and
   a key that ran but only half. So the claims here are made against the
   dispatcher, not against the help table. *)

let render = "bin/masc_tui_render.ml"
let tui = "bin/masc_tui.ml"

let calls ~module_path ~binding_name ~callee =
  Ast_grep.count_calls_in_value_binding ~module_path ~binding_name ~callee

let reached module_path binding_name callee =
  Alcotest.(check bool)
    (Printf.sprintf "%s calls %s" binding_name callee)
    true
    (calls ~module_path ~binding_name ~callee > 0)

(* Without this the wizard is drawn by nobody: the pane keeps listing
   endpoints while a session sits open behind it. *)
let test_the_voice_pane_hands_over_to_the_wizard () =
  reached render "render_voice" "render_voice_wizard"

(* The counter says "step N of M". Computing M from the step list is what makes
   a new step move the counter rather than making the counter lie. *)
let test_the_step_counter_is_computed_from_the_step_list () =
  reached render "render_voice_wizard" "Voice_wizard.steps"

(* The review either offers to save or says what is missing. Asking gaps is
   what makes those the same answer. *)
let test_the_review_asks_what_is_missing () =
  reached render "render_voice_wizard" "Voice_wizard.gaps"

(* The starting addresses are only useful if they are on the screen where the
   address is asked for. *)
let test_the_starting_addresses_reach_the_screen () =
  reached render "render_voice_wizard" "Voice_wizard.suggested_addresses"

(* The prompts are Voice_wizard's words. Restating them in the renderer would
   let the two drift, and the screen would ask a question the state machine is
   not answering. *)
let test_the_prompts_come_from_the_state_machine () =
  reached render "render_voice_wizard" "Voice_wizard.step_prompt"

let test_e_opens_the_wizard () =
  reached tui "main" "Masc_tui_types.voice_wizard_open"

(* Every session mover the wizard has, checked for a key that reaches it. One
   of these being absent is exactly the shape that ships a step you can enter
   and cannot leave. *)
let movers =
  [ "Masc_tui_types.voice_wizard_next"
  ; "Masc_tui_types.voice_wizard_previous"
  ; "Masc_tui_types.voice_wizard_append"
  ; "Masc_tui_types.voice_wizard_backspace"
  ; "Masc_tui_types.voice_wizard_clear"
  ; "Masc_tui_types.voice_wizard_commit"
  ; "Masc_tui_types.voice_wizard_cycle_provider"
  ; "Masc_tui_types.voice_wizard_cycle_section"
  ]

let test_every_mover_has_a_key () = List.iter (fun mover -> reached tui "main" mover) movers

(* Writing a configuration is not the same as it answering. The save path asks
   the endpoints afterwards, and that ask is a separate call the compiler has
   no reason to keep. *)
let test_saving_is_followed_by_asking_the_endpoints () =
  Alcotest.(check bool)
    "the TUI has a probe launcher and a save launcher"
    true
    (Ast_grep.count_calls ~module_path:tui ~callee:"launch_voice_wizard_probe" > 0
     && Ast_grep.count_calls ~module_path:tui ~callee:"launch_voice_wizard_save" > 0)

let () =
  Alcotest.run
    "masc_tui_voice_wizard_wiring"
    [ ( "the screen"
      , [ Alcotest.test_case "the voice pane hands over to the wizard" `Quick
            test_the_voice_pane_hands_over_to_the_wizard
        ; Alcotest.test_case "the step counter is computed from the step list" `Quick
            test_the_step_counter_is_computed_from_the_step_list
        ; Alcotest.test_case "the review asks what is missing" `Quick
            test_the_review_asks_what_is_missing
        ; Alcotest.test_case "the starting addresses reach the screen" `Quick
            test_the_starting_addresses_reach_the_screen
        ; Alcotest.test_case "the prompts come from the state machine" `Quick
            test_the_prompts_come_from_the_state_machine
        ] )
    ; ( "the keys"
      , [ Alcotest.test_case "e opens the wizard" `Quick test_e_opens_the_wizard
        ; Alcotest.test_case "every mover has a key" `Quick test_every_mover_has_a_key
        ; Alcotest.test_case "saving is followed by asking the endpoints" `Quick
            test_saving_is_followed_by_asking_the_endpoints
        ] )
    ]
